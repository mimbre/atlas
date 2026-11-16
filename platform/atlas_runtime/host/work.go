package main

// The work commands: a hand-built HTTP/1.1 client of the work contract on
// <home>/backend.sock (design 2026-11-16-runtime-backend §1.8, §8). Each command maps its
// flags onto one request as given; the Runtime validates it and answers with the outcome's
// entity, or with an application/problem+json refusal. History (turns, events) is read on
// read.sock (runtime.read/1) until the operations contract (S2), so turns from before the
// cutover stay listed.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	backendSocket = "backend.sock"
	// A submit can wait for the work core while it starts another turn, which it does
	// synchronously (its facade call allows 150 s).
	backendTimeout = 160 * time.Second
	// Lists and output pages are bounded by the Runtime; this only stops a runaway reply.
	backendMaxBody = 64 << 20
	readAPI        = "runtime.read/1"
	titleMaxBytes  = 200
)

// workCall is one request of the work contract.
type workCall struct {
	method string
	path   string
	query  url.Values
	header http.Header
	body   map[string]any
}

// backendProblem is a refusal: the problem+json body (type, title, status and the
// outcome's fields, such as reason, detail, retry_after and capacity) and its HTTP status.
type backendProblem struct {
	status int
	body   map[string]any
}

func (p *backendProblem) Error() string {
	text := fmt.Sprintf("Runtime refused (HTTP %d", p.status)
	if kind, ok := p.body["type"].(string); ok && kind != "" {
		text += " " + kind
	}
	text += ")"
	if reason, ok := p.body["reason"].(string); ok && reason != "" {
		text += ": " + reason
	}
	if detail, ok := p.body["detail"].(string); ok && detail != "" {
		text += ": " + detail
	} else if title, ok := p.body["title"].(string); ok && title != "" && p.body["reason"] == nil {
		text += ": " + title
	}
	return text
}

// Result keeps the problem's fields in the CLI's error reply (writeCommandError).
func (p *backendProblem) Result() map[string]any {
	result := make(map[string]any, len(p.body))
	for key, value := range p.body {
		result[key] = value
	}
	return result
}

// readProblem is a runtime.read/1 refusal, with its code.
type readProblem struct{ code, message string }

func (p *readProblem) Error() string          { return p.code + ": " + p.message }
func (p *readProblem) Result() map[string]any { return map[string]any{"code": p.code} }

var errStopped = errors.New("Runtime service is stopped; run atlas-runtime service start")

// workCommands are the commands served by the work contract.
var workCommands = map[string]func(string, []string) (workCall, error){
	"start":    submitCall,
	"continue": submitCall,
	"status":   statusCall,
	"capacity": capacityCall,
	"retry":    retryCall,
	"stop":     cancelCall,
	"kill":     cancelCall,
	"output":   outputCall,
}

func callBackend(dir string, call workCall) (map[string]any, error) {
	socket := filepath.Join(dir, backendSocket)
	client := &http.Client{
		Timeout: backendTimeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				dialer := net.Dialer{Timeout: time.Second}
				return dialer.DialContext(ctx, "unix", socket)
			},
			DisableKeepAlives: true,
		},
	}
	var body io.Reader
	if call.body != nil {
		data, err := json.Marshal(call.body)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(data)
	}
	target := "http://localhost" + call.path
	if len(call.query) > 0 {
		target += "?" + call.query.Encode()
	}
	request, err := http.NewRequest(call.method, target, body)
	if err != nil {
		return nil, err
	}
	for name, values := range call.header {
		request.Header[name] = values
	}
	request.Header.Set("Accept", "application/json")
	if call.body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := client.Do(request)
	if err != nil {
		if absent(err) {
			return nil, errStopped
		}
		return nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, backendMaxBody+1))
	if err != nil {
		return nil, err
	}
	if len(data) > backendMaxBody {
		return nil, fmt.Errorf("Runtime backend reply exceeds %d bytes", backendMaxBody)
	}
	var reply map[string]any
	if err = json.Unmarshal(data, &reply); err != nil || reply == nil {
		return nil, fmt.Errorf("Runtime backend answered HTTP %d without a JSON object", response.StatusCode)
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, &backendProblem{status: response.StatusCode, body: reply}
	}
	return reply, nil
}

// readRequest is one runtime.read/1 operation on read.sock.
func readRequest(dir, op string, args map[string]any) (map[string]any, error) {
	conn, err := net.DialTimeout("unix", filepath.Join(dir, "read.sock"), time.Second)
	if err != nil {
		if absent(err) {
			return nil, errStopped
		}
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	request := map[string]any{"api": readAPI, "op": op}
	for key, value := range args {
		request[key] = value
	}
	if err = json.NewEncoder(conn).Encode(request); err != nil {
		return nil, err
	}
	var reply map[string]any
	if err = json.NewDecoder(conn).Decode(&reply); err != nil {
		return nil, err
	}
	if failure, ok := reply["error"].(map[string]any); ok {
		code, _ := failure["code"].(string)
		message, _ := failure["message"].(string)
		return nil, &readProblem{code: code, message: message}
	}
	delete(reply, "api")
	delete(reply, "op")
	return reply, nil
}

// visited names the flags given on the command line.
func visited(flags *flag.FlagSet) map[string]bool {
	set := map[string]bool{}
	flags.Visit(func(f *flag.Flag) { set[f.Name] = true })
	return set
}

func noArguments(flags *flag.FlagSet) error {
	if flags.NArg() != 0 {
		return errors.New("unexpected arguments")
	}
	return nil
}

// title is the assignment's first non-blank line, without a Markdown heading mark, cut to
// titleMaxBytes on a character boundary.
func title(assignment string) string {
	for _, line := range strings.Split(assignment, "\n") {
		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "#"))
		if line == "" {
			continue
		}
		if len(line) > titleMaxBytes {
			cut := titleMaxBytes
			for cut > 0 && !utf8.RuneStart(line[cut]) {
				cut--
			}
			line = line[:cut]
		}
		return line
	}
	return ""
}

// start and continue submit a work: POST /v1/work. Continue is start with --resume-from.
func submitCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	titleFlag := flags.String("title", "", "work title (default: the assignment's first line)")
	profile := flags.String("profile", "", "execution profile, for example deep_coding, light_work or independent_review")
	costClass := flags.String("cost-class", "", "cost class: low, standard or high")
	slot := flags.String("slot", "", "slot to run on (default: the Runtime chooses)")
	resume := flags.String("resume-from", "", "turn whose conversation and workspace the work continues")
	key := flags.String("key", "", "client key, sent as Idempotency-Key: the same request with it returns the same work")
	cwd := flags.String("cwd", "", "folder workspace")
	permissions := flags.String("permissions", "read-only", "folder permissions: read-only, workspace-write or materialized-folder")
	repository := flags.String("repo", "", "repository workspace (dedicated-repository): GitHub HTTPS URL")
	branch := flags.String("branch", "", "repository workspace: new task branch")
	base := flags.String("base", "develop", "repository workspace: the branch's base")
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	set := visited(flags)
	if flags.NArg() != 1 {
		return workCall{}, fmt.Errorf("use %s [flags] \"assignment\": one assignment, after the flags (-- before one starting with a dash)", name)
	}
	if name == "continue" && !set["resume-from"] {
		return workCall{}, errors.New("use continue --resume-from TURN_ID [flags] \"assignment\"")
	}
	assignment := flags.Arg(0)
	request := map[string]any{"instructions": assignment, "title": title(assignment)}
	if set["title"] {
		request["title"] = *titleFlag
	}
	for _, option := range []struct {
		flag, field string
		value       *string
	}{{"profile", "profile", profile}, {"cost-class", "cost_class", costClass}, {"slot", "slot", slot}, {"resume-from", "resume_from", resume}} {
		if set[option.flag] {
			request[option.field] = *option.value
		}
	}
	folder := set["cwd"] || set["permissions"]
	repo := set["repo"] || set["branch"] || set["base"]
	switch {
	case folder && repo:
		return workCall{}, errors.New("a workspace is a folder (--cwd, --permissions) or a repository (--repo, --branch, --base), not both")
	case repo:
		workspace := map[string]any{"kind": "repository", "base": *base}
		if set["repo"] {
			workspace["url"] = *repository
		}
		if set["branch"] {
			workspace["branch"] = *branch
		}
		request["workspace"] = workspace
	case folder:
		workspace := map[string]any{"kind": "folder", "permissions": *permissions}
		if set["cwd"] {
			// The Runtime runs elsewhere: a relative folder is this command's.
			path, err := filepath.Abs(*cwd)
			if err != nil {
				return workCall{}, err
			}
			workspace["path"] = path
		}
		request["workspace"] = workspace
	}
	call := workCall{method: http.MethodPost, path: "/v1/work", body: request}
	if set["key"] {
		call.header = http.Header{"Idempotency-Key": {*key}}
	}
	return call, nil
}

// status reads work: GET /v1/work/{id}, GET /v1/work?key= or GET /v1/work?state=&changed_since=.
func statusCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	work := flags.String("work", "", "one work, by its ID")
	key := flags.String("key", "", "one work, by its client key")
	state := flags.String("state", "", "only work whose current attempt is in this state")
	changed := flags.String("changed-since", "", "only work changed after this change sequence")
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	if err := noArguments(flags); err != nil {
		return workCall{}, err
	}
	set := visited(flags)
	call := workCall{method: http.MethodGet, path: "/v1/work", query: url.Values{}}
	if set["work"] {
		call.path += "/" + url.PathEscape(*work)
	}
	for _, option := range []struct {
		flag, field string
		value       *string
	}{{"key", "key", key}, {"state", "state", state}, {"changed-since", "changed_since", changed}} {
		if set[option.flag] {
			call.query.Set(option.field, *option.value)
		}
	}
	return call, nil
}

// capacity: GET /v1/capacity.
func capacityCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	if err := noArguments(flags); err != nil {
		return workCall{}, err
	}
	return workCall{method: http.MethodGet, path: "/v1/capacity"}, nil
}

// retry starts a new attempt: POST /v1/work/{id}/attempts.
func retryCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	work := flags.String("work", "", "the work to retry")
	resume := flags.Bool("resume", false, "continue from the current attempt's resume point")
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	if err := noArguments(flags); err != nil {
		return workCall{}, err
	}
	set := visited(flags)
	if !set["work"] {
		return workCall{}, errors.New("use retry --work WORK_ID [--resume]")
	}
	body := map[string]any{}
	if set["resume"] {
		body["resume"] = *resume
	}
	return workCall{method: http.MethodPost, path: "/v1/work/" + url.PathEscape(*work) + "/attempts", body: body}, nil
}

// stop and kill cancel a work: POST /v1/work/{id}/cancel, graceful or force.
func cancelCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	work := flags.String("work", "", "the work to cancel")
	reason := flags.String("reason", "", "why, recorded with the cancel")
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	if err := noArguments(flags); err != nil {
		return workCall{}, err
	}
	set := visited(flags)
	if !set["work"] {
		return workCall{}, fmt.Errorf("use %s --work WORK_ID [--reason TEXT]", name)
	}
	body := map[string]any{"mode": "graceful"}
	if name == "kill" {
		body["mode"] = "force"
	}
	if set["reason"] {
		body["reason"] = *reason
	}
	return workCall{method: http.MethodPost, path: "/v1/work/" + url.PathEscape(*work) + "/cancel", body: body}, nil
}

// output reads one page of a turn's output: GET /v1/turns/{turn_id}/output?cursor=.
func outputCall(name string, args []string) (workCall, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	turn := flags.String("turn", "", "the turn whose output to read")
	cursor := flags.String("cursor", "", "cursor of the previous page")
	if err := flags.Parse(args); err != nil {
		return workCall{}, err
	}
	if err := noArguments(flags); err != nil {
		return workCall{}, err
	}
	set := visited(flags)
	if !set["turn"] {
		return workCall{}, errors.New("use output --turn TURN_ID [--cursor CURSOR]")
	}
	call := workCall{method: http.MethodGet, path: "/v1/turns/" + url.PathEscape(*turn) + "/output"}
	if set["cursor"] {
		call.query = url.Values{"cursor": {*cursor}}
	}
	return call, nil
}
