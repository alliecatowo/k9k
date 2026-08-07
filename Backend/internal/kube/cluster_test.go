package kube

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/k9k-app/k9k/backend/internal/api"
	appsv1 "k8s.io/api/apps/v1"
	authorizationv1 "k8s.io/api/authorization/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
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

func TestTriggerCronJobCreatesOwnedJobFromTemplate(t *testing.T) {
	cronJob := &batchv1.CronJob{
		ObjectMeta: metav1.ObjectMeta{Name: "nightly", Namespace: "demo", UID: types.UID("cronjob-uid")},
		Spec: batchv1.CronJobSpec{
			JobTemplate: batchv1.JobTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"workload": "nightly"}, Annotations: map[string]string{"team": "platform"}},
				Spec: batchv1.JobSpec{
					Template: corev1.PodTemplateSpec{
						Spec: corev1.PodSpec{
							RestartPolicy: corev1.RestartPolicyNever,
							Containers:    []corev1.Container{{Name: "job", Image: "busybox:1.36", Command: []string{"true"}}},
						},
					},
				},
			},
		},
	}
	typed := fake.NewSimpleClientset(cronJob)
	cluster := &Cluster{typed: typed}
	result, err := cluster.TriggerCronJob(context.Background(), api.CronJobTriggerRequest{Namespace: "demo", CronJob: "nightly"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Namespace != "demo" || result.CronJob != "nightly" || result.Job == "" {
		t.Errorf("result = %#v", result)
	}
	job, err := typed.BatchV1().Jobs("demo").Get(context.Background(), result.Job, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if job.Labels["workload"] != "nightly" || job.Annotations["team"] != "platform" || len(job.OwnerReferences) != 1 {
		t.Fatalf("job metadata = %#v", job.ObjectMeta)
	}
	owner := job.OwnerReferences[0]
	if owner.APIVersion != "batch/v1" || owner.Kind != "CronJob" || owner.Name != "nightly" || owner.UID != "cronjob-uid" || owner.Controller == nil || !*owner.Controller {
		t.Errorf("owner = %#v", owner)
	}
	if len(job.Spec.Template.Spec.Containers) != 1 || job.Spec.Template.Spec.Containers[0].Image != "busybox:1.36" {
		t.Errorf("job template = %#v", job.Spec.Template.Spec)
	}
}

func TestRollbackDeploymentReplacesCompleteTemplateFromInactiveReplicaSet(t *testing.T) {
	controller := true
	replicaSet := &appsv1.ReplicaSet{
		ObjectMeta: metav1.ObjectMeta{Name: "web-old", Namespace: "demo", UID: types.UID("rs-uid"), OwnerReferences: []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "Deployment", Name: "web", Controller: &controller}}},
		Spec:       appsv1.ReplicaSetSpec{Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "web"}}, Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "web", Image: "nginx:1.27"}}}}},
		Status:     appsv1.ReplicaSetStatus{Replicas: 0},
	}
	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: "web", Namespace: "demo"},
		Spec:       appsv1.DeploymentSpec{Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "web"}, Annotations: map[string]string{"new": "annotation"}}, Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "web", Image: "nginx:new"}}}}},
	}
	typed := fake.NewSimpleClientset(replicaSet, deployment)
	cluster := &Cluster{typed: typed}
	result, err := cluster.RollbackDeployment(context.Background(), api.DeploymentRollbackRequest{Namespace: "demo", ReplicaSet: "web-old", ExpectedRSUID: "rs-uid"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := result, (api.DeploymentRollbackResult{Namespace: "demo", Deployment: "web", ReplicaSet: "web-old"}); got != want {
		t.Errorf("result = %#v, want %#v", got, want)
	}
	updated, err := typed.AppsV1().Deployments("demo").Get(context.Background(), "web", metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := updated.Spec.Template.Annotations; len(got) != 0 {
		t.Errorf("rollback retained newer template annotations: %#v", got)
	}
	if got := updated.Spec.Template.Spec.Containers[0].Image; got != "nginx:1.27" {
		t.Errorf("rollback image = %q", got)
	}
}

func TestRollbackDeploymentRejectsActiveOrStaleReplicaSet(t *testing.T) {
	controller := true
	replicaSet := &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Name: "web", Namespace: "demo", UID: types.UID("rs-uid"), OwnerReferences: []metav1.OwnerReference{{APIVersion: "apps/v1", Kind: "Deployment", Name: "web", Controller: &controller}}}, Status: appsv1.ReplicaSetStatus{Replicas: 1}}
	cluster := &Cluster{typed: fake.NewSimpleClientset(replicaSet)}
	if _, err := cluster.RollbackDeployment(context.Background(), api.DeploymentRollbackRequest{Namespace: "demo", ReplicaSet: "web", ExpectedRSUID: "wrong"}); err == nil {
		t.Fatal("stale ReplicaSet UID was accepted")
	}
	if _, err := cluster.RollbackDeployment(context.Background(), api.DeploymentRollbackRequest{Namespace: "demo", ReplicaSet: "web", ExpectedRSUID: "rs-uid"}); err == nil {
		t.Fatal("active ReplicaSet was accepted")
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

func TestCopyContextPreservesReferencesAndChangesOnlyNamespace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	raw := clientcmdapi.Config{Contexts: map[string]*clientcmdapi.Context{
		"production": {Cluster: "cluster-prod", AuthInfo: "user-prod", Namespace: "production"},
	}}
	if err := clientcmd.WriteToFile(raw, path); err != nil {
		t.Fatal(err)
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	rules.ExplicitPath = path
	cluster := &Cluster{rules: rules, config: clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, &clientcmd.ConfigOverrides{})}
	if err := cluster.CopyContext("production", "staging", "stage"); err != nil {
		t.Fatal(err)
	}
	updated, err := clientcmd.LoadFromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := updated.Contexts["staging"], (&clientcmdapi.Context{Cluster: "cluster-prod", AuthInfo: "user-prod", Namespace: "stage"}); got == nil || got.Cluster != want.Cluster || got.AuthInfo != want.AuthInfo || got.Namespace != want.Namespace {
		t.Errorf("copied context = %#v, want %#v", got, want)
	}
	if err := cluster.CopyContext("production", "staging", ""); err == nil {
		t.Fatal("duplicate context name was accepted")
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
