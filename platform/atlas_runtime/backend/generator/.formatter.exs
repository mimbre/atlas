# The backend DSL reads without parentheses, in a backend contract and in tests.
backend_dsl = [
  version: 1,
  boundary: 1,
  expose: 1,
  not_exposed: 1,
  rights: 2,
  event: 2,
  event: 3,
  target: 2,
  target: 3,
  resource: 3,
  stream: 2,
  status: 2,
  status: 3,
  error: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: backend_dsl,
  export: [locals_without_parens: backend_dsl]
]
