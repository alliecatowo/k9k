package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/k9k-app/k9k/backend/internal/protocol"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
)

// fakeCluster deliberately records the complete API boundary.  The server
// tests use it to make the wire contract observable without a Kubernetes API
// server (which is covered separately by the k3s smoke tests).
type fakeCluster struct {
	mu sync.Mutex

	contexts   []Context
	namespaces []string
	discovery  []ResourceType
	list       []ResourceSummary
	object     *unstructured.Unstructured
	watcher    *contextWatch

	contextsErr, selectErr, namespacesErr, discoveryErr error
	listErr, getErr, watchErr, deleteErr, patchErr      error

	selected []string
	lists    []resourceCall
	gets     []resourceCall
	watches  []resourceCall
	deletes  []resourceCall
	patches  []patchCall
}

type resourceCall struct {
	gvr        schema.GroupVersionResource
	namespace  string
	name       string
	namespaced bool
	selector   string
}

type patchCall struct {
	resourceCall
	patch []byte
}

func (f *fakeCluster) Contexts() ([]Context, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Context(nil), f.contexts...), f.contextsErr
}

func (f *fakeCluster) SelectContext(name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.selected = append(f.selected, name)
	return f.selectErr
}

func (f *fakeCluster) Namespaces(context.Context) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.namespaces...), f.namespacesErr
}

func (f *fakeCluster) Discovery(context.Context) ([]ResourceType, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]ResourceType(nil), f.discovery...), f.discoveryErr
}

func (f *fakeCluster) List(_ context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) ([]ResourceSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lists = append(f.lists, resourceCall{gvr: gvr, namespace: namespace, namespaced: namespaced, selector: selector})
	return append([]ResourceSummary(nil), f.list...), f.listErr
}

func (f *fakeCluster) Get(_ context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) (*unstructured.Unstructured, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets = append(f.gets, resourceCall{gvr: gvr, namespace: namespace, name: name, namespaced: namespaced})
	return f.object, f.getErr
}

func (f *fakeCluster) Watch(ctx context.Context, gvr schema.GroupVersionResource, namespace string, namespaced bool, selector string) (watch.Interface, error) {
	f.mu.Lock()
	f.watches = append(f.watches, resourceCall{gvr: gvr, namespace: namespace, namespaced: namespaced, selector: selector})
	if f.watchErr != nil {
		f.mu.Unlock()
		return nil, f.watchErr
	}
	if f.watcher == nil {
		f.watcher = newContextWatch()
	}
	w := f.watcher
	f.mu.Unlock()
	go func() {
		<-ctx.Done()
		w.Stop()
	}()
	return w, nil
}

func (f *fakeCluster) Delete(_ context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletes = append(f.deletes, resourceCall{gvr: gvr, namespace: namespace, name: name, namespaced: namespaced})
	return f.deleteErr
}

func (f *fakeCluster) Patch(_ context.Context, gvr schema.GroupVersionResource, namespace, name string, namespaced bool, patch []byte) (*unstructured.Unstructured, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.patches = append(f.patches, patchCall{resourceCall: resourceCall{gvr: gvr, namespace: namespace, name: name, namespaced: namespaced}, patch: append([]byte(nil), patch...)})
	return f.object, f.patchErr
}

func (f *fakeCluster) PodLogs(context.Context, string, string, string, bool, bool, bool, int64) (io.ReadCloser, error) {
	return io.NopCloser(strings.NewReader("")), nil
}

func (f *fakeCluster) Events(context.Context, string, string) ([]ClusterEvent, error) {
	return nil, nil
}

type contextWatch struct {
	ch   chan watch.Event
	once sync.Once
}

func newContextWatch() *contextWatch                   { return &contextWatch{ch: make(chan watch.Event, 16)} }
func (w *contextWatch) Stop()                          { w.once.Do(func() { close(w.ch) }) }
func (w *contextWatch) ResultChan() <-chan watch.Event { return w.ch }
func (w *contextWatch) send(event watch.Event)         { w.ch <- event }

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}
func (b *lockedBuffer) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.b.String() }

func request(id, operation string, params any) protocol.Request {
	var raw json.RawMessage
	if params != nil {
		encoded, err := json.Marshal(params)
		if err != nil {
			panic(err)
		}
		raw = encoded
	}
	return protocol.Request{Version: protocol.Version, ID: id, Operation: operation, Params: raw}
}

func runRequests(t *testing.T, client *fakeCluster, requests ...protocol.Request) []protocol.Envelope {
	t.Helper()
	var input strings.Builder
	for _, r := range requests {
		encoded, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		input.Write(encoded)
		input.WriteByte('\n')
	}
	var output lockedBuffer
	if err := NewServer(client, strings.NewReader(input.String()), &output).Run(context.Background()); err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	return decodeEnvelopes(t, output.String())
}

func decodeEnvelopes(t *testing.T, output string) []protocol.Envelope {
	t.Helper()
	var result []protocol.Envelope
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		var envelope protocol.Envelope
		if err := json.Unmarshal(scanner.Bytes(), &envelope); err != nil {
			t.Fatalf("invalid output line %q: %v", scanner.Text(), err)
		}
		result = append(result, envelope)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return result
}

func envelopeByID(t *testing.T, values []protocol.Envelope, id string) protocol.Envelope {
	t.Helper()
	for _, value := range values {
		if value.ID == id {
			return value
		}
	}
	t.Fatalf("no envelope with id %q in %#v", id, values)
	return protocol.Envelope{}
}

func mustObject(t *testing.T, value any) map[string]any {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func decodeResult[T any](t *testing.T, value any) T {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var result T
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestServerRejectsMalformedAndInvalidRequests(t *testing.T) {
	client := &fakeCluster{}
	input := strings.Join([]string{
		"not-json",
		`{"version":99,"id":"version","operation":"health"}`,
		`{"version":1,"operation":"health"}`,
		`{"version":1,"id":"no-operation"}`,
		`{"version":1,"id":"unknown","operation":"nope"}`,
		`{"version":1,"id":"bad-params","operation":"resource.get","params":{"resource":"pods","name":"p"}}`,
	}, "\n") + "\n"
	var output lockedBuffer
	if err := NewServer(client, strings.NewReader(input), &output).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := decodeEnvelopes(t, output.String())
	if len(got) != 6 {
		t.Fatalf("response count = %d, want 6", len(got))
	}
	wantCodes := map[string]string{"": "invalid_request", "version": "unsupported_version", "no-operation": "invalid_request", "unknown": "unknown_operation", "bad-params": "invalid_params"}
	seen := map[string]int{}
	for _, envelope := range got {
		if envelope.Error == nil {
			t.Fatalf("expected error response, got %#v", envelope)
		}
		seen[envelope.Error.Code]++
		if envelope.ID != "" && wantCodes[envelope.ID] != envelope.Error.Code {
			t.Errorf("id %q error = %q, want %q", envelope.ID, envelope.Error.Code, wantCodes[envelope.ID])
		}
	}
	if seen["parse_error"] != 1 || seen["invalid_request"] != 2 {
		t.Fatalf("unexpected errors: %#v", seen)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.gets) != 0 {
		t.Errorf("invalid request reached cluster: %#v", client.gets)
	}
}

func TestServerContextAndReadOperations(t *testing.T) {
	object := &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "api", "namespace": "demo"}}}
	client := &fakeCluster{
		contexts:   []Context{{Name: "dev", Cluster: "dev-cluster", User: "alice", Active: true}},
		namespaces: []string{"default", "demo"},
		discovery:  []ResourceType{{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true, ShortNames: []string{"po"}}},
		list:       []ResourceSummary{{APIVersion: "v1", Kind: "Pod", Namespace: "demo", Name: "api", Status: "Running"}},
		object:     object,
	}
	responses := runRequests(t, client,
		request("contexts", "context.list", nil),
		request("select", "context.select", map[string]any{"name": "prod"}),
		request("namespaces", "namespace.list", nil),
		request("discovery", "discovery.list", nil),
		request("list", "resource.list", map[string]any{"gvr": "v1/pods", "namespace": "demo", "selector": "app=api"}),
		request("get", "resource.get", map[string]any{"group": "apps", "version": "v1", "resource": "deployments", "namespace": "demo", "name": "api"}),
	)
	if got := mustObject(t, envelopeByID(t, responses, "select").Result)["selected"]; got != "prod" {
		t.Errorf("selected = %#v", got)
	}
	if got := decodeResult[[]Context](t, envelopeByID(t, responses, "contexts").Result); len(got) != 1 || got[0].Name != "dev" || !got[0].Active {
		t.Errorf("context list = %#v", got)
	}
	if got := decodeResult[[]string](t, envelopeByID(t, responses, "namespaces").Result); len(got) != 2 || got[1] != "demo" {
		t.Errorf("namespace list = %#v", got)
	}
	if got := decodeResult[[]ResourceType](t, envelopeByID(t, responses, "discovery").Result); len(got) != 1 || got[0].Resource != "pods" || !got[0].Namespaced {
		t.Errorf("discovery list = %#v", got)
	}
	if got := decodeResult[[]ResourceSummary](t, envelopeByID(t, responses, "list").Result); len(got) != 1 || got[0].Name != "api" || got[0].Status != "Running" {
		t.Errorf("resource list = %#v", got)
	}
	if got := mustObject(t, envelopeByID(t, responses, "get").Result)["kind"]; got != "Pod" {
		t.Errorf("get kind = %#v", got)
	}

	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.selected) != 1 || client.selected[0] != "prod" {
		t.Errorf("selected = %#v", client.selected)
	}
	if len(client.lists) != 1 || client.lists[0].gvr != (schema.GroupVersionResource{Version: "v1", Resource: "pods"}) || client.lists[0].namespace != "demo" || client.lists[0].selector != "app=api" {
		t.Errorf("list call = %#v", client.lists)
	}
	if len(client.gets) != 1 || client.gets[0].gvr != (schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}) || client.gets[0].name != "api" {
		t.Errorf("get call = %#v", client.gets)
	}
}

func TestResourceTypeSerializesMissingShortNamesAsArray(t *testing.T) {
	encoded, err := json.Marshal(ResourceType{Version: "v1", Resource: "pods", Kind: "Pod"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"shortNames":[]`) {
		t.Fatalf("short names must be an array for Swift decoding, got %s", encoded)
	}
}

func TestServerConfigSummaryAcceptsMissingAndPartialK9sConfiguration(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "aliases.yaml"), []byte("aliases:\n  po: v1/pods\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "views.yaml"), []byte("views:\n  v1/pods:\n    sortColumn: NAME:asc\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	responses := runRequests(t, &fakeCluster{}, request("config", "config.summary", map[string]any{"directory": directory}))
	response := envelopeByID(t, responses, "config")
	if response.Error != nil {
		t.Fatalf("config.summary error = %#v", response.Error)
	}
	result := mustObject(t, response.Result)
	if result["directory"] != directory {
		t.Errorf("directory = %#v, want %q", result["directory"], directory)
	}
	aliases := decodeResult[[]map[string]any](t, result["aliases"])
	if len(aliases) != 1 || aliases[0]["name"] != "po" || aliases[0]["target"] != "v1/pods" {
		t.Errorf("aliases = %#v", aliases)
	}
	files := decodeResult[map[string]map[string]any](t, result["files"])
	if files["aliases"]["present"] != true || files["hotkeys"]["present"] != false || files["plugins"]["present"] != false {
		t.Errorf("file statuses = %#v", files)
	}
}

func TestServerDeleteRequiresConfirmationAndScaleUsesMergePatch(t *testing.T) {
	client := &fakeCluster{object: &unstructured.Unstructured{Object: map[string]any{"kind": "Deployment", "spec": map[string]any{"replicas": int64(3)}}}}
	params := map[string]any{"gvr": "apps/v1/deployments", "namespace": "demo", "name": "api"}
	responses := runRequests(t, client,
		request("unconfirmed", "resource.delete", params),
		request("confirmed", "resource.delete", map[string]any{"gvr": "apps/v1/deployments", "namespace": "demo", "name": "api", "confirm": true}),
		request("patch", "resource.patch", map[string]any{"gvr": "apps/v1/deployments", "namespace": "demo", "name": "api", "patch": map[string]any{"metadata": map[string]any{"labels": map[string]string{"team": "platform"}}}}),
		request("scale", "resource.scale", map[string]any{"gvr": "apps/v1/deployments", "namespace": "demo", "name": "api", "replicas": 3}),
	)
	if got := envelopeByID(t, responses, "unconfirmed").Error; got == nil || got.Code != "confirmation_required" {
		t.Errorf("unconfirmed deletion = %#v", got)
	}
	if got := envelopeByID(t, responses, "confirmed").Result; mustObject(t, got)["deleted"] != true {
		t.Errorf("delete result = %#v", got)
	}

	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.deletes) != 1 || client.deletes[0].name != "api" {
		t.Errorf("deletes = %#v", client.deletes)
	}
	if len(client.patches) != 2 {
		t.Fatalf("patch calls = %#v", client.patches)
	}
	wantScale := map[string]any{"spec": map[string]any{"replicas": float64(3)}}
	var scalePatch map[string]any
	for _, call := range client.patches {
		candidate := mustObject(t, json.RawMessage(call.patch))
		if equalJSON(candidate, wantScale) {
			scalePatch = candidate
			break
		}
	}
	if scalePatch == nil {
		t.Errorf("scale patch not found in %#v", client.patches)
	}
}

func TestServerWatchEmitsEventsAndCancellationClosesStream(t *testing.T) {
	client := &fakeCluster{watcher: newContextWatch()}
	inputReader, inputWriter := io.Pipe()
	var output lockedBuffer
	server := NewServer(client, inputReader, &output)
	done := make(chan error, 1)
	go func() { done <- server.Run(context.Background()) }()

	writeRequest(t, inputWriter, protocol.Request{Version: protocol.Version, ID: "watch", Operation: "resource.watch", StreamID: "pods", Params: json.RawMessage(`{"gvr":"v1/pods","namespace":"demo"}`)})
	waitFor(t, &output, func(values []protocol.Envelope) bool {
		return hasEnvelope(values, "watch", "response") && hasEnvelope(values, "", "resource.watch.started")
	})
	client.watcher.send(watch.Event{Type: watch.Added, Object: &unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "api", "namespace": "demo"}, "status": map[string]any{"phase": "Running"}}}})
	waitFor(t, &output, func(values []protocol.Envelope) bool { return hasEnvelope(values, "", "resource.added") })
	writeRequest(t, inputWriter, protocol.Request{Version: protocol.Version, ID: "cancel", Operation: "stream.cancel", StreamID: "pods"})
	waitFor(t, &output, func(values []protocol.Envelope) bool {
		return hasEnvelope(values, "cancel", "response") && hasEnvelope(values, "", "resource.watch.closed")
	})
	if err := inputWriter.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not stop after input closed")
	}
	values := decodeEnvelopes(t, output.String())
	for _, value := range values {
		if value.Type == "resource.watch.closed" && mustObject(t, value.Result)["reason"] != "cancelled" {
			t.Errorf("close result = %#v", value.Result)
		}
	}
}

func TestServerSerializesConcurrentResponsesAsCompleteJSONLines(t *testing.T) {
	client := &fakeCluster{}
	var input strings.Builder
	const count = 64
	for i := 0; i < count; i++ {
		encoded, err := json.Marshal(protocol.Request{Version: protocol.Version, ID: string(rune('a' + i)), Operation: "health"})
		if err != nil {
			t.Fatal(err)
		}
		input.Write(encoded)
		input.WriteByte('\n')
	}
	output := &fragmentingWriter{}
	if err := NewServer(client, strings.NewReader(input.String()), output).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	values := decodeEnvelopes(t, output.String())
	if len(values) != count {
		t.Fatalf("complete JSON envelopes = %d, want %d; raw=%q", len(values), count, output.String())
	}
	seen := map[string]bool{}
	for _, value := range values {
		if value.Type != "response" || value.Error != nil {
			t.Errorf("unexpected envelope %#v", value)
		}
		seen[value.ID] = true
	}
	if len(seen) != count {
		t.Errorf("unique response ids = %d, want %d", len(seen), count)
	}
}

// fragmentingWriter yields between bytes.  Without Server.write's mutex,
// concurrently-dispatched health requests deterministically tend to interleave.
type fragmentingWriter struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *fragmentingWriter) Write(p []byte) (int, error) {
	for _, value := range p {
		w.mu.Lock()
		err := w.b.WriteByte(value)
		w.mu.Unlock()
		if err != nil {
			return 0, err
		}
		runtime.Gosched()
	}
	return len(p), nil
}
func (w *fragmentingWriter) String() string { w.mu.Lock(); defer w.mu.Unlock(); return w.b.String() }

func writeRequest(t *testing.T, writer io.Writer, value protocol.Request) {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(append(encoded, '\n')); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, output *lockedBuffer, predicate func([]protocol.Envelope) bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		values := decodeEnvelopes(t, output.String())
		if predicate(values) {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("timed out waiting for output: %s", output.String())
}

func hasEnvelope(values []protocol.Envelope, id, typ string) bool {
	for _, value := range values {
		if value.ID == id && value.Type == typ {
			return true
		}
	}
	return false
}

func equalJSON(left, right any) bool {
	a, errA := json.Marshal(left)
	b, errB := json.Marshal(right)
	return errA == nil && errB == nil && bytes.Equal(a, b)
}

var _ ClusterClient = (*fakeCluster)(nil)
var _ watch.Interface = (*contextWatch)(nil)
