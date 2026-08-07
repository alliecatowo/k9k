package api

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// relationships is deliberately bounded to the common workload and routing
// resources. It gives an XRay view useful production topology without issuing
// a cluster-wide list of every discovered CRD.
func (s *Server) relationships(ctx context.Context, params resourceParams) (RelationshipGraph, error) {
	root, err := s.cluster.Get(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced())
	if err != nil {
		return RelationshipGraph{}, err
	}
	graph := newRelationshipGraph(root)
	discovery, discoveryErr := s.cluster.Discovery(ctx)
	if discoveryErr != nil {
		graph.Warnings = append(graph.Warnings, "Could not resolve referenced kinds: "+discoveryErr.Error())
	}
	byKind := relationshipTypes(discovery)

	for _, owner := range root.GetOwnerReferences() {
		node := RelationshipNode{ID: relationshipID(owner.APIVersion, owner.Kind, root.GetNamespace(), owner.Name, string(owner.UID)), APIVersion: owner.APIVersion, Kind: owner.Kind, Namespace: root.GetNamespace(), Name: owner.Name, UID: string(owner.UID)}
		if resolved, resolveErr := s.resolveRelationshipNode(ctx, byKind, node); resolveErr == nil {
			node = resolved
		} else if !isMissingRelationshipKind(resolveErr) {
			graph.Warnings = append(graph.Warnings, "Could not resolve owner "+owner.Kind+"/"+owner.Name+": "+resolveErr.Error())
		}
		graph.addNode(node)
		graph.addEdge(node.ID, graph.RootID, "owner")
	}

	for _, ref := range objectReferences(root.Object, root.GetNamespace()) {
		node := ref
		if resolved, resolveErr := s.resolveRelationshipNode(ctx, byKind, node); resolveErr == nil {
			node = resolved
		} else if !isMissingRelationshipKind(resolveErr) {
			graph.Warnings = append(graph.Warnings, "Could not resolve reference "+node.Kind+"/"+node.Name+": "+resolveErr.Error())
		}
		graph.addNode(node)
		graph.addEdge(graph.RootID, node.ID, "uses")
	}

	// Each candidate request is namespaced to the focal object when possible.
	// Authorization failures are a partial snapshot, not a fatal XRay failure.
	for _, candidate := range relationshipCandidates(byKind) {
		namespace := ""
		if candidate.Namespaced {
			namespace = root.GetNamespace()
			if namespace == "" {
				continue
			}
		}
		items, listErr := s.cluster.List(ctx, candidate.GVR, namespace, candidate.Namespaced, "")
		if listErr != nil {
			graph.Warnings = append(graph.Warnings, "Could not inspect "+candidate.Kind+": "+listErr.Error())
			continue
		}
		for _, item := range items {
			node := relationshipNodeFromSummary(item)
			for _, owner := range ownerReferences(item.Raw) {
				if root.GetUID() != "" && owner.UID == string(root.GetUID()) {
					graph.addNode(node)
					graph.addEdge(graph.RootID, node.ID, "owns")
				}
			}
			if root.GetKind() == "Pod" && item.Kind == "Service" && selectorsMatch(item.Raw, root.GetLabels()) {
				graph.addNode(node)
				graph.addEdge(node.ID, graph.RootID, "routes")
			}
			if item.Kind == "Pod" && selectorsMatch(root.Object, item.Labels) {
				graph.addNode(node)
				graph.addEdge(graph.RootID, node.ID, "selects")
			}
			if referencesObject(item.Raw, root.GetKind(), root.GetName(), root.GetNamespace()) {
				graph.addNode(node)
				graph.addEdge(node.ID, graph.RootID, "uses")
			}
		}
	}
	graph.sort()
	return graph, nil
}

type relationshipType struct {
	GVR        schema.GroupVersionResource
	Kind       string
	Namespaced bool
}

func relationshipTypes(types []ResourceType) map[string]relationshipType {
	result := make(map[string]relationshipType, len(types))
	for _, typ := range types {
		key := typ.Group + "/" + typ.Version + "/" + typ.Kind
		result[key] = relationshipType{GVR: schema.GroupVersionResource{Group: typ.Group, Version: typ.Version, Resource: typ.Resource}, Kind: typ.Kind, Namespaced: typ.Namespaced}
	}
	return result
}

func relationshipCandidates(types map[string]relationshipType) []relationshipType {
	wanted := map[string]bool{"Pod": true, "Service": true, "Deployment": true, "StatefulSet": true, "DaemonSet": true, "ReplicaSet": true, "Job": true, "CronJob": true}
	result := make([]relationshipType, 0, len(wanted))
	for _, typ := range types {
		if wanted[typ.Kind] {
			result = append(result, typ)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Kind < result[j].Kind })
	return result
}

func (s *Server) resolveRelationshipNode(ctx context.Context, types map[string]relationshipType, node RelationshipNode) (RelationshipNode, error) {
	group, version := groupVersion(node.APIVersion)
	typ, ok := types[group+"/"+version+"/"+node.Kind]
	if !ok {
		return node, fmt.Errorf("kind is not discoverable")
	}
	object, err := s.cluster.Get(ctx, typ.GVR, node.Namespace, node.Name, typ.Namespaced)
	if err != nil {
		return node, err
	}
	return relationshipNodeFromObject(object), nil
}

func isMissingRelationshipKind(err error) bool {
	return strings.Contains(err.Error(), "not discoverable")
}

func groupVersion(apiVersion string) (string, string) {
	parts := strings.Split(strings.TrimSpace(apiVersion), "/")
	if len(parts) == 1 {
		return "", parts[0]
	}
	return strings.Join(parts[:len(parts)-1], "/"), parts[len(parts)-1]
}

func newRelationshipGraph(root *unstructured.Unstructured) RelationshipGraph {
	node := relationshipNodeFromObject(root)
	return RelationshipGraph{RootID: node.ID, Nodes: []RelationshipNode{node}, Edges: []RelationshipEdge{}, Warnings: []string{}}
}

func relationshipNodeFromObject(object *unstructured.Unstructured) RelationshipNode {
	if object == nil {
		return RelationshipNode{}
	}
	return RelationshipNode{ID: relationshipID(object.GetAPIVersion(), object.GetKind(), object.GetNamespace(), object.GetName(), string(object.GetUID())), APIVersion: object.GetAPIVersion(), Kind: object.GetKind(), Namespace: object.GetNamespace(), Name: object.GetName(), UID: string(object.GetUID()), Status: relationshipStatus(object.Object), Resolved: true}
}

func relationshipNodeFromSummary(item ResourceSummary) RelationshipNode {
	return RelationshipNode{ID: relationshipID(item.APIVersion, item.Kind, item.Namespace, item.Name, item.UID), APIVersion: item.APIVersion, Kind: item.Kind, Namespace: item.Namespace, Name: item.Name, UID: item.UID, Status: item.Status, Resolved: true}
}

func relationshipStatus(object map[string]any) string {
	value, _, _ := unstructured.NestedString(object, "status", "phase")
	if value == "" {
		value, _, _ = unstructured.NestedString(object, "status", "state")
	}
	return value
}

func relationshipID(apiVersion, kind, namespace, name, uid string) string {
	if uid != "" {
		return "uid:" + uid
	}
	return "ref:" + apiVersion + ":" + kind + ":" + namespace + ":" + name
}

func (g *RelationshipGraph) addNode(node RelationshipNode) {
	if node.ID == "" {
		return
	}
	for index := range g.Nodes {
		if g.Nodes[index].ID == node.ID {
			if node.Resolved {
				g.Nodes[index] = node
			}
			return
		}
	}
	g.Nodes = append(g.Nodes, node)
}

func (g *RelationshipGraph) addEdge(from, to, relation string) {
	if from == "" || to == "" || from == to {
		return
	}
	for _, edge := range g.Edges {
		if edge.From == from && edge.To == to && edge.Relation == relation {
			return
		}
	}
	g.Edges = append(g.Edges, RelationshipEdge{From: from, To: to, Relation: relation})
}

func (g *RelationshipGraph) sort() {
	sort.Slice(g.Nodes, func(i, j int) bool { return g.Nodes[i].ID < g.Nodes[j].ID })
	sort.Slice(g.Edges, func(i, j int) bool {
		if g.Edges[i].Relation == g.Edges[j].Relation {
			if g.Edges[i].From == g.Edges[j].From {
				return g.Edges[i].To < g.Edges[j].To
			}
			return g.Edges[i].From < g.Edges[j].From
		}
		return g.Edges[i].Relation < g.Edges[j].Relation
	})
	sort.Strings(g.Warnings)
}

type ownerReference struct{ UID string }

func ownerReferences(object map[string]any) []ownerReference {
	items, _, _ := unstructured.NestedSlice(object, "metadata", "ownerReferences")
	result := make([]ownerReference, 0, len(items))
	for _, item := range items {
		if value, ok := item.(map[string]any); ok {
			if uid, ok := value["uid"].(string); ok && uid != "" {
				result = append(result, ownerReference{UID: uid})
			}
		}
	}
	return result
}

func selectorsMatch(object map[string]any, labels map[string]string) bool {
	selector, found, _ := unstructured.NestedStringMap(object, "spec", "selector")
	if !found {
		selector, found, _ = unstructured.NestedStringMap(object, "spec", "selector", "matchLabels")
	}
	if !found || len(selector) == 0 {
		return false
	}
	for key, value := range selector {
		if labels[key] != value {
			return false
		}
	}
	return true
}

func referencesObject(object map[string]any, kind, name, namespace string) bool {
	for _, reference := range objectReferences(object, namespace) {
		if reference.Kind == kind && reference.Name == name && (reference.Namespace == "" || reference.Namespace == namespace) {
			return true
		}
	}
	return false
}

func objectReferences(object map[string]any, namespace string) []RelationshipNode {
	result := []RelationshipNode{}
	seen := map[string]bool{}
	var visit func(any, string)
	visit = func(value any, key string) {
		switch item := value.(type) {
		case map[string]any:
			name, hasName := item["name"].(string)
			kind := ""
			switch key {
			case "configMapKeyRef", "configMapRef", "configMap":
				kind = "ConfigMap"
			case "secretKeyRef", "secretRef", "imagePullSecrets", "secret":
				kind = "Secret"
			case "persistentVolumeClaim":
				kind = "PersistentVolumeClaim"
			}
			if key == "persistentVolumeClaim" {
				if value, ok := item["claimName"].(string); ok {
					name, hasName = value, true
				}
			}
			if key == "secret" {
				if value, ok := item["secretName"].(string); ok {
					name, hasName = value, true
				}
			}
			if hasName && kind != "" {
				node := RelationshipNode{ID: relationshipID("v1", kind, namespace, name, ""), APIVersion: "v1", Kind: kind, Namespace: namespace, Name: name}
				if !seen[node.ID] {
					seen[node.ID] = true
					result = append(result, node)
				}
			}
			for childKey, child := range item {
				visit(child, childKey)
			}
		case []any:
			for _, child := range item {
				visit(child, key)
			}
		case string:
			if key == "serviceAccountName" && item != "" {
				node := RelationshipNode{ID: relationshipID("v1", "ServiceAccount", namespace, item, ""), APIVersion: "v1", Kind: "ServiceAccount", Namespace: namespace, Name: item}
				if !seen[node.ID] {
					seen[node.ID] = true
					result = append(result, node)
				}
			}
		}
	}
	visit(object, "")
	return result
}
