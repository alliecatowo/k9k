package api

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/k9k-app/k9k/backend/internal/protocol"
)

func TestStreamRegistryBoundsActiveStreamsAndReleasesCancelledSlots(t *testing.T) {
	server := NewServer(nil, nil, &bytes.Buffer{})
	for index := range maxActiveStreams {
		id := streamTestID(index)
		if got := server.registerStream(id, func() {}); got != streamRegistered {
			t.Fatalf("register %q = %v, want registered", id, got)
		}
	}
	if got := server.registerStream("overflow", func() {}); got != streamLimitReached {
		t.Fatalf("overflow register = %v, want streamLimitReached", got)
	}

	server.unregisterStream(streamTestID(0))
	if got := server.registerStream("replacement", func() {}); got != streamRegistered {
		t.Fatalf("replacement register = %v, want registered", got)
	}
}

func TestStreamRegistryReturnsStableCapacityError(t *testing.T) {
	var output bytes.Buffer
	server := NewServer(nil, nil, &output)
	for index := range maxActiveStreams {
		if got := server.registerStream(streamTestID(index), func() {}); got != streamRegistered {
			t.Fatalf("register %d = %v", index, got)
		}
	}

	cancelled := false
	if rejected := server.registerStreamFailure("overflow-request", "overflow", func() { cancelled = true }); !rejected {
		t.Fatal("overflow registration unexpectedly succeeded")
	}
	if !cancelled {
		t.Fatal("rejected stream context was not cancelled")
	}
	var response protocol.Envelope
	if err := json.Unmarshal(output.Bytes(), &response); err != nil {
		t.Fatalf("decode capacity response: %v; output=%q", err, output.String())
	}
	if response.ID != "overflow-request" || response.Error == nil || response.Error.Code != "stream_limit" {
		t.Fatalf("capacity response = %#v, want stream_limit", response)
	}
	details, ok := response.Error.Details.(map[string]any)
	if !ok || details["limit"] != float64(maxActiveStreams) {
		t.Fatalf("capacity details = %#v, want limit %d", response.Error.Details, maxActiveStreams)
	}

	server.cancelAllStreams()
}

func streamTestID(index int) string { return "stream-" + string(rune('a'+index)) }
