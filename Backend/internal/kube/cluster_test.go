package kube

import (
	"context"
	"testing"

	"github.com/k9k-app/k9k/backend/internal/api"
	authorizationv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	clientgotesting "k8s.io/client-go/testing"
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
