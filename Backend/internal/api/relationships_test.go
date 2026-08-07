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

func TestRelationshipsRecursivelyConnectsOwnerChainFromBoundedInventory(t *testing.T) {
	deployment := relationshipFixture("apps/v1", "Deployment", "demo", "web", "deployment-uid", nil)
	replicaSet := relationshipFixture("apps/v1", "ReplicaSet", "demo", "web-6bd", "replicaset-uid", []any{map[string]any{"apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "uid": "deployment-uid"}})
	pod := relationshipFixture("v1", "Pod", "demo", "web-6bd-abc", "pod-uid", []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-6bd", "uid": "replicaset-uid"}})
	client := &fakeCluster{
		object: deployment,
		discovery: []ResourceType{
			{Group: "apps", Version: "v1", Resource: "deployments", Kind: "Deployment", Namespaced: true},
			{Group: "apps", Version: "v1", Resource: "replicasets", Kind: "ReplicaSet", Namespaced: true},
			{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		},
		list: []ResourceSummary{
			{APIVersion: "apps/v1", Kind: "ReplicaSet", Namespace: "demo", Name: "web-6bd", UID: "replicaset-uid", Raw: replicaSet.Object},
			{APIVersion: "v1", Kind: "Pod", Namespace: "demo", Name: "web-6bd-abc", UID: "pod-uid", Raw: pod.Object},
		},
	}
	graph, err := NewServer(client, nil, nil).relationships(t.Context(), resourceParams{GVR: "apps/v1/deployments", Namespace: "demo", Name: "web"})
	if err != nil {
		t.Fatalf("relationships: %v", err)
	}
	if len(graph.Nodes) != 3 {
		t.Fatalf("nodes = %#v", graph.Nodes)
	}
	if !hasRelationshipEdge(graph, "uid:deployment-uid", "uid:replicaset-uid", "owns") || !hasRelationshipEdge(graph, "uid:replicaset-uid", "uid:pod-uid", "owns") {
		t.Fatalf("recursive owner graph = %#v", graph.Edges)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.lists) == 0 || client.lists[0].limit != maxRelationshipCandidateItems {
		t.Fatalf("relationship inventory must use bounded pages, calls = %#v", client.lists)
	}
}

func TestRelationshipsReportsDepthTruncationInsteadOfClaimingCompleteness(t *testing.T) {
	objects := []*unstructured.Unstructured{
		relationshipFixture("apps/v1", "ReplicaSet", "demo", "node-0", "uid-0", nil),
		relationshipFixture("apps/v1", "ReplicaSet", "demo", "node-1", "uid-1", []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "node-0", "uid": "uid-0"}}),
		relationshipFixture("apps/v1", "ReplicaSet", "demo", "node-2", "uid-2", []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "node-1", "uid": "uid-1"}}),
		relationshipFixture("apps/v1", "ReplicaSet", "demo", "node-3", "uid-3", []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "node-2", "uid": "uid-2"}}),
		relationshipFixture("apps/v1", "ReplicaSet", "demo", "node-4", "uid-4", []any{map[string]any{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "node-3", "uid": "uid-3"}}),
	}
	list := make([]ResourceSummary, 0, len(objects)-1)
	for _, object := range objects[1:] {
		list = append(list, ResourceSummary{APIVersion: "apps/v1", Kind: "ReplicaSet", Namespace: "demo", Name: object.GetName(), UID: string(object.GetUID()), Raw: object.Object})
	}
	client := &fakeCluster{object: objects[0], discovery: []ResourceType{{Group: "apps", Version: "v1", Resource: "replicasets", Kind: "ReplicaSet", Namespaced: true}}, list: list}
	graph, err := NewServer(client, nil, nil).relationships(t.Context(), resourceParams{GVR: "apps/v1/replicasets", Namespace: "demo", Name: "node-0"})
	if err != nil {
		t.Fatalf("relationships: %v", err)
	}
	if !graph.Truncated || graph.MaxDepth != maxRelationshipDepth {
		t.Fatalf("graph must disclose the depth cap: %#v", graph)
	}
	if len(graph.Nodes) != maxRelationshipDepth+1 {
		t.Fatalf("nodes = %d, want root plus %d hops", len(graph.Nodes), maxRelationshipDepth)
	}
}

func relationshipFixture(apiVersion, kind, namespace, name, uid string, owners []any) *unstructured.Unstructured {
	metadata := map[string]any{"name": name, "namespace": namespace, "uid": uid}
	if len(owners) > 0 {
		metadata["ownerReferences"] = owners
	}
	return &unstructured.Unstructured{Object: map[string]any{"apiVersion": apiVersion, "kind": kind, "metadata": metadata}}
}

func hasRelationshipEdge(graph RelationshipGraph, from, to, relation string) bool {
	for _, edge := range graph.Edges {
		if edge.From == from && edge.To == to && edge.Relation == relation {
			return true
		}
	}
	return false
}
