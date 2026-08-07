package api

import (
	"encoding/json"
	"time"
)

type Context struct {
	Name    string `json:"name"`
	Cluster string `json:"cluster"`
	User    string `json:"user"`
	Active  bool   `json:"active"`
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
