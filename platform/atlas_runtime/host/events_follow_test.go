package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// wait bounds how long a test waits for the follower; it is a test safety net, not behavior.
const wait = 5 * time.Second

// fakeClock fires timers only when the test advances it.
type fakeClock struct {
	mu     sync.Mutex
	now    time.Duration
	timers []fakeTimer
	armed  map[time.Duration]int
}

type fakeTimer struct {
	at time.Duration
	ch chan time.Time
}

func newFakeClock() *fakeClock { return &fakeClock{armed: map[time.Duration]int{}} }

func (c *fakeClock) After(d time.Duration) <-chan time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	ch := make(chan time.Time, 1)
	c.timers = append(c.timers, fakeTimer{c.now + d, ch})
	c.armed[d]++
	return ch
}

// waitArmed waits until the follower has asked for n timers of duration d in total.
func (c *fakeClock) waitArmed(t *testing.T, d time.Duration, n int) {
	t.Helper()
	for deadline := time.Now().Add(wait); ; time.Sleep(time.Millisecond) {
		c.mu.Lock()
		got := c.armed[d]
		c.mu.Unlock()
		if got >= n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("follower armed %d timers of %v, want %d", got, d, n)
		}
	}
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now += d
	pending := c.timers[:0]
	for _, timer := range c.timers {
		if timer.at <= c.now {
			timer.ch <- time.Time{}
		} else {
			pending = append(pending, timer)
		}
	}
	c.timers = pending
}

// fakeJournalSocket is a scripted runtime.sock journal: the test accepts each connection and
// writes its frames. Nothing listens on read.sock.
type fakeJournalSocket struct {
	path     string
	listener net.Listener
	conns    chan net.Conn
}

func newFakeJournalSocket(t *testing.T) (*fakeJournalSocket, string) {
	t.Helper()
	dir := socketDirectory(t)
	socket := &fakeJournalSocket{path: filepath.Join(dir, "runtime.sock"), conns: make(chan net.Conn, 16)}
	socket.listen(t)
	t.Cleanup(socket.close)
	return socket, dir
}

func (s *fakeJournalSocket) listen(t *testing.T) {
	t.Helper()
	listener, err := net.Listen("unix", s.path)
	if err != nil {
		t.Fatal(err)
	}
	s.listener = listener
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			s.conns <- conn
		}
	}()
}

// close stops listening and removes the socket, so dialing fails as with a stopped Runtime.
func (s *fakeJournalSocket) close() {
	if s.listener != nil {
		s.listener.Close()
		s.listener = nil
	}
}

type fakeFollow struct {
	conn    net.Conn
	request map[string]any
}

func (s *fakeJournalSocket) accept(t *testing.T) *fakeFollow {
	t.Helper()
	select {
	case conn := <-s.conns:
		t.Cleanup(func() { conn.Close() })
		conn.SetReadDeadline(time.Now().Add(wait))
		line, err := bufio.NewReader(conn).ReadBytes('\n')
		if err != nil {
			t.Fatalf("read follow request: %v", err)
		}
		follow := &fakeFollow{conn: conn}
		if err = json.Unmarshal(line, &follow.request); err != nil {
			t.Fatal(err)
		}
		if follow.request["api"] != "runtime.read/1" || follow.request["op"] != "follow" {
			t.Fatalf("not a follow request: %s", line)
		}
		return follow
	case <-time.After(wait):
		t.Fatal("follower did not connect")
		return nil
	}
}

func (s *fakeJournalSocket) noConnection(t *testing.T) {
	t.Helper()
	select {
	case <-s.conns:
		t.Fatal("follower reconnected before its back-off elapsed")
	default:
	}
}

func (f *fakeFollow) send(t *testing.T, frame map[string]any) {
	t.Helper()
	frame["api"], frame["op"] = "runtime.read/1", "follow"
	if err := json.NewEncoder(f.conn).Encode(frame); err != nil {
		t.Fatal(err)
	}
}

func page(cursor string, sequences ...int) map[string]any {
	events := []any{}
	for _, sequence := range sequences {
		events = append(events, map[string]any{"sequence": sequence, "kind": "execution_finished", "turn_id": "turn-1", "worker_id": "w"})
	}
	return map[string]any{"type": "page", "events": events, "cursor": cursor, "more": false, "recording_started_at": "2026-11-10T00:00:00Z"}
}

// lineSink collects the follower's output lines.
type lineSink struct{ lines chan string }

func (s *lineSink) Write(p []byte) (int, error) {
	for _, line := range strings.SplitAfter(string(p), "\n") {
		if line != "" {
			s.lines <- strings.TrimSuffix(line, "\n")
		}
	}
	return len(p), nil
}

func (s *lineSink) expect(t *testing.T, want ...string) {
	t.Helper()
	for _, expected := range want {
		select {
		case got := <-s.lines:
			if got != expected {
				t.Fatalf("output line %q, want %q", got, expected)
			}
		case <-time.After(wait):
			t.Fatalf("no output line, want %q", expected)
		}
	}
}

func event(sequence int) string {
	line, _ := json.Marshal(map[string]any{"sequence": sequence, "kind": "execution_finished", "turn_id": "turn-1", "worker_id": "w"})
	return string(line)
}

type followRun struct {
	cancel context.CancelFunc
	done   chan error
	out    *lineSink
	clock  *fakeClock
}

func startFollower(t *testing.T, socket *fakeJournalSocket, cursor string) *followRun {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	run := &followRun{cancel: cancel, done: make(chan error, 1), out: &lineSink{lines: make(chan string, 100)}, clock: newFakeClock()}
	follower := &eventFollower{
		dial:   func() (net.Conn, error) { return net.Dial("unix", socket.path) },
		clock:  run.clock,
		out:    run.out,
		cursor: cursor,
	}
	go func() { run.done <- follower.run(ctx) }()
	t.Cleanup(func() { cancel(); <-run.done })
	return run
}

func (r *followRun) stop(t *testing.T) {
	t.Helper()
	r.cancel()
	select {
	case err := <-r.done:
		r.done <- err
		if err != nil {
			t.Fatalf("follower did not exit cleanly: %v", err)
		}
	case <-time.After(wait):
		t.Fatal("follower did not exit after cancellation")
	}
	select {
	case line := <-r.out.lines:
		t.Fatalf("unexpected output line %q", line)
	default:
	}
}

func TestEventsFollowPrintsLiveLinesInOrder(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "e:1")
	follow := socket.accept(t)
	if follow.request["cursor"] != "e:1" {
		t.Fatalf("follow did not start from --cursor: %#v", follow.request)
	}
	follow.send(t, page("e:3", 2, 3))
	run.out.expect(t, event(2), event(3), `{"cursor":"e:3"}`)
	follow.send(t, map[string]any{"type": "heartbeat", "cursor": "e:3"})
	follow.send(t, page("e:4", 4))
	run.out.expect(t, event(4), `{"cursor":"e:4"}`)
	run.stop(t)
}

func TestEventsFollowReconnectsAtOnceFromLastCursorAfterCloseWithoutEnd(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	first := socket.accept(t)
	if _, ok := first.request["cursor"]; ok {
		t.Fatalf("follow without --cursor sent one: %#v", first.request)
	}
	first.send(t, page("e:2", 1, 2))
	run.out.expect(t, event(1), event(2), `{"cursor":"e:2"}`)
	first.conn.Close()
	// No clock advance: the reconnect must not wait for a back-off.
	second := socket.accept(t)
	if second.request["cursor"] != "e:2" {
		t.Fatalf("reconnect did not resume from the last printed cursor: %#v", second.request)
	}
	second.send(t, page("e:3", 3))
	// No unreachable/reachable lines in between, and nothing after e:2 skipped.
	run.out.expect(t, event(3), `{"cursor":"e:3"}`)
	second.send(t, map[string]any{"type": "end", "reason": "too_slow"})
	third := socket.accept(t)
	if third.request["cursor"] != "e:3" {
		t.Fatalf("too_slow reconnect did not resume from the last cursor: %#v", third.request)
	}
	run.stop(t)
}

func TestEventsFollowReportsUnreachableOnlyWhenTheReconnectFails(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	first := socket.accept(t)
	first.send(t, page("e:1", 1))
	run.out.expect(t, event(1), `{"cursor":"e:1"}`)
	socket.close()
	first.conn.Close()
	run.out.expect(t, `{"reachable":false,"reason":"connect_failed"}`)
	socket.listen(t)
	run.clock.waitArmed(t, time.Second, 1)
	socket.noConnection(t)
	run.clock.advance(time.Second)
	second := socket.accept(t)
	if second.request["cursor"] != "e:1" {
		t.Fatalf("reconnect did not resume from the last printed cursor: %#v", second.request)
	}
	second.send(t, page("e:2", 2))
	run.out.expect(t, `{"reachable":true}`, event(2), `{"cursor":"e:2"}`)
	run.stop(t)
}

func TestEventsFollowServiceStoppingIsUnreachableUntilAReconnectPages(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	first := socket.accept(t)
	first.send(t, page("e:1", 1))
	run.out.expect(t, event(1), `{"cursor":"e:1"}`)
	socket.close()
	first.send(t, map[string]any{"type": "end", "reason": "service_stopping"})
	first.conn.Close()
	run.out.expect(t, `{"reachable":false,"reason":"service_stopping"}`)
	// Retries back off (1 s, then 2 s) and report unreachable only once.
	run.clock.waitArmed(t, time.Second, 1)
	run.clock.advance(time.Second)
	run.clock.waitArmed(t, 2*time.Second, 1)
	socket.listen(t)
	socket.noConnection(t)
	run.clock.advance(2 * time.Second)
	second := socket.accept(t)
	if second.request["cursor"] != "e:1" {
		t.Fatalf("reconnect did not resume from the last printed cursor: %#v", second.request)
	}
	second.send(t, page("e:1"))
	run.out.expect(t, `{"reachable":true}`)
	second.send(t, page("e:2", 2))
	run.out.expect(t, event(2), `{"cursor":"e:2"}`)
	run.stop(t)
}

// A stopping service still answers until its exit lands, but ends a reconnect's follow with
// service_stopping before any page: the follower stays unreachable through the exit and never
// prints reachable in between.
func TestEventsFollowReconnectDuringServiceStopStaysUnreachable(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	first := socket.accept(t)
	first.send(t, page("e:1", 1))
	run.out.expect(t, event(1), `{"cursor":"e:1"}`)
	first.send(t, map[string]any{"type": "end", "reason": "service_stopping"})
	first.conn.Close()
	run.out.expect(t, `{"reachable":false,"reason":"service_stopping"}`)
	run.clock.waitArmed(t, time.Second, 1)
	run.clock.advance(time.Second)
	second := socket.accept(t)
	second.send(t, map[string]any{"type": "end", "reason": "service_stopping"})
	second.conn.Close()
	run.clock.waitArmed(t, 2*time.Second, 1)
	socket.close()
	run.clock.advance(2 * time.Second)
	run.clock.waitArmed(t, 4*time.Second, 1)
	run.stop(t)
}

func TestEventsFollowSilenceIsUnreachable(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	first := socket.accept(t)
	first.send(t, page("e:1", 1))
	run.out.expect(t, event(1), `{"cursor":"e:1"}`)
	// A heartbeat within 45 s keeps the stream alive.
	run.clock.waitArmed(t, followSilence, 2)
	run.clock.advance(30 * time.Second)
	first.send(t, map[string]any{"type": "heartbeat", "cursor": "e:1"})
	run.clock.waitArmed(t, followSilence, 3)
	run.clock.advance(30 * time.Second)
	first.send(t, page("e:2", 2))
	run.out.expect(t, event(2), `{"cursor":"e:2"}`)
	// Then 45 s with nothing is loss: the follower drops the connection and backs off.
	run.clock.waitArmed(t, followSilence, 4)
	run.clock.advance(followSilence)
	run.out.expect(t, `{"reachable":false,"reason":"silence"}`)
	first.conn.SetReadDeadline(time.Now().Add(wait))
	if _, err := first.conn.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("silent connection was not closed: %v", err)
	}
	run.clock.waitArmed(t, time.Second, 1)
	run.clock.advance(time.Second)
	second := socket.accept(t)
	if second.request["cursor"] != "e:2" {
		t.Fatalf("reconnect did not resume from the last printed cursor: %#v", second.request)
	}
	second.send(t, page("e:2"))
	run.out.expect(t, `{"reachable":true}`)
	run.stop(t)
}

func TestEventsFollowPassesResetNoticesThrough(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "e:1")
	follow := socket.accept(t)
	gap := page("e:9", 8, 9)
	gap["reset"] = map[string]any{"reason": "retention_gap", "from_sequence": 2, "to_sequence": 7}
	follow.send(t, gap)
	run.out.expect(t, `{"reset":{"from_sequence":2,"reason":"retention_gap","to_sequence":7}}`, event(8), event(9), `{"cursor":"e:9"}`)
	epoch := page("f:1", 1)
	epoch["reset"] = map[string]any{"reason": "epoch_changed"}
	follow.send(t, epoch)
	run.out.expect(t, `{"reset":{"reason":"epoch_changed"}}`, event(1), `{"cursor":"f:1"}`)
	run.stop(t)
}

func TestEventsFollowWithoutServiceStartsUnreachable(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	socket.close()
	run := startFollower(t, socket, "")
	run.out.expect(t, `{"reachable":false,"reason":"connect_failed"}`)
	run.stop(t)
}

func TestEventsFollowStopsOnInvalidCursor(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "bogus")
	follow := socket.accept(t)
	json.NewEncoder(follow.conn).Encode(map[string]any{"api": "runtime.read/1", "error": map[string]any{"code": "invalid_cursor", "message": "malformed cursor"}})
	follow.conn.Close()
	select {
	case err := <-run.done:
		run.done <- err
		if err == nil || !strings.Contains(err.Error(), "invalid_cursor") {
			t.Fatalf("expected invalid_cursor failure, got %v", err)
		}
	case <-time.After(wait):
		t.Fatal("follower kept running after invalid_cursor")
	}
}

func TestEventsFollowExitsCleanlyOnSignal(t *testing.T) {
	socket, dir := newFakeJournalSocket(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	out := &lineSink{lines: make(chan string, 100)}
	done := make(chan error, 1)
	go func() {
		result, err := executeTo([]string{"events", "--follow", "--cursor", "e:1"}, out)
		if result != nil {
			t.Errorf("events --follow returned a result: %#v", result)
		}
		done <- err
	}()
	follow := socket.accept(t)
	follow.send(t, page("e:2", 2))
	// The first line is printed after the signal handler is installed.
	out.expect(t, event(2), `{"cursor":"e:2"}`)
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("events --follow did not exit cleanly on SIGTERM: %v", err)
		}
	case <-time.After(wait):
		t.Fatal("events --follow kept running after SIGTERM")
	}
}

// The CLI path itself, which dials <home>/runtime.sock (nothing serves read.sock): after a
// Runtime restart (a new listener, then the old connection closes) it resumes from the last
// printed cursor at once, and passes the new epoch's reset through.
func TestEventsFollowOnRuntimeSocketResumesAcrossARestart(t *testing.T) {
	socket, dir := newFakeJournalSocket(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	out := &lineSink{lines: make(chan string, 100)}
	done := make(chan error, 1)
	go func() {
		_, err := executeTo([]string{"events", "--follow", "--cursor", "e:1"}, out)
		done <- err
	}()
	first := socket.accept(t)
	if first.request["cursor"] != "e:1" {
		t.Fatalf("follow did not start from --cursor: %#v", first.request)
	}
	first.send(t, page("e:3", 2, 3))
	out.expect(t, event(2), event(3), `{"cursor":"e:3"}`)
	// Restart: the old listener goes, a new one binds, then the old connection drops.
	socket.close()
	socket.listen(t)
	first.conn.Close()
	second := socket.accept(t)
	if second.request["cursor"] != "e:3" {
		t.Fatalf("reconnect did not resume from the last printed cursor: %#v", second.request)
	}
	epoch := page("f:1", 1)
	epoch["reset"] = map[string]any{"reason": "epoch_changed"}
	second.send(t, epoch)
	out.expect(t, `{"reset":{"reason":"epoch_changed"}}`, event(1), `{"cursor":"f:1"}`)
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("events --follow did not exit cleanly: %v", err)
		}
	case <-time.After(wait):
		t.Fatal("events --follow kept running after SIGTERM")
	}
}

// journalServer answers each runtime.read/1 request on dir/runtime.sock with reply, recording
// the requests; nothing listens on read.sock.
func journalServer(t *testing.T, dir string, reply map[string]any) chan map[string]any {
	t.Helper()
	listener, err := net.Listen("unix", filepath.Join(dir, "runtime.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	seen := make(chan map[string]any, 4)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			var request map[string]any
			if json.NewDecoder(conn).Decode(&request) == nil {
				seen <- request
				json.NewEncoder(conn).Encode(reply)
			}
			conn.Close()
		}
	}()
	return seen
}

func TestEventsPageIsReadOnRuntimeSocket(t *testing.T) {
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	seen := journalServer(t, dir, map[string]any{"api": readAPI, "op": "events", "events": []any{}, "cursor": "e:1:5", "more": false})
	result, err := execute([]string{"events", "--cursor", "e:1:5", "--limit", "5"})
	if err != nil {
		t.Fatal(err)
	}
	if request, want := <-seen, map[string]any{"api": readAPI, "op": "events", "cursor": "e:1:5", "limit": float64(5)}; !reflect.DeepEqual(request, want) {
		t.Fatalf("request %#v, want %#v", request, want)
	}
	if want := map[string]any{"events": []any{}, "cursor": "e:1:5", "more": false}; !reflect.DeepEqual(result, want) {
		t.Fatalf("result %#v, want %#v", result, want)
	}

	// A refusal keeps its code, as on read.sock.
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	journalServer(t, dir, map[string]any{"api": readAPI, "error": map[string]any{"code": "invalid_cursor", "message": "Cursor does not identify a position in this stream"}})
	_, err = execute([]string{"events", "--cursor", "stale"})
	var out bytes.Buffer
	writeCommandError(&out, err)
	var printed map[string]any
	if json.Unmarshal(out.Bytes(), &printed); printed["code"] != "invalid_cursor" ||
		printed["error"] != "invalid_cursor: Cursor does not identify a position in this stream" {
		t.Fatalf("journal refusal lost its code: %s", out.String())
	}

	// A Runtime that answers the journal request as a command refuses it visibly.
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	journalServer(t, dir, map[string]any{"command_error": "Unknown command"})
	if _, err = execute([]string{"events"}); err == nil || !strings.Contains(err.Error(), "Unknown command") {
		t.Fatalf("a command error was not reported: %v", err)
	}

	// No Runtime: stopped, as for every other command.
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	if _, err = execute([]string{"events"}); err != errStopped {
		t.Fatalf("events without a Runtime: %v", err)
	}
}

func TestEventsFollowStopsOnACommandErrorReply(t *testing.T) {
	socket, _ := newFakeJournalSocket(t)
	run := startFollower(t, socket, "")
	follow := socket.accept(t)
	json.NewEncoder(follow.conn).Encode(map[string]any{"command_error": "Unknown command"})
	follow.conn.Close()
	select {
	case err := <-run.done:
		run.done <- err
		if err == nil || !strings.Contains(err.Error(), "Unknown command") {
			t.Fatalf("expected the command error, got %v", err)
		}
	case <-time.After(wait):
		t.Fatal("follower kept running after a command error")
	}
}
