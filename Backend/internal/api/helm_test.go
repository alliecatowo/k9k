package api

import (
	"archive/tar"
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

func TestHelmLifecycleUsesConfirmedPinnedReleaseAndStorageRBAC(t *testing.T) {
	target := helmStorageSecret(t, "demo", "web", 3, map[string]any{
		"name": "web", "namespace": "demo", "version": 3,
		"chart": map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.0.0"}},
	})
	current := helmStorageSecret(t, "demo", "web", 5, map[string]any{
		"name": "web", "namespace": "demo", "version": 5,
		"chart": map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.1.0"}},
	})
	target.SetLabels(map[string]string{"owner": "helm", "name": "web", "version": "3", "status": "superseded"})
	current.SetLabels(map[string]string{"owner": "helm", "name": "web", "version": "5", "status": "deployed"})
	client := &fakeCluster{
		list: []ResourceSummary{
			{Name: target.GetName(), Namespace: "demo", Labels: target.GetLabels()},
			{Name: current.GetName(), Namespace: "demo", Labels: current.GetLabels()},
		},
		objects: map[string]*unstructured.Unstructured{
			"demo/" + target.GetName():  target,
			"demo/" + current.GetName(): current,
		},
		accessFn: func(AccessCheck) AccessReview { return AccessReview{Allowed: true} },
	}
	rollback := map[string]any{
		"namespace": "demo", "release": "web", "targetStorageName": target.GetName(), "targetRevision": 3,
		"expectedStorageName": current.GetName(), "expectedRevision": 5, "confirm": true,
	}
	uninstall := map[string]any{
		"namespace": "demo", "release": "web", "expectedStorageName": current.GetName(), "expectedRevision": 5,
		"confirm": true, "confirmationText": "web",
	}
	responses := runRequests(t, client,
		request("rollback-missing", "helm.rollback", map[string]any{
			"namespace": "demo", "release": "web", "targetStorageName": target.GetName(), "targetRevision": 3,
			"expectedStorageName": current.GetName(), "expectedRevision": 5,
		}),
		request("rollback", "helm.rollback", rollback),
		request("uninstall", "helm.uninstall", uninstall),
	)
	if failure := envelopeByID(t, responses, "rollback-missing"); failure.Error == nil || failure.Error.Code != "confirmation_required" {
		t.Fatalf("unconfirmed rollback = %#v", failure)
	}
	if response := envelopeByID(t, responses, "rollback"); response.Error != nil {
		t.Fatalf("rollback = %#v", response)
	}
	if response := envelopeByID(t, responses, "uninstall"); response.Error != nil {
		t.Fatalf("uninstall = %#v", response)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if got, want := client.helmRollbacks, []HelmRollbackRequest{{Namespace: "demo", Release: "web", TargetStorageName: target.GetName(), TargetRevision: 3, ExpectedStorageName: current.GetName(), ExpectedRevision: 5}}; len(got) != 1 || got[0] != want[0] {
		t.Fatalf("Helm rollbacks = %#v, want %#v", got, want)
	}
	if got, want := client.helmUninstalls, []HelmUninstallRequest{{Namespace: "demo", Release: "web", ExpectedStorageName: current.GetName(), ExpectedRevision: 5}}; len(got) != 1 || got[0] != want[0] {
		t.Fatalf("Helm uninstalls = %#v, want %#v", got, want)
	}
	if len(client.accesses) != 7 { // rollback get/list/create/update; uninstall get/list/update
		t.Fatalf("storage access checks = %#v", client.accesses)
	}
}

func TestHelmLifecycleRejectsStaleReleaseAndUninstallConfirmation(t *testing.T) {
	current := helmStorageSecret(t, "demo", "web", 6, map[string]any{
		"name": "web", "namespace": "demo", "version": 6,
		"chart": map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.2.0"}},
	})
	client := &fakeCluster{
		list:     []ResourceSummary{{Name: current.GetName(), Namespace: "demo", Labels: current.GetLabels()}},
		objects:  map[string]*unstructured.Unstructured{"demo/" + current.GetName(): current},
		accessFn: func(AccessCheck) AccessReview { return AccessReview{Allowed: true} },
	}
	responses := runRequests(t, client,
		request("stale", "helm.uninstall", map[string]any{"namespace": "demo", "release": "web", "expectedStorageName": "sh.helm.release.v1.web.v5", "expectedRevision": 5, "confirm": true, "confirmationText": "web"}),
		request("typed-wrong", "helm.uninstall", map[string]any{"namespace": "demo", "release": "web", "expectedStorageName": current.GetName(), "expectedRevision": 6, "confirm": true, "confirmationText": "different"}),
	)
	if failure := envelopeByID(t, responses, "stale"); failure.Error == nil || failure.Error.Code != "stale_release" {
		t.Fatalf("stale uninstall = %#v", failure)
	}
	if failure := envelopeByID(t, responses, "typed-wrong"); failure.Error == nil || failure.Error.Code != "confirmation_required" {
		t.Fatalf("uninstall confirmation = %#v", failure)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.helmUninstalls) != 0 {
		t.Fatalf("uninstalls must not run for stale or unconfirmed requests: %#v", client.helmUninstalls)
	}
}

func TestHelmUpgradeRequiresSensitivePlanAndExactDigest(t *testing.T) {
	current := helmStorageSecret(t, "demo", "web", 7, map[string]any{
		"name": "web", "namespace": "demo", "version": 7,
		"chart": map[string]any{"metadata": map[string]any{"name": "web-chart", "version": "1.0.0"}},
	})
	client := &fakeCluster{
		list:     []ResourceSummary{{Name: current.GetName(), Namespace: "demo", Labels: current.GetLabels()}},
		objects:  map[string]*unstructured.Unstructured{"demo/" + current.GetName(): current},
		accessFn: func(AccessCheck) AccessReview { return AccessReview{Allowed: true} },
	}
	params := map[string]any{
		"namespace": "demo", "release": "web", "expectedStorageName": current.GetName(), "expectedRevision": 7,
		"chartArchiveBase64": helmTestChartArchive(t), "valuesYAML": "replicas: 3\n", "valuesMode": "reset",
	}
	withAcknowledgement := make(map[string]any, len(params)+1)
	for key, value := range params {
		withAcknowledgement[key] = value
	}
	withAcknowledgement["acknowledgeSensitive"] = true
	responses := runRequests(t, client,
		request("refuse", "helm.upgrade.plan", params),
		request("plan", "helm.upgrade.plan", withAcknowledgement),
	)
	if failure := envelopeByID(t, responses, "refuse"); failure.Error == nil || failure.Error.Code != "confirmation_required" {
		t.Fatalf("unacknowledged plan = %#v", failure)
	}
	plan := decodeResult[HelmUpgradePlan](t, envelopeByID(t, responses, "plan").Result)
	if plan.PlanDigest == "" || plan.ChartName != "test" || plan.NextRevision != 8 {
		t.Fatalf("upgrade plan = %#v", plan)
	}
	upgrade := make(map[string]any, len(withAcknowledgement)+2)
	for key, value := range withAcknowledgement {
		upgrade[key] = value
	}
	upgrade["planDigest"] = plan.PlanDigest
	upgrade["confirm"] = true
	responses = runRequests(t, client,
		request("missing-digest", "helm.upgrade", withAcknowledgement),
		request("upgrade", "helm.upgrade", upgrade),
	)
	if failure := envelopeByID(t, responses, "missing-digest"); failure.Error == nil || failure.Error.Code != "invalid_params" {
		t.Fatalf("upgrade without plan digest = %#v", failure)
	}
	if response := envelopeByID(t, responses, "upgrade"); response.Error != nil {
		t.Fatalf("upgrade = %#v", response)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.helmUpgradePlans) != 1 || len(client.helmUpgrades) != 1 || client.helmUpgrades[0].PlanDigest != plan.PlanDigest {
		t.Fatalf("upgrade calls = plans %#v, upgrades %#v", client.helmUpgradePlans, client.helmUpgrades)
	}
}

func helmTestChartArchive(t *testing.T) string {
	t.Helper()
	var compressed bytes.Buffer
	gz := gzip.NewWriter(&compressed)
	tarWriter := tar.NewWriter(gz)
	for name, contents := range map[string]string{
		"test/Chart.yaml":               "apiVersion: v2\nname: test\nversion: 1.0.0\n",
		"test/templates/configmap.yaml": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Release.Name }}\n",
	} {
		if err := tarWriter.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(contents)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatalf("write chart header: %v", err)
		}
		if _, err := tarWriter.Write([]byte(contents)); err != nil {
			t.Fatalf("write chart entry: %v", err)
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatalf("close chart tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close chart gzip: %v", err)
	}
	return base64.StdEncoding.EncodeToString(compressed.Bytes())
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
