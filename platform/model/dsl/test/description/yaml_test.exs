defmodule RelaDSL.Description.YamlTest do
  use ExUnit.Case, async: true
  alias RelaDSL.Description.Yaml

  test "a scalar is plain where YAML reads it back as the same text, else single-quoted" do
    for plain <-
          [
            "Draft",
            "^[0-9]{4}$",
            "https://example.invalid/x#",
            "The agent's turn",
            "a-b",
            "e.g. https://x/y"
          ] ++
            ["Flux group; empty = no group", "-x", "D-"],
        do: assert(Yaml.quote_scalar(plain) == plain, plain)

    for {text, quoted} <- [
          {"Out: it says so", "'Out: it says so'"},
          {"on", "'on'"},
          {"Yes", "'Yes'"},
          {"1.0", "'1.0'"},
          {"12", "'12'"},
          {"null", "'null'"},
          {"2026-11-12", "'2026-11-12'"},
          {"it's: here", "'it''s: here'"},
          {"#tag", "'#tag'"},
          {"a #b", "'a #b'"},
          {"- item", "'- item'"},
          {"ends:", "'ends:'"},
          {" lead", "' lead'"},
          {"*star", "'*star'"},
          {"", "''"}
        ],
        do: assert(Yaml.quote_scalar(text) == quoted, text)
  end

  test "block maps, block lists at the key's indent, list items of maps, and | blocks" do
    doc =
      {:ordered,
       [
         {"types",
          {:ordered,
           [
             {"t",
              {:ordered,
               [
                 {"values", ["a", "b"]},
                 {"validations", [{:ordered, [{"pattern", "^x$"}, {"error", "Not: x"}]}]}
               ]}}
           ]}},
         {"text", "Two\nlines\n"},
         {"exact", "No end\nnewline"},
         {"n", 1},
         {"flag", false}
       ]}

    assert Yaml.document(doc, "Head.") == """
           # Head.
           types:
             t:
               values:
               - a
               - b
               validations:
               - pattern: ^x$
                 error: 'Not: x'
           text: |
             Two
             lines
           exact: |-
             No end
             newline
           n: 1
           flag: false
           """
  end

  test "acl.yaml: comments, flow lists of grants, and the principals' roles" do
    roles = [
      %{name: "a-flow", comment: "Writes.", read: ["*"], create: nil, update: [:x, :y]},
      %{name: "judge", comment: nil, read: ["*"], create: [:z], update: nil}
    ]

    assert Yaml.acl("One.\n\nTwo.", roles, [{"system:a", "a-flow"}]) == """
           # One.
           #
           # Two.
           roles:
             # Writes.
             a-flow:
               read: ["*"]
               update: [x, y]
             judge:
               read: ["*"]
               create: [z]
           assignments:
             system:a: a-flow
           """
  end
end
