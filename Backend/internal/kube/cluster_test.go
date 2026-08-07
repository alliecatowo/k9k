package kube

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	authorizationv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/fake"
	clientgotesting "k8s.io/client-go/testing"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	metricsv1beta1 "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
)

func TestCheckAccessCreatesSelfSubjectAccessReview(t *testing.T) {
	typed := fake.NewSimpleClientset()
	typed.PrependReactor("create", "selfsubjectaccessreviews", func(action clientgotesting.Action) (bool, runtime.Object, error) {
		created, ok := action.(clientgotesting.CreateAction)
		if !ok {
			t.Fatalf("action = %T, want CreateAction", action)
		}
		review, ok := created.GetObject().(*authorizationv1.SelfSubjectAccessReview)
		if !ok {
			t.Fatalf("object = %T, want SelfSubjectAccessReview", created.GetObject())
		}
		attributes := review.Spec.ResourceAttributes
		if attributes == nil {
			t.Fatal("missing resource attributes")
		}
		if got, want := *attributes, (authorizationv1.ResourceAttributes{Verb: "get", Group: "apps", Version: "v1", Resource: "deployments", Subresource: "scale", Namespace: "demo", Name: "api"}); got != want {
			t.Errorf("attributes = %#v, want %#v", got, want)
		}
		return true, &authorizationv1.SelfSubjectAccessReview{
			ObjectMeta: metav1.ObjectMeta{Name: "review"},
			Status: authorizationv1.SubjectAccessReviewStatus{
				Allowed:         false,
				Denied:          true,
				Reason:          "not permitted",
				EvaluationError: "authorizer warning",
			},
		}, nil
	})

	cluster := &Cluster{typed: typed}
	result, err := cluster.CheckAccess(context.Background(), api.AccessCheck{
		Verb: "get", Group: "apps", Version: "v1", Resource: "deployments", Subresource: "scale", Namespace: "demo", Name: "api",
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := result, (api.AccessReview{Allowed: false, Denied: true, Reason: "not permitted", EvaluationError: "authorizer warning"}); got != want {
		t.Errorf("review = %#v, want %#v", got, want)
	}
}

func TestCheckAccessRequiresSelectedContext(t *testing.T) {
	_, err := (&Cluster{}).CheckAccess(context.Background(), api.AccessCheck{Verb: "get", Resource: "pods"})
	if err == nil || err.Error() != "no usable Kubernetes context is selected" {
		t.Errorf("error = %v", err)
	}
}

func TestContextRenameAndDeleteModifyOnlyInactiveContextEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	raw := clientcmdapi.Config{
		CurrentContext: "active",
		Contexts: map[string]*clientcmdapi.Context{
			"active": {Cluster: "cluster-a", AuthInfo: "user-a", Namespace: "default"},
			"stage":  {Cluster: "cluster-b", AuthInfo: "user-b", Namespace: "platform"},
		},
	}
	if err := clientcmd.WriteToFile(raw, path); err != nil {
		t.Fatal(err)
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	rules.ExplicitPath = path
	cluster := &Cluster{
		rules:   rules,
		config:  clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, &clientcmd.ConfigOverrides{CurrentContext: "active"}),
		context: "active",
	}
	if err := cluster.RenameContext("stage", "production"); err != nil {
		t.Fatal(err)
	}
	updated, err := clientcmd.LoadFromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, found := updated.Contexts["stage"]; found {
		t.Fatal("old context name remains in kubeconfig")
	}
	if got := updated.Contexts["production"]; got == nil || got.Cluster != "cluster-b" || got.AuthInfo != "user-b" || got.Namespace != "platform" {
		t.Errorf("renamed context = %#v", got)
	}
	if got := updated.Contexts["active"]; got == nil || got.Cluster != "cluster-a" || got.AuthInfo != "user-a" {
		t.Errorf("active context was unexpectedly changed = %#v", got)
	}
	if err := cluster.DeleteContext("production"); err != nil {
		t.Fatal(err)
	}
	updated, err = clientcmd.LoadFromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, found := updated.Contexts["production"]; found {
		t.Fatal("deleted context remains in kubeconfig")
	}
	if err := cluster.DeleteContext("active"); err == nil {
		t.Fatal("deleting the active context unexpectedly succeeded")
	}
}

func TestMetricsUsesMetricsAPIAndPreservesPodContainerUsage(t *testing.T) {
	timestamp := time.Date(2026, time.August, 6, 12, 0, 0, 0, time.UTC)
	podMetric := metricsv1beta1.PodMetrics{
		TypeMeta: metav1.TypeMeta{APIVersion: "metrics.k8s.io/v1beta1", Kind: "PodMetrics"}, ObjectMeta: metav1.ObjectMeta{Name: "api", Namespace: "demo"}, Timestamp: metav1.NewTime(timestamp), Window: metav1.Duration{Duration: 30 * time.Second},
		Containers: []metricsv1beta1.ContainerMetrics{
			{Name: "app", Usage: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("12m"), corev1.ResourceMemory: resource.MustParse("128Mi")}},
			{Name: "sidecar", Usage: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("3m"), corev1.ResourceMemory: resource.MustParse("64Mi")}},
		},
	}
	nodeMetric := metricsv1beta1.NodeMetrics{
		TypeMeta: metav1.TypeMeta{APIVersion: "metrics.k8s.io/v1beta1", Kind: "NodeMetrics"}, ObjectMeta: metav1.ObjectMeta{Name: "worker"}, Timestamp: metav1.NewTime(timestamp), Window: metav1.Duration{Duration: time.Minute},
		Usage: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("125m"), corev1.ResourceMemory: resource.MustParse("1Gi")},
	}
	metricClient := metricsfake.NewSimpleClientset()
	metricClient.PrependReactor("list", "pods", func(action clientgotesting.Action) (bool, runtime.Object, error) {
		return true, &metricsv1beta1.PodMetricsList{Items: []metricsv1beta1.PodMetrics{podMetric}}, nil
	})
	metricClient.PrependReactor("get", "nodes", func(action clientgotesting.Action) (bool, runtime.Object, error) {
		return true, &nodeMetric, nil
	})
	cluster := &Cluster{metrics: metricClient.MetricsV1beta1()}
	pods, err := cluster.Metrics(context.Background(), api.MetricsQuery{Version: "v1beta1", Resource: "pods", Namespace: "demo"})
	if err != nil {
		t.Fatal(err)
	}
	if len(pods) != 1 {
		t.Fatalf("pod metrics = %#v", pods)
	}
	pod := pods[0]
	if pod.APIVersion != "metrics.k8s.io/v1beta1" || pod.Name != "api" || pod.Namespace != "demo" || pod.Timestamp != timestamp || pod.Window != "30s" {
		t.Errorf("pod metadata = %#v", pod)
	}
	if got, want := pod.Usage, map[string]string{"cpu": "15m", "memory": "192Mi"}; !mapsEqual(got, want) {
		t.Errorf("aggregated usage = %#v, want %#v", got, want)
	}
	if len(pod.Containers) != 2 || pod.Containers[0].Usage["cpu"] != "12m" || pod.Containers[1].Usage["memory"] != "64Mi" {
		t.Errorf("container usage = %#v", pod.Containers)
	}

	nodes, err := cluster.Metrics(context.Background(), api.MetricsQuery{Version: "v1beta1", Resource: "nodes", Name: "worker"})
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 1 || nodes[0].Name != "worker" || nodes[0].Usage["cpu"] != "125m" || len(nodes[0].Containers) != 0 {
		t.Errorf("node metrics = %#v", nodes)
	}
}

func TestMetricsClassifiesAbsentAPIAndRequiresContext(t *testing.T) {
	if _, err := (&Cluster{}).Metrics(context.Background(), api.MetricsQuery{Resource: "pods"}); err == nil || err.Error() != "no usable Kubernetes context is selected" {
		t.Errorf("missing context error = %v", err)
	}
	err := normalizeMetricsError(apierrors.NewNotFound(schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}, "api"))
	var unavailable *api.MetricsUnavailableError
	if !errors.As(err, &unavailable) {
		t.Errorf("not found metrics API error must be unavailable, got %T: %v", err, err)
	}
}

func mapsEqual(left, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}
