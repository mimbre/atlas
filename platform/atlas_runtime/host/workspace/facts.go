package workspace

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Facts kinds (S6, B4): `atlas-runtime workspace facts KIND [ARGUMENT]...` reports raw facts
// as one JSON value and decides nothing; the Elixir core decides on them
// (AtlasRuntime.Sandbox.Facts). A kind refuses only when it cannot inspect (an I/O failure
// or malformed arguments or input). Where a fact depends on a list of names, the list is
// input: Elixir writes it as JSON on stdin, so no Go copy of it exists. Each kind lives in its
// own facts_<kind>.go in this package and registers itself from init().

// FactsKind reports the facts for one kind from its arguments and stdin.
type FactsKind func(args []string, stdin io.Reader) (any, error)

var factsKinds = map[string]FactsKind{}

// Register adds a facts kind. It panics on an empty kind, a nil function or a second
// registration of the same kind, which are programming errors.
func Register(kind string, facts FactsKind) {
	if kind == "" || facts == nil {
		panic("workspace facts: Register needs a kind and a function")
	}
	if _, registered := factsKinds[kind]; registered {
		panic("workspace facts: kind registered twice: " + kind)
	}
	factsKinds[kind] = facts
}

// RunFacts dispatches args[0] to its kind with the remaining arguments and stdin, and
// writes the kind's result as one JSON line.
func RunFacts(args []string, stdin io.Reader, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("use workspace facts KIND [ARGUMENT]...")
	}
	facts, registered := factsKinds[args[0]]
	if !registered {
		return fmt.Errorf("unknown facts kind: %s", args[0])
	}
	result, err := facts(args[1:], stdin)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(result)
}
