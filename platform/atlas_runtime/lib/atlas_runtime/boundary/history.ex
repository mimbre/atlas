defmodule AtlasRuntime.Boundary.History do
  @moduledoc """
  The facade of the history contract (`AtlasRuntimeBoundary.History`; design §1.2, §1.3,
  §13.1 Q1, Q2): read-only turn summaries for callers outside the core. Generated: one
  function per capability, which checks the caller's right and the input before it calls
  `AtlasRuntime.History`, and checks what that answers against the declared outcomes.
  History is no model entity in S2 (§1.7), so there are no translations.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.History,
    implementation: AtlasRuntime.History
end
