# The model DSL reads without parentheses, in a contract and in tests.
model_dsl = [
  version: 1,
  type: 2,
  defmodel: 2,
  defrecord: 3,
  field: 2,
  field: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: model_dsl,
  export: [locals_without_parens: model_dsl]
]
