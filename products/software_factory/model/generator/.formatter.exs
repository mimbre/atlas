# The flow DSL reads without parentheses, in a contract and in tests.
flow_dsl = [
  subflow: 2,
  subflow: 3,
  run_as: 1,
  per_subject: 1,
  owner: 1,
  channel: 1,
  start: 1,
  start: 2,
  initial: 1,
  state: 2,
  state: 3,
  final: 1,
  final: 2,
  final: 3,
  pass: 2,
  gate: 2,
  effect: 2,
  wait_for: 2,
  await: 2,
  branch: 1,
  set: 1,
  create: 2,
  timer: 3,
  defgate: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"],
  locals_without_parens: flow_dsl,
  export: [locals_without_parens: flow_dsl]
]
