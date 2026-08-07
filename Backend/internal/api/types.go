package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/tools/remotecommand"
)

// ErrManifestIdentityMismatch is returned when the object selected for an
// editor was deleted/recreated or otherwise no longer has its original UID.
var ErrManifestIdentityMismatch = errors.New("manifest identity no longer matches the selected resource")

type Context struct {
	Name      string `json:"name"`
	Cluster   string `json:"cluster"`
	User      string `json:"user"`
	Namespace string `json:"namespace,omitempty"`
	Active    bool   `json:"active"`
}

type ResourceType struct {
	Group      string   `json:"group"`
	Version    string   `json:"version"`
	Resource   string   `json:"resource"`
	Kind       string   `json:"kind"`
	Namespaced bool     `json:"namespaced"`
	ShortNames []string `json:"shortNames"`
}

// MarshalJSON keeps the cross-process contract Swift-friendly: Kubernetes
// discovery commonly supplies nil short names, but absence means an empty
// collection rather than a nullable field.
func (r ResourceType) MarshalJSON() ([]byte, error) {
	type wire ResourceType
	if r.ShortNames == nil {
		r.ShortNames = []string{}
	}
	return json.Marshal(wire(r))
}

type ResourceSummary struct {
	APIVersion string            `json:"apiVersion"`
	Kind       string            `json:"kind"`
	Namespace  string            `json:"namespace,omitempty"`
	Name       string            `json:"name"`
	UID        string            `json:"uid"`
	CreatedAt  time.Time         `json:"createdAt"`
	Age        string            `json:"age"`
	Status     string            `json:"status"`
	Labels     map[string]string `json:"labels,omitempty"`
	Raw        map[string]any    `json:"raw,omitempty"`
}

// RelationshipGraph is a bounded, read-only topology snapshot centred on one
// selected object. Nodes use stable object identity where Kubernetes provided
// a UID; unresolved references are retained rather than silently discarded.
type RelationshipGraph struct {
	RootID   string             `json:"rootID"`
	Nodes    []RelationshipNode `json:"nodes"`
	Edges    []RelationshipEdge `json:"edges"`
	Warnings []string           `json:"warnings"`
}

type RelationshipNode struct {
	ID         string `json:"id"`
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Namespace  string `json:"namespace,omitempty"`
	Name       string `json:"name"`
	UID        string `json:"uid,omitempty"`
	Status     string `json:"status,omitempty"`
	Resolved   bool   `json:"resolved"`
}

// RelationshipEdge is directed: from is the resource that owns, selects,
// routes to, or uses to. Relation is one of owner, owns, selects, routes, or
// uses and is intentionally descriptive rather than a Kubernetes API type.
type RelationshipEdge struct {
	From     string `json:"from"`
	To       string `json:"to"`
	Relation string `json:"relation"`
}

// ClusterEvent is a normalized Kubernetes Event, retaining the fields users
// need for diagnosis without exposing Swift to core/v1 API details.
type ClusterEvent struct {
	Namespace string    `json:"namespace"`
	Type      string    `json:"type"`
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Count     int32     `json:"count"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
	Source    string    `json:"source,omitempty"`
}

// MetricsQuery selects one metrics.k8s.io/v1beta1 collection. Resource is
// deliberately constrained to Kubernetes' two metrics resources: pods and
// nodes. An empty Name returns the collection; a non-empty Name returns the
// matching object when it exists.
type MetricsQuery struct {
	Version   string `json:"version"`
	Resource  string `json:"resource"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name,omitempty"`
}

// ContainerMetrics retains each container's reported resource quantities.
// Quantities stay as canonical Kubernetes strings (for example "12m" and
// "128Mi") so the GUI does not lose precision by converting them to floats.
type ContainerMetrics struct {
	Name  string            `json:"name"`
	Usage map[string]string `json:"usage"`
}

// ResourceMetrics is the normalized shape used for both pod and node metrics.
// Pods expose a total Usage plus the individual Containers that contributed to
// it; node metrics have an empty Containers collection. Timestamp and Window
// describe the sampling interval supplied by Metrics Server.
type ResourceMetrics struct {
	APIVersion string             `json:"apiVersion"`
	Resource   string             `json:"resource"`
	Namespace  string             `json:"namespace,omitempty"`
	Name       string             `json:"name"`
	Timestamp  time.Time          `json:"timestamp"`
	Window     string             `json:"window"`
	Usage      map[string]string  `json:"usage"`
	Containers []ContainerMetrics `json:"containers"`
}

// MetricsUnavailableError distinguishes an uninstalled or unavailable
// metrics.k8s.io API from ordinary API failures such as authorization errors.
// The protocol maps it to a stable, non-fatal metrics_unavailable code so the
// GUI can continue displaying resources without fabricating utilization data.
type MetricsUnavailableError struct{ Err error }

func (e *MetricsUnavailableError) Error() string {
	if e == nil || e.Err == nil {
		return "Kubernetes metrics API is unavailable"
	}
	return fmt.Sprintf("Kubernetes metrics API is unavailable: %v", e.Err)
}

func (e *MetricsUnavailableError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// AccessCheck identifies one Kubernetes resource API action to evaluate for
// the identity represented by the selected kubeconfig context. It deliberately
// carries no subject fields: SelfSubjectAccessReview always asks about the
// current caller, never an impersonated user.
type AccessCheck struct {
	Verb        string `json:"verb"`
	Group       string `json:"group,omitempty"`
	Version     string `json:"version,omitempty"`
	Resource    string `json:"resource"`
	Subresource string `json:"subresource,omitempty"`
	Namespace   string `json:"namespace,omitempty"`
	Name        string `json:"name,omitempty"`
}

// AccessReview is the normalized SelfSubjectAccessReview result. A false
// Allowed value is meaningful even when Denied is false: an authorizer can
// have no opinion. EvaluationError is returned by Kubernetes when it could not
// completely evaluate the review.
type AccessReview struct {
	Allowed         bool   `json:"allowed"`
	Denied          bool   `json:"denied"`
	Reason          string `json:"reason,omitempty"`
	EvaluationError string `json:"evaluationError,omitempty"`
}

// NodeDrainRequest is the deliberately narrow drain contract exposed to the
// native client. K9k never force-deletes Pods during a drain: eviction honors
// PodDisruptionBudgets and any individual failure is reported in the result.
// DaemonSet and mirror Pods are left in place by Kubernetes drain semantics.
type NodeDrainRequest struct {
	Node               string `json:"node"`
	IgnoreDaemonSets   bool   `json:"ignoreDaemonSets"`
	DeleteEmptyDirData bool   `json:"deleteEmptyDirData"`
}

// NodeDrainResult retains every decision so the GUI can distinguish an
// eviction accepted by the API server from Pods that were intentionally left
// behind or blocked by policy.
type NodeDrainResult struct {
	Node     string         `json:"node"`
	Evicted  []NodeDrainPod `json:"evicted"`
	Skipped  []NodeDrainPod `json:"skipped"`
	Blocked  []NodeDrainPod `json:"blocked"`
	Failures []NodeDrainPod `json:"failures"`
}

type NodeDrainPod struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Reason    string `json:"reason"`
}

// PortForwardRequest describes one pod port-forward owned by the helper. The
// local address is always loopback-only; K9k deliberately never turns a pod
// port into a network-reachable listener without an explicit Kubernetes
// Service or Ingress.
type PortForwardRequest struct {
	Namespace    string `json:"namespace"`
	Pod          string `json:"pod"`
	LocalPort    int    `json:"localPort"`
	RemotePort   int    `json:"remotePort"`
	LocalAddress string `json:"localAddress"`
}

// PortForwardBinding is emitted once the API-server tunnel is established and
// the OS has reserved a local TCP port. LocalPort can differ from the request
// when the caller requested port zero.
type PortForwardBinding struct {
	Namespace    string `json:"namespace"`
	Pod          string `json:"pod"`
	LocalAddress string `json:"localAddress"`
	LocalPort    int    `json:"localPort"`
	RemotePort   int    `json:"remotePort"`
}

// PodExecRequest describes a single command run inside an existing container.
// Command is an argv array, never a shell fragment: the helper sends it to the
// Kubernetes pods/exec API unchanged and does not invoke a local shell.
type PodExecRequest struct {
	Namespace string   `json:"namespace"`
	Pod       string   `json:"pod"`
	Container string   `json:"container,omitempty"`
	Command   []string `json:"command"`
	Stdin     bool     `json:"stdin"`
	TTY       bool     `json:"tty"`
	Attach    bool     `json:"attach,omitempty"`
}

// PodExecStreams are the byte-oriented endpoints of an exec session. stdout
// and stderr deliberately remain separate when TTY is false; a TTY combines
// them according to Kubernetes remotecommand semantics.
type PodExecStreams struct {
	Stdin             io.Reader
	Stdout            io.Writer
	Stderr            io.Writer
	TerminalSizeQueue remotecommand.TerminalSizeQueue
}

// ManifestIdentity pins an editor session to the exact object that was opened.
// UID is deliberately included: a name can be deleted and recreated while an
// editor is open, and applying to that replacement would be surprising.
type ManifestIdentity struct {
	Group      string `json:"group,omitempty"`
	Version    string `json:"version"`
	Resource   string `json:"resource"`
	Namespaced bool   `json:"namespaced"`
	Namespace  string `json:"namespace,omitempty"`
	Name       string `json:"name"`
	UID        string `json:"uid"`
	Kind       string `json:"kind"`
}

// ManifestDocument is an editor-safe representation of a selected Kubernetes
// object. YAML excludes server-managed metadata and status while Identity
// carries the immutable selection guard required for an update.
type ManifestDocument struct {
	Identity ManifestIdentity `json:"identity"`
	YAML     string           `json:"yaml"`
}

// ManifestApplyRequest crosses into the direct client-go layer only after the
// protocol has parsed YAML and checked identity. DryRun invokes Kubernetes
// admission/defaulting without persisting anything.
type ManifestApplyRequest struct {
	Identity ManifestIdentity
	Object   *unstructured.Unstructured
	DryRun   bool
}
