defmodule AtlasRuntime.Sandbox.HomeLayout do
  @moduledoc """
  The Runtime home's top-level entries and their class (S6 plan §6 SP2, binding B13).

  - `denied`: denied in every spec. A profile that cannot deny the whole home (a managed
    repository, whose home contains the project) denies each by path, present or absent at
    launch. The order is the deny order of the Codex profile and is significant (B7).
  - `atomic_temps`: the atomic-write temps of the denied home files. The static census has no
    class for them (`<> ".tmp"`); the fixed P0 lists them at the end of `sensitiveHomeNames`,
    and a managed repository denies them by path after the other names. They are class `denied`.
  - `chain`: on a managed repository's ancestor chain (`workers`); the spec denies its other
    entries, a sibling worker created later included.
  - `own`: the turn's own `scratch/<turn>`, re-allowed inside the denied `scratch`.

  `denied ++ atomic_temps` replaces `sensitiveHomeNames` (`host/host/codex.go:177-182`) and the `workers`
  chain exemption (`codex.go:224-226`). Its checked-in twin is
  `test/fixtures/s6/home_layout.json`, which the Go census (`TestS6HomeLayout`, against
  `censusHome` and `sensitiveHomeNames`) and the Elixir test (`home_layout_test.exs`) both
  assert, so the static census has one target that outlives the Go list (review Y4).
  """

  # The Runtime's sockets, denied by path in every profile beside the home itself
  # (runtimeSockets, codex.go:138).
  @sockets ["runtime.sock", "backend.sock"]

  # The other denied names, in sensitiveHomeNames' order (codex.go:177-180); see
  # runtime_home_census_test.go for what each holds.
  @denied @sockets ++
            [
              "turns",
              "code.json",
              "server.json",
              "backends.json",
              "policy.json",
              "availability.json",
              "service.log",
              "service.lock",
              "passes",
              "snapshots",
              "materializations",
              "scratch",
              "work",
              "admissions",
              "preparations",
              "packets",
              "submissions",
              "rebinds",
              "frozen",
              "execution-events.json",
              "mode.json",
              "clients.json",
              "sources",
              "local-source"
            ]

  # The atomic-write temps in the home, in sensitiveHomeNames' order (codex.go:181-182): the
  # .tmp siblings of the denied files. Mirrors A2g's atomicHomeTemps
  # (host/host/s6_render_parity_test.go), which the spec rows encode; kept apart from @denied so
  # that list stays the census class.
  @atomic_temps [
    "code.json.tmp",
    "server.json.tmp",
    "backends.json.tmp",
    "policy.json.tmp",
    "availability.json.tmp",
    "execution-events.json.tmp",
    "mode.json.tmp",
    "clients.json.tmp"
  ]

  # The managed repositories' worker directories (siblingWorkerGlobs, codex.go:224-258).
  @chain ["workers"]

  @doc "The Runtime sockets in the home, in deny order."
  def sockets, do: @sockets

  @doc "Every `denied` name, in deny order."
  def denied, do: @denied

  @doc "The atomic-write temps, which a managed repository denies after the `denied` names."
  def atomic_temps, do: @atomic_temps

  @doc "What a managed repository denies by path in its home, in order: `denied`, then the temps."
  def managed_denied, do: @denied ++ @atomic_temps

  @doc "Every `chain` name."
  def chain, do: @chain

  @doc "Every top-level name the Runtime creates or reserves in its home."
  def names, do: @denied ++ @atomic_temps ++ @chain

  @doc "The class of a top-level name: `:denied`, `:chain`, or `nil` when it is not one."
  def class(name) do
    cond do
      name in @denied or name in @atomic_temps -> :denied
      name in @chain -> :chain
      true -> nil
    end
  end

  @doc "The worker-directory entry: the managed repositories' chain exemption."
  def workers, do: "workers"

  @doc "The scratch entry, whose `<turn>` child is a turn's own (class `own`)."
  def scratch, do: "scratch"
end
