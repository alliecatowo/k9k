package kube

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestSummarizeDerivesControllerStatus(t *testing.T) {
	for _, test := range []struct {
		name   string
		object map[string]any
		want   string
	}{
		{"deployment ready", map[string]any{"kind": "Deployment", "spec": map[string]any{"replicas": int64(2)}, "status": map[string]any{"readyReplicas": int64(2)}}, "Ready"},
		{"deployment progressing", map[string]any{"kind": "Deployment", "spec": map[string]any{"replicas": int64(2)}, "status": map[string]any{"readyReplicas": int64(1)}}, "Progressing"},
		{"daemon set", map[string]any{"kind": "DaemonSet", "status": map[string]any{"desiredNumberScheduled": int64(2), "numberAvailable": int64(2)}}, "Ready"},
		{"job", map[string]any{"kind": "Job", "status": map[string]any{"succeeded": int64(1)}}, "Succeeded"},
		{"cron job", map[string]any{"kind": "CronJob", "status": map[string]any{"lastScheduleTime": "2026-08-07T12:00:00Z"}}, "Scheduled"},
		{"node", map[string]any{"kind": "Node", "status": map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "True"}}}}, "Ready"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := Summarize(&unstructured.Unstructured{Object: test.object}).Status; got != test.want {
				t.Fatalf("status = %q, want %q", got, test.want)
			}
		})
	}
}
