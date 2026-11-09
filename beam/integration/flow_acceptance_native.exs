# Native proof of slice 10: the design of a use case on Flow's durable runs
# (design_and_accept), for the design phase of the legacy flow design_and_accept, which
# keeps the building phase, against a private Rela and real Facts, with the model compiled
# for the test environment, Flow's engine and its processes, and a manual clock. Owns and
# stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_acceptance_native.exs PRIVATE_DIR RELA_BIN_DIR
#
# It proves, on the use cases as test and prod hold them (written, approved with and
# without issues, without a design phase; in review and sent back for the import rows):
# the cutover keeps what each presents and its owner; a run starts, as the table says, only
# for a design being written or reviewed, writing nothing; approved and phase-less use cases
# never get one; restart while waiting moves nothing; changes requested send the design
# back and in review returns it; the review's approval accepts it once, across a restart of
# Flow after the run ended and before its accepted write reached Facts (the legacy building
# phase presents it all along, one writer at every step); a replayed write is stored once;
# the building phase goes on on the legacy flow; the build subflow is not run.
import ExUnit.Assertions
alias AtlasFlow.{Engine, Item, ManualClock, Talk}
alias AtlasFlow.Runs.{Run, Store}
[dir, bin] = System.argv()
root = Path.expand("../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)
python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

{out, status} =
  System.cmd(
    python,
    [
      Path.join(root, "rela/scripts/config.py"),
      "copy",
      "--root",
      Path.join(root, "rela"),
      "--data",
      data
    ],
    stderr_to_stdout: true
  )

assert status == 0, out
{:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)

server =
  Port.open({:spawn_executable, Path.join(bin, "rela-server")}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, os_pid} = Port.info(server, :os_pid)

# The composition as Flow ran it before slice 10: the same, with the design not selected.
defmodule AcceptanceProof.Before do
  @moduledoc false
  @behaviour AtlasFlow.Model
  defdelegate subflows(environment), to: Model.AtlasEyra
  defdelegate legacy(), to: Model.AtlasEyra
  defdelegate runs(), to: Model.AtlasEyra
  defdelegate migrations(), to: Model.AtlasEyra
  defdelegate composition(), to: Model.AtlasEyra
  defdelegate actors(), to: Model.AtlasEyra
  defdelegate relations(), to: Model.AtlasEyra
  defdelegate turn(), to: Model.AtlasEyra
  def selection("design_and_accept"), do: nil
  def selection(name), do: Model.AtlasEyra.selection(name)
end

try do
  now = ~U[2026-11-13 00:00:00Z]
  {:ok, clock} = ManualClock.start_link(now)

  facts_opts = [
    rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
    data_dir: Path.join(dir, "facts"),
    flow_input_clock: fn -> ManualClock.now(clock) end
  ]

  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "reviewer-1"})
  {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
  :ok = AtlasBus.attach("control/session-acceptance-proof")
  readiness_deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}} = d} ->
        d

      other ->
        assert System.monotonic_time(:millisecond) < readiness_deadline, inspect(other)
        await.(await)
    end
  end

  served = await.(await)
  assert Map.take(served, ~w(entities relations types)) == Model.AtlasEyra.rela_schema()
  runner = AtlasFlow.Model.load(Model.AtlasEyra, :test)
  %{config: config, refusal: nil} = runner

  assert Enum.sort(Map.keys(config["selection"])) ==
           ~w(decide design_and_accept issue pr_review pr_test pull_request)

  restart = fn facts ->
    GenServer.stop(facts)
    {:ok, facts} = AtlasFacts.Server.start_link(facts_opts)
    _ = await.(await)
    facts
  end

  put = fn kind, content ->
    assert {:stored, _} = Talk.put(kind, content), inspect(content)
  end

  read = fn kind, key ->
    %{"fact" => fact} = Talk.transition_read(kind, %{"key" => key, "plain" => true})
    fact
  end

  # Flow's engine with its processes, each started fresh: Flow keeps nothing, only Facts does.
  items = fn ->
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor), do: pid
  end

  stop_items = fn ->
    for pid <- items.(), do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
  end

  # Every process looks once more, and has stored what it writes.
  flush = fn ->
    for pid <- items.() do
      send(pid, :look)

      try do
        :sys.get_state(pid)
        :sys.get_state(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  start_engine = fn model ->
    {:ok, engine} =
      Engine.start_link(
        every: 3_600_000,
        clock: {ManualClock, clock},
        model: model,
        environment: :test
      )

    Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil
    flush.()
    engine
  end

  stop_engine = fn engine ->
    GenServer.stop(engine)
    stop_items.()
  end

  round = fn engine ->
    Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil
    flush.()
  end

  # What a use case presents, on its Assignment, and to whom: {expected, owner, state}.
  presents = fn key ->
    [assignment] = read.("use_case", key)["links"]["assignment"]
    a = read.("assignment", assignment)
    {a["values"]["expected"], a["links"]["assigned_to"], a["values"]["flow_state"]}
  end

  shown = fn key -> Tuple.delete_at(presents.(key), 2) end

  run_of = fn flow, key ->
    case read.(config["kind"], Run.key(flow, "use_case", key, 1)) do
      nil -> nil
      fact -> elem(Store.decode(config, fact), 1)
    end
  end

  design = fn key -> run_of.("design_and_accept", key) end
  summary = fn run -> run && {run["state"], run["status"], run["entry"]} end

  for {kind, key, name} <- [
        {"agent", "coordinator", "Coordinator"},
        {"agent", "architect", "Architect"},
        {"person", "reviewer-1", "Reviewer"}
      ],
      do: put.(kind, %{"op" => "create", "key" => key, "values" => %{"name" => name}})

  # The use cases as test and prod hold them (status refine): created as a client stores
  # them, with what each one's design status says. A use case has a manual id (UC-), and
  # Facts stores no fact without a key.
  use_case = fn n, design_status ->
    key = "UC-Proof-#{n}"
    values = %{"title" => "Use case #{n}", "description" => "Proof", "status" => "refine"}

    values =
      if design_status, do: Map.put(values, "design_status", design_status), else: values

    put.("use_case", %{"op" => "create", "key" => key, "values" => values})
    key
  end

  issue = fn n, under ->
    key = "IS-Proof-#{n}"

    put.("issue", %{
      "op" => "create",
      "key" => key,
      "values" => %{"title" => "Issue #{n}", "stage" => "specification"},
      "links" => %{"in_use_case" => [under]}
    })

    key
  end

  writing = use_case.(1, "writing")
  building = use_case.(2, "approved")
  _ = issue.(1, building)
  _ = issue.(2, building)
  breaking = use_case.(3, "approved")
  phaseless = use_case.(4, nil)
  reviewing = use_case.(5, "in_review")
  sent_back = use_case.(6, "changes_requested")
  all = [writing, building, breaking, phaseless, reviewing, sent_back]
  architect = ["architect"]
  coordinator = ["coordinator"]

  # Before the cutover: the legacy flow presents every use case, as on test and prod.
  engine = start_engine.(AcceptanceProof.Before)

  live = %{
    writing => {"Write its Design part", architect, "design"},
    building => {"Build it", coordinator, "building"},
    breaking => {"Break it down into issues", coordinator, "break_down"},
    phaseless => {"Build it", coordinator, "building"},
    reviewing => {"Have its design reviewed", coordinator, "design_review"},
    sent_back => {"Write its Design part", architect, "design"}
  }

  for key <- all, do: assert(presents.(key) == live[key], key)
  for key <- all, do: assert(design.(key) == nil)
  stop_engine.(engine)
  values = Map.new(all, &{&1, read.("use_case", &1)})

  # The cutover. A run starts only for a design being written or reviewed: one being
  # written as a new one does, the others joining their wait, each writing nothing.
  engine = start_engine.(Model.AtlasEyra)
  assert summary.(design.(writing)) == {"designing", "active", 1}
  refute Map.has_key?(design.(writing)["last_input"], "import")
  assert summary.(design.(reviewing)) == {"design_review", "active", 1}
  assert summary.(design.(sent_back)) == {"redesign", "active", 1}
  for key <- [reviewing, sent_back], do: assert(design.(key)["last_input"]["import"] == true)

  # Approved, with or without issues, and without a design phase: never a run, nothing
  # written on the use case, the legacy flow presents it.
  for key <- [building, breaking, phaseless] do
    assert design.(key) == nil
    assert read.("use_case", key)["version"] == values[key]["version"]
    assert Store.selected(config, "use_case", read.("use_case", key)) == nil
  end

  # What every use case presents, and to whom, is what it presented before. The state's
  # name is the run's where the run presents it.
  for key <- all, do: assert(shown.(key) == Tuple.delete_at(live[key], 2), key)

  assert Enum.map([writing, reviewing, sent_back], &elem(presents.(&1), 2)) ==
           ["designing", "design_review", "redesign"]

  # The run of an admitted use case changed nothing on it but its count of issues (the
  # composition's, now that both ends are selected): none, none open.
  for key <- [writing, reviewing, sent_back] do
    fact = read.("use_case", key)
    assert Map.drop(fact["values"], ~w(children open_children)) == values[key]["values"]

    assert Map.take(fact["values"], ~w(children open_children)) == %{
             "children" => 0,
             "open_children" => 0
           }

    assert {"design_and_accept", _} = Store.selected(config, "use_case", fact)
  end

  # Restart while waiting (Facts and Flow): nothing moves, nothing is written again.
  stop_engine.(engine)
  facts = restart.(facts)
  waiting = Map.new(all, &{&1, {design.(&1), read.("use_case", &1)["version"]}})
  engine = start_engine.(Model.AtlasEyra)
  for key <- all, do: assert({design.(key), read.("use_case", key)["version"]} == waiting[key])
  for key <- all, do: assert(shown.(key) == Tuple.delete_at(live[key], 2), key)

  # Its review asks for changes: back to the Architect; written again, in review again.
  set = fn key, status ->
    put.("use_case", %{"op" => "change", "key" => key, "values" => %{"design_status" => status}})
  end

  set.(reviewing, "changes_requested")
  round.(engine)
  assert summary.(design.(reviewing)) == {"redesign", "active", 2}
  assert presents.(reviewing) == {"Write its Design part", architect, "redesign"}
  set.(reviewing, "in_review")
  round.(engine)
  assert summary.(design.(reviewing)) == {"design_review", "active", 3}
  assert presents.(reviewing) == {"Have its design reviewed", coordinator, "design_review"}

  # Its review approves it: the design is accepted. Flow stops after the run ended and
  # before its accepted write reached Facts (as it stores the run before it sends it).
  stop_engine.(engine)
  set.(reviewing, "approved")
  stored = read.(config["kind"], Run.key("design_and_accept", "use_case", reviewing, 1))
  {:ok, waited} = Store.decode(config, stored)

  {:ok, ended} =
    Run.step(waited, runner.flows["design_and_accept"], read.("use_case", reviewing), now)

  assert {summary.(ended), length(ended["pending"]["writes"])} ==
           {{"accepted", "completed", 4}, 1}

  values_of = Store.encode(config, ended)

  Task.async(fn ->
    :ok = AtlasBus.attach("flow")

    assert {:stored, _} =
             Talk.put(config["kind"], %{
               "op" => "change",
               "key" => stored["key"],
               "values" => values_of,
               "version" => stored["version"],
               "was" => Map.new(Map.keys(values_of), &{&1, stored["values"][&1]}),
               "by" => config["writer"]["by"]
             })
  end)
  |> Task.await(30_000)

  # Restarted, its process looks before the engine's round: the design is no longer the
  # run's to present (approved), so the legacy building phase presents it: not the run,
  # and not nobody.
  spec =
    {Item, {"use_case", reviewing, every: 3_600_000, clock: {ManualClock, clock}, runner: runner}}

  {:ok, _} = DynamicSupervisor.start_child(AtlasFlow.Supervisor, spec)
  flush.()
  assert design.(reviewing)["pending"]["writes"] != []
  assert read.("use_case", reviewing)["values"]["design_status"] == "approved"
  assert presents.(reviewing) == {"Break it down into issues", coordinator, "break_down"}
  stop_items.()

  # The engine's round pays the run's debt: accepted, once; the same writer presents it.
  version = read.("use_case", reviewing)["version"]
  engine = start_engine.(Model.AtlasEyra)
  paid = design.(reviewing)
  assert summary.(paid) == {"accepted", "completed", 4}
  assert paid["pending"]["writes"] == []
  accepted = read.("use_case", reviewing)
  assert accepted["values"]["design_status"] == "accepted"
  assert accepted["version"] != version
  assert presents.(reviewing) == {"Break it down into issues", coordinator, "break_down"}
  assert Store.selected(config, "use_case", accepted) == nil

  # The same write again, under its id (a lost answer, replayed with the engine stopped,
  # so the bus name is free): stored once.
  stop_engine.(engine)
  [write] = ended["pending"]["writes"]

  Task.async(fn ->
    :ok = AtlasBus.attach("flow")
    assert {:stored, _} = Talk.put(write["kind"], write["content"], write["id"])
  end)
  |> Task.await(30_000)

  assert read.("use_case", reviewing)["version"] == accepted["version"]

  # Restart at acceptance (Facts and Flow): nothing moves, nothing is written again.
  facts = restart.(facts)
  engine = start_engine.(Model.AtlasEyra)
  assert design.(reviewing) == paid
  assert read.("use_case", reviewing)["version"] == accepted["version"]

  # Its building phase goes on on the legacy flow: an issue under it, and it is built.
  # The build subflow is not selected: it starts no run.
  _ = issue.(3, reviewing)
  round.(engine)
  assert presents.(reviewing) == {"Build it", coordinator, "building"}
  assert design.(reviewing)["state"] == "accepted" and design.(reviewing)["entry"] == 4
  assert run_of.("test_and_accept_use_case", reviewing) == nil

  # One process per use case, one writer each: the run while it is admitted and active,
  # the legacy flow otherwise.
  for key <- all do
    assert [{_, _}] = Registry.lookup(AtlasFlow.Items, {"use_case", key})
    run = design.(key)
    admitted = Store.selected(config, "use_case", read.("use_case", key)) != nil
    assert admitted == (run != nil and run["status"] == "active"), key
  end

  stop_engine.(engine)
  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-acceptance native proof: live presentations kept, imports, never a run for " <>
      "approved or phase-less use cases, restart while waiting, changes requested, accepted " <>
      "once across a restart before its write, one writer at every step, build on legacy ok"
  )
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^server, {:exit_status, _}} -> :ok
      after
        1_000 -> raise "private rela-server did not exit after SIGKILL"
      end
  end

  if Port.info(server), do: Port.close(server)
end
