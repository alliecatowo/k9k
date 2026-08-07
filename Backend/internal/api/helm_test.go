package api

import (
	"context"
	"testing"
	"time"
)

func TestHelmHistoryFiltersSortsAndBoundsStorageMetadata(t *testing.T) {
	client := &fakeCluster{list: []ResourceSummary{
		{Kind: "Secret", Namespace: "demo", Name: "sh.helm.release.v1.web.v1", Age: "2h", CreatedAt: time.Date(2026, 8, 7, 8, 0, 0, 0, time.UTC), Labels: map[string]string{"owner": "helm", "name": "web", "version": "1", "status": "superseded"}},
		{Kind: "Secret", Namespace: "demo", Name: "sh.helm.release.v1.web.v2", Age: "1h", CreatedAt: time.Date(2026, 8, 7, 9, 0, 0, 0, time.UTC), Labels: map[string]string{"owner": "helm", "name": "web", "version": "2", "status": "deployed"}},
		{Kind: "Secret", Namespace: "demo", Name: "sh.helm.release.v1.web.legacy", Age: "3h", CreatedAt: time.Date(2026, 8, 7, 7, 0, 0, 0, time.UTC), Labels: map[string]string{"owner": "helm", "name": "web", "version": "not-a-number"}},
		{Kind: "Secret", Namespace: "demo", Name: "sh.helm.release.v1.api.v7", Labels: map[string]string{"owner": "helm", "name": "api", "version": "7", "status": "deployed"}},
		{Kind: "Secret", Namespace: "demo", Name: "release-annotation", Labels: map[string]string{"owner": "helm", "version": "3", "status": "failed"}, Raw: map[string]any{"metadata": map[string]any{"annotations": map[string]any{"meta.helm.sh/release-name": "web"}}}},
	}}

	history, err := NewServer(client, nil, nil).helmHistory(context.Background(), "demo", "web")
	if err != nil {
		t.Fatalf("helm history: %v", err)
	}
	if history.Release != "web" || history.Namespace != "demo" || history.Total != 4 || history.Truncated {
		t.Fatalf("unexpected history summary: %#v", history)
	}
	if got, want := len(history.Revisions), 4; got != want {
		t.Fatalf("revisions = %d, want %d", got, want)
	}
	if got := history.Revisions; got[0].Revision != 3 || got[0].Status != "failed" || got[1].Revision != 2 || got[2].Revision != 1 || got[3].Revision != 0 || got[3].Status != "unknown" {
		t.Fatalf("revision ordering/status = %#v", got)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.lists) != 1 || client.lists[0].namespace != "demo" || client.lists[0].selector != "owner=helm" {
		t.Fatalf("history list call = %#v", client.lists)
	}
}

func TestHelmHistoryProtocolValidatesReleaseAndReturnsHistory(t *testing.T) {
	client := &fakeCluster{list: []ResourceSummary{{Name: "sh.helm.release.v1.web.v1", Namespace: "demo", Labels: map[string]string{"owner": "helm", "name": "web", "version": "1", "status": "deployed"}}}}
	responses := runRequests(t, client,
		request("history", "helm.history", map[string]any{"namespace": "demo", "release": "web"}),
		request("missing", "helm.history", map[string]any{"namespace": "demo"}),
	)
	history := decodeResult[HelmReleaseHistory](t, envelopeByID(t, responses, "history").Result)
	if history.Release != "web" || len(history.Revisions) != 1 || history.Revisions[0].Revision != 1 {
		t.Fatalf("history = %#v", history)
	}
	if failure := envelopeByID(t, responses, "missing"); failure.Error == nil || failure.Error.Code != "invalid_params" {
		t.Fatalf("missing release response = %#v", failure)
	}
}

func TestHelmHistoryUsesEmptyArrayForNoRevisions(t *testing.T) {
	history, err := NewServer(&fakeCluster{}, nil, nil).helmHistory(context.Background(), "demo", "missing")
	if err != nil {
		t.Fatalf("helm history: %v", err)
	}
	if history.Revisions == nil || len(history.Revisions) != 0 {
		t.Fatalf("empty revisions = %#v, want non-nil []", history.Revisions)
	}
}
