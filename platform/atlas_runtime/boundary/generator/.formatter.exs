# The schema DSL reads without parentheses, in a contract and in tests.
schema_dsl = [
  version: 1,
  defmodel: 2,
  defcapability: 2,
  field: 2,
  field: 3,
  invalid_input: 1,
  invalid_input: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: schema_dsl,
  export: [locals_without_parens: schema_dsl]
]
