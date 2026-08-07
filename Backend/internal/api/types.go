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

// KubeconfigReference is a name-only relationship from a context to either a
// Cluster or AuthInfo kubeconfig entry. It intentionally excludes the entry's
// contents: server URLs, certificate data, tokens, exec configuration, and
// every other credential-bearing field remain inside kubeconfig.
type KubeconfigReference struct {
	Name   string   `json:"name"`
	Exists bool     `json:"exists"`
	UsedBy []string `json:"usedBy"`
}

// KubeconfigDiagnostic describes a structural kubeconfig issue that can be
// safely shown in the native settings UI. It contains only names and
// relationship state, never endpoint or authentication material.
type KubeconfigDiagnostic struct {
	Code     string `json:"code"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
}

// KubeconfigContextInspection is a read-only, credential-free view of one
// context and the named Cluster/AuthInfo entries it references. UsedBy helps
// an operator see shared references before changing any context metadata.
type KubeconfigContextInspection struct {
	Context     *Context               `json:"context,omitempty"`
	Cluster     KubeconfigReference    `json:"cluster"`
	AuthInfo    KubeconfigReference    `json:"authInfo"`
	Diagnostics []KubeconfigDiagnostic `json:"diagnostics"`
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
	APIVersion      string            `json:"apiVersion"`
	Kind            string            `json:"kind"`
	Namespace       string            `json:"namespace,omitempty"`
	Name            string            `json:"name"`
	UID             string            `json:"uid"`
	ResourceVersion string            `json:"resourceVersion,omitempty"`
	CreatedAt       time.Time         `json:"createdAt"`
	Age             string            `json:"age"`
	Status          string            `json:"status"`
	Labels          map[string]string `json:"labels,omitempty"`
	Columns         map[string]string `json:"columns,omitempty"`
	Raw             map[string]any    `json:"raw,omitempty"`
}

// ResourceListQuery is the bounded, continuation-aware read shape used by
// resource.listPage. It deliberately keeps the browser projection separate
// from a selected object's full raw representation.
type ResourceListQuery struct {
	Selector      string
	FieldSelector string
	Limit         int64
	Continue      string
	Columns       []string
	// IncludeRaw is reserved for bounded internal consumers such as XRay. It
	// is intentionally not exposed by resource.listPage: normal browser lists
	// must stay lean and hydrate one selected object at a time.
	IncludeRaw bool
}

// ResourceListPage is an additive v1 protocol response. ResourceVersion is
// the exact list snapshot revision callers must pass into resource.watch to
// avoid the list-to-watch event-loss window.
type ResourceListPage struct {
	Items              []ResourceSummary `json:"items"`
	ResourceVersion    string            `json:"resourceVersion"`
	Continue           string            `json:"continue,omitempty"`
	RemainingItemCount *int64            `json:"remainingItemCount,omitempty"`
}

// RolloutHistoryRequest names one exact workload object. ExpectedUID prevents
// a stale inspector from browsing revisions for a delete/recreate replacement.
type RolloutHistoryRequest struct {
	Group       string `json:"group"`
	Version     string `json:"version"`
	Resource    string `json:"resource"`
	Namespace   string `json:"namespace"`
	Name        string `json:"name"`
	ExpectedUID string `json:"expectedUID"`
}

// RolloutHistory is deliberately metadata-only. Historical templates can
// contain credentials and are not needed to review the identity/status of a
// revision before the separately guarded deployment rollback operation.
type RolloutHistory struct {
	WorkloadKind    string            `json:"workloadKind"`
	WorkloadName    string            `json:"workloadName"`
	Namespace       string            `json:"namespace"`
	CurrentRevision string            `json:"currentRevision,omitempty"`
	UpdatedRevision string            `json:"updatedRevision,omitempty"`
	Revisions       []RolloutRevision `json:"revisions"`
	Truncated       bool              `json:"truncated"`
}

type RolloutRevision struct {
	Kind             string    `json:"kind"`
	Name             string    `json:"name"`
	UID              string    `json:"uid"`
	Revision         string    `json:"revision,omitempty"`
	CreatedAt        time.Time `json:"createdAt"`
	Age              string    `json:"age"`
	Status           string    `json:"status"`
	Active           bool      `json:"active"`
	RollbackEligible bool      `json:"rollbackEligible"`
}

// HelmReleaseHistory is a bounded, metadata-only view of a Helm v3 release's
// standard Secret storage. Helm records one Secret per revision and exposes
// release name, revision, and lifecycle state in labels. Keeping this surface
// metadata-only means K9k can present useful history without decoding the
// opaque release payload (which may contain chart values and rendered
// manifests).
type HelmReleaseHistory struct {
	Release   string                `json:"release"`
	Namespace string                `json:"namespace,omitempty"`
	Revisions []HelmReleaseRevision `json:"revisions"`
	Total     int                   `json:"total"`
	Truncated bool                  `json:"truncated"`
}

// HelmReleaseRevision identifies one Helm storage Secret. Revision zero is
// reserved for malformed legacy storage where Helm did not provide a numeric
// version label; it is shown after valid revisions rather than discarded.
type HelmReleaseRevision struct {
	Revision    int       `json:"revision"`
	Status      string    `json:"status"`
	StorageName string    `json:"storageName"`
	CreatedAt   time.Time `json:"createdAt"`
	Age         string    `json:"age"`
}

// HelmReleaseInspection is a bounded, read-only projection of one revision
// stored by Helm's default v3 Secret driver. Chart metadata is returned by
// default. The release manifest, rendered NOTES, and user-supplied values are
// deliberately omitted unless the caller explicitly acknowledges they may
// contain credentials or other production-sensitive material.
type HelmReleaseInspection struct {
	Release                   string                 `json:"release"`
	Namespace                 string                 `json:"namespace"`
	Revision                  HelmReleaseRevision    `json:"revision"`
	Chart                     HelmChartMetadata      `json:"chart"`
	SensitiveContentAvailable bool                   `json:"sensitiveContentAvailable"`
	Sensitive                 *HelmSensitiveContents `json:"sensitive,omitempty"`
}

// HelmChartMetadata is intentionally the public Chart.yaml metadata rather
// than Helm's complete Chart archive. Templates, embedded files, and chart
// default values are not exported from the storage payload.
type HelmChartMetadata struct {
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	AppVersion  string   `json:"appVersion,omitempty"`
	APIVersion  string   `json:"apiVersion,omitempty"`
	Description string   `json:"description,omitempty"`
	Type        string   `json:"type,omitempty"`
	Home        string   `json:"home,omitempty"`
	Icon        string   `json:"icon,omitempty"`
	KubeVersion string   `json:"kubeVersion,omitempty"`
	Deprecated  bool     `json:"deprecated"`
	Sources     []string `json:"sources"`
	Keywords    []string `json:"keywords"`
}

// HelmSensitiveContents is returned only after an explicit acknowledgement.
// Every field is independently bounded and may be marked truncated, so a
// compressed release Secret cannot turn into an unbounded IPC payload.
type HelmSensitiveContents struct {
	Warning           string `json:"warning"`
	Manifest          string `json:"manifest,omitempty"`
	ManifestTruncated bool   `json:"manifestTruncated"`
	Notes             string `json:"notes,omitempty"`
	NotesTruncated    bool   `json:"notesTruncated"`
	ValuesJSON        string `json:"valuesJSON,omitempty"`
	ValuesTruncated   bool   `json:"valuesTruncated"`
}

// HelmRollbackRequest pins both ends of a Helm rollback. TargetRevision is
// the historical revision to restore, while ExpectedRevision identifies the
// release state the operator actually reviewed. The storage names make a
// delete/recreate or a racing Helm upgrade fail before the SDK runs.
type HelmRollbackRequest struct {
	Namespace           string `json:"namespace"`
	Release             string `json:"release"`
	TargetStorageName   string `json:"targetStorageName"`
	TargetRevision      int    `json:"targetRevision"`
	ExpectedStorageName string `json:"expectedStorageName"`
	ExpectedRevision    int    `json:"expectedRevision"`
}

type HelmRollbackResult struct {
	Namespace      string `json:"namespace"`
	Release        string `json:"release"`
	TargetRevision int    `json:"targetRevision"`
	Message        string `json:"message"`
}

// HelmUninstallRequest retains release storage history by default. The
// expected storage revision is never treated as a generic Secret identifier:
// the server revalidates that it is the current Secret for this exact Helm
// release before invoking the Helm SDK.
type HelmUninstallRequest struct {
	Namespace           string `json:"namespace"`
	Release             string `json:"release"`
	ExpectedStorageName string `json:"expectedStorageName"`
	ExpectedRevision    int    `json:"expectedRevision"`
}

type HelmUninstallResult struct {
	Namespace   string `json:"namespace"`
	Release     string `json:"release"`
	KeepHistory bool   `json:"keepHistory"`
	Info        string `json:"info,omitempty"`
	Message     string `json:"message"`
}

// HelmUpgradeRequest accepts only a bounded, explicitly selected packaged
// chart archive. K9k deliberately does not fetch HTTP/OCI repositories or
// inherit a Helm repository credential store from a GUI action.
type HelmUpgradeRequest struct {
	Namespace           string `json:"namespace"`
	Release             string `json:"release"`
	ExpectedStorageName string `json:"expectedStorageName"`
	ExpectedRevision    int    `json:"expectedRevision"`
	ChartArchiveBase64  string `json:"chartArchiveBase64"`
	ValuesYAML          string `json:"valuesYAML,omitempty"`
	ValuesMode          string `json:"valuesMode"`
	PlanDigest          string `json:"planDigest,omitempty"`
}

// HelmUpgradePlan is sensitive by design: rendered manifests and values can
// include credentials. The server returns it only after acknowledgement and
// bounds the manifest before it crosses the helper IPC boundary.
type HelmUpgradePlan struct {
	Namespace      string `json:"namespace"`
	Release        string `json:"release"`
	ChartName      string `json:"chartName"`
	ChartVersion   string `json:"chartVersion"`
	ValuesMode     string `json:"valuesMode"`
	PlanDigest     string `json:"planDigest"`
	Manifest       string `json:"manifest"`
	ManifestDigest string `json:"manifestDigest"`
	Notes          string `json:"notes,omitempty"`
	NextRevision   int    `json:"nextRevision"`
}

type HelmUpgradeResult struct {
	Namespace string `json:"namespace"`
	Release   string `json:"release"`
	Revision  int    `json:"revision"`
	Message   string `json:"message"`
}

// HelmRepositoryInspection intentionally contains only public repository
// metadata. Credentials, TLS paths, auth headers, and registry config are
// never accepted by this protocol, let alone returned to Swift.
type HelmRepositoryInspection struct {
	Repositories []HelmRepositorySource `json:"repositories"`
	Warnings     []string               `json:"warnings"`
}

type HelmRepositorySource struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// RelationshipGraph is a bounded, read-only topology snapshot centred on one
// selected object. Nodes use stable object identity where Kubernetes provided
// a UID; unresolved references are retained rather than silently discarded.
type RelationshipGraph struct {
	RootID   string             `json:"rootID"`
	Nodes    []RelationshipNode `json:"nodes"`
	Edges    []RelationshipEdge `json:"edges"`
	Warnings []string           `json:"warnings"`
	// Truncated is true when a deliberately finite XRay safety bound was hit.
	// A partial graph is still useful, but must never masquerade as complete.
	Truncated bool `json:"truncated"`
	MaxDepth  int  `json:"maxDepth"`
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

// EffectiveRBACRequest asks K9k to explain the RBAC objects that directly
// mention one subject. It is intentionally a static, read-only inspection: it
// never impersonates the subject or claims to be an authorization decision.
// BindingNamespace narrows User/Group inspection to one namespace when set.
type EffectiveRBACRequest struct {
	SubjectKind      string `json:"subjectKind"`
	SubjectName      string `json:"subjectName"`
	SubjectNamespace string `json:"subjectNamespace,omitempty"`
	BindingNamespace string `json:"bindingNamespace,omitempty"`
}

// EffectiveRBACAnalysis is a bounded snapshot of direct RoleBinding and
// ClusterRoleBinding declarations. The API server's authorizer remains the
// only authority for an actual allow/deny decision (rbac.check).
type EffectiveRBACAnalysis struct {
	Subject   EffectiveRBACSubject   `json:"subject"`
	Bindings  []EffectiveRBACBinding `json:"bindings"`
	Warnings  []string               `json:"warnings"`
	Truncated bool                   `json:"truncated"`
}

type EffectiveRBACSubject struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// EffectiveRBACBinding retains only the fields needed to explain one direct
// grant. Rules are copies of the referenced Role/ClusterRole rules and do not
// evaluate external authorizers, admission policy, or group membership.
type EffectiveRBACBinding struct {
	Kind         string              `json:"kind"`
	Name         string              `json:"name"`
	Namespace    string              `json:"namespace,omitempty"`
	RoleKind     string              `json:"roleKind"`
	RoleName     string              `json:"roleName"`
	Rules        []EffectiveRBACRule `json:"rules"`
	RoleResolved bool                `json:"roleResolved"`
	Warning      string              `json:"warning,omitempty"`
}

type EffectiveRBACRule struct {
	APIGroups       []string `json:"apiGroups"`
	Resources       []string `json:"resources"`
	Verbs           []string `json:"verbs"`
	ResourceNames   []string `json:"resourceNames"`
	NonResourceURLs []string `json:"nonResourceURLs"`
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

// NodeShellTarget is a verified, existing DaemonSet Pod on one node. K9k
// intentionally never guesses a debug image, selector, or host mount for a
// node shell: the operator configures a trusted DaemonSet and container, then
// this target binds the terminal to the exact Pod Kubernetes reports for the
// selected node.
type NodeShellTarget struct {
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	DaemonSet string `json:"daemonSet"`
	Pod       string `json:"pod"`
	Container string `json:"container"`
}

// PodDebugRequest creates one ephemeral debugging container in an existing
// Pod. It intentionally contains no privileged/host settings; Kubernetes
// admission and the Pod's security policy remain authoritative.
type PodDebugRequest struct {
	Namespace       string   `json:"namespace"`
	Pod             string   `json:"pod"`
	TargetContainer string   `json:"targetContainer,omitempty"`
	Image           string   `json:"image"`
	Command         []string `json:"command"`
}

type PodDebugResult struct {
	Namespace string `json:"namespace"`
	Pod       string `json:"pod"`
	Container string `json:"container"`
	Image     string `json:"image"`
}

// CronJobTriggerRequest runs one immediate Job from a CronJob's configured
// job template. It is intentionally narrower than generic resource creation:
// callers can select the CronJob but cannot alter its workload template.
type CronJobTriggerRequest struct {
	Namespace string `json:"namespace"`
	CronJob   string `json:"cronJob"`
}

type CronJobTriggerResult struct {
	Namespace string `json:"namespace"`
	CronJob   string `json:"cronJob"`
	Job       string `json:"job"`
}

// DeploymentRollbackRequest restores a Deployment's pod template from a
// selected inactive ReplicaSet. The UID makes a stale row (deleted/recreated
// at the same name) fail safely instead of rolling back an unrelated object.
type DeploymentRollbackRequest struct {
	Namespace     string `json:"namespace"`
	ReplicaSet    string `json:"replicaSet"`
	ExpectedRSUID string `json:"expectedRSUID"`
}

type DeploymentRollbackResult struct {
	Namespace  string `json:"namespace"`
	Deployment string `json:"deployment"`
	ReplicaSet string `json:"replicaSet"`
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

// ManifestDiffResult compares the currently selected live object with the
// server-side-apply dry-run of an imported manifest.  Both documents are
// canonical editable YAML, so volatile metadata and status cannot create
// misleading changes.  The textual diff is deliberately accompanied by a
// structured change list for native clients that want to filter or render
// individual paths without parsing a patch format.
type ManifestDiffResult struct {
	Identity  ManifestIdentity     `json:"identity"`
	Live      ManifestDocument     `json:"live"`
	Preview   ManifestDocument     `json:"preview"`
	Diff      string               `json:"diff"`
	Changes   []ManifestDiffChange `json:"changes"`
	Changed   bool                 `json:"changed"`
	Truncated bool                 `json:"truncated"`
}

type ManifestDiffChange struct {
	Path      string `json:"path"`
	Operation string `json:"operation"`
	Live      string `json:"live,omitempty"`
	Preview   string `json:"preview,omitempty"`
}

// ManifestBatchDeleteResult describes a manifest-directory deletion preflight
// or a completed outcome. Kubernetes cannot transact arbitrary deletes, so a
// caller must always disclose that a later failure may follow earlier removes.
type ManifestBatchDeleteResult struct {
	Validated bool               `json:"validated"`
	Deleted   bool               `json:"deleted"`
	Items     []ManifestIdentity `json:"items"`
}

// ManifestApplyRequest crosses into the direct client-go layer only after the
// protocol has parsed YAML and checked identity. DryRun invokes Kubernetes
// admission/defaulting without persisting anything.
type ManifestApplyRequest struct {
	Identity ManifestIdentity
	Object   *unstructured.Unstructured
	DryRun   bool
	Create   bool
}
