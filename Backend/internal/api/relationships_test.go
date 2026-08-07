package api

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestServerRelationshipsGetReturnsOwnerAndDeclaredDependencies(t *testing.T) {
	client := &fakeCluster{object: &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{
			"name": "web", "namespace": "demo", "uid": "pod-uid",
			"ownerReferences": []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-rs", "uid": "rs-uid"}},
		},
		"spec": map[string]any{
			"serviceAccountName": "runner",
			"volumes":            []any{map[string]any{"configMap": map[string]any{"name": "settings"}}},
		},
	}}}
	responses := runRequests(t, client, request("relationships", "relationships.get", map[string]any{"gvr": "v1/pods", "namespace": "demo", "name": "web"}))
	graph := decodeResult[RelationshipGraph](t, envelopeByID(t, responses, "relationships").Result)
	if graph.RootID != "uid:pod-uid" || len(graph.Nodes) != 4 {
		t.Fatalf("graph = %#v", graph)
	}
	relations := map[string]int{}
	for _, edge := range graph.Edges {
		relations[edge.Relation]++
	}
	if relations["owner"] != 1 || relations["uses"] != 2 {
		t.Errorf("edges = %#v", graph.Edges)
	}
}

func TestObjectReferencesExtractsCommonPodDependencies(t *testing.T) {
	object := map[string]any{"spec": map[string]any{
		"serviceAccountName": "runner",
		"volumes": []any{
			map[string]any{"configMap": map[string]any{"name": "settings"}},
			map[string]any{"secret": map[string]any{"secretName": "credentials"}},
			map[string]any{"persistentVolumeClaim": map[string]any{"claimName": "cache"}},
		},
		"containers": []any{map[string]any{"env": []any{map[string]any{"valueFrom": map[string]any{"secretKeyRef": map[string]any{"name": "credentials"}}}}}},
	}}
	refs := objectReferences(object, "demo")
	want := map[string]bool{"ConfigMap/settings": true, "Secret/credentials": true, "PersistentVolumeClaim/cache": true, "ServiceAccount/runner": true}
	if len(refs) != len(want) {
		t.Fatalf("reference count = %d, want %d: %#v", len(refs), len(want), refs)
	}
	for _, ref := range refs {
		key := ref.Kind + "/" + ref.Name
		if !want[key] {
			t.Errorf("unexpected reference %q", key)
		}
		delete(want, key)
	}
	for key := range want {
		t.Errorf("missing reference %q", key)
	}
}

func TestSelectorsMatchServiceAndWorkloadSelectors(t *testing.T) {
	labels := map[string]string{"app": "web", "tier": "frontend"}
	if !selectorsMatch(map[string]any{"spec": map[string]any{"selector": map[string]any{"app": "web"}}}, labels) {
		t.Fatal("service selector did not match")
	}
	if !selectorsMatch(map[string]any{"spec": map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"app": "web", "tier": "frontend"}}}}, labels) {
		t.Fatal("workload matchLabels did not match")
	}
	if selectorsMatch(map[string]any{"spec": map[string]any{"selector": map[string]any{"app": "other"}}}, labels) {
		t.Fatal("mismatched selector unexpectedly matched")
	}
}
