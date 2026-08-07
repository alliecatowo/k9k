package protocol

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"
)

func TestRequestJSONRoundTrip(t *testing.T) {
	t.Parallel()

	want := Request{
		Version:   Version,
		ID:        "request-42",
		Operation: "resource.list",
		StreamID:  "stream-7",
		Params:    json.RawMessage(`{"group":"apps","version":"v1","resource":"deployments"}`),
	}
	encoded, err := json.Marshal(want)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}

	var got Request
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatalf("unmarshal request: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("round trip = %#v, want %#v", got, want)
	}
}

func TestResponseProducesVersionedResponse(t *testing.T) {
	t.Parallel()

	got := Response("request-1", map[string]any{"contexts": 2})
	if got.Version != Version || got.ID != "request-1" || got.Type != "response" {
		t.Errorf("response envelope = %#v", got)
	}
	if got.Error != nil {
		t.Errorf("successful response has error: %#v", got.Error)
	}
}

func TestEventUsesStreamIDInsteadOfRequestID(t *testing.T) {
	t.Parallel()

	got := Event("watch-pods", "resource.changed", map[string]string{"name": "api-0"})
	if got.Version != Version || got.StreamID != "watch-pods" || got.Type != "resource.changed" {
		t.Errorf("event envelope = %#v", got)
	}
	if got.ID != "" {
		t.Errorf("event ID = %q, want empty", got.ID)
	}
}

func TestFailurePreservesErrorContract(t *testing.T) {
	t.Parallel()

	got := Failure("request-3", "not_found", errors.New("pod api-0 was not found"))
	if got.Version != Version || got.ID != "request-3" || got.Type != "response" {
		t.Errorf("failure envelope = %#v", got)
	}
	if got.Error == nil {
		t.Fatal("failure did not include error")
	}
	if got.Error.Code != "not_found" || got.Error.Message != "pod api-0 was not found" {
		t.Errorf("error = %#v", got.Error)
	}
}

func TestOptionalProtocolFieldsAreOmitted(t *testing.T) {
	t.Parallel()

	encoded, err := json.Marshal(Request{Version: Version, ID: "request-4", Operation: "context.list"})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatalf("decode request fields: %v", err)
	}
	if _, exists := fields["streamID"]; exists {
		t.Error("empty streamID was serialized")
	}
	if _, exists := fields["params"]; exists {
		t.Error("empty params was serialized")
	}
}
