package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// A follower that hears nothing (no page, no heartbeat) for three heartbeat intervals treats the
// Runtime as unreachable. Reconnects after loss back off from 1 s to 15 s.
const (
	followSilence    = 45 * time.Second
	followBackoffMin = time.Second
	followBackoffMax = 15 * time.Second
	followMaxLine    = 8 << 20
)

// followClock is the only source of time for events --follow, so tests can drive it.
type followClock interface {
	After(time.Duration) <-chan time.Time
}

type realClock struct{}

func (realClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

type eventFollower struct {
	dial  func() (net.Conn, error)
	clock followClock
	out   io.Writer
	// cursor is the last cursor printed; every reconnect resumes from it.
	cursor string
}

// followEventsCommand runs events --follow against <home>/read.sock until SIGINT or SIGTERM.
func followEventsCommand(dir, cursor string, out io.Writer) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	socket := filepath.Join(dir, "read.sock")
	follower := &eventFollower{
		dial:   func() (net.Conn, error) { return net.DialTimeout("unix", socket, time.Second) },
		clock:  realClock{},
		out:    out,
		cursor: cursor,
	}
	return follower.run(ctx)
}

// followFrame is one line of the read socket's follow stream, or its admission error.
type followFrame struct {
	Type   string            `json:"type"`
	Events []json.RawMessage `json:"events"`
	Cursor string            `json:"cursor"`
	Reset  json.RawMessage   `json:"reset"`
	Reason string            `json:"reason"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// followEnd says how one connection ended.
type followEnd struct {
	paged  bool   // at least one page arrived, so the Runtime answered on this connection
	closed bool   // the connection closed without an end frame
	reason string // why the Runtime counts as unreachable if the follower does not reconnect at once
	err    error  // fatal: stop following
}

// fatalReadErrors are refusals that a reconnect cannot fix.
var fatalReadErrors = map[string]bool{
	"invalid_cursor": true, "invalid_request": true, "unsupported_api": true, "not_a_read": true,
}

func (f *eventFollower) run(ctx context.Context) error {
	unreachable := false
	delay := time.Duration(0)
	for {
		if delay > 0 {
			select {
			case <-ctx.Done():
				return nil
			case <-f.clock.After(delay):
			}
		}
		result := f.connect(ctx, &unreachable)
		if ctx.Err() != nil {
			return nil
		}
		if result.err != nil {
			return result.err
		}
		if result.paged {
			delay = 0
		}
		// A connection that answered and then closed without end (for example a server that
		// dropped a slow reader), or ended too_slow, is not loss: reconnect at once. Only a failed
		// reconnect reports unreachable.
		if result.paged && (result.closed || result.reason == "too_slow") {
			continue
		}
		if !unreachable {
			unreachable = true
			if err := f.print(map[string]any{"reachable": false, "reason": result.reason}); err != nil {
				return err
			}
		}
		if delay == 0 {
			delay = followBackoffMin
		} else if delay *= 2; delay > followBackoffMax {
			delay = followBackoffMax
		}
	}
}

// connect follows one connection until it ends, prints its frames and reports how it ended.
func (f *eventFollower) connect(ctx context.Context, unreachable *bool) followEnd {
	conn, err := f.dial()
	if err != nil {
		return followEnd{reason: "connect_failed"}
	}
	defer conn.Close()
	request := map[string]any{"api": "runtime.read/1", "op": "follow"}
	if f.cursor != "" {
		request["cursor"] = f.cursor
	}
	if err = json.NewEncoder(conn).Encode(request); err != nil {
		return followEnd{reason: "connect_failed"}
	}
	lines := make(chan []byte)
	done := make(chan struct{})
	defer close(done)
	go func() {
		defer close(lines)
		reader := bufio.NewScanner(conn)
		reader.Buffer(make([]byte, 0, 64<<10), followMaxLine)
		for reader.Scan() {
			select {
			case lines <- bytes.Clone(reader.Bytes()):
			case <-done:
				return
			}
		}
	}()
	result := followEnd{}
	for {
		silence := f.clock.After(followSilence)
		var line []byte
		var open bool
		select {
		case <-ctx.Done():
			return result
		case <-silence:
			result.reason = "silence"
			return result
		case line, open = <-lines:
		}
		if !open {
			result.closed = true
			result.reason = "connection_closed"
			return result
		}
		var frame followFrame
		if err = json.Unmarshal(line, &frame); err != nil {
			result.err = fmt.Errorf("Runtime read socket sent an invalid follow line: %w", err)
			return result
		}
		if frame.Error != nil {
			if fatalReadErrors[frame.Error.Code] {
				result.err = fmt.Errorf("%s: %s", frame.Error.Code, frame.Error.Message)
			} else {
				result.reason = frame.Error.Code
			}
			return result
		}
		switch frame.Type {
		case "page":
			if err = f.page(frame, !result.paged && *unreachable); err != nil {
				result.err = err
				return result
			}
			result.paged = true
			*unreachable = false
		case "end":
			result.reason = frame.Reason
			if result.reason == "" {
				result.reason = "end"
			}
			return result
		}
		// Heartbeats and unknown frame types only prove liveness.
	}
}

// page prints a page: the reachable notice when it ends an outage, its reset, each event, and its
// cursor once it differs from the last printed one.
func (f *eventFollower) page(frame followFrame, recovered bool) error {
	if recovered {
		if err := f.print(map[string]any{"reachable": true}); err != nil {
			return err
		}
	}
	if len(frame.Reset) != 0 && !bytes.Equal(frame.Reset, []byte("null")) {
		if err := f.print(map[string]any{"reset": frame.Reset}); err != nil {
			return err
		}
	}
	for _, event := range frame.Events {
		if err := f.print(event); err != nil {
			return err
		}
	}
	if frame.Cursor == "" {
		return errors.New("Runtime read socket sent a page without a cursor")
	}
	if frame.Cursor != f.cursor {
		if err := f.print(map[string]any{"cursor": frame.Cursor}); err != nil {
			return err
		}
		f.cursor = frame.Cursor
	}
	return nil
}

// print writes one compact JSON line in a single write.
func (f *eventFollower) print(value any) error {
	line, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = f.out.Write(append(line, '\n'))
	return err
}
