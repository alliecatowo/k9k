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
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/transport/spdy"
	metricsv1beta1 "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

const maxManualCronJobNamePrefix = 42

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
	metrics   metricsclient.MetricsV1beta1Interface
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
	metricClient, err := metricsclient.NewForConfig(restConfig)
	if err != nil {
		return err
	}
	c.rest, c.dynamic, c.typed, c.discovery, c.metrics = restConfig, dyn, typed, disc, metricClient
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
		result = append(result, api.Context{Name: name, Cluster: value.Cluster, User: value.AuthInfo, Namespace: value.Namespace, Active: name == active})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func (c *Cluster) SelectContext(name string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reload(name)
}

// UpdateContextNamespace modifies the persisted default namespace of one
// kubeconfig context through client-go's writer. It deliberately leaves the
// cluster and AuthInfo references untouched, so a graphical setting cannot
// expose or replace credentials. clientcmd.ModifyConfig handles a normal
// single-file config and KUBECONFIG loading rules atomically enough for its
// established client-go semantics.
func (c *Cluster) UpdateContextNamespace(name, namespace string) error {
	c.mu.RLock()
	config := c.config
	rules := c.rules
	active := c.context
	c.mu.RUnlock()
	raw, err := config.RawConfig()
	if err != nil {
		return err
	}
	contextValue, exists := raw.Contexts[name]
	if !exists {
		return fmt.Errorf("kubeconfig context %q does not exist", name)
	}
	contextValue.Namespace = namespace
	raw.Contexts[name] = contextValue
	if err := clientcmd.ModifyConfig(rules, raw, true); err != nil {
		return err
	}
	if name == active {
		c.mu.Lock()
		defer c.mu.Unlock()
		return c.reload(active)
	}
	return nil
}

// RenameContext changes only the kubeconfig context key. The cluster and
// AuthInfo objects, including any credentials they hold, are intentionally
// untouched. An active context is reloaded under its new name after the
// atomic-ish client-go config write has succeeded.
func (c *Cluster) RenameContext(name, newName string) error {
	c.mu.RLock()
	config := c.config
	rules := c.rules
	active := c.context
	c.mu.RUnlock()
	raw, err := config.RawConfig()
	if err != nil {
		return err
	}
	contextValue, exists := raw.Contexts[name]
	if !exists {
		return fmt.Errorf("kubeconfig context %q does not exist", name)
	}
	if _, exists := raw.Contexts[newName]; exists {
		return fmt.Errorf("kubeconfig context %q already exists", newName)
	}
	delete(raw.Contexts, name)
	raw.Contexts[newName] = contextValue
	if raw.CurrentContext == name {
		raw.CurrentContext = newName
	}
	if err := clientcmd.ModifyConfig(rules, raw, true); err != nil {
		return err
	}
	if active == name {
		c.mu.Lock()
		defer c.mu.Unlock()
		return c.reload(newName)
	}
	return nil
}

// DeleteContext removes only an inactive kubeconfig context entry. K9k refuses
// to delete the selected or kubeconfig-current context so a settings action can
// never strand the running application without a usable cluster client.
func (c *Cluster) DeleteContext(name string) error {
	c.mu.RLock()
	config := c.config
	rules := c.rules
	active := c.context
	c.mu.RUnlock()
	raw, err := config.RawConfig()
	if err != nil {
		return err
	}
	if _, exists := raw.Contexts[name]; !exists {
		return fmt.Errorf("kubeconfig context %q does not exist", name)
	}
	if name == active || name == raw.CurrentContext {
		return fmt.Errorf("cannot delete active kubeconfig context %q; select a different context first", name)
	}
	delete(raw.Contexts, name)
	return clientcmd.ModifyConfig(rules, raw, true)
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
func (c *Cluster) List(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector, fieldSelector string) ([]api.ResourceSummary, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	list, err := resource.List(ctx, metav1.ListOptions{LabelSelector: selector, FieldSelector: fieldSelector})
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
func (c *Cluster) Watch(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector, fieldSelector string) (watch.Interface, error) {
	resource, err := c.resource(gvr, namespace, namespaced)
	if err != nil {
		return nil, err
	}
	return resource.Watch(ctx, metav1.ListOptions{LabelSelector: selector, FieldSelector: fieldSelector})
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

// Manifest returns an editor-safe canonical YAML document. It never exports
// status or volatile server metadata, but carries the object UID separately so
// a later apply cannot silently target a delete/recreate replacement.
func (c *Cluster) Manifest(ctx context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) (api.ManifestDocument, error) {
	object, err := c.Get(ctx, gvr, namespace, name, namespaced)
	if err != nil {
		return api.ManifestDocument{}, err
	}
	return api.NewManifestDocument(object, api.ManifestIdentity{
		Group: gvr.Group, Version: gvr.Version, Resource: gvr.Resource, Namespaced: namespaced,
		Namespace: namespace, Name: name, UID: string(object.GetUID()), Kind: object.GetKind(),
	})
}

// ApplyManifest uses server-side apply directly through the dynamic client. A
// fresh GET guards the original UID before *each* dry run or actual write; the
// two-step protocol therefore cannot mutate an object that was recreated after
// the editor opened. Force is intentionally left false so ownership conflicts
// remain visible to the native editor instead of stealing fields.
func (c *Cluster) ApplyManifest(ctx context.Context, request api.ManifestApplyRequest) (*unstructured.Unstructured, error) {
	identity := request.Identity
	gvr := schema.GroupVersionResource{Group: identity.Group, Version: identity.Version, Resource: identity.Resource}
	resource, err := c.resource(gvr, identity.Namespace, identity.Namespaced)
	if err != nil {
		return nil, err
	}
	if !request.Create {
		current, err := resource.Get(ctx, identity.Name, metav1.GetOptions{})
		if err != nil {
			return nil, err
		}
		if string(current.GetUID()) != identity.UID || current.GetKind() != identity.Kind || current.GetAPIVersion() != gvr.GroupVersion().String() {
			return nil, api.ErrManifestIdentityMismatch
		}
	}
	options := metav1.ApplyOptions{FieldManager: "k9k"}
	if request.DryRun {
		options.DryRun = []string{metav1.DryRunAll}
	}
	return resource.Apply(ctx, identity.Name, request.Object, options)
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

// PodExec connects directly to Kubernetes' pods/exec or pods/attach SPDY
// endpoint using the selected kubeconfig. There is no local shell or kubectl
// subprocess in either execution path.
func (c *Cluster) PodExec(ctx context.Context, request api.PodExecRequest, streams api.PodExecStreams) error {
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

	endpointRequest := typed.CoreV1().RESTClient().Post().
		Namespace(request.Namespace).
		Resource("pods").
		Name(request.Pod)
	if request.Attach {
		options := &corev1.PodAttachOptions{Container: request.Container, Stdin: request.Stdin, Stdout: streams.Stdout != nil, Stderr: streams.Stderr != nil && !request.TTY, TTY: request.TTY}
		endpointRequest = endpointRequest.SubResource("attach").VersionedParams(options, scheme.ParameterCodec)
	} else {
		options := &corev1.PodExecOptions{Container: request.Container, Command: append([]string(nil), request.Command...), Stdin: request.Stdin, Stdout: streams.Stdout != nil, Stderr: streams.Stderr != nil && !request.TTY, TTY: request.TTY}
		endpointRequest = endpointRequest.SubResource("exec").VersionedParams(options, scheme.ParameterCodec)
	}
	endpoint := endpointRequest.URL()
	executor, err := remotecommand.NewSPDYExecutor(restConfig, http.MethodPost, endpoint)
	if err != nil {
		return fmt.Errorf("create pod exec transport: %w", err)
	}
	if err := executor.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin: streams.Stdin, Stdout: streams.Stdout, Stderr: streams.Stderr,
		Tty: request.TTY, TerminalSizeQueue: streams.TerminalSizeQueue,
	}); err != nil {
		return err
	}
	return nil
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

// Metrics reads the standard metrics.k8s.io/v1beta1 API through client-go.
// Metrics Server is optional in Kubernetes installations, so an absent API is
// identified explicitly for the GUI rather than being mistaken for zero usage.
func (c *Cluster) Metrics(ctx context.Context, query api.MetricsQuery) ([]api.ResourceMetrics, error) {
	c.mu.RLock()
	client := c.metrics
	c.mu.RUnlock()
	if client == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}

	switch query.Resource {
	case "pods":
		if query.Name != "" {
			item, err := client.PodMetricses(query.Namespace).Get(ctx, query.Name, metav1.GetOptions{})
			if err != nil {
				return nil, normalizeMetricsError(err)
			}
			return []api.ResourceMetrics{summarizePodMetrics(item)}, nil
		}
		list, err := client.PodMetricses(query.Namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, normalizeMetricsError(err)
		}
		result := make([]api.ResourceMetrics, 0, len(list.Items))
		for i := range list.Items {
			result = append(result, summarizePodMetrics(&list.Items[i]))
		}
		return result, nil
	case "nodes":
		if query.Name != "" {
			item, err := client.NodeMetricses().Get(ctx, query.Name, metav1.GetOptions{})
			if err != nil {
				return nil, normalizeMetricsError(err)
			}
			return []api.ResourceMetrics{summarizeNodeMetrics(item)}, nil
		}
		list, err := client.NodeMetricses().List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, normalizeMetricsError(err)
		}
		result := make([]api.ResourceMetrics, 0, len(list.Items))
		for i := range list.Items {
			result = append(result, summarizeNodeMetrics(&list.Items[i]))
		}
		return result, nil
	default:
		return nil, fmt.Errorf("unsupported metrics resource %q", query.Resource)
	}
}

// DrainNode performs Kubernetes-native eviction for ordinary Pods on a
// cordoned node. It deliberately does not implement force deletion: PDBs,
// termination grace, and RBAC errors remain visible in the result. Mirror and
// DaemonSet Pods cannot be safely evicted, and emptyDir data requires an
// explicit opt-in from the native confirmation sheet.
func (c *Cluster) DrainNode(ctx context.Context, request api.NodeDrainRequest) (api.NodeDrainResult, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return api.NodeDrainResult{}, fmt.Errorf("no usable Kubernetes context is selected")
	}
	node, err := typed.CoreV1().Nodes().Get(ctx, request.Node, metav1.GetOptions{})
	if err != nil {
		return api.NodeDrainResult{}, err
	}
	if !node.Spec.Unschedulable {
		return api.NodeDrainResult{}, fmt.Errorf("node %q must be cordoned before draining", request.Node)
	}
	result := api.NodeDrainResult{
		Node: request.Node, Evicted: []api.NodeDrainPod{}, Skipped: []api.NodeDrainPod{}, Blocked: []api.NodeDrainPod{}, Failures: []api.NodeDrainPod{},
	}
	pods, err := typed.CoreV1().Pods("").List(ctx, metav1.ListOptions{FieldSelector: "spec.nodeName=" + request.Node})
	if err != nil {
		return api.NodeDrainResult{}, err
	}
	for _, pod := range pods.Items {
		entry := api.NodeDrainPod{Namespace: pod.Namespace, Name: pod.Name}
		if !pod.DeletionTimestamp.IsZero() {
			entry.Reason = "already terminating"
			result.Skipped = append(result.Skipped, entry)
			continue
		}
		if pod.Annotations[corev1.MirrorPodAnnotationKey] != "" {
			entry.Reason = "mirror Pod managed by the node"
			result.Blocked = append(result.Blocked, entry)
			continue
		}
		if isDaemonSetPod(&pod) {
			entry.Reason = "DaemonSet Pod left running"
			if request.IgnoreDaemonSets {
				result.Skipped = append(result.Skipped, entry)
			} else {
				result.Blocked = append(result.Blocked, entry)
			}
			continue
		}
		if podUsesEmptyDir(&pod) && !request.DeleteEmptyDirData {
			entry.Reason = "uses emptyDir data; enable deletion explicitly to evict"
			result.Blocked = append(result.Blocked, entry)
			continue
		}
		if err := typed.PolicyV1().Evictions(pod.Namespace).Evict(ctx, &policyv1.Eviction{ObjectMeta: metav1.ObjectMeta{Name: pod.Name, Namespace: pod.Namespace}}); err != nil {
			entry.Reason = err.Error()
			result.Failures = append(result.Failures, entry)
			continue
		}
		entry.Reason = "eviction accepted"
		result.Evicted = append(result.Evicted, entry)
	}
	return result, nil
}

// DebugPod appends a minimally-scoped ephemeral container through the typed
// Kubernetes subresource. This is not a local Docker shell and it never
// alters the Pod template; admission, image policy, and RBAC apply normally.
func (c *Cluster) DebugPod(ctx context.Context, request api.PodDebugRequest) (api.PodDebugResult, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return api.PodDebugResult{}, fmt.Errorf("no usable Kubernetes context is selected")
	}
	pod, err := typed.CoreV1().Pods(request.Namespace).Get(ctx, request.Pod, metav1.GetOptions{})
	if err != nil {
		return api.PodDebugResult{}, err
	}
	name := fmt.Sprintf("k9k-debug-%d", time.Now().UnixNano())
	if len(name) > 63 {
		name = name[:63]
	}
	container := corev1.EphemeralContainer{
		EphemeralContainerCommon: corev1.EphemeralContainerCommon{
			Name: name, Image: request.Image, Command: append([]string(nil), request.Command...),
			Stdin: true, TTY: true, ImagePullPolicy: corev1.PullIfNotPresent,
		},
		TargetContainerName: request.TargetContainer,
	}
	pod.Spec.EphemeralContainers = append(pod.Spec.EphemeralContainers, container)
	if _, err := typed.CoreV1().Pods(request.Namespace).UpdateEphemeralContainers(ctx, request.Pod, pod, metav1.UpdateOptions{}); err != nil {
		return api.PodDebugResult{}, err
	}
	return api.PodDebugResult{Namespace: request.Namespace, Pod: request.Pod, Container: name, Image: request.Image}, nil
}

// TriggerCronJob creates one Job from the live CronJob template. The metadata
// and controller reference mirror K9s' CronJob runner, adapted from
// `.vendor/k9s/internal/dao/cronjob.go` (Apache-2.0): a manually-run Job keeps
// the template labels/annotations and remains visibly owned by its CronJob.
func (c *Cluster) TriggerCronJob(ctx context.Context, request api.CronJobTriggerRequest) (api.CronJobTriggerResult, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return api.CronJobTriggerResult{}, fmt.Errorf("no usable Kubernetes context is selected")
	}
	cronJob, err := typed.BatchV1().CronJobs(request.Namespace).Get(ctx, request.CronJob, metav1.GetOptions{})
	if err != nil {
		return api.CronJobTriggerResult{}, err
	}
	prefix := cronJob.Name
	if len(prefix) >= maxManualCronJobNamePrefix {
		prefix = prefix[:maxManualCronJobNamePrefix]
	}
	controller := true
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:        prefix + "-manual-" + rand.String(3),
			Namespace:   request.Namespace,
			Labels:      cloneStringMap(cronJob.Spec.JobTemplate.Labels),
			Annotations: cloneStringMap(cronJob.Spec.JobTemplate.Annotations),
			OwnerReferences: []metav1.OwnerReference{{
				APIVersion: "batch/v1", Kind: "CronJob", Name: cronJob.Name, UID: cronJob.UID,
				Controller: &controller, BlockOwnerDeletion: &controller,
			}},
		},
		Spec: *cronJob.Spec.JobTemplate.Spec.DeepCopy(),
	}
	created, err := typed.BatchV1().Jobs(request.Namespace).Create(ctx, job, metav1.CreateOptions{})
	if err != nil {
		return api.CronJobTriggerResult{}, err
	}
	return api.CronJobTriggerResult{Namespace: request.Namespace, CronJob: cronJob.Name, Job: created.Name}, nil
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	clone := make(map[string]string, len(values))
	for key, value := range values {
		clone[key] = value
	}
	return clone
}

func isDaemonSetPod(pod *corev1.Pod) bool {
	for _, owner := range pod.OwnerReferences {
		if owner.Kind == "DaemonSet" {
			return true
		}
	}
	return false
}

func podUsesEmptyDir(pod *corev1.Pod) bool {
	for _, volume := range pod.Spec.Volumes {
		if volume.EmptyDir != nil {
			return true
		}
	}
	return false
}

func normalizeMetricsError(err error) error {
	if apierrors.IsNotFound(err) || apierrors.IsServiceUnavailable(err) || apierrors.IsMethodNotSupported(err) {
		return &api.MetricsUnavailableError{Err: err}
	}
	return err
}

func summarizePodMetrics(item *metricsv1beta1.PodMetrics) api.ResourceMetrics {
	containers := make([]api.ContainerMetrics, 0, len(item.Containers))
	total := corev1.ResourceList{}
	for _, container := range item.Containers {
		containers = append(containers, api.ContainerMetrics{Name: container.Name, Usage: usageStrings(container.Usage)})
		for resource, quantity := range container.Usage {
			if prior, exists := total[resource]; exists {
				prior.Add(quantity)
				total[resource] = prior
			} else {
				total[resource] = quantity.DeepCopy()
			}
		}
	}
	return api.ResourceMetrics{
		APIVersion: "metrics.k8s.io/v1beta1", Resource: "pods", Namespace: item.Namespace, Name: item.Name,
		Timestamp: item.Timestamp.Time, Window: item.Window.Duration.String(), Usage: usageStrings(total), Containers: containers,
	}
}

func summarizeNodeMetrics(item *metricsv1beta1.NodeMetrics) api.ResourceMetrics {
	return api.ResourceMetrics{
		APIVersion: "metrics.k8s.io/v1beta1", Resource: "nodes", Name: item.Name,
		Timestamp: item.Timestamp.Time, Window: item.Window.Duration.String(), Usage: usageStrings(item.Usage), Containers: []api.ContainerMetrics{},
	}
}

func usageStrings(usage corev1.ResourceList) map[string]string {
	result := make(map[string]string, len(usage))
	for resource, quantity := range usage {
		result[string(resource)] = quantity.String()
	}
	return result
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
func IsNotFound(err error) bool { return apierrors.IsNotFound(err) }

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
