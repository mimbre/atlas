// Package s6fixture is the Go half of the S6 parity harness (plan s6-plan.md, package F, B2).
// It loads the shared tables in platform/atlas_runtime/test/fixtures/s6, builds a row's `fs`
// spec under a temporary root, and substitutes the path placeholders. Its Elixir twin is
// test/support/s6_fixture.ex; both must build byte-identical trees and report identical
// errors for one spec, which the self-test in _self/ checks. Only tests import this package.
package s6fixture

import "strings"

// Places maps the placeholder names of B2 to the concrete paths of one built row.
type Places map[string]string

// placeNames is the fixed placeholder set, in substitution order.
var placeNames = []string{"tmp", "home", "user", "temporary"}

// DefaultPlaces lays the placeholders out under a canonical root: {tmp} is the root itself,
// {home} the Runtime home, {user} the user's home and {temporary} the private temp.
func DefaultPlaces(root string) Places {
	return Places{
		"tmp":       root,
		"home":      root + "/home",
		"user":      root + "/user",
		"temporary": root + "/temporary",
	}
}

// Substitute replaces every "{name}" of a known placeholder by its path.
func (p Places) Substitute(s string) string {
	for _, name := range placeNames {
		if value, ok := p[name]; ok {
			s = strings.ReplaceAll(s, "{"+name+"}", value)
		}
	}
	return s
}

// Abstract is Substitute's inverse for results: each occurrence of a placeholder's path that
// stands alone as a path (the bytes before and after it are not path-name bytes) becomes
// "{name}". Longer paths win, so {home} is preferred over {tmp}.
func (p Places) Abstract(s string) string {
	order := p.abstractOrder()
	var out strings.Builder
	for i := 0; i < len(s); {
		matched := false
		if i == 0 || !boundaryByte(s[i-1]) {
			for _, name := range order {
				value := p[name]
				if value != "" && strings.HasPrefix(s[i:], value) &&
					(i+len(value) == len(s) || !nameByte(s[i+len(value)])) {
					out.WriteString("{" + name + "}")
					i += len(value)
					matched = true
					break
				}
			}
		}
		if !matched {
			out.WriteByte(s[i])
			i++
		}
	}
	return out.String()
}

func (p Places) abstractOrder() []string {
	order := []string{}
	for _, name := range placeNames {
		if _, ok := p[name]; ok {
			order = append(order, name)
		}
	}
	// Stable insertion sort: longer path first, placeholder order on ties.
	for i := 1; i < len(order); i++ {
		for j := i; j > 0 && len(p[order[j]]) > len(p[order[j-1]]); j-- {
			order[j], order[j-1] = order[j-1], order[j]
		}
	}
	return order
}

// SubstituteValue applies Substitute to every string value (not object keys) of decoded JSON.
func (p Places) SubstituteValue(value any) any { return mapStrings(value, p.Substitute) }

// AbstractValue applies Abstract to every string value (not object keys) of decoded JSON.
func (p Places) AbstractValue(value any) any { return mapStrings(value, p.Abstract) }

func mapStrings(value any, f func(string) string) any {
	switch v := value.(type) {
	case string:
		return f(v)
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = mapStrings(item, f)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = mapStrings(item, f)
		}
		return out
	default:
		return value
	}
}

// nameByte is a byte that continues a path component name.
func nameByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '.' || b == '_' || b == '-'
}

// boundaryByte is a byte after which a placeholder path cannot start.
func boundaryByte(b byte) bool { return nameByte(b) || b == '/' }
