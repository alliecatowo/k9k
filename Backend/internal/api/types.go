package api

import "time"

type Context struct {
	Name    string `json:"name"`
	Cluster string `json:"cluster"`
	User    string `json:"user"`
	Active  bool   `json:"active"`
}

type ResourceType struct {
	Group      string `json:"group"`
	Version    string `json:"version"`
	Resource   string `json:"resource"`
	Kind       string `json:"kind"`
	Namespaced bool   `json:"namespaced"`
	ShortNames []string `json:"shortNames"`
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

