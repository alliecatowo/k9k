// Package protocol defines K9k's versioned stdin/stdout wire protocol.
package protocol

import "encoding/json"

const Version = 1

type Request struct {
	Version   int             `json:"version"`
	ID        string          `json:"id"`
	Operation string          `json:"operation"`
	StreamID  string          `json:"streamID,omitempty"`
	Params    json.RawMessage `json:"params,omitempty"`
}

type Envelope struct {
	Version  int    `json:"version"`
	ID       string `json:"id,omitempty"`
	StreamID string `json:"streamID,omitempty"`
	Type     string `json:"type"`
	Result   any    `json:"result,omitempty"`
	Error    *Error `json:"error,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

func Response(id string, result any) Envelope { return Envelope{Version: Version, ID: id, Type: "response", Result: result} }
func Event(streamID, name string, result any) Envelope {
	return Envelope{Version: Version, StreamID: streamID, Type: name, Result: result}
}
func Failure(id, code string, err error) Envelope {
	return Envelope{Version: Version, ID: id, Type: "response", Error: &Error{Code: code, Message: err.Error()}}
}

