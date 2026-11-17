defmodule AtlasFlow.Boundary.Tasks do
  @moduledoc """
  The facade of Flow's `tasks` contract (`AtlasFlowBoundary.Tasks`; plan 2026-11-17 §3.3,
  ADR 0006): the way in for callers in the same BEAM, such as Control. Generated: one
  function per capability, which checks the caller's right and the input before it calls
  `AtlasFlow.Tasks`, and checks what that answers against the declared outcomes.

  A caller is `{id, rights}`. `:read` lets it list a subject's tasks, read one task with its
  attempts, and ask for a machinery's status. Reading tasks reads Flow's records in Facts
  over the Bus from the calling process, so that process must be attached to the Bus (as a
  Control session is); `machinery_status` asks the machinery itself.
  """
  use AtlasFlowBoundary.Generator.Targets.Boundary,
    contract: AtlasFlowBoundary.Tasks,
    implementation: AtlasFlow.Tasks
end
