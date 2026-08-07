package kube

import (
	"context"
	"fmt"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	"helm.sh/helm/v3/pkg/action"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const helmAPITimeout = 45 * time.Second

// helmRESTClientGetter bridges the already-selected K9k kubeconfig context to
// Helm's SDK. It never invokes the helm executable, reads a second kubeconfig,
// or mutates any of K9k's context settings.
type helmRESTClientGetter struct {
	restConfig *rest.Config
	discovery  discovery.DiscoveryInterface
	mapper     meta.RESTMapper
	loader     clientcmd.ClientConfig
}

func (g helmRESTClientGetter) ToRESTConfig() (*rest.Config, error) {
	if g.restConfig == nil {
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	return rest.CopyConfig(g.restConfig), nil
}

func (g helmRESTClientGetter) ToDiscoveryClient() (discovery.CachedDiscoveryInterface, error) {
	if g.discovery == nil {
		return nil, fmt.Errorf("no usable Kubernetes discovery client is selected")
	}
	return memory.NewMemCacheClient(g.discovery), nil
}

func (g helmRESTClientGetter) ToRESTMapper() (meta.RESTMapper, error) {
	if g.mapper == nil {
		return nil, fmt.Errorf("no usable Kubernetes REST mapper is selected")
	}
	return g.mapper, nil
}

// ToRawKubeConfigLoader completes genericclioptions.RESTClientGetter, which
// Helm's Kubernetes resource builder uses to obtain the requested release
// namespace. The config is an in-memory snapshot of K9k's already-selected
// context, never a new deferred loader for a different kubeconfig file.
func (g helmRESTClientGetter) ToRawKubeConfigLoader() clientcmd.ClientConfig {
	return g.loader
}

// helmActionConfiguration creates a bounded Helm SDK client from the same
// current context that powers K9k's generic browser. A snapshot copy prevents
// an in-flight lifecycle action from inheriting later UI context changes.
func (c *Cluster) helmActionConfiguration(namespace string) (*action.Configuration, error) {
	c.mu.RLock()
	if c.rest == nil || c.discovery == nil || c.config == nil {
		c.mu.RUnlock()
		return nil, fmt.Errorf("no usable Kubernetes context is selected")
	}
	config := rest.CopyConfig(c.rest)
	discoveryClient := c.discovery
	contextName := c.context
	rawConfig, rawConfigErr := c.config.RawConfig()
	c.mu.RUnlock()
	if rawConfigErr != nil {
		return nil, fmt.Errorf("snapshot active kubeconfig context: %w", rawConfigErr)
	}
	// Helm's action API does not accept a context. Bound every underlying API
	// request rather than allowing a stalled API server to pin this helper.
	config.Timeout = helmAPITimeout
	cache := memory.NewMemCacheClient(discoveryClient)
	getter := helmRESTClientGetter{
		restConfig: config,
		discovery:  discoveryClient,
		mapper:     restmapper.NewDeferredDiscoveryRESTMapper(cache),
		loader: clientcmd.NewDefaultClientConfig(rawConfig, &clientcmd.ConfigOverrides{
			CurrentContext: contextName,
			Context:        clientcmdapi.Context{Namespace: namespace},
		}),
	}
	result := new(action.Configuration)
	if err := result.Init(getter, namespace, "secret", func(string, ...interface{}) {}); err != nil {
		return nil, fmt.Errorf("initialize Helm SDK: %w", err)
	}
	return result, nil
}

// RollbackHelm performs the genuine Helm SDK rollback lifecycle. It creates
// Helm's next release revision and applies the target manifest using Helm's
// own storage, hooks, and Kubernetes client; it never edits Secret payloads
// itself. K9k intentionally does not wait for workload readiness here because
// its normal resource/watch UI is the responsive progress surface.
func (c *Cluster) RollbackHelm(ctx context.Context, request api.HelmRollbackRequest) (api.HelmRollbackResult, error) {
	if err := ctx.Err(); err != nil {
		return api.HelmRollbackResult{}, err
	}
	config, err := c.helmActionConfiguration(request.Namespace)
	if err != nil {
		return api.HelmRollbackResult{}, err
	}
	rollback := action.NewRollback(config)
	rollback.Version = request.TargetRevision
	rollback.Wait = false
	rollback.Timeout = helmAPITimeout
	rollback.CleanupOnFail = true
	rollback.MaxHistory = 128
	if err := rollback.Run(request.Release); err != nil {
		return api.HelmRollbackResult{}, fmt.Errorf("Helm rollback %q to revision %d: %w", request.Release, request.TargetRevision, err)
	}
	return api.HelmRollbackResult{
		Namespace: request.Namespace, Release: request.Release, TargetRevision: request.TargetRevision,
		Message: "Rollback started through Helm; watch the release resources for rollout status.",
	}, nil
}

// UninstallHelm runs Helm's native release deletion flow with hooks enabled.
// KeepHistory is deliberately true: K9k removes release resources but retains
// Helm's revision record instead of purging the Secret driver history.
func (c *Cluster) UninstallHelm(ctx context.Context, request api.HelmUninstallRequest) (api.HelmUninstallResult, error) {
	if err := ctx.Err(); err != nil {
		return api.HelmUninstallResult{}, err
	}
	config, err := c.helmActionConfiguration(request.Namespace)
	if err != nil {
		return api.HelmUninstallResult{}, err
	}
	uninstall := action.NewUninstall(config)
	uninstall.Wait = false
	uninstall.Timeout = helmAPITimeout
	uninstall.KeepHistory = true
	uninstall.DeletionPropagation = "background"
	response, err := uninstall.Run(request.Release)
	if err != nil {
		return api.HelmUninstallResult{}, fmt.Errorf("Helm uninstall %q: %w", request.Release, err)
	}
	info := ""
	if response != nil {
		info = response.Info
	}
	return api.HelmUninstallResult{
		Namespace: request.Namespace, Release: request.Release, KeepHistory: true, Info: info,
		Message: "Uninstall started through Helm. Release history was retained.",
	}, nil
}
