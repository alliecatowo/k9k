package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
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

func TestHelmInspectProjectsChartMetadataWithoutSensitiveReleaseContent(t *testing.T) {
	client := &fakeCluster{object: helmStorageSecret(t, "demo", "web", 7, map[string]any{
		"name": "web", "namespace": "demo", "version": 7,
		"chart":    map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.2.3", "appVersion": "9.8.7", "description": "A test chart", "sources": []string{"https://example.invalid/src"}}},
		"config":   map[string]any{"password": "do-not-return"},
		"manifest": "apiVersion: v1\nkind: Secret\nstringData:\n  password: do-not-return\n",
		"info":     map[string]any{"notes": "do-not-return"},
	})}
	result, err := NewServer(client, nil, nil).helmInspect(context.Background(), HelmReleaseInspectionRequest{Namespace: "demo", Release: "web", StorageName: "sh.helm.release.v1.web.v7", Revision: 7})
	if err != nil {
		t.Fatalf("helm inspect: %v", err)
	}
	if result.Chart.Name != "web-chart" || result.Chart.Version != "1.2.3" || result.Chart.AppVersion != "9.8.7" || !result.SensitiveContentAvailable {
		t.Fatalf("metadata projection = %#v", result)
	}
	if result.Sensitive != nil {
		t.Fatalf("sensitive release contents must be omitted by default: %#v", result.Sensitive)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.gets) != 1 || client.gets[0].gvr != helmSecretsGVR || client.gets[0].namespace != "demo" || client.gets[0].name != "sh.helm.release.v1.web.v7" || !client.gets[0].namespaced {
		t.Fatalf("inspect get = %#v", client.gets)
	}
}

func TestHelmInspectRequiresExplicitAcknowledgementAndBoundsSensitiveContent(t *testing.T) {
	client := &fakeCluster{object: helmStorageSecret(t, "demo", "web", 2, map[string]any{
		"name": "web", "namespace": "demo", "version": 2,
		"chart":  map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.0.0"}},
		"config": map[string]any{"replicas": 3}, "manifest": "kind: ConfigMap\n", "info": map[string]any{"notes": "hello"},
	})}
	server := NewServer(client, nil, nil)
	result, err := server.helmInspect(context.Background(), HelmReleaseInspectionRequest{Namespace: "demo", Release: "web", StorageName: "sh.helm.release.v1.web.v2", Revision: 2, IncludeSensitive: true, AcknowledgeSensitive: true})
	if err != nil {
		t.Fatalf("sensitive inspect: %v", err)
	}
	if result.Sensitive == nil || result.Sensitive.Manifest != "kind: ConfigMap\n" || result.Sensitive.Notes != "hello" || result.Sensitive.ValuesJSON == "" {
		t.Fatalf("sensitive contents = %#v", result.Sensitive)
	}
	responses := runRequests(t, client, request("refuse", "helm.inspect", map[string]any{"namespace": "demo", "release": "web", "storageName": "sh.helm.release.v1.web.v2", "revision": 2, "includeSensitive": true}))
	if failure := envelopeByID(t, responses, "refuse"); failure.Error == nil || failure.Error.Code != "confirmation_required" {
		t.Fatalf("unacknowledged inspection response = %#v", failure)
	}
}

func TestHelmInspectProtocolReturnsMetadataOnlyByDefault(t *testing.T) {
	client := &fakeCluster{object: helmStorageSecret(t, "demo", "web", 4, map[string]any{
		"name": "web", "namespace": "demo", "version": 4,
		"chart":  map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "2.0.0"}},
		"config": map[string]any{"token": "hidden"}, "manifest": "hidden", "info": map[string]any{"notes": "hidden"},
	})}
	responses := runRequests(t, client, request("inspect", "helm.inspect", map[string]any{
		"namespace": "demo", "release": "web", "storageName": "sh.helm.release.v1.web.v4", "revision": 4,
	}))
	inspection := decodeResult[HelmReleaseInspection](t, envelopeByID(t, responses, "inspect").Result)
	if inspection.Chart.Name != "web-chart" || inspection.Sensitive != nil || !inspection.SensitiveContentAvailable {
		t.Fatalf("protocol inspection = %#v", inspection)
	}
}

func TestHelmInspectRejectsUnrelatedSecretBeforeDecoding(t *testing.T) {
	client := &fakeCluster{object: &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Secret", "metadata": map[string]any{"name": "other", "namespace": "demo", "labels": map[string]any{"owner": "other", "name": "web", "version": "1"}},
		"data": map[string]any{"release": "not-a-real-release"},
	}}}
	_, err := NewServer(client, nil, nil).helmInspect(context.Background(), HelmReleaseInspectionRequest{Namespace: "demo", Release: "web", StorageName: "other", Revision: 1})
	if err == nil {
		t.Fatal("expected unrelated Secret to be rejected")
	}
}

func TestHelmInspectTruncatesEachSensitiveField(t *testing.T) {
	overlong := strings.Repeat("x", maxHelmSensitiveContentBytes+128)
	client := &fakeCluster{object: helmStorageSecret(t, "demo", "web", 8, map[string]any{
		"name": "web", "namespace": "demo", "version": 8,
		"chart":    map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.0.0"}},
		"manifest": overlong, "info": map[string]any{"notes": overlong}, "config": map[string]any{"long": overlong},
	})}
	result, err := NewServer(client, nil, nil).helmInspect(context.Background(), HelmReleaseInspectionRequest{Namespace: "demo", Release: "web", StorageName: "sh.helm.release.v1.web.v8", Revision: 8, IncludeSensitive: true, AcknowledgeSensitive: true})
	if err != nil {
		t.Fatalf("bounded inspect: %v", err)
	}
	if result.Sensitive == nil || !result.Sensitive.ManifestTruncated || !result.Sensitive.NotesTruncated || !result.Sensitive.ValuesTruncated {
		t.Fatalf("sensitive truncation markers = %#v", result.Sensitive)
	}
	if len(result.Sensitive.Manifest) > maxHelmSensitiveContentBytes || len(result.Sensitive.Notes) > maxHelmSensitiveContentBytes || len(result.Sensitive.ValuesJSON) > maxHelmSensitiveContentBytes {
		t.Fatalf("sensitive field exceeded limit: %#v", result.Sensitive)
	}
}

func helmStorageSecret(t *testing.T, namespace, release string, revision int, payload map[string]any) *unstructured.Unstructured {
	t.Helper()
	jsonPayload, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(jsonPayload); err != nil {
		t.Fatalf("gzip fixture: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close fixture gzip: %v", err)
	}
	helmEnvelope := base64.StdEncoding.EncodeToString(compressed.Bytes())
	secretData := base64.StdEncoding.EncodeToString([]byte(helmEnvelope))
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Secret",
		"metadata": map[string]any{"name": "sh.helm.release.v1." + release + ".v" + strconv.Itoa(revision), "namespace": namespace, "labels": map[string]any{"owner": "helm", "name": release, "version": strconv.Itoa(revision), "status": "deployed"}},
		"data":     map[string]any{"release": secretData},
	}}
}
