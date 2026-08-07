package api

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// XRay is intentionally finite. A relationship query is often run against a
// production namespace, so topology expansion must never turn a single click
// into an unbounded cluster crawl. The caps below bound both Kubernetes reads
// and the graph handed to Swift; truncation is reported on the graph rather
// than silently omitting objects.
const (
	maxRelationshipDepth          = 3
	maxRelationshipNodes          = 96
	maxRelationshipEdges          = 240
	maxRelationshipCandidateItems = 160
	maxRelationshipInventory      = 640
	maxRelationshipResolutions    = 48
	maxRelationshipObjectRefs     = 64
)

var errRelationshipResolutionLimit = errors.New("relationship resolution limit reached")

type relationshipObject struct {
	node   RelationshipNode
	object map[string]any
}

type relationshipResolver struct {
	server      *Server
	types       map[string]relationshipType
	byReference map[string]relationshipObject
	resolved    int
}

// relationships builds a recursively resolved, namespace-bounded topology.
// It expands direct owners and declared references, then connects the known
// workload/service inventory to every resolved node through a breadth-first
// walk. This covers useful chains such as Deployment → ReplicaSet → Pod and
// Pod ← Service without ever probing arbitrary CRDs cluster-wide.
func (s *Server) relationships(ctx context.Context, params resourceParams) (RelationshipGraph, error) {
	root, err := s.cluster.Get(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced())
	if err != nil {
		return RelationshipGraph{}, err
	}
	graph := newRelationshipGraph(root)
	graph.MaxDepth = maxRelationshipDepth
	discovery, discoveryErr := s.cluster.Discovery(ctx)
	if discoveryErr != nil {
		graph.addWarning("Could not resolve referenced kinds: " + discoveryErr.Error())
	}
	byKind := relationshipTypes(discovery)
	inventory := s.relationshipInventory(ctx, byKind, root.GetNamespace(), &graph)
	rootRecord := relationshipObject{node: graph.Nodes[0], object: root.Object}
	byReference := map[string]relationshipObject{relationshipReferenceKey(rootRecord.node): rootRecord}
	for _, item := range inventory {
		if item.node.ID != graph.RootID {
			byReference[relationshipReferenceKey(item.node)] = item
		}
	}
	resolver := relationshipResolver{server: s, types: byKind, byReference: byReference}

	type pending struct {
		item  relationshipObject
		depth int
	}
	queue := []pending{{item: rootRecord, depth: 0}}
	visitedDepth := map[string]int{rootRecord.node.ID: 0}
	enqueue := func(item relationshipObject, depth int) {
		if item.node.ID == "" || len(item.object) == 0 || depth > maxRelationshipDepth {
			return
		}
		if previous, seen := visitedDepth[item.node.ID]; seen && previous <= depth {
			return
		}
		visitedDepth[item.node.ID] = depth
		queue = append(queue, pending{item: item, depth: depth})
	}

	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		if current.depth >= maxRelationshipDepth {
			graph.markTruncated("Topology expansion reached the maximum depth of 3 hops.")
			continue
		}

		for _, owner := range rootOwners(current.item.object) {
			node := RelationshipNode{ID: relationshipID(owner.APIVersion, owner.Kind, current.item.node.Namespace, owner.Name, string(owner.UID)), APIVersion: owner.APIVersion, Kind: owner.Kind, Namespace: current.item.node.Namespace, Name: owner.Name, UID: string(owner.UID)}
			resolved, resolvedObject, resolveErr := resolver.resolve(ctx, node)
			if resolveErr != nil && !isMissingRelationshipKind(resolveErr) && !errors.Is(resolveErr, errRelationshipResolutionLimit) {
				graph.addWarning("Could not resolve owner " + owner.Kind + "/" + owner.Name + ": " + resolveErr.Error())
			}
			if errors.Is(resolveErr, errRelationshipResolutionLimit) {
				graph.markTruncated("Topology resolution was capped at 48 referenced objects.")
			}
			if graph.addBoundedNode(resolved) {
				graph.addBoundedEdge(resolved.ID, current.item.node.ID, "owner")
				enqueue(resolvedObject, current.depth+1)
			}
		}

		references, referencesTruncated := boundedObjectReferences(current.item.object, current.item.node.Namespace)
		if referencesTruncated {
			graph.markTruncated("A resource declared more than 64 direct references; XRay kept the first 64.")
		}
		for _, reference := range references {
			resolved, resolvedObject, resolveErr := resolver.resolve(ctx, reference)
			if resolveErr != nil && !isMissingRelationshipKind(resolveErr) && !errors.Is(resolveErr, errRelationshipResolutionLimit) {
				graph.addWarning("Could not resolve reference " + reference.Kind + "/" + reference.Name + ": " + resolveErr.Error())
			}
			if errors.Is(resolveErr, errRelationshipResolutionLimit) {
				graph.markTruncated("Topology resolution was capped at 48 referenced objects.")
			}
			if graph.addBoundedNode(resolved) {
				graph.addBoundedEdge(current.item.node.ID, resolved.ID, "uses")
				enqueue(resolvedObject, current.depth+1)
			}
		}

		for _, candidate := range inventory {
			for _, edge := range relationshipEdgesBetween(current.item, candidate) {
				// Every candidate edge is incident to current, so accepting the
				// far endpoint before the edge preserves graph bounds and avoids
				// dangling edge references.
				if graph.addBoundedNode(candidate.node) {
					graph.addBoundedEdge(edge.From, edge.To, edge.Relation)
					enqueue(candidate, current.depth+1)
				}
			}
		}
	}
	graph.sort()
	return graph, nil
}

// relationshipInventory performs one bounded first page per common workload
// kind. It asks for raw objects only inside the Go helper, never on the
// browser's resource.listPage IPC route, because selectors and references
// cannot be reconstructed from summaries alone.
func (s *Server) relationshipInventory(ctx context.Context, types map[string]relationshipType, namespace string, graph *RelationshipGraph) []relationshipObject {
	result := make([]relationshipObject, 0)
	for _, candidate := range relationshipCandidates(types) {
		if len(result) >= maxRelationshipInventory {
			graph.markTruncated("Topology candidate inventory was capped at 640 objects.")
			break
		}
		candidateNamespace := ""
		if candidate.Namespaced {
			candidateNamespace = namespace
			if candidateNamespace == "" {
				continue
			}
		}
		page, listErr := s.cluster.ListPage(ctx, candidate.GVR, candidateNamespace, candidate.Namespaced, ResourceListQuery{Limit: maxRelationshipCandidateItems, IncludeRaw: true})
		if listErr != nil {
			graph.addWarning("Could not inspect " + candidate.Kind + ": " + listErr.Error())
			continue
		}
		if page.Continue != "" || page.RemainingItemCount != nil && *page.RemainingItemCount > 0 {
			graph.markTruncated("Topology candidate inventory for " + candidate.Kind + " was capped at 160 objects.")
		}
		for _, summary := range page.Items {
			if len(result) >= maxRelationshipInventory {
				graph.markTruncated("Topology candidate inventory was capped at 640 objects.")
				break
			}
			if summary.Kind == "" {
				summary.Kind = candidate.Kind
			}
			if summary.APIVersion == "" {
				summary.APIVersion = apiVersionForGVR(candidate.GVR)
			}
			result = append(result, relationshipObject{node: relationshipNodeFromSummary(summary), object: summary.Raw})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].node.ID < result[j].node.ID })
	return result
}

func (r *relationshipResolver) resolve(ctx context.Context, node RelationshipNode) (RelationshipNode, relationshipObject, error) {
	if item, ok := r.byReference[relationshipReferenceKey(node)]; ok {
		return item.node, item, nil
	}
	if r.resolved >= maxRelationshipResolutions {
		return node, relationshipObject{node: node}, errRelationshipResolutionLimit
	}
	group, version := groupVersion(node.APIVersion)
	typ, ok := r.types[group+"/"+version+"/"+node.Kind]
	if !ok {
		return node, relationshipObject{node: node}, fmt.Errorf("kind is not discoverable")
	}
	r.resolved++
	object, err := r.server.cluster.Get(ctx, typ.GVR, node.Namespace, node.Name, typ.Namespaced)
	if err != nil {
		return node, relationshipObject{node: node}, err
	}
	resolved := relationshipNodeFromObject(object)
	item := relationshipObject{node: resolved, object: object.Object}
	r.byReference[relationshipReferenceKey(resolved)] = item
	return resolved, item, nil
}

func relationshipReferenceKey(node RelationshipNode) string {
	return node.APIVersion + ":" + node.Kind + ":" + node.Namespace + ":" + node.Name
}

func apiVersionForGVR(gvr schema.GroupVersionResource) string {
	if gvr.Group == "" {
		return gvr.Version
	}
	return gvr.Group + "/" + gvr.Version
}

func rootOwners(object map[string]any) []metav1.OwnerReference {
	resource := unstructured.Unstructured{Object: object}
	return resource.GetOwnerReferences()
}

func relationshipEdgesBetween(focal, candidate relationshipObject) []RelationshipEdge {
	if focal.node.ID == "" || candidate.node.ID == "" || focal.node.ID == candidate.node.ID || len(candidate.object) == 0 {
		return nil
	}
	edges := make([]RelationshipEdge, 0, 2)
	for _, owner := range ownerReferences(candidate.object) {
		if focal.node.UID != "" && owner.UID == focal.node.UID {
			edges = append(edges, RelationshipEdge{From: focal.node.ID, To: candidate.node.ID, Relation: "owns"})
			break
		}
	}
	if focal.node.Kind == "Pod" && candidate.node.Kind == "Service" && selectorsMatch(candidate.object, labelsForRelationshipObject(focal)) {
		edges = append(edges, RelationshipEdge{From: candidate.node.ID, To: focal.node.ID, Relation: "routes"})
	}
	if candidate.node.Kind == "Pod" && selectorsMatch(focal.object, labelsForRelationshipObject(candidate)) {
		edges = append(edges, RelationshipEdge{From: focal.node.ID, To: candidate.node.ID, Relation: "selects"})
	}
	if referencesObject(candidate.object, focal.node.Kind, focal.node.Name, focal.node.Namespace) {
		edges = append(edges, RelationshipEdge{From: candidate.node.ID, To: focal.node.ID, Relation: "uses"})
	}
	return edges
}

func labelsForRelationshipObject(item relationshipObject) map[string]string {
	labels, _, _ := unstructured.NestedStringMap(item.object, "metadata", "labels")
	return labels
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

// addBoundedNode keeps topology output finite while preserving any earlier
// resolved identity for an existing node. Returning false means callers must
// not add an edge that would point at an omitted node.
func (g *RelationshipGraph) addBoundedNode(node RelationshipNode) bool {
	if node.ID == "" {
		return false
	}
	for index := range g.Nodes {
		if g.Nodes[index].ID == node.ID {
			if node.Resolved {
				g.Nodes[index] = node
			}
			return true
		}
	}
	if len(g.Nodes) >= maxRelationshipNodes {
		g.markTruncated("Topology was capped at 96 nodes.")
		return false
	}
	g.Nodes = append(g.Nodes, node)
	return true
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

func (g *RelationshipGraph) addBoundedEdge(from, to, relation string) {
	if from == "" || to == "" || from == to {
		return
	}
	for _, edge := range g.Edges {
		if edge.From == from && edge.To == to && edge.Relation == relation {
			return
		}
		// The BFS can discover a parent/child pair both through the child's
		// ownerReference and through the parent's reverse inventory scan. Keep
		// the first, focal-friendly spelling (owner or owns) rather than draw
		// the same line twice with contradictory labels.
		if edge.From == from && edge.To == to && ((edge.Relation == "owner" && relation == "owns") || (edge.Relation == "owns" && relation == "owner")) {
			return
		}
	}
	if len(g.Edges) >= maxRelationshipEdges {
		g.markTruncated("Topology was capped at 240 edges.")
		return
	}
	g.Edges = append(g.Edges, RelationshipEdge{From: from, To: to, Relation: relation})
}

func (g *RelationshipGraph) addWarning(warning string) {
	warning = strings.TrimSpace(warning)
	if warning == "" {
		return
	}
	for _, existing := range g.Warnings {
		if existing == warning {
			return
		}
	}
	g.Warnings = append(g.Warnings, warning)
}

func (g *RelationshipGraph) markTruncated(warning string) {
	g.Truncated = true
	g.addWarning(warning)
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
	references, _ := boundedObjectReferences(object, namespace)
	return references
}

func boundedObjectReferences(object map[string]any, namespace string) ([]RelationshipNode, bool) {
	result := []RelationshipNode{}
	seen := map[string]bool{}
	const clusterScopedReference = "\x00"
	truncated := false
	add := func(apiVersion, kind, referenceNamespace, name string) {
		apiVersion = strings.TrimSpace(apiVersion)
		kind = strings.TrimSpace(kind)
		name = strings.TrimSpace(name)
		if apiVersion == "" {
			apiVersion = "v1"
		}
		if referenceNamespace == clusterScopedReference {
			referenceNamespace = ""
		} else if referenceNamespace == "" {
			referenceNamespace = namespace
		}
		if kind == "" || name == "" {
			return
		}
		node := RelationshipNode{ID: relationshipID(apiVersion, kind, referenceNamespace, name, ""), APIVersion: apiVersion, Kind: kind, Namespace: referenceNamespace, Name: name}
		if !seen[node.ID] {
			if len(result) >= maxRelationshipObjectRefs {
				truncated = true
				return
			}
			seen[node.ID] = true
			result = append(result, node)
		}
	}
	apiVersionForReference := func(item map[string]any) string {
		if apiVersion, ok := item["apiVersion"].(string); ok && apiVersion != "" {
			return apiVersion
		}
		if group, ok := item["apiGroup"].(string); ok && group != "" {
			return group + "/v1"
		}
		return "v1"
	}
	var visit func(any, string)
	visit = func(value any, key string) {
		switch item := value.(type) {
		case map[string]any:
			name, hasName := item["name"].(string)
			referenceNamespace, _ := item["namespace"].(string)
			kind := ""
			apiVersion := "v1"
			switch key {
			case "configMapKeyRef", "configMapRef", "configMap":
				kind = "ConfigMap"
			case "secretKeyRef", "secretRef", "imagePullSecrets", "secret":
				kind = "Secret"
			case "persistentVolumeClaim":
				kind = "PersistentVolumeClaim"
			case "service":
				// networking.k8s.io/v1 Ingress backends and Gateway-style
				// backends commonly declare {service: {name: …}}.
				kind = "Service"
			case "roleRef":
				// RoleBinding/ClusterRoleBinding point at the policy object
				// through apiGroup rather than apiVersion.
				apiVersion = apiVersionForReference(item)
				if roleKind, ok := item["kind"].(string); ok && (roleKind == "Role" || roleKind == "ClusterRole") {
					kind = roleKind
					if roleKind == "ClusterRole" {
						referenceNamespace = clusterScopedReference
					}
				}
			case "targetRef", "scaleTargetRef", "objectReference":
				// These Kubernetes ObjectReference-shaped fields are explicit
				// declarations, unlike arbitrary {kind,name} user data in CRDs.
				apiVersion = apiVersionForReference(item)
				kind, _ = item["kind"].(string)
			case "subject", "subjects":
				// RBAC users/groups are external identities, but a ServiceAccount
				// subject is a navigable Kubernetes object in this namespace.
				if subjectKind, _ := item["kind"].(string); subjectKind == "ServiceAccount" {
					kind = subjectKind
				}
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
				add(apiVersion, kind, referenceNamespace, name)
			}
			for childKey, child := range item {
				visit(child, childKey)
			}
		case []any:
			for _, child := range item {
				visit(child, key)
			}
		case string:
			switch key {
			case "serviceAccountName":
				add("v1", "ServiceAccount", namespace, item)
			case "serviceName":
				// StatefulSet serviceName and legacy Ingress serviceName are
				// direct Service dependencies, not loose text matches.
				add("v1", "Service", namespace, item)
			}
		}
	}
	visit(object, "")
	return result, truncated
}
