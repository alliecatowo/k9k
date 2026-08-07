package api

import (
	"bufio"
	"context"
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
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
)

const maxRequestBytes = 16 << 20

// ClusterClient is the narrow Kubernetes surface used by the IPC server. It is
// intentionally an interface so the protocol can be exercised without a live
// cluster.
type ClusterClient interface {
	Contexts() ([]Context, error)
	SelectContext(name string) error
	Namespaces(context.Context) ([]string, error)
	Discovery(context.Context) ([]ResourceType, error)
	List(context.Context, schema.GroupVersionResource, string, bool, string) ([]ResourceSummary, error)
	Get(context.Context, schema.GroupVersionResource, string, string, bool) (*unstructured.Unstructured, error)
	Watch(context.Context, schema.GroupVersionResource, string, bool, string) (watch.Interface, error)
	Delete(context.Context, schema.GroupVersionResource, string, string, bool) error
	Patch(context.Context, schema.GroupVersionResource, string, string, bool, []byte) (*unstructured.Unstructured, error)
	PodLogs(context.Context, string, string, string, bool, bool, bool, int64) (io.ReadCloser, error)
	Events(context.Context, string, string) ([]ClusterEvent, error)
	CheckAccess(context.Context, AccessCheck) (AccessReview, error)
	PortForward(context.Context, PortForwardRequest, func(PortForwardBinding)) error
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
	work     sync.WaitGroup
}

func NewServer(cluster ClusterClient, input io.Reader, output io.Writer) *Server {
	return &Server{
		cluster: cluster,
		in:      input,
		out:     output,
		streams: make(map[string]context.CancelFunc),
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
		result, listErr := s.cluster.List(ctx, params.gvr(), params.Namespace, params.isNamespaced(), params.Selector)
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

	watcher, watchErr := s.cluster.Watch(watchContext, params.gvr(), params.Namespace, params.isNamespaced(), params.Selector)
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
	Group      string `json:"group"`
	Version    string `json:"version"`
	Resource   string `json:"resource"`
	GVR        string `json:"gvr"`
	Namespace  string `json:"namespace"`
	Namespaced *bool  `json:"namespaced"`
	Selector   string `json:"selector"`
	Name       string `json:"name"`
	StreamID   string `json:"streamID"`
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

type scaleParams struct {
	resourceParams
	Replicas int32 `json:"replicas"`
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
