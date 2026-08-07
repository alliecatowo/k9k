package api

import (
	"context"
	"fmt"
)

// maxActiveStreams protects the long-lived helper from an accidental client
// loop retaining watches, logs, terminals, or forwards forever. It is per
// helper process, deliberately leaves ample room for normal parallel work,
// and is released as soon as a stream closes or is cancelled.
const maxActiveStreams = 64

type streamRegistration uint8

const (
	streamRegistered streamRegistration = iota
	streamAlreadyExists
	streamLimitReached
)

func (s *Server) registerStream(id string, cancel context.CancelFunc) streamRegistration {
	s.streamMu.Lock()
	defer s.streamMu.Unlock()
	if _, exists := s.streams[id]; exists {
		return streamAlreadyExists
	}
	if len(s.streams) >= maxActiveStreams {
		return streamLimitReached
	}
	s.streams[id] = cancel
	return streamRegistered
}

func (s *Server) registerStreamFailure(requestID, streamID string, cancel context.CancelFunc) bool {
	switch s.registerStream(streamID, cancel) {
	case streamRegistered:
		return false
	case streamAlreadyExists:
		cancel()
		s.writeFailure(requestID, "stream_exists", fmt.Errorf("stream %q already exists", streamID), nil)
	case streamLimitReached:
		cancel()
		s.writeFailure(requestID, "stream_limit", fmt.Errorf("K9k allows at most %d active streams; cancel an existing stream before opening another", maxActiveStreams), map[string]any{"limit": maxActiveStreams})
	}
	return true
}
