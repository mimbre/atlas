//go:build s6facts

package workspace

import (
	"errors"
	"io"
)

// Kind s6-echo exists only in a binary built with -tags s6facts, which the Elixir facts
// test builds (test/sandbox/facts_test.exs): it proves that arguments and stdin reach a
// registered kind through the real command. Production builds never contain it.
func init() {
	Register("s6-echo", func(args []string, stdin io.Reader) (any, error) {
		if len(args) == 1 && args[0] == "refuse" {
			return nil, errors.New("s6-echo refused")
		}
		input, err := io.ReadAll(stdin)
		if err != nil {
			return nil, err
		}
		return map[string]any{"args": args, "stdin": string(input)}, nil
	})
}
