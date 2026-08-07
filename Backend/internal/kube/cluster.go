package kube

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Cluster centralizes client-go semantics; Swift never parses kubeconfig or speaks to the API server.
type Cluster struct {
	mu       sync.RWMutex
	context  string
	rules    *clientcmd.ClientConfigLoadingRules
	config   clientcmd.ClientConfig
	rest     *rest.Config
	dynamic  dynamic.Interface
	typed    kubernetes.Interface
	discovery discovery.DiscoveryInterface
}

func New() (*Cluster, error) {
	c := &Cluster{rules: clientcmd.NewDefaultClientConfigLoadingRules()}
	if err := c.reload(""); err != nil { return nil, err }
	return c, nil
}

func (c *Cluster) reload(selected string) error {
	overrides := &clientcmd.ConfigOverrides{CurrentContext: selected}
	config := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(c.rules, overrides)
	restConfig, err := config.ClientConfig()
	if err != nil { return err }
	dyn, err := dynamic.NewForConfig(restConfig); if err != nil { return err }
	typed, err := kubernetes.NewForConfig(restConfig); if err != nil { return err }
	disc, err := discovery.NewDiscoveryClientForConfig(restConfig); if err != nil { return err }
	c.config, c.rest, c.dynamic, c.typed, c.discovery = config, restConfig, dyn, typed, disc
	c.context = selected
	return nil
}

func (c *Cluster) Contexts() ([]api.Context, error) {
	c.mu.RLock(); config := c.config; selected := c.context; c.mu.RUnlock()
	raw, err := config.RawConfig(); if err != nil { return nil, err }
	active := raw.CurrentContext; if selected != "" { active = selected }
	result := make([]api.Context, 0, len(raw.Contexts))
	for name, value := range raw.Contexts { result = append(result, api.Context{Name:name, Cluster:value.Cluster, User:value.AuthInfo, Active:name == active}) }
	sort.Slice(result, func(i,j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func (c *Cluster) SelectContext(name string) error { c.mu.Lock(); defer c.mu.Unlock(); return c.reload(name) }
func (c *Cluster) Namespaces(ctx context.Context) ([]string, error) {
	c.mu.RLock(); typed := c.typed; c.mu.RUnlock()
	list, err := typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{}); if err != nil { return nil, err }
	items := make([]string, 0, len(list.Items)); for _, item := range list.Items { items = append(items, item.Name) }; sort.Strings(items); return items, nil
}

func (c *Cluster) Discovery(ctx context.Context) ([]api.ResourceType, error) {
	c.mu.RLock(); disc := c.discovery; c.mu.RUnlock()
	lists, err := disc.ServerPreferredResources()
	if err != nil { if !discovery.IsGroupDiscoveryFailedError(err) { return nil, err } }
	seen := map[string]bool{}; result := []api.ResourceType{}
	for _, list := range lists {
		groupVersion, parseErr := schema.ParseGroupVersion(list.GroupVersion); if parseErr != nil { continue }
		for _, resource := range list.APIResources {
			if strings.Contains(resource.Name, "/") { continue }
			key := list.GroupVersion + "/" + resource.Name; if seen[key] { continue }; seen[key] = true
			result = append(result, api.ResourceType{Group:groupVersion.Group, Version:groupVersion.Version, Resource:resource.Name, Kind:resource.Kind, Namespaced:resource.Namespaced, ShortNames:resource.ShortNames})
		}
	}
	sort.Slice(result, func(i,j int) bool { return result[i].Kind < result[j].Kind }); return result, nil
}

func parseGVR(group, version, resource string) schema.GroupVersionResource { return schema.GroupVersionResource{Group:group, Version:version, Resource:resource} }
func (c *Cluster) resource(gvr schema.GroupVersionResource, namespace string, namespaced bool) dynamic.ResourceInterface {
	c.mu.RLock(); dyn := c.dynamic; c.mu.RUnlock(); r := dyn.Resource(gvr); if namespaced { return r.Namespace(namespace) }; return r
}
func (c *Cluster) List(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) ([]api.ResourceSummary, error) {
	list, err := c.resource(gvr, namespace, namespaced).List(ctx, metav1.ListOptions{LabelSelector:selector}); if err != nil { return nil, err }
	result := make([]api.ResourceSummary, 0, len(list.Items)); for i := range list.Items { result = append(result, Summarize(&list.Items[i])) }; return result, nil
}
func (c *Cluster) Get(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) (*unstructured.Unstructured, error) { return c.resource(gvr, namespace, namespaced).Get(ctx,name,metav1.GetOptions{}) }
func (c *Cluster) Watch(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) (watch.Interface, error) { return c.resource(gvr, namespace, namespaced).Watch(ctx, metav1.ListOptions{LabelSelector:selector}) }
func (c *Cluster) Delete(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) error { return c.resource(gvr, namespace, namespaced).Delete(ctx,name,metav1.DeleteOptions{}) }
func (c *Cluster) Patch(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool, patch []byte) (*unstructured.Unstructured,error) { return c.resource(gvr, namespace, namespaced).Patch(ctx,name,types.MergePatchType,patch,metav1.PatchOptions{}) }
func IsNotFound(err error) bool { return errors.IsNotFound(err) }

func Summarize(item *unstructured.Unstructured) api.ResourceSummary {
	status, _, _ := unstructured.NestedString(item.Object, "status", "phase")
	if status == "" { status, _, _ = unstructured.NestedString(item.Object, "status", "state") }
	if status == "" { status = "Unknown" }
	created := item.GetCreationTimestamp().Time
	age := "—"; if !created.IsZero() { age = humanDuration(created) }
	return api.ResourceSummary{APIVersion:item.GetAPIVersion(), Kind:item.GetKind(), Namespace:item.GetNamespace(), Name:item.GetName(), UID:string(item.GetUID()), CreatedAt:created, Age:age, Status:status, Labels:item.GetLabels(), Raw:item.Object}
}
func humanDuration(created time.Time) string {
	d := time.Since(created)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}
