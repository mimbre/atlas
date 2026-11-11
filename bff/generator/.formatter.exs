# The schema DSL reads without parentheses, in a contract and in tests.
schema_dsl = [
  version: 1,
  defoperation: 2,
  defblock: 2,
  defmodel: 2,
  defmarkup: 2,
  defpage: 2,
  defendpoint: 2,
  defendpoint: 3,
  field: 2,
  field: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: schema_dsl,
  export: [locals_without_parens: schema_dsl]
]
