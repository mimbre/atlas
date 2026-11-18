defmodule AtlasE2E.Pull.Needs do
  @moduledoc """
  What a scenario needs beyond the gate's own bench (plan rev 2 §13; the F2/F3 seam), and
  what it requires of the tree.

  **Needs** (`needs: [:github, …]` on a scenario) are modules `AtlasE2E.Pull.Needs.<Name>`
  implementing this behaviour; every callback is optional:

  - `settings(ctx)`: settings deep-merged into the instance's (before it is written);
  - `policy(policy, ctx)`: the Runtime's `policy.json`, changed;
  - `path(ctx)`: folders put on the Runtime's `PATH` after the stub's (a stub `gh`);
  - `code(ctx)`: the Code home's additions, `%{files: %{name => bytes}, sources: %{repo => remote}}`
    (`orchestrator.token`, `gh`, more repositories);
  - `start(ctx)` → ctx and `stop(ctx)`: processes of its own, which it records in the
    registry (`AtlasE2E.Pull.Bench.record/3`) so the reaper stops and proves them gone.

  The gate (S1–S6) needs none. F2/F3 adds `needs/github.ex` and `needs/review_profiles.ex`
  and scenarios `pull/scenarios/20-*.exs`; more than one Runtime (`AtlasE2E.Pull.Runtime.
  prepare/3` and `start/2` are keyed by name) needs D7 first.

  **Requirements** (`requires: [:d2]`) name a package of the tree a scenario cannot run
  without. One that is missing makes the scenario report `needs <package>` and not run;
  the run then ends `incomplete` (exit 6), never passed. `ATLAS_PULL_E2E_ASSUME_<PKG>=1|0`
  overrides the probe.
  """

  @callback settings(map()) :: map()
  @callback policy(map(), map()) :: map()
  @callback path(map()) :: [Path.t()]
  @callback code(map()) :: %{optional(:files) => map(), optional(:sources) => map()}
  @callback start(map()) :: map()
  @callback stop(map()) :: :ok
  @optional_callbacks settings: 1, policy: 2, path: 1, code: 1, start: 1, stop: 1

  @doc "The modules of the needs of `scenarios`, each once, in order."
  def modules(scenarios) do
    scenarios
    |> Enum.flat_map(& &1.needs)
    |> Enum.uniq()
    |> Enum.map(fn need ->
      module = Module.concat(__MODULE__, Macro.camelize(to_string(need)))

      if Code.ensure_loaded?(module),
        do: module,
        else: raise("a scenario needs #{inspect(need)}, and #{inspect(module)} does not exist")
    end)
  end

  @doc "Fold the needs' `fun` over `acc` (each need that implements it)."
  def fold(modules, fun, arity, acc, call) do
    Enum.reduce(modules, acc, fn module, acc ->
      if function_exported?(module, fun, arity), do: call.(module, acc), else: acc
    end)
  end

  # ---- requirements -------------------------------------------------------------------

  @requirements %{
    d2: %{
      name: "D2",
      what: "the Runtime's streamed put_blob (chunked upload)",
      # D2 carries put_blob over HTTP through the generated client; before it,
      # HttpTarget.put_blob/2 keeps every blob local and answers too_large.
      file: "platform/atlas_runtime/lib/atlas_runtime/sources/http_target.ex",
      probe: "Client.put_blob("
    }
  }

  @doc "`[{requirement, name, what}]` of `requires` that this tree lacks."
  def missing(requires, root) do
    for req <- requires, not present?(req, root) do
      r = Map.fetch!(@requirements, req)
      {req, r.name, r.what}
    end
  end

  @doc "Whether the tree at `root` has requirement `req` (the env override first)."
  def present?(req, root) do
    r = Map.fetch!(@requirements, req)

    case System.get_env("ATLAS_PULL_E2E_ASSUME_#{r.name}") do
      "1" -> true
      "0" -> false
      _ -> String.contains?(File.read!(Path.join(root, r.file)), r.probe)
    end
  end
end
