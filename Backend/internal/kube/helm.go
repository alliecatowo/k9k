package kube

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"path"
	"strings"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const helmAPITimeout = 45 * time.Second

const (
	maxHelmChartFiles       = 2048
	maxHelmChartContentSize = 32 << 20
	maxHelmChartFileSize    = 4 << 20
	maxHelmPlanManifestSize = 1 << 20
)

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

// PlanHelmUpgrade renders an exact packaged chart through Helm's server
// dry-run upgrade path. Its archive parser accepts only bounded regular tar
// files, so neither a path from the sandboxed UI nor a compressed chart bomb
// becomes an out-of-band filesystem read or unbounded helper allocation.
func (c *Cluster) PlanHelmUpgrade(ctx context.Context, request api.HelmUpgradeRequest) (api.HelmUpgradePlan, error) {
	chart, values, err := loadHelmUpgradeInput(request)
	if err != nil {
		return api.HelmUpgradePlan{}, err
	}
	config, err := c.helmActionConfiguration(request.Namespace)
	if err != nil {
		return api.HelmUpgradePlan{}, err
	}
	upgrade := configuredHelmUpgrade(config, request)
	upgrade.DryRun = true
	upgrade.DryRunOption = "server"
	upgrade.HideSecret = true
	release, err := upgrade.RunWithContext(ctx, request.Release, chart, values)
	if err != nil {
		return api.HelmUpgradePlan{}, fmt.Errorf("plan Helm upgrade %q: %w", request.Release, err)
	}
	if release == nil || release.Chart == nil || release.Chart.Metadata == nil {
		return api.HelmUpgradePlan{}, fmt.Errorf("Helm upgrade plan returned no chart metadata")
	}
	if len(release.Manifest) > maxHelmPlanManifestSize {
		return api.HelmUpgradePlan{}, fmt.Errorf("rendered Helm manifest exceeds the %d-byte review limit", maxHelmPlanManifestSize)
	}
	manifestDigest := fmt.Sprintf("%x", sha256.Sum256([]byte(release.Manifest)))
	return api.HelmUpgradePlan{
		Namespace: request.Namespace, Release: request.Release,
		ChartName: release.Chart.Metadata.Name, ChartVersion: release.Chart.Metadata.Version,
		ValuesMode: request.ValuesMode, Manifest: release.Manifest, ManifestDigest: manifestDigest,
		Notes: release.Info.Notes, NextRevision: release.Version,
	}, nil
}

// UpgradeHelm applies the exact packaged chart represented by a previously
// reviewed plan digest. It does not resolve repositories, execute a local
// shell, or use a persisted Helm repository/config directory.
func (c *Cluster) UpgradeHelm(ctx context.Context, request api.HelmUpgradeRequest) (api.HelmUpgradeResult, error) {
	chart, values, err := loadHelmUpgradeInput(request)
	if err != nil {
		return api.HelmUpgradeResult{}, err
	}
	config, err := c.helmActionConfiguration(request.Namespace)
	if err != nil {
		return api.HelmUpgradeResult{}, err
	}
	release, err := configuredHelmUpgrade(config, request).RunWithContext(ctx, request.Release, chart, values)
	if err != nil {
		return api.HelmUpgradeResult{}, fmt.Errorf("Helm upgrade %q: %w", request.Release, err)
	}
	if release == nil {
		return api.HelmUpgradeResult{}, fmt.Errorf("Helm upgrade returned no release")
	}
	return api.HelmUpgradeResult{
		Namespace: request.Namespace, Release: request.Release, Revision: release.Version,
		Message: "Upgrade started through Helm; watch the release resources for rollout status.",
	}, nil
}

func configuredHelmUpgrade(config *action.Configuration, request api.HelmUpgradeRequest) *action.Upgrade {
	upgrade := action.NewUpgrade(config)
	upgrade.Namespace = request.Namespace
	upgrade.Wait = false
	upgrade.Timeout = helmAPITimeout
	upgrade.CleanupOnFail = true
	upgrade.MaxHistory = 128
	switch request.ValuesMode {
	case "reuse":
		upgrade.ReuseValues = true
	case "reset-then-reuse":
		upgrade.ResetThenReuseValues = true
	default:
		upgrade.ResetValues = true
	}
	return upgrade
}

func loadHelmUpgradeInput(request api.HelmUpgradeRequest) (*chart.Chart, map[string]interface{}, error) {
	archive, err := base64.StdEncoding.DecodeString(request.ChartArchiveBase64)
	if err != nil || len(archive) == 0 || len(archive) > 8<<20 {
		return nil, nil, fmt.Errorf("invalid bounded packaged chart archive")
	}
	chart, err := loadBoundedHelmArchive(archive)
	if err != nil {
		return nil, nil, err
	}
	values, err := chartutil.ReadValues([]byte(request.ValuesYAML))
	if err != nil {
		return nil, nil, fmt.Errorf("parse Helm values YAML: %w", err)
	}
	return chart, values, nil
}

func loadBoundedHelmArchive(archive []byte) (*chart.Chart, error) {
	reader, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, fmt.Errorf("packaged chart must be gzip-compressed tar: %w", err)
	}
	defer reader.Close()
	tarReader := tar.NewReader(reader)
	files := make([]*loader.BufferedFile, 0, 64)
	var total int64
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read packaged chart archive: %w", err)
		}
		if header.Typeflag == tar.TypeDir {
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return nil, fmt.Errorf("packaged chart contains unsupported non-regular entry %q", header.Name)
		}
		name := path.Clean(strings.TrimPrefix(header.Name, "./"))
		if name == "." || path.IsAbs(name) || strings.HasPrefix(name, "../") || strings.Contains(name, "\\") {
			return nil, fmt.Errorf("packaged chart contains unsafe path %q", header.Name)
		}
		if header.Size < 0 || header.Size > maxHelmChartFileSize || total+header.Size > maxHelmChartContentSize || len(files) >= maxHelmChartFiles {
			return nil, fmt.Errorf("packaged chart exceeds K9k archive limits")
		}
		data, err := io.ReadAll(io.LimitReader(tarReader, header.Size+1))
		if err != nil || int64(len(data)) != header.Size {
			return nil, fmt.Errorf("read packaged chart entry %q", header.Name)
		}
		total += int64(len(data))
		files = append(files, &loader.BufferedFile{Name: name, Data: data})
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("packaged chart is empty")
	}
	chart, err := loader.LoadFiles(files)
	if err != nil {
		return nil, fmt.Errorf("load packaged chart: %w", err)
	}
	return chart, nil
}
