package kube

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	authorizationv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
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
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

// Cluster centralizes client-go semantics; Swift never parses kubeconfig or speaks to the API server.
type Cluster struct {
	mu        sync.RWMutex
	context   string
	rules     *clientcmd.ClientConfigLoadingRules
	config    clientcmd.ClientConfig
	rest      *rest.Config
	dynamic   dynamic.Interface
	typed     kubernetes.Interface
	discovery discovery.DiscoveryInterface
}

func New() (*Cluster, error) {
	c := &Cluster{rules: clientcmd.NewDefaultClientConfigLoadingRules()}
	// A missing/invalid current context must not prevent the GUI from opening:
	// context.list remains usable and the user can select a valid context later.
	_ = c.reload("")
	return c, nil
}

func (c *Cluster) reload(selected string) error {
	overrides := &clientcmd.ConfigOverrides{CurrentContext: selected}
	config := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(c.rules, overrides)
	c.config, c.context = config, selected
	restConfig, err := config.ClientConfig()
	if err != nil {
		return err
	}
	dyn, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return err
	}
	typed, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return err
	}
	disc, err := discovery.NewDiscoveryClientForConfig(restConfig)
	if err != nil {
		return err
	}
	c.rest, c.dynamic, c.typed, c.discovery = restConfig, dyn, typed, disc
	return nil
}

func (c *Cluster) Contexts() ([]api.Context, error) {
	c.mu.RLock()
	config := c.config
	selected := c.context
	c.mu.RUnlock()
	raw, err := config.RawConfig()
	if err != nil {
		return nil, err
	}
	active := raw.CurrentContext
	if selected != "" {
		active = selected
	}
	result := make([]api.Context, 0, len(raw.Contexts))
	for name, value := range raw.Contexts {
		result = append(result, api.Context{Name: name, Cluster: value.Cluster, User: value.AuthInfo, Active: name == active})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func (c *Cluster) SelectContext(name string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reload(name)
}
func (c *Cluster) Namespaces(ctx context.Context) ([]string, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	list, err := typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	items := make([]string, 0, len(list.Items))
	for _, item := range list.Items {
		items = append(items, item.Name)
	}
	sort.Strings(items)
	return items, nil
}

func (c *Cluster) Discovery(ctx context.Context) ([]api.ResourceType, error) {
	c.mu.RLock()
	disc := c.discovery
	c.mu.RUnlock()
	if disc == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	lists, err := disc.ServerPreferredResources()
	if err != nil {
		if !discovery.IsGroupDiscoveryFailedError(err) {
			return nil, err
		}
	}
	seen := map[string]bool{}
	result := []api.ResourceType{}
	for _, list := range lists {
		groupVersion, parseErr := schema.ParseGroupVersion(list.GroupVersion)
		if parseErr != nil {
			continue
		}
		for _, resource := range list.APIResources {
			if strings.Contains(resource.Name, "/") {
				continue
			}
			key := list.GroupVersion + "/" + resource.Name
			if seen[key] {
				continue
			}
			seen[key] = true
			result = append(result, api.ResourceType{Group: groupVersion.Group, Version: groupVersion.Version, Resource: resource.Name, Kind: resource.Kind, Namespaced: resource.Namespaced, ShortNames: resource.ShortNames})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Kind < result[j].Kind })
	return result, nil
}

func parseGVR(group, version, resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: group, Version: version, Resource: resource}
}
func (c *Cluster) resource(gvr schema.GroupVersionResource, namespace string, namespaced bool) (dynamic.ResourceInterface, error) {
	c.mu.RLock()
	dyn := c.dynamic
	c.mu.RUnlock()
	if dyn == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	r := dyn.Resource(gvr)
	if namespaced {
		return r.Namespace(namespace), nil
	}
	return r, nil
}
func (c *Cluster) List(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) ([]api.ResourceSummary, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	list, err := resource.List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, err
	}
	result := make([]api.ResourceSummary, 0, len(list.Items))
	for i := range list.Items {
		result = append(result, Summarize(&list.Items[i]))
	}
	return result, nil
}
func (c *Cluster) Get(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) (*unstructured.Unstructured, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	return resource.Get(ctx, name, metav1.GetOptions{})
}
func (c *Cluster) Watch(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) (watch.Interface, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	return resource.Watch(ctx, metav1.ListOptions{LabelSelector: selector})
}
func (c *Cluster) Delete(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) error {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return err
	}
	return resource.Delete(ctx, name, metav1.DeleteOptions{})
}
func (c *Cluster) Patch(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool, patch []byte) (*unstructured.Unstructured, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	return resource.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
}

func (c *Cluster) PodLogs(ctx context.Context, namespace, pod, container string, previous, follow, timestamps bool, tailLines int64) (io.ReadCloser, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	options := &corev1.PodLogOptions{Container: container, Previous: previous, Follow: follow, Timestamps: timestamps}
	if tailLines > 0 {
		options.TailLines = &tailLines
	}
	return typed.CoreV1().Pods(namespace).GetLogs(pod, options).Stream(ctx)
}

// PortForward establishes a direct SPDY connection to the selected API server
// and blocks for the lifetime of the local tunnel. It intentionally binds only
// the loopback address validated by the API layer; no kubectl subprocess is
// involved. onReady is invoked exactly once after client-go has opened the
// local TCP listener and received the remote port-forward readiness signal.
func (c *Cluster) PortForward(ctx context.Context, request api.PortForwardRequest, onReady func(api.PortForwardBinding)) error {
	c.mu.RLock()
	typed := c.typed
	var restConfig *rest.Config
	if c.rest != nil {
		restConfig = rest.CopyConfig(c.rest)
	}
	c.mu.RUnlock()
	if typed == nil || restConfig == nil {
		return fmt.Errorf("no usable Kubernetes context is selected")
	}

	transport, upgrader, err := spdy.RoundTripperFor(restConfig)
	if err != nil {
		return fmt.Errorf("build port-forward transport: %w", err)
	}
	endpoint := typed.CoreV1().RESTClient().Post().
		Namespace(request.Namespace).
		Resource("pods").
		Name(request.Pod).
		SubResource("portforward").
		URL()
	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, endpoint)

	stop := make(chan struct{})
	go func() {
		<-ctx.Done()
		close(stop)
	}()

	ready := make(chan struct{})
	portSpec := fmt.Sprintf("%d:%d", request.LocalPort, request.RemotePort)
	forwarder, err := portforward.NewOnAddresses(dialer, []string{request.LocalAddress}, []string{portSpec}, stop, ready, io.Discard, io.Discard)
	if err != nil {
		return fmt.Errorf("create port forward: %w", err)
	}

	forwardDone := make(chan struct{})
	readyOnce := sync.Once{}
	go func() {
		select {
		case <-ready:
			ports, portsErr := forwarder.GetPorts()
			if portsErr != nil || len(ports) != 1 {
				return
			}
			readyOnce.Do(func() {
				onReady(api.PortForwardBinding{
					Namespace: request.Namespace, Pod: request.Pod, LocalAddress: request.LocalAddress,
					LocalPort: int(ports[0].Local), RemotePort: int(ports[0].Remote),
				})
			})
		case <-forwardDone:
			// A failed upgrade never closes ready. Avoid retaining a goroutine
			// for each unsuccessful connection attempt.
			return
		}
	}()
	err = forwarder.ForwardPorts()
	close(forwardDone)
	return err
}

func (c *Cluster) Events(ctx context.Context, namespace, involvedUID string) ([]api.ClusterEvent, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	options := metav1.ListOptions{}
	if involvedUID != "" {
		options.FieldSelector = "involvedObject.uid=" + involvedUID
	}
	list, err := typed.CoreV1().Events(namespace).List(ctx, options)
	if err != nil {
		return nil, err
	}
	items := make([]api.ClusterEvent, 0, len(list.Items))
	for _, event := range list.Items {
		last := event.LastTimestamp.Time
		if last.IsZero() {
			last = event.EventTime.Time
		}
		if last.IsZero() {
			last = event.CreationTimestamp.Time
		}
		items = append(items, api.ClusterEvent{Namespace: event.Namespace, Type: event.Type, Reason: event.Reason, Message: event.Message, Count: event.Count, FirstSeen: event.FirstTimestamp.Time, LastSeen: last, Source: event.Source.Component})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].LastSeen.After(items[j].LastSeen) })
	return items, nil
}

// CheckAccess asks the selected API server whether the active kubeconfig
// identity may perform one resource action. This is a read-only authorization
// review; it never impersonates or evaluates an arbitrary subject.
func (c *Cluster) CheckAccess(ctx context.Context, check api.AccessCheck) (api.AccessReview, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return api.AccessReview{}, fmt.Errorf("no usable Kubernetes context is selected")
	}
	review, err := typed.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, &authorizationv1.SelfSubjectAccessReview{
		Spec: authorizationv1.SelfSubjectAccessReviewSpec{
			ResourceAttributes: &authorizationv1.ResourceAttributes{
				Verb:        check.Verb,
				Group:       check.Group,
				Version:     check.Version,
				Resource:    check.Resource,
				Subresource: check.Subresource,
				Namespace:   check.Namespace,
				Name:        check.Name,
			},
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return api.AccessReview{}, err
	}
	return api.AccessReview{
		Allowed:         review.Status.Allowed,
		Denied:          review.Status.Denied,
		Reason:          review.Status.Reason,
		EvaluationError: review.Status.EvaluationError,
	}, nil
}
func IsNotFound(err error) bool { return errors.IsNotFound(err) }

func Summarize(item *unstructured.Unstructured) api.ResourceSummary {
	status, _, _ := unstructured.NestedString(item.Object, "status", "phase")
	if status == "" {
		status, _, _ = unstructured.NestedString(item.Object, "status", "state")
	}
	if status == "" {
		status = "Unknown"
	}
	created := item.GetCreationTimestamp().Time
	age := "—"
	if !created.IsZero() {
		age = humanDuration(created)
	}
	return api.ResourceSummary{APIVersion: item.GetAPIVersion(), Kind: item.GetKind(), Namespace: item.GetNamespace(), Name: item.GetName(), UID: string(item.GetUID()), CreatedAt: created, Age: age, Status: status, Labels: item.GetLabels(), Raw: item.Object}
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
