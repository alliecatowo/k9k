package api

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/k9k-app/k9k/backend/internal/config"
	"github.com/k9k-app/k9k/backend/internal/protocol"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/tools/remotecommand"
	kubeexec "k8s.io/client-go/util/exec"
	"sigs.k8s.io/yaml"
)

const maxRequestBytes = 16 << 20

const (
	maxExecInputChunkBytes  = 64 << 10
	maxExecInputQueueChunks = 32
	maxExecOutputChunkBytes = 64 << 10
)

// ClusterClient is the narrow Kubernetes surface used by the IPC server. It is
// intentionally an interface so the protocol can be exercised without a live
// cluster.
type ClusterClient interface {
	Contexts() ([]Context, error)
	SelectContext(name string) error
	UpdateContextNamespace(name, namespace string) error
	RenameContext(name, newName string) error
	DeleteContext(name string) error
	Namespaces(context.Context) ([]string, error)
	Discovery(context.Context) ([]ResourceType, error)
	List(context.Context, schema.GroupVersionResource, string, bool, string, string) ([]ResourceSummary, error)
	Get(context.Context, schema.GroupVersionResource, string, string, bool) (*unstructured.Unstructured, error)
	Watch(context.Context, schema.GroupVersionResource, string, bool, string, string) (watch.Interface, error)
	Delete(context.Context, schema.GroupVersionResource, string, string, bool) error
	Patch(context.Context, schema.GroupVersionResource, string, string, bool, []byte) (*unstructured.Unstructured, error)
	Manifest(context.Context, schema.GroupVersionResource, string, string, bool) (ManifestDocument, error)
	ApplyManifest(context.Context, ManifestApplyRequest) (*unstructured.Unstructured, error)
	PodLogs(context.Context, string, string, string, bool, bool, bool, int64) (io.ReadCloser, error)
	Events(context.Context, string, string) ([]ClusterEvent, error)
	Metrics(context.Context, MetricsQuery) ([]ResourceMetrics, error)
	DrainNode(context.Context, NodeDrainRequest) (NodeDrainResult, error)
	DebugPod(context.Context, PodDebugRequest) (PodDebugResult, error)
	CheckAccess(context.Context, AccessCheck) (AccessReview, error)
	PortForward(context.Context, PortForwardRequest, func(PortForwardBinding)) error
	PodExec(context.Context, PodExecRequest, PodExecStreams) error
}

// Server dispatches K9k's newline-delimited JSON protocol. Concurrent request
// handling keeps cancellation responsive while writeMu guarantees each emitted
// envelope remains one complete JSON line.
type Server struct {
	cluster ClusterClient
	in      io.Reader
	out     io.Writer

	writeMu  sync.Mutex
	streamMu sync.Mutex
	streams  map[string]context.CancelFunc
	execMu   sync.Mutex
	execs    map[string]*execSession
	work     sync.WaitGroup
}

func NewServer(cluster ClusterClient, input io.Reader, output io.Writer) *Server {
	return &Server{
		cluster: cluster,
		in:      input,
		out:     output,
		streams: make(map[string]context.CancelFunc),
		execs:   make(map[string]*execSession),
	}
}

// Run returns only after input closes and every in-flight operation has exited.
// A bad request is reported to the peer without terminating the backend.
func (s *Server) Run(ctx context.Context) error {
	if s.cluster == nil {
		return errors.New("Kubernetes client is required")
	}
	if s.in == nil || s.out == nil {
		return errors.New("stdin and stdout are required")
	}

	readErr := make(chan error, 1)
	go func() { readErr <- s.readRequests(ctx) }()

	select {
	case err := <-readErr:
		s.cancelAllStreams()
		s.work.Wait()
		return err
	case <-ctx.Done():
		s.cancelAllStreams()
		s.work.Wait()
		return nil
	}
}

func (s *Server) readRequests(ctx context.Context) error {
	scanner := bufio.NewScanner(s.in)
	scanner.Buffer(make([]byte, 64*1024), maxRequestBytes)
	for scanner.Scan() {
		var raw json.RawMessage
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			s.writeFailure("", "parse_error", err, nil)
			continue
		}

		var request protocol.Request
		if err := json.Unmarshal(raw, &request); err != nil {
			s.writeFailure("", "parse_error", err, nil)
			continue
		}
		if request.Version != protocol.Version {
			s.writeFailure(request.ID, "unsupported_version", fmt.Errorf("unsupported protocol version %d", request.Version), map[string]any{"supported": protocol.Version})
			continue
		}
		if request.ID == "" {
			s.writeFailure("", "invalid_request", errors.New("request id is required"), nil)
			continue
		}
		if request.Operation == "" {
			s.writeFailure(request.ID, "invalid_request", errors.New("operation is required"), nil)
			continue
		}

		// Input and resize frames must retain their NDJSON arrival order. Both
		// operations are bounded/non-blocking, so handling them on the reader
		// goroutine cannot stall cancellation or ordinary API requests.
		if request.Operation == "exec.stdin" || request.Operation == "exec.resize" {
			s.dispatch(ctx, request)
			continue
		}

		s.work.Add(1)
		go func(request protocol.Request) {
			defer s.work.Done()
			s.dispatch(ctx, request)
		}(request)
	}
	if err := scanner.Err(); err != nil {
		s.writeFailure("", "parse_error", err, nil)
		return err
	}
	return nil
}

func (s *Server) dispatch(ctx context.Context, request protocol.Request) {
	if request.Operation == "resource.watch" {
		s.startWatch(ctx, request)
		return
	}
	if request.Operation == "logs.open" {
		s.startLogs(ctx, request)
		return
	}
	if request.Operation == "portforward.open" {
		s.startPortForward(ctx, request)
		return
	}
	if request.Operation == "exec.open" {
		s.startExec(ctx, request)
		return
	}
	if request.Operation == "attach.open" {
		s.startAttach(ctx, request)
		return
	}

	result, opErr := s.handle(ctx, request)
	if opErr != nil {
		s.writeFailure(request.ID, opErr.code, opErr.err, opErr.details)
		return
	}
	s.write(protocol.Response(request.ID, result))
}

type operationError struct {
	code    string
	err     error
	details any
}

func invalidParams(err error) *operationError {
	return &operationError{code: "invalid_params", err: err}
}
func kubeError(err error) *operationError { return &operationError{code: "kubernetes_error", err: err} }

// execInput is a bounded, cancellable Reader for interactive terminal bytes.
// Requests are accepted by the scanner in wire order, then remotecommand pulls
// them as the API server is ready. The finite queue keeps a disconnected or
// slow pod from allowing unbounded helper memory growth.
type execInput struct {
	chunks  chan []byte
	done    chan struct{}
	once    sync.Once
	pending []byte
}

func newExecInput() *execInput {
	return &execInput{
		chunks: make(chan []byte, maxExecInputQueueChunks),
		done:   make(chan struct{}),
	}
}

func (in *execInput) Read(destination []byte) (int, error) {
	for len(in.pending) == 0 {
		select {
		case chunk := <-in.chunks:
			in.pending = chunk
		case <-in.done:
			return 0, io.EOF
		}
	}
	n := copy(destination, in.pending)
	in.pending = in.pending[n:]
	return n, nil
}

func (in *execInput) Enqueue(data []byte) error {
	if len(data) > maxExecInputChunkBytes {
		return fmt.Errorf("exec input must not exceed %d bytes", maxExecInputChunkBytes)
	}
	copyOfData := append([]byte(nil), data...)
	select {
	case <-in.done:
		return io.ErrClosedPipe
	default:
	}
	select {
	case <-in.done:
		return io.ErrClosedPipe
	case in.chunks <- copyOfData:
		return nil
	default:
		return errExecInputBackpressure
	}
}

func (in *execInput) Close() { in.once.Do(func() { close(in.done) }) }

var errExecInputBackpressure = errors.New("exec input queue is full; wait for the terminal to drain")

// resizeQueue follows the client-go TerminalSizeQueue contract. It begins
// with an explicit initial size and coalesces later resizes: terminal programs
// only need the current dimensions, not every intermediate drag position.
type resizeQueue struct {
	sizes chan remotecommand.TerminalSize
	done  chan struct{}
	once  sync.Once
}

func newResizeQueue(columns, rows uint16) *resizeQueue {
	queue := &resizeQueue{sizes: make(chan remotecommand.TerminalSize, 1), done: make(chan struct{})}
	queue.sizes <- remotecommand.TerminalSize{Width: columns, Height: rows}
	return queue
}

func (q *resizeQueue) Next() *remotecommand.TerminalSize {
	select {
	case size := <-q.sizes:
		return &size
	case <-q.done:
		return nil
	}
}

func (q *resizeQueue) Resize(columns, rows uint16) error {
	if columns == 0 || rows == 0 {
		return errors.New("columns and rows must be positive")
	}
	select {
	case <-q.done:
		return io.ErrClosedPipe
	default:
	}
	size := remotecommand.TerminalSize{Width: columns, Height: rows}
	select {
	case q.sizes <- size:
		return nil
	default:
		// There is one queued resize. Replace it with the current dimensions.
		select {
		case <-q.sizes:
		default:
		}
		select {
		case <-q.done:
			return io.ErrClosedPipe
		case q.sizes <- size:
			return nil
		default:
			return nil
		}
	}
}

func (q *resizeQueue) Close() { q.once.Do(func() { close(q.done) }) }

type execSession struct {
	input  *execInput
	resize *resizeQueue
	stdin  bool
}

// execEventWriter preserves every remote byte using base64, including ANSI
// escape sequences and non-UTF-8 output. The GUI can therefore feed the
// decoded bytes directly to a terminal emulator without newline heuristics.
type execEventWriter struct {
	server   *Server
	streamID string
	event    string
}

func (w execEventWriter) Write(data []byte) (int, error) {
	written := len(data)
	for len(data) > 0 {
		length := len(data)
		if length > maxExecOutputChunkBytes {
			length = maxExecOutputChunkBytes
		}
		w.server.write(protocol.Event(w.streamID, w.event, map[string]any{
			"encoding": "base64", "dataBase64": base64.StdEncoding.EncodeToString(data[:length]),
		}))
		data = data[length:]
	}
	return written, nil
}

func (s *Server) handle(ctx context.Context, request protocol.Request) (any, *operationError) {
	switch request.Operation {
	case "health", "health.ping", "ping":
		return map[string]any{"status": "ok", "protocolVersion": protocol.Version}, nil
	case "config.summary":
		var params struct {
			Directory string `json:"directory"`
		}
		if len(request.Params) != 0 && string(request.Params) != "null" {
			if err := json.Unmarshal(request.Params, &params); err != nil {
				return nil, invalidParams(fmt.Errorf("decode params: %w", err))
			}
		}
		result, err := config.LoadSummary(params.Directory)
		if err != nil {
			return nil, &operationError{code: "config_error", err: err}
		}
		return result, nil
	case "config.document":
		var params struct {
			Directory string `json:"directory"`
			Name      string `json:"name"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		result, err := config.LoadDocument(params.Directory, params.Name)
		if err != nil {
			return nil, &operationError{code: "config_error", err: err}
		}
		return result, nil
	case "config.write":
		var params struct {
			Directory      string `json:"directory"`
			Name           string `json:"name"`
			ExpectedSHA256 string `json:"expectedSHA256"`
			Content        string `json:"content"`
			Confirm        bool   `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("configuration write requires confirm: true")}
		}
		result, err := config.SaveDocument(params.Directory, params.Name, params.ExpectedSHA256, params.Content)
		if err != nil {
			return nil, &operationError{code: "config_error", err: err}
		}
		return result, nil
	case "context.list":
		result, err := s.cluster.Contexts()
		if err != nil {
			return nil, kubeError(err)
		}
		return result, nil
	case "context.select":
		var params struct {
			Name string `json:"name"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if params.Name == "" {
			return nil, invalidParams(errors.New("name is required"))
		}
		if err := s.cluster.SelectContext(params.Name); err != nil {
			return nil, kubeError(err)
		}
		return map[string]any{"selected": params.Name}, nil
	case "context.update":
		var params struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
			Confirm   bool   `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		params.Name = strings.TrimSpace(params.Name)
		params.Namespace = strings.TrimSpace(params.Namespace)
		if params.Name == "" {
			return nil, invalidParams(errors.New("context name is required"))
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("kubeconfig context update requires confirm: true")}
		}
		if err := s.cluster.UpdateContextNamespace(params.Name, params.Namespace); err != nil {
			return nil, kubeError(err)
		}
		return map[string]any{"name": params.Name, "namespace": params.Namespace, "updated": true}, nil
	case "context.rename":
		var params struct {
			Name    string `json:"name"`
			NewName string `json:"newName"`
			Confirm bool   `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		params.Name = strings.TrimSpace(params.Name)
		params.NewName = strings.TrimSpace(params.NewName)
		if params.Name == "" || params.NewName == "" {
			return nil, invalidParams(errors.New("context name and newName are required"))
		}
		if params.Name == params.NewName {
			return nil, invalidParams(errors.New("new context name must be different"))
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("kubeconfig context rename requires confirm: true")}
		}
		if err := s.cluster.RenameContext(params.Name, params.NewName); err != nil {
			return nil, kubeError(err)
		}
		return map[string]any{"name": params.Name, "newName": params.NewName, "renamed": true}, nil
	case "context.delete":
		var params struct {
			Name    string `json:"name"`
			Confirm bool   `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		params.Name = strings.TrimSpace(params.Name)
		if params.Name == "" {
			return nil, invalidParams(errors.New("context name is required"))
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("kubeconfig context deletion requires confirm: true")}
		}
		if err := s.cluster.DeleteContext(params.Name); err != nil {
			return nil, kubeError(err)
		}
		return map[string]any{"name": params.Name, "deleted": true}, nil
	case "namespace.list":
		result, err := s.cluster.Namespaces(ctx)
		if err != nil {
			return nil, kubeError(err)
		}
		return result, nil
	case "discovery.list":
		result, err := s.cluster.Discovery(ctx)
		if err != nil {
			return nil, kubeError(err)
		}
		return result, nil
	case "resource.list":
		params, err := decodeResourceParams(request.Params, false)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, listErr := s.cluster.List(ctx, params.gvr(), params.Namespace, params.isNamespaced(), params.Selector, params.FieldSelector)
		if listErr != nil {
			return nil, kubeError(listErr)
		}
		return result, nil
	case "resource.get":
		params, err := decodeResourceParams(request.Params, true)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, getErr := s.cluster.Get(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced())
		if getErr != nil {
			return nil, kubeError(getErr)
		}
		return result.Object, nil
	case "relationships.get":
		params, err := decodeResourceParams(request.Params, true)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, relationshipErr := s.relationships(ctx, params)
		if relationshipErr != nil {
			return nil, kubeError(relationshipErr)
		}
		return result, nil
	case "manifest.get":
		params, err := decodeResourceParams(request.Params, true)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, manifestErr := s.cluster.Manifest(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced())
		if manifestErr != nil {
			return nil, kubeError(manifestErr)
		}
		return result, nil
	case "manifest.apply":
		params, err := decodeManifestApplyParams(request.Params)
		if err != nil {
			return nil, invalidParams(err)
		}
		// Always issue the exact server-side apply as a dry run first. This
		// validates schema, admission, defaulting, and ownership conflicts
		// without persisting a change; confirm only enables the second write.
		preview, applyErr := s.cluster.ApplyManifest(ctx, params.request(true))
		if applyErr != nil {
			return nil, manifestOperationError(applyErr, "manifest validation failed")
		}
		previewDocument, documentErr := NewManifestDocument(preview, params.identity())
		if documentErr != nil {
			return nil, kubeError(documentErr)
		}
		if !params.Confirm {
			return map[string]any{"validated": true, "applied": false, "manifest": previewDocument}, nil
		}
		applied, applyErr := s.cluster.ApplyManifest(ctx, params.request(false))
		if applyErr != nil {
			return nil, manifestOperationError(applyErr, "manifest apply failed")
		}
		appliedDocument, documentErr := NewManifestDocument(applied, params.identity())
		if documentErr != nil {
			return nil, kubeError(documentErr)
		}
		return map[string]any{"validated": true, "applied": true, "manifest": appliedDocument}, nil
	case "resource.events":
		var params struct {
			Namespace string `json:"namespace"`
			UID       string `json:"uid"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if params.Namespace == "" {
			return nil, invalidParams(errors.New("namespace is required for event lookup"))
		}
		result, eventsErr := s.cluster.Events(ctx, params.Namespace, params.UID)
		if eventsErr != nil {
			return nil, kubeError(eventsErr)
		}
		return result, nil
	case "metrics.list":
		params, err := decodeMetricsQuery(request.Params)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, metricsErr := s.cluster.Metrics(ctx, params)
		if metricsErr != nil {
			var unavailable *MetricsUnavailableError
			if errors.As(metricsErr, &unavailable) {
				return nil, &operationError{code: "metrics_unavailable", err: metricsErr}
			}
			return nil, kubeError(metricsErr)
		}
		return map[string]any{
			"apiVersion": "metrics.k8s.io/" + params.Version,
			"resource":   params.Resource,
			"items":      result,
		}, nil
	case "node.drain":
		var params struct {
			NodeDrainRequest
			Confirm bool `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		params.Node = strings.TrimSpace(params.Node)
		if params.Node == "" {
			return nil, invalidParams(errors.New("node is required"))
		}
		if !params.IgnoreDaemonSets {
			return nil, invalidParams(errors.New("node draining requires ignoreDaemonSets: true; DaemonSet Pods cannot be evicted"))
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("node drain requires confirm: true")}
		}
		result, drainErr := s.cluster.DrainNode(ctx, params.NodeDrainRequest)
		if drainErr != nil {
			return nil, kubeError(drainErr)
		}
		return result, nil
	case "pod.debug":
		var params struct {
			PodDebugRequest
			Confirm bool `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		params.Namespace, params.Pod, params.Image = strings.TrimSpace(params.Namespace), strings.TrimSpace(params.Pod), strings.TrimSpace(params.Image)
		if params.Namespace == "" || params.Pod == "" || params.Image == "" {
			return nil, invalidParams(errors.New("namespace, pod, and image are required"))
		}
		if strings.ContainsAny(params.Image, " \t\r\n") {
			return nil, invalidParams(errors.New("image must not contain whitespace"))
		}
		if len(params.Command) == 0 {
			params.Command = []string{"/bin/sh"}
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("ephemeral debug container requires confirm: true")}
		}
		result, debugErr := s.cluster.DebugPod(ctx, params.PodDebugRequest)
		if debugErr != nil {
			return nil, kubeError(debugErr)
		}
		return result, nil
	case "rbac.check":
		params, err := decodeAccessCheckParams(request.Params)
		if err != nil {
			return nil, invalidParams(err)
		}
		result, reviewErr := s.cluster.CheckAccess(ctx, params.accessCheck())
		if reviewErr != nil {
			return nil, kubeError(reviewErr)
		}
		return result, nil
	case "resource.patch":
		var params patchParams
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if err := params.validate(); err != nil {
			return nil, invalidParams(err)
		}
		result, patchErr := s.cluster.Patch(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced(), params.Patch)
		if patchErr != nil {
			return nil, kubeError(patchErr)
		}
		return result.Object, nil
	case "resource.delete":
		var params struct {
			resourceParams
			Confirm bool `json:"confirm"`
		}
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if err := params.validateResource(); err != nil || params.Name == "" || (params.isNamespaced() && params.Namespace == "") {
			if err != nil {
				return nil, invalidParams(err)
			}
			return nil, invalidParams(errors.New("name and namespaced resource namespace are required"))
		}
		if !params.Confirm {
			return nil, &operationError{code: "confirmation_required", err: errors.New("resource deletion requires confirm: true")}
		}
		if deleteErr := s.cluster.Delete(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced()); deleteErr != nil {
			return nil, kubeError(deleteErr)
		}
		return map[string]any{"deleted": true, "name": params.Name}, nil
	case "resource.scale":
		var params scaleParams
		if err := decodeParams(request.Params, &params); err != nil {
			return nil, invalidParams(err)
		}
		if err := params.validate(); err != nil {
			return nil, invalidParams(err)
		}
		patch, _ := json.Marshal(map[string]any{"spec": map[string]int32{"replicas": params.Replicas}})
		result, patchErr := s.cluster.Patch(ctx, params.gvr(), params.Namespace, params.Name, params.isNamespaced(), patch)
		if patchErr != nil {
			return nil, kubeError(patchErr)
		}
		return result.Object, nil
	case "exec.stdin":
		params, err := decodeExecInputParams(request)
		if err != nil {
			return nil, invalidParams(err)
		}
		session := s.execSession(params.StreamID)
		if session == nil {
			return nil, &operationError{code: "stream_not_found", err: fmt.Errorf("exec stream %q is not active", params.StreamID)}
		}
		if !session.stdin {
			return nil, invalidParams(errors.New("exec.stdin requires an exec stream opened with stdin: true"))
		}
		if err := session.input.Enqueue(params.Data); err != nil {
			if errors.Is(err, io.ErrClosedPipe) {
				return nil, &operationError{code: "stream_closed", err: fmt.Errorf("exec stream %q is closed", params.StreamID)}
			}
			if errors.Is(err, errExecInputBackpressure) {
				return nil, &operationError{code: "input_backpressure", err: err}
			}
			return nil, invalidParams(err)
		}
		return map[string]any{"streamID": params.StreamID, "accepted": true, "bytes": len(params.Data)}, nil
	case "exec.resize":
		params, err := decodeExecResizeParams(request)
		if err != nil {
			return nil, invalidParams(err)
		}
		session := s.execSession(params.StreamID)
		if session == nil {
			return nil, &operationError{code: "stream_not_found", err: fmt.Errorf("exec stream %q is not active", params.StreamID)}
		}
		if session.resize == nil {
			return nil, invalidParams(errors.New("exec.resize requires a TTY exec stream"))
		}
		if err := session.resize.Resize(params.Columns, params.Rows); err != nil {
			if errors.Is(err, io.ErrClosedPipe) {
				return nil, &operationError{code: "stream_closed", err: fmt.Errorf("exec stream %q is closed", params.StreamID)}
			}
			return nil, invalidParams(err)
		}
		return map[string]any{"streamID": params.StreamID, "accepted": true, "columns": params.Columns, "rows": params.Rows}, nil
	case "stream.cancel", "resource.cancel", "resource.watch.cancel":
		streamID := request.StreamID
		if streamID == "" {
			var params struct {
				StreamID string `json:"streamID"`
			}
			if err := decodeParams(request.Params, &params); err != nil {
				return nil, invalidParams(err)
			}
			streamID = params.StreamID
		}
		if streamID == "" {
			return nil, invalidParams(errors.New("streamID is required"))
		}
		return map[string]any{"streamID": streamID, "cancelled": s.cancelStream(streamID)}, nil
	default:
		return nil, &operationError{code: "unknown_operation", err: fmt.Errorf("unknown operation %q", request.Operation)}
	}
}

type logParams struct {
	StreamID   string `json:"streamID"`
	Namespace  string `json:"namespace"`
	Pod        string `json:"pod"`
	Container  string `json:"container"`
	Previous   bool   `json:"previous"`
	Follow     bool   `json:"follow"`
	Timestamps bool   `json:"timestamps"`
	TailLines  int64  `json:"tailLines"`
}

type execParams struct {
	StreamID       string   `json:"streamID"`
	Namespace      string   `json:"namespace"`
	Pod            string   `json:"pod"`
	Container      string   `json:"container"`
	Command        []string `json:"command"`
	TTY            *bool    `json:"tty"`
	Stdin          *bool    `json:"stdin"`
	InitialColumns int      `json:"initialColumns"`
	InitialRows    int      `json:"initialRows"`
}

func (p *execParams) validate() error {
	p.Namespace = strings.TrimSpace(p.Namespace)
	p.Pod = strings.TrimSpace(p.Pod)
	p.Container = strings.TrimSpace(p.Container)
	if p.Namespace == "" || p.Pod == "" {
		return errors.New("namespace and pod are required")
	}
	if len(p.Command) == 0 {
		return errors.New("command must contain at least one argv element")
	}
	if len(p.Command) > 64 {
		return errors.New("command cannot contain more than 64 argv elements")
	}
	commandBytes := 0
	for index, argument := range p.Command {
		if strings.IndexByte(argument, 0) >= 0 {
			return fmt.Errorf("command argument %d contains a NUL byte", index)
		}
		commandBytes += len(argument)
	}
	if commandBytes > 64<<10 {
		return errors.New("command arguments cannot exceed 65536 bytes")
	}
	if p.InitialColumns < 0 || p.InitialColumns > 65535 || p.InitialRows < 0 || p.InitialRows > 65535 {
		return errors.New("initial terminal dimensions must be between 0 and 65535")
	}
	return nil
}

func (p execParams) tty() bool {
	return p.TTY == nil || *p.TTY
}

func (p execParams) stdin() bool {
	// Interactive TTY sessions naturally expect input. For a non-TTY command,
	// stdin is opt-in so a one-shot command cannot wait forever for EOF.
	if p.Stdin != nil {
		return *p.Stdin
	}
	return p.tty()
}

func (p execParams) request() PodExecRequest {
	return PodExecRequest{
		Namespace: p.Namespace, Pod: p.Pod, Container: p.Container,
		Command: append([]string(nil), p.Command...), TTY: p.tty(), Stdin: p.stdin(),
	}
}

func (p execParams) initialDimensions() (uint16, uint16) {
	columns, rows := p.InitialColumns, p.InitialRows
	if columns == 0 {
		columns = 80
	}
	if rows == 0 {
		rows = 24
	}
	return uint16(columns), uint16(rows)
}

// attachParams deliberately shares the terminal transport controls with exec
// but accepts no command: Kubernetes attaches to the container's primary
// process rather than starting a shell inside it.
type attachParams struct {
	StreamID       string `json:"streamID"`
	Namespace      string `json:"namespace"`
	Pod            string `json:"pod"`
	Container      string `json:"container"`
	TTY            *bool  `json:"tty"`
	Stdin          *bool  `json:"stdin"`
	InitialColumns int    `json:"initialColumns"`
	InitialRows    int    `json:"initialRows"`
}

func (p attachParams) tty() bool { return p.TTY == nil || *p.TTY }
func (p attachParams) stdin() bool {
	if p.Stdin != nil {
		return *p.Stdin
	}
	return p.tty()
}
func (p attachParams) validate() error {
	if strings.TrimSpace(p.Namespace) == "" || strings.TrimSpace(p.Pod) == "" {
		return errors.New("namespace and pod are required")
	}
	if p.InitialColumns < 0 || p.InitialColumns > 65535 || p.InitialRows < 0 || p.InitialRows > 65535 {
		return errors.New("initialColumns and initialRows must be between 0 and 65535")
	}
	return nil
}
func (p attachParams) initialDimensions() (uint16, uint16) {
	columns, rows := p.InitialColumns, p.InitialRows
	if columns == 0 {
		columns = 80
	}
	if rows == 0 {
		rows = 24
	}
	return uint16(columns), uint16(rows)
}
func (p attachParams) request() PodExecRequest {
	return PodExecRequest{Namespace: p.Namespace, Pod: p.Pod, Container: p.Container, Stdin: p.stdin(), TTY: p.tty(), Attach: true}
}

type execInputParams struct {
	StreamID   string  `json:"streamID"`
	Data       *string `json:"data"`
	DataBase64 *string `json:"dataBase64"`
}

func decodeExecInputParams(request protocol.Request) (struct {
	StreamID string
	Data     []byte
}, error) {
	var params execInputParams
	if err := decodeParams(request.Params, &params); err != nil {
		return struct {
			StreamID string
			Data     []byte
		}{}, err
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		return struct {
			StreamID string
			Data     []byte
		}{}, errors.New("streamID is required")
	}
	if params.Data != nil && params.DataBase64 != nil {
		return struct {
			StreamID string
			Data     []byte
		}{}, errors.New("provide exactly one of data or dataBase64")
	}
	if params.Data == nil && params.DataBase64 == nil {
		return struct {
			StreamID string
			Data     []byte
		}{}, errors.New("data or dataBase64 is required")
	}
	data := []byte(nil)
	if params.Data != nil {
		data = []byte(*params.Data)
	} else {
		decoded, err := base64.StdEncoding.DecodeString(*params.DataBase64)
		if err != nil {
			return struct {
				StreamID string
				Data     []byte
			}{}, fmt.Errorf("decode dataBase64: %w", err)
		}
		data = decoded
	}
	return struct {
		StreamID string
		Data     []byte
	}{StreamID: streamID, Data: data}, nil
}

type execResizeParams struct {
	StreamID string `json:"streamID"`
	Columns  int    `json:"columns"`
	Rows     int    `json:"rows"`
}

func decodeExecResizeParams(request protocol.Request) (struct {
	StreamID string
	Columns  uint16
	Rows     uint16
}, error) {
	var params execResizeParams
	if err := decodeParams(request.Params, &params); err != nil {
		return struct {
			StreamID string
			Columns  uint16
			Rows     uint16
		}{}, err
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		return struct {
			StreamID string
			Columns  uint16
			Rows     uint16
		}{}, errors.New("streamID is required")
	}
	if params.Columns < 1 || params.Columns > 65535 || params.Rows < 1 || params.Rows > 65535 {
		return struct {
			StreamID string
			Columns  uint16
			Rows     uint16
		}{}, errors.New("columns and rows must be between 1 and 65535")
	}
	return struct {
		StreamID string
		Columns  uint16
		Rows     uint16
	}{StreamID: streamID, Columns: uint16(params.Columns), Rows: uint16(params.Rows)}, nil
}

// startExec creates a direct Kubernetes remotecommand session. The helper
// owns the pipes and terminal resize queue while the frontend communicates
// exclusively through the versioned NDJSON stream protocol.
func (s *Server) startExec(ctx context.Context, request protocol.Request) {
	var params execParams
	if err := decodeParams(request.Params, &params); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	if err := params.validate(); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		s.writeFailure(request.ID, "invalid_params", errors.New("streamID is required"), nil)
		return
	}

	streamContext, cancel := context.WithCancel(ctx)
	if !s.registerStream(streamID, cancel) {
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
		return
	}
	input := newExecInput()
	var resize *resizeQueue
	if params.tty() {
		columns, rows := params.initialDimensions()
		resize = newResizeQueue(columns, rows)
	}
	session := &execSession{input: input, resize: resize, stdin: params.stdin()}
	if !s.registerExecSession(streamID, session) {
		s.unregisterStream(streamID)
		input.Close()
		if resize != nil {
			resize.Close()
		}
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("exec stream %q already exists", streamID), nil)
		return
	}

	result := map[string]any{
		"streamID": streamID, "status": "started", "namespace": params.Namespace,
		"pod": params.Pod, "container": params.Container, "command": params.Command,
		"tty": params.tty(), "stdin": params.stdin(),
	}
	s.write(protocol.Response(request.ID, result))
	s.write(protocol.Event(streamID, "exec.started", result))
	s.work.Add(1)
	go func() {
		defer s.work.Done()
		defer s.unregisterExecSession(streamID)
		defer s.unregisterStream(streamID)
		defer cancel()
		defer input.Close()
		if resize != nil {
			defer resize.Close()
		}

		streams := PodExecStreams{
			Stdout: execEventWriter{server: s, streamID: streamID, event: "exec.stdout"},
			Stderr: execEventWriter{server: s, streamID: streamID, event: "exec.stderr"},
		}
		if params.stdin() {
			streams.Stdin = input
		}
		if resize != nil {
			streams.TerminalSizeQueue = resize
		}
		execErr := s.cluster.PodExec(streamContext, params.request(), streams)
		reason := "completed"
		closeResult := map[string]any{"reason": reason, "exitCode": 0}
		if streamContext.Err() != nil {
			reason = "cancelled"
			closeResult = map[string]any{"reason": reason}
		} else if execErr != nil {
			reason = "error"
			exitCode, isExit := remoteExitCode(execErr)
			closeResult = map[string]any{"reason": reason, "message": execErr.Error()}
			if isExit {
				closeResult["exitCode"] = exitCode
			}
			s.write(protocol.Event(streamID, "exec.error", closeResult))
		}
		closeResult["reason"] = reason
		s.write(protocol.Event(streamID, "exec.closed", closeResult))
	}()
}

// startAttach mirrors exec's byte-stream lifecycle while marking the direct
// client-go request as an attach. Keeping the stream event names identical
// lets the native VT terminal safely reuse its ordered stdin/resize transport.
func (s *Server) startAttach(ctx context.Context, request protocol.Request) {
	var params attachParams
	if err := decodeParams(request.Params, &params); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	if err := params.validate(); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		s.writeFailure(request.ID, "invalid_params", errors.New("streamID is required"), nil)
		return
	}
	streamContext, cancel := context.WithCancel(ctx)
	if !s.registerStream(streamID, cancel) {
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
		return
	}
	input := newExecInput()
	var resize *resizeQueue
	if params.tty() {
		columns, rows := params.initialDimensions()
		resize = newResizeQueue(columns, rows)
	}
	session := &execSession{input: input, resize: resize, stdin: params.stdin()}
	if !s.registerExecSession(streamID, session) {
		s.unregisterStream(streamID)
		input.Close()
		if resize != nil {
			resize.Close()
		}
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("exec stream %q already exists", streamID), nil)
		return
	}
	result := map[string]any{"streamID": streamID, "status": "started", "namespace": params.Namespace, "pod": params.Pod, "container": params.Container, "attach": true, "tty": params.tty(), "stdin": params.stdin()}
	s.write(protocol.Response(request.ID, result))
	s.write(protocol.Event(streamID, "exec.started", result))
	s.work.Add(1)
	go func() {
		defer s.work.Done()
		defer s.unregisterExecSession(streamID)
		defer s.unregisterStream(streamID)
		defer cancel()
		defer input.Close()
		if resize != nil {
			defer resize.Close()
		}
		streams := PodExecStreams{Stdout: execEventWriter{server: s, streamID: streamID, event: "exec.stdout"}, Stderr: execEventWriter{server: s, streamID: streamID, event: "exec.stderr"}}
		if params.stdin() {
			streams.Stdin = input
		}
		if resize != nil {
			streams.TerminalSizeQueue = resize
		}
		err := s.cluster.PodExec(streamContext, params.request(), streams)
		closeResult := map[string]any{"reason": "completed", "exitCode": 0}
		if streamContext.Err() != nil {
			closeResult = map[string]any{"reason": "cancelled"}
		} else if err != nil {
			closeResult = map[string]any{"reason": "error", "message": err.Error()}
			if exitCode, isExit := remoteExitCode(err); isExit {
				closeResult["exitCode"] = exitCode
			}
			s.write(protocol.Event(streamID, "exec.error", closeResult))
		}
		s.write(protocol.Event(streamID, "exec.closed", closeResult))
	}()
}

func remoteExitCode(err error) (int, bool) {
	var exitError kubeexec.ExitError
	if errors.As(err, &exitError) && exitError.Exited() {
		return exitError.ExitStatus(), true
	}
	return 0, false
}

type portForwardParams struct {
	StreamID     string `json:"streamID"`
	Namespace    string `json:"namespace"`
	Pod          string `json:"pod"`
	LocalPort    int    `json:"localPort"`
	RemotePort   int    `json:"remotePort"`
	LocalAddress string `json:"localAddress"`
}

func (p *portForwardParams) validate() error {
	if strings.TrimSpace(p.Namespace) == "" || strings.TrimSpace(p.Pod) == "" {
		return errors.New("namespace and pod are required")
	}
	if p.RemotePort < 1 || p.RemotePort > 65535 {
		return errors.New("remotePort must be between 1 and 65535")
	}
	if p.LocalPort < 0 || p.LocalPort > 65535 {
		return errors.New("localPort must be between 0 and 65535")
	}
	p.LocalAddress = strings.TrimSpace(p.LocalAddress)
	if p.LocalAddress == "" || strings.EqualFold(p.LocalAddress, "localhost") {
		p.LocalAddress = "127.0.0.1"
	}
	ip := net.ParseIP(p.LocalAddress)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("localAddress must be a loopback IP address")
	}
	return nil
}

func (p portForwardParams) request() PortForwardRequest {
	return PortForwardRequest{
		Namespace: p.Namespace, Pod: p.Pod, LocalPort: p.LocalPort,
		RemotePort: p.RemotePort, LocalAddress: p.LocalAddress,
	}
}

// startPortForward waits to acknowledge the request until client-go confirms
// both the API-server tunnel and local listener. This lets the GUI safely open
// the returned endpoint immediately, including when localPort was zero.
func (s *Server) startPortForward(ctx context.Context, request protocol.Request) {
	var params portForwardParams
	if err := decodeParams(request.Params, &params); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	if err := params.validate(); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		s.writeFailure(request.ID, "invalid_params", errors.New("streamID is required"), nil)
		return
	}

	streamContext, cancel := context.WithCancel(ctx)
	if !s.registerStream(streamID, cancel) {
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
		return
	}
	defer s.unregisterStream(streamID)
	defer cancel()

	ready := make(chan PortForwardBinding, 1)
	done := make(chan error, 1)
	go func() {
		done <- s.cluster.PortForward(streamContext, params.request(), func(binding PortForwardBinding) {
			// The client must only signal one binding. Keep the callback
			// non-blocking so a failing forward cannot strand a client-go goroutine.
			select {
			case ready <- binding:
			default:
			}
		})
	}()

	var forwardErr error
	select {
	case binding := <-ready:
		if streamContext.Err() != nil {
			forwardErr = <-done
			break
		}
		result := map[string]any{
			"streamID": streamID, "status": "ready", "namespace": binding.Namespace,
			"pod": binding.Pod, "localAddress": binding.LocalAddress,
			"localPort": binding.LocalPort, "remotePort": binding.RemotePort,
		}
		s.write(protocol.Response(request.ID, result))
		s.write(protocol.Event(streamID, "portforward.ready", result))
		forwardErr = <-done
	case forwardErr = <-done:
		if streamContext.Err() == nil {
			if forwardErr == nil {
				forwardErr = errors.New("port forward ended before it was ready")
			}
			s.writeFailure(request.ID, "kubernetes_error", forwardErr, nil)
			return
		}
	}

	reason := "completed"
	if streamContext.Err() != nil {
		reason = "cancelled"
	} else if forwardErr != nil {
		reason = "error"
		s.write(protocol.Event(streamID, "portforward.error", map[string]any{"message": forwardErr.Error()}))
	}
	s.write(protocol.Event(streamID, "portforward.closed", map[string]any{"reason": reason}))
}

func (p logParams) validate() error {
	if p.Namespace == "" || p.Pod == "" {
		return errors.New("namespace and pod are required")
	}
	if p.TailLines < 0 {
		return errors.New("tailLines cannot be negative")
	}
	return nil
}

// startLogs keeps log backpressure outside Swift and couples the stream to a
// cancellable protocol ID. The frontend can always discard old lines locally.
func (s *Server) startLogs(ctx context.Context, request protocol.Request) {
	var params logParams
	if err := decodeParams(request.Params, &params); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	if err := params.validate(); err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		s.writeFailure(request.ID, "invalid_params", errors.New("streamID is required"), nil)
		return
	}
	streamContext, cancel := context.WithCancel(ctx)
	if !s.registerStream(streamID, cancel) {
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
		return
	}
	stream, err := s.cluster.PodLogs(streamContext, params.Namespace, params.Pod, params.Container, params.Previous, params.Follow, params.Timestamps, params.TailLines)
	if err != nil {
		s.unregisterStream(streamID)
		cancel()
		s.writeFailure(request.ID, "kubernetes_error", err, nil)
		return
	}
	s.write(protocol.Response(request.ID, map[string]any{"streamID": streamID, "status": "started"}))
	s.work.Add(1)
	go func() {
		defer s.work.Done()
		defer s.unregisterStream(streamID)
		defer cancel()
		defer stream.Close()
		scanner := bufio.NewScanner(stream)
		scanner.Buffer(make([]byte, 64*1024), maxRequestBytes)
		for scanner.Scan() {
			s.write(protocol.Event(streamID, "logs.data", map[string]any{"line": scanner.Text()}))
		}
		reason := "completed"
		if streamContext.Err() != nil {
			reason = "cancelled"
		}
		if err := scanner.Err(); err != nil && streamContext.Err() == nil {
			s.write(protocol.Event(streamID, "logs.error", map[string]any{"message": err.Error()}))
			reason = "error"
		}
		s.write(protocol.Event(streamID, "logs.closed", map[string]any{"reason": reason}))
	}()
}

func (s *Server) startWatch(ctx context.Context, request protocol.Request) {
	params, err := decodeResourceParams(request.Params, false)
	if err != nil {
		s.writeFailure(request.ID, "invalid_params", err, nil)
		return
	}
	streamID := request.StreamID
	if streamID == "" {
		streamID = params.StreamID
	}
	if streamID == "" {
		s.writeFailure(request.ID, "invalid_params", errors.New("streamID is required"), nil)
		return
	}

	watchContext, cancel := context.WithCancel(ctx)
	if !s.registerStream(streamID, cancel) {
		cancel()
		s.writeFailure(request.ID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
		return
	}

	watcher, watchErr := s.cluster.Watch(watchContext, params.gvr(), params.Namespace, params.isNamespaced(), params.Selector, params.FieldSelector)
	if watchErr != nil {
		s.unregisterStream(streamID)
		cancel()
		s.writeFailure(request.ID, "kubernetes_error", watchErr, nil)
		return
	}

	s.write(protocol.Response(request.ID, map[string]any{"streamID": streamID, "status": "started"}))
	s.work.Add(1)
	go func() {
		defer s.work.Done()
		defer s.unregisterStream(streamID)
		defer cancel()
		defer watcher.Stop()
		s.write(protocol.Event(streamID, "resource.watch.started", map[string]any{"gvr": params.gvrString(), "namespace": params.Namespace}))

		for event := range watcher.ResultChan() {
			if object, ok := event.Object.(*unstructured.Unstructured); ok {
				name := watchEventName(event.Type)
				if name != "" {
					s.write(protocol.Event(streamID, name, summarize(object)))
					continue
				}
			}
			s.write(protocol.Event(streamID, "resource.watch.event", map[string]any{"type": string(event.Type), "resource": event.Object}))
		}

		reason := "completed"
		if watchContext.Err() != nil {
			reason = "cancelled"
		}
		s.write(protocol.Event(streamID, "resource.watch.closed", map[string]any{"reason": reason}))
	}()
}

func (s *Server) registerStream(id string, cancel context.CancelFunc) bool {
	s.streamMu.Lock()
	defer s.streamMu.Unlock()
	if _, exists := s.streams[id]; exists {
		return false
	}
	s.streams[id] = cancel
	return true
}

func (s *Server) unregisterStream(id string) {
	s.streamMu.Lock()
	delete(s.streams, id)
	s.streamMu.Unlock()
}

func (s *Server) registerExecSession(id string, session *execSession) bool {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	if _, exists := s.execs[id]; exists {
		return false
	}
	s.execs[id] = session
	return true
}

func (s *Server) unregisterExecSession(id string) {
	s.execMu.Lock()
	delete(s.execs, id)
	s.execMu.Unlock()
}

func (s *Server) execSession(id string) *execSession {
	s.execMu.Lock()
	defer s.execMu.Unlock()
	return s.execs[id]
}

func (s *Server) cancelStream(id string) bool {
	s.streamMu.Lock()
	cancel, exists := s.streams[id]
	s.streamMu.Unlock()
	if exists {
		cancel()
	}
	return exists
}

func (s *Server) cancelAllStreams() {
	s.streamMu.Lock()
	cancels := make([]context.CancelFunc, 0, len(s.streams))
	for _, cancel := range s.streams {
		cancels = append(cancels, cancel)
	}
	s.streamMu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

func (s *Server) write(envelope protocol.Envelope) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = json.NewEncoder(s.out).Encode(envelope)
}

func (s *Server) writeFailure(id, code string, err error, details any) {
	s.write(protocol.Envelope{Version: protocol.Version, ID: id, Type: "response", Error: &protocol.Error{Code: code, Message: err.Error(), Details: details}})
}

func decodeParams(raw json.RawMessage, destination any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return errors.New("params are required")
	}
	if err := json.Unmarshal(raw, destination); err != nil {
		return fmt.Errorf("decode params: %w", err)
	}
	return nil
}

type resourceParams struct {
	Group         string `json:"group"`
	Version       string `json:"version"`
	Resource      string `json:"resource"`
	GVR           string `json:"gvr"`
	Namespace     string `json:"namespace"`
	Namespaced    *bool  `json:"namespaced"`
	Selector      string `json:"selector"`
	FieldSelector string `json:"fieldSelector"`
	Name          string `json:"name"`
	StreamID      string `json:"streamID"`
}

func decodeResourceParams(raw json.RawMessage, nameRequired bool) (resourceParams, error) {
	var params resourceParams
	if err := decodeParams(raw, &params); err != nil {
		return params, err
	}
	if err := params.validateResource(); err != nil {
		return params, err
	}
	if nameRequired && params.Name == "" {
		return params, errors.New("name is required")
	}
	if nameRequired && params.isNamespaced() && params.Namespace == "" {
		return params, errors.New("namespace is required for a namespaced resource")
	}
	return params, nil
}

func (p *resourceParams) validateResource() error {
	if p.GVR != "" {
		parts := splitGVR(p.GVR)
		if len(parts) == 2 {
			p.Version, p.Resource = parts[0], parts[1]
		}
		if len(parts) == 3 {
			p.Group, p.Version, p.Resource = parts[0], parts[1], parts[2]
		}
	}
	if p.Version == "" {
		p.Version = "v1"
	}
	if p.Resource == "" {
		return errors.New("resource is required (or provide gvr)")
	}
	return nil
}

func (p resourceParams) isNamespaced() bool { return p.Namespaced == nil || *p.Namespaced }
func (p resourceParams) gvr() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: p.Group, Version: p.Version, Resource: p.Resource}
}
func (p resourceParams) gvrString() string {
	if p.Group == "" {
		return p.Version + "/" + p.Resource
	}
	return p.Group + "/" + p.Version + "/" + p.Resource
}

func splitGVR(value string) []string {
	var parts []string
	for _, part := range strings.Split(value, "/") {
		if part != "" {
			parts = append(parts, part)
		}
	}
	return parts
}

type patchParams struct {
	resourceParams
	Patch json.RawMessage `json:"patch"`
}

func (p *patchParams) validate() error {
	if err := p.validateResource(); err != nil {
		return err
	}
	if p.Name == "" {
		return errors.New("name is required")
	}
	if p.isNamespaced() && p.Namespace == "" {
		return errors.New("namespace is required for a namespaced resource")
	}
	if !json.Valid(p.Patch) || len(p.Patch) == 0 {
		return errors.New("patch must be a JSON object")
	}
	var object map[string]any
	if err := json.Unmarshal(p.Patch, &object); err != nil || object == nil {
		return errors.New("patch must be a JSON object")
	}
	return nil
}

type manifestApplyParams struct {
	resourceParams
	ExpectedUID string `json:"expectedUID"`
	Kind        string `json:"kind"`
	Manifest    string `json:"manifest"`
	Confirm     bool   `json:"confirm"`
}

func decodeManifestApplyParams(raw json.RawMessage) (manifestApplyParams, error) {
	var params manifestApplyParams
	if err := decodeParams(raw, &params); err != nil {
		return params, err
	}
	if err := params.validate(); err != nil {
		return params, err
	}
	return params, nil
}

func (p manifestApplyParams) identity() ManifestIdentity {
	return ManifestIdentity{
		Group: p.Group, Version: p.Version, Resource: p.Resource, Namespaced: p.isNamespaced(),
		Namespace: p.Namespace, Name: p.Name, UID: p.ExpectedUID, Kind: p.Kind,
	}
}

func (p manifestApplyParams) request(dryRun bool) ManifestApplyRequest {
	return ManifestApplyRequest{Identity: p.identity(), Object: p.object(), DryRun: dryRun}
}

func (p *manifestApplyParams) validate() error {
	if err := p.validateResource(); err != nil {
		return err
	}
	p.ExpectedUID = strings.TrimSpace(p.ExpectedUID)
	p.Kind = strings.TrimSpace(p.Kind)
	p.Manifest = strings.TrimSpace(p.Manifest)
	if p.Name == "" || p.ExpectedUID == "" || p.Kind == "" {
		return errors.New("name, expectedUID, and kind are required")
	}
	if p.isNamespaced() && p.Namespace == "" {
		return errors.New("namespace is required for a namespaced resource")
	}
	if p.Manifest == "" {
		return errors.New("manifest is required")
	}
	object, err := parseManifestYAML(p.Manifest)
	if err != nil {
		return err
	}
	if object.GetAPIVersion() != p.gvr().GroupVersion().String() || object.GetKind() != p.Kind {
		return fmt.Errorf("manifest apiVersion and kind must remain %s and %s", p.gvr().GroupVersion().String(), p.Kind)
	}
	if object.GetName() != p.Name {
		return fmt.Errorf("manifest metadata.name must remain %q", p.Name)
	}
	if p.isNamespaced() && object.GetNamespace() != p.Namespace {
		return fmt.Errorf("manifest metadata.namespace must remain %q", p.Namespace)
	}
	if !p.isNamespaced() && object.GetNamespace() != "" {
		return errors.New("manifest metadata.namespace must be empty for a cluster-scoped resource")
	}
	if uid := string(object.GetUID()); uid != "" && uid != p.ExpectedUID {
		return errors.New("manifest metadata.uid does not match expectedUID")
	}
	for _, field := range []string{"resourceVersion", "managedFields", "creationTimestamp", "generation", "selfLink", "deletionTimestamp", "deletionGracePeriodSeconds"} {
		if _, found, _ := unstructured.NestedFieldNoCopy(object.Object, "metadata", field); found {
			return fmt.Errorf("manifest metadata.%s is server-managed and must be omitted", field)
		}
	}
	if _, found, _ := unstructured.NestedFieldNoCopy(object.Object, "status"); found {
		return errors.New("manifest status is server-managed and must be omitted")
	}
	return nil
}

func (p manifestApplyParams) object() *unstructured.Unstructured {
	object, _ := parseManifestYAML(p.Manifest)
	return object
}

func parseManifestYAML(source string) (*unstructured.Unstructured, error) {
	var object map[string]any
	if err := yaml.UnmarshalStrict([]byte(source), &object); err != nil {
		return nil, fmt.Errorf("invalid manifest YAML: %w", err)
	}
	if object == nil {
		return nil, errors.New("manifest must be a YAML object")
	}
	result := &unstructured.Unstructured{Object: object}
	if result.GetAPIVersion() == "" || result.GetKind() == "" {
		return nil, errors.New("manifest apiVersion and kind are required")
	}
	if result.GetName() == "" {
		return nil, errors.New("manifest metadata.name is required")
	}
	return result, nil
}

func NewManifestDocument(object *unstructured.Unstructured, identity ManifestIdentity) (ManifestDocument, error) {
	if object == nil {
		return ManifestDocument{}, errors.New("Kubernetes returned an empty manifest")
	}
	editable := canonicalEditableObject(object)
	encoded, err := yaml.Marshal(editable.Object)
	if err != nil {
		return ManifestDocument{}, fmt.Errorf("marshal canonical manifest YAML: %w", err)
	}
	identity.Kind = object.GetKind()
	if identity.UID == "" {
		identity.UID = string(object.GetUID())
	}
	return ManifestDocument{Identity: identity, YAML: string(encoded)}, nil
}

// canonicalEditableObject strips fields owned by the API server. They are not
// useful in an editor and would make a read → edit → apply cycle noisy or
// invalid, especially for dynamic custom resources.
func canonicalEditableObject(object *unstructured.Unstructured) *unstructured.Unstructured {
	editable := object.DeepCopy()
	unstructured.RemoveNestedField(editable.Object, "status")
	for _, field := range []string{"uid", "resourceVersion", "managedFields", "creationTimestamp", "generation", "selfLink", "deletionTimestamp", "deletionGracePeriodSeconds"} {
		unstructured.RemoveNestedField(editable.Object, "metadata", field)
	}
	return editable
}

func manifestOperationError(err error, fallback string) *operationError {
	if apierrors.IsConflict(err) {
		return &operationError{code: "manifest_conflict", err: fmt.Errorf("%s: %w", fallback, err)}
	}
	if errors.Is(err, ErrManifestIdentityMismatch) {
		return &operationError{code: "identity_mismatch", err: err}
	}
	return &operationError{code: "manifest_validation_failed", err: fmt.Errorf("%s: %w", fallback, err)}
}

type scaleParams struct {
	resourceParams
	Replicas int32 `json:"replicas"`
}

type metricsParams struct {
	Version   string `json:"version"`
	Resource  string `json:"resource"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
}

func decodeMetricsQuery(raw json.RawMessage) (MetricsQuery, error) {
	var params metricsParams
	if err := decodeParams(raw, &params); err != nil {
		return MetricsQuery{}, err
	}
	params.Version = strings.TrimSpace(params.Version)
	if params.Version == "" {
		params.Version = "v1beta1"
	}
	if params.Version != "v1beta1" {
		return MetricsQuery{}, fmt.Errorf("unsupported metrics version %q (supported: v1beta1)", params.Version)
	}
	params.Resource = strings.TrimSpace(strings.ToLower(params.Resource))
	switch params.Resource {
	case "pods":
		// Namespace is optional: empty intentionally means all namespaces.
	case "nodes":
		if strings.TrimSpace(params.Namespace) != "" {
			return MetricsQuery{}, errors.New("namespace is not valid for node metrics")
		}
	default:
		return MetricsQuery{}, errors.New("resource must be pods or nodes")
	}
	return MetricsQuery{
		Version: params.Version, Resource: params.Resource,
		Namespace: strings.TrimSpace(params.Namespace), Name: strings.TrimSpace(params.Name),
	}, nil
}

type accessCheckParams struct {
	resourceParams
	Verb        string `json:"verb"`
	Subresource string `json:"subresource"`
}

func decodeAccessCheckParams(raw json.RawMessage) (accessCheckParams, error) {
	var params accessCheckParams
	if err := decodeParams(raw, &params); err != nil {
		return params, err
	}
	if err := params.validateResource(); err != nil {
		return params, err
	}
	params.Verb = strings.TrimSpace(params.Verb)
	if params.Verb == "" {
		return params, errors.New("verb is required")
	}
	return params, nil
}

func (p accessCheckParams) accessCheck() AccessCheck {
	return AccessCheck{
		Verb:        p.Verb,
		Group:       p.Group,
		Version:     p.Version,
		Resource:    p.Resource,
		Subresource: p.Subresource,
		Namespace:   p.Namespace,
		Name:        p.Name,
	}
}

func (p *scaleParams) validate() error {
	if err := p.validateResource(); err != nil {
		return err
	}
	if p.Name == "" {
		return errors.New("name is required")
	}
	if p.isNamespaced() && p.Namespace == "" {
		return errors.New("namespace is required for a namespaced resource")
	}
	if p.Replicas < 0 {
		return errors.New("replicas cannot be negative")
	}
	return nil
}

func summarize(item *unstructured.Unstructured) ResourceSummary {
	status, _, _ := unstructured.NestedString(item.Object, "status", "phase")
	if status == "" {
		status, _, _ = unstructured.NestedString(item.Object, "status", "state")
	}
	if status == "" {
		status = "Unknown"
	}
	created := item.GetCreationTimestamp().Time
	age := "—"
	if !created.IsZero() {
		age = humanDuration(created)
	}
	return ResourceSummary{
		APIVersion: item.GetAPIVersion(), Kind: item.GetKind(), Namespace: item.GetNamespace(), Name: item.GetName(),
		UID: string(item.GetUID()), CreatedAt: created, Age: age, Status: status,
		Labels: item.GetLabels(), Raw: item.Object,
	}
}

func watchEventName(eventType watch.EventType) string {
	switch eventType {
	case watch.Added:
		return "resource.added"
	case watch.Modified:
		return "resource.modified"
	case watch.Deleted:
		return "resource.deleted"
	default:
		return ""
	}
}

func humanDuration(created time.Time) string {
	duration := time.Since(created)
	if duration < 0 {
		return "0s"
	}
	if duration < time.Minute {
		return fmt.Sprintf("%ds", int(duration.Seconds()))
	}
	if duration < time.Hour {
		return fmt.Sprintf("%dm", int(duration.Minutes()))
	}
	if duration < 24*time.Hour {
		return fmt.Sprintf("%dh", int(duration.Hours()))
	}
	if duration < 30*24*time.Hour {
		return fmt.Sprintf("%dd", int(duration.Hours()/24))
	}
	if duration < 365*24*time.Hour {
		return fmt.Sprintf("%dmo", int(duration.Hours()/(24*30)))
	}
	return fmt.Sprintf("%dy", int(duration.Hours()/(24*365)))
}
