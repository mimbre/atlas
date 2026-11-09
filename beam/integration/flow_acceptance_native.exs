# Native proof of slices 10, 11 and 12: a use case on Flow's durable runs, its design on
# design_and_accept and its building, testing and acceptance on test_and_accept_use_case,
# together taking every use case from the legacy flow design_and_accept; and a scene on
# test_and_accept_scene, taking every scene from the legacy flow test_and_accept, so all
# eight generated subflows are selected; against a private Rela and real Facts, with the
# model compiled for the test environment, Flow's engine and its processes, and a manual
# clock. Owns and stops its private Rela and Facts.
# MIX_ENV=test mix run integration/flow_acceptance_native.exs PRIVATE_DIR RELA_BIN_DIR
#
# It proves, on the use cases as test and prod hold them (written; approved with and
# without issues; without a design phase, with and without issues; accepted; in review and
# sent back for the design's import rows): the cutover keeps what each presents and its
# owner, and leaves none to the legacy flow; the build run imports approved, phase-less and
# accepted use cases as its table says, writing nothing but their count of issues; restart
# while waiting moves nothing; changes requested send the design back and in review returns
# it; the review's approval accepts it once; Flow restarted after the design's accepted
# write reached Facts and before it made the build run makes exactly one, which starts on
# its predicate, on its own cursor; issues under it are built and their completion hands it
# to the decider, across a restart; the decider's accept ends it; reopening it starts no
# new generation.
#
# For scenes (built; empty; with all its use cases completed; accepted), as test and prod
# hold them: before slice 12 the legacy flow presents each and no scene holds a count of
# its use cases (nothing counts them while no subflow runs on a scene); the cutover keeps
# what each presents and its owner, leaves none to the legacy flow, imports each as its
# table says and writes nothing on it but its count (and the reset of the verdict of the
# one it tests); restart while it is tested moves nothing; the decider's accept ends it;
# a use case under it reopened, the scene reopened and open work added under it start no
# new generation (its count still changes), and only an explicit restart does.
import ExUnit.Assertions
alias AtlasFlow.{Engine, ManualClock, Talk}
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
rela = {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"}

# The composition as Flow ran it before slice 11: the same, with the build and the scene
# not selected.
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
  def selection("test_and_accept_use_case"), do: nil
  def selection("test_and_accept_scene"), do: nil
  def selection(name), do: Model.AtlasEyra.selection(name)
end

# The composition as Flow ran it before slice 12: the same, with the scene not selected.
defmodule AcceptanceProof.Slice11 do
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
  def selection("test_and_accept_scene"), do: nil
  def selection(name), do: Model.AtlasEyra.selection(name)
end

try do
  now = ~U[2026-11-13 00:00:00Z]
  {:ok, clock} = ManualClock.start_link(now)

  facts_opts = [
    rela: rela,
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
           ~w(decide design_and_accept issue pr_review pr_test pull_request test_and_accept_scene test_and_accept_use_case)

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

  # The bus name `flow` is the engine's: it is released once the Registry saw the engine
  # go, and checked for (a bounded number of times, no timer) before anything else takes it.
  released = fn released, n ->
    cond do
      "flow" not in AtlasBus.endpoints() -> :ok
      n == 0 -> flunk("the bus name flow is still attached after the engine stopped")
      true -> :erlang.yield() && released.(released, n - 1)
    end
  end

  stop_engine = fn engine ->
    GenServer.stop(engine)
    stop_items.()
    released.(released, 1_000_000)
  end

  # Writes Flow makes itself, sent as Flow (`flow`) while no engine runs, from a process of
  # their own that gives the name back before it ends.
  as_flow = fn fun ->
    refute "flow" in AtlasBus.endpoints()

    Task.async(fn ->
      :ok = AtlasBus.attach("flow")

      try do
        fun.()
      after
        Registry.unregister(AtlasBus.Endpoints, "flow")
      end
    end)
    |> Task.await(30_000)
  end

  round = fn engine ->
    Engine.round(engine)
    assert :sys.get_state(engine).refusal == nil
    flush.()
  end

  blank = fn
    v when v in [nil, "", []] -> nil
    v -> v
  end

  # What a use case presents, on its Assignment, and to whom: {expected, owner, state}.
  presents = fn key ->
    [assignment] = read.("use_case", key)["links"]["assignment"]
    a = read.("assignment", assignment)

    {blank.(a["values"]["expected"]), blank.(a["links"]["assigned_to"]),
     blank.(a["values"]["flow_state"])}
  end

  run_of = fn flow, key, generation ->
    case read.(config["kind"], Run.key(flow, "use_case", key, generation)) do
      nil -> nil
      fact -> elem(Store.decode(config, fact), 1)
    end
  end

  # What a scene presents, and its run of generation `generation`.
  scene_presents = fn key ->
    [assignment] = read.("scene", key)["links"]["assignment"]
    a = read.("assignment", assignment)

    {blank.(a["values"]["expected"]), blank.(a["links"]["assigned_to"]),
     blank.(a["values"]["flow_state"])}
  end

  scene_run = fn key, generation ->
    case read.(config["kind"], Run.key("test_and_accept_scene", "scene", key, generation)) do
      nil -> nil
      fact -> elem(Store.decode(config, fact), 1)
    end
  end

  design = fn key -> run_of.("design_and_accept", key, 1) end
  build = fn key -> run_of.("test_and_accept_use_case", key, 1) end
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

  issue = fn n, under, values ->
    key = "IS-Proof-#{n}"

    put.("issue", %{
      "op" => "create",
      "key" => key,
      "values" => Map.merge(%{"title" => "Issue #{n}", "stage" => "specification"}, values),
      "links" => %{"in_use_case" => [under]}
    })

    key
  end

  # A merged pull request of an issue: Facts completes the issue by it, and its run
  # reports it to the issue's run (`pr_outcome`), which ends.
  merged = fn number, issue ->
    put.("pull_request", %{
      "op" => "create",
      "key" => "PR-eyra-atlas-#{number}",
      "values" => %{"url" => "https://github.com/eyra/atlas/pull/#{number}", "state" => "merged"},
      "links" => %{"in_issue" => [issue]}
    })
  end

  # Accepted and reopened as Control sends them for the decider: the To do answer (the
  # verdict, with accepted_by naming the one who answers), and the Reopen action.
  accept = fn key ->
    put.("use_case", %{
      "op" => "change",
      "key" => key,
      "values" => %{"verdict" => "accept"},
      "links" => %{"accepted_by" => ["reviewer-1"]},
      "by" => "reviewer-1"
    })
  end

  reopen = fn key ->
    put.("use_case", %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => %{"accepted_by" => []},
      "by" => "reviewer-1",
      "cause" => "Not right yet"
    })
  end

  # The scenes as test and prod hold them (status refine; a scene has a manual id, SC-).
  scene = fn n ->
    key = "SC-Proof-#{n}"

    put.("scene", %{
      "op" => "create",
      "key" => key,
      "values" => %{"title" => "Scene #{n}", "description" => "Proof", "status" => "refine"}
    })

    key
  end

  in_scene = fn key, scene ->
    put.("use_case", %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => %{"in_scene" => [scene]}
    })
  end

  # Accepted and reopened as Control sends them for the decider, on a scene.
  accept_scene = fn key ->
    put.("scene", %{
      "op" => "change",
      "key" => key,
      "values" => %{"verdict" => "accept"},
      "links" => %{"accepted_by" => ["reviewer-1"]},
      "by" => "reviewer-1"
    })
  end

  reopen_scene = fn key ->
    put.("scene", %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => %{"accepted_by" => []},
      "by" => "reviewer-1",
      "cause" => "Not right yet"
    })
  end

  # Built (use cases under it, open), empty, tested (its one use case accepted), accepted.
  built_scene = scene.(1)
  empty_scene = scene.(2)
  tested_scene = scene.(3)
  accepted_scene = scene.(4)
  scenes = [built_scene, empty_scene, tested_scene, accepted_scene]

  writing = use_case.(1, "writing")
  building = use_case.(2, "approved")
  _ = issue.(1, building, %{})
  _ = issue.(2, building, %{})
  breaking = use_case.(3, "approved")
  phaseless = use_case.(4, nil)
  reviewing = use_case.(5, "in_review")
  sent_back = use_case.(6, "changes_requested")
  done = use_case.(7, "approved")
  in_scene.(building, built_scene)
  in_scene.(phaseless, built_scene)
  in_scene.(done, tested_scene)
  accept.(done)
  accept_scene.(accepted_scene)
  phaseless_built = use_case.(8, nil)
  _ = issue.(5, phaseless_built, %{})
  all = [writing, building, breaking, phaseless, reviewing, sent_back, done, phaseless_built]
  architect = ["architect"]
  coordinator = ["coordinator"]
  decider = ["reviewer-1"]

  # Before the cutover, as on test and prod (slice 10): the design run presents a design
  # being written or reviewed, the legacy flow every other use case.
  engine = start_engine.(AcceptanceProof.Before)

  live = %{
    writing => {"Write its Design part", architect, "designing"},
    building => {"Build it", coordinator, "building"},
    breaking => {"Break it down into issues", coordinator, "break_down"},
    phaseless => {"Build it", coordinator, "building"},
    reviewing => {"Have its design reviewed", coordinator, "design_review"},
    sent_back => {"Write its Design part", architect, "redesign"},
    done => {nil, nil, nil},
    phaseless_built => {"Build it", coordinator, "building"}
  }

  for key <- all, do: assert(presents.(key) == live[key], key)
  assert summary.(design.(writing)) == {"designing", "active", 1}
  refute Map.has_key?(design.(writing)["last_input"], "import")
  assert summary.(design.(reviewing)) == {"design_review", "active", 1}
  assert summary.(design.(sent_back)) == {"redesign", "active", 1}
  for key <- [reviewing, sent_back], do: assert(design.(key)["last_input"]["import"] == true)
  for key <- all, do: assert(build.(key) == nil)

  # The legacy flow presents every scene: built, broken down, tested by the decider (all
  # under it completed), nothing for the accepted one; no scene holds a count of its use
  # cases, and none has a run.
  scene_live = %{
    built_scene => {"Build it", coordinator, "building"},
    empty_scene => {"Break it down into use cases and issues", coordinator, "break_down"},
    tested_scene => {"Test it", decider, "to_test"},
    accepted_scene => {nil, nil, nil}
  }

  uncounted = fn ->
    for key <- scenes do
      assert scene_presents.(key) == scene_live[key], key
      assert scene_run.(key, 1) == nil, key
      fact = read.("scene", key)
      assert blank.(fact["values"]["children"]) == nil, key
      assert blank.(fact["values"]["open_children"]) == nil, key
    end
  end

  uncounted.()
  stop_engine.(engine)
  values = Map.new(all, &{&1, read.("use_case", &1)})

  # The cutover of slice 11. The build run takes every use case the design run does not:
  # approved or with no design phase it joins building, its count moving it where the
  # legacy flow had it; accepted, it is completed history. Each writes nothing but its
  # count of issues.
  engine = start_engine.(AcceptanceProof.Slice11)

  for {key, at} <- [
        {building, {"building", "active", 1}},
        {breaking, {"break_down", "active", 2}},
        {phaseless, {"building", "active", 1}},
        {phaseless_built, {"building", "active", 1}},
        {done, {"accepted", "completed", 1}}
      ] do
    assert summary.(build.(key)) == at, key
    assert design.(key) == nil
  end

  # Imported where the table says (the approved one with nothing under it moved on by its
  # count, after its import).
  for key <- [building, phaseless, phaseless_built, done],
      do: assert(build.(key)["last_input"]["import"] == true, key)

  for key <- [writing, reviewing, sent_back], do: assert(build.(key) == nil)

  # What every use case presents, and to whom, is what it presented before; no use case
  # is left to the legacy flow.
  for key <- all do
    assert presents.(key) == live[key], key
    assert {_, _} = Store.selected(config, "use_case", read.("use_case", key))
  end

  # The runs changed nothing on a use case but its count of issues (the composition's).
  counts = %{
    building => {2, 2},
    breaking => {0, 0},
    phaseless => {0, 0},
    phaseless_built => {1, 1},
    done => {0, 0}
  }

  for key <- all do
    fact = read.("use_case", key)

    assert Map.drop(fact["values"], ~w(children open_children)) ==
             Map.drop(values[key]["values"], ~w(children open_children)),
           key

    if c = counts[key] do
      assert {fact["values"]["children"], fact["values"]["open_children"]} == c, key
    end
  end

  # Still no scene holds a count, though use cases are under them and their build runs
  # run: the count of a scene's use cases applies only once a subflow runs on the scene,
  # and only that run writes it. The legacy flow presents every scene as before.
  uncounted.()
  stop_engine.(engine)
  scene_values = Map.new(scenes, &{&1, read.("scene", &1)})

  # The cutover of slice 12: every scene is the scene run's, none the legacy flow's. Not
  # completed, it joins building, and its count, on its first entry, moves it where the
  # legacy flow had it (break down with none under it, to test with all completed);
  # accepted, it is completed history. Each writes nothing on the scene but its count, and
  # the one it tests the reset of its verdict.
  engine = start_engine.(Model.AtlasEyra)

  for {key, at, count} <- [
        {built_scene, {"building", "active", 1}, {2, 2}},
        {empty_scene, {"break_down", "active", 2}, {0, 0}},
        {tested_scene, {"to_test", "active", 2}, {1, 0}},
        {accepted_scene, {"accepted", "completed", 1}, {0, 0}}
      ] do
    run = scene_run.(key, 1)
    assert summary.(run) == at, key
    assert run["last_input"]["import"] == true or run["entry"] > 1, key
    assert run["pending"]["writes"] == [], key
    assert scene_presents.(key) == scene_live[key], key
    assert {"test_and_accept_scene", _} = Store.selected(config, "scene", read.("scene", key))
    fact = read.("scene", key)
    assert {fact["values"]["children"], fact["values"]["open_children"]} == count, key
    changed = if key == tested_scene, do: %{"verdict" => "none"}, else: %{}

    assert Map.drop(fact["values"], ~w(children open_children)) ==
             Map.merge(scene_values[key]["values"], changed),
           key
  end

  # The imports: building and history straight from the table.
  for key <- [built_scene, accepted_scene],
      do: assert(scene_run.(key, 1)["last_input"]["import"] == true, key)

  # Nothing moved a use case: what each presents is what it presented before.
  for key <- all, do: assert(presents.(key) == live[key], key)

  # Restart while waiting (Facts and Flow): nothing moves, nothing is written again.
  stop_engine.(engine)
  facts = restart.(facts)
  runs = fn key -> {design.(key), build.(key), read.("use_case", key)["version"]} end
  waiting = Map.new(all, &{&1, runs.(&1)})
  scene_runs = fn key -> {scene_run.(key, 1), read.("scene", key)["version"]} end
  scenes_waiting = Map.new(scenes, &{&1, scene_runs.(&1)})
  engine = start_engine.(Model.AtlasEyra)
  for key <- all, do: assert(runs.(key) == waiting[key], key)
  for key <- all, do: assert(presents.(key) == live[key], key)
  # The scene in acceptance too: its test waits, its verdict is not reset again.
  for key <- scenes, do: assert(scene_runs.(key) == scenes_waiting[key], key)
  for key <- scenes, do: assert(scene_presents.(key) == scene_live[key], key)

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

  # Its review approves it: the design is accepted. Flow stops after the run ended and its
  # accepted write reached Facts, and before it made the build run.
  stop_engine.(engine)
  set.(reviewing, "approved")
  stored = read.(config["kind"], Run.key("design_and_accept", "use_case", reviewing, 1))
  {:ok, waited} = Store.decode(config, stored)

  {:ok, ended} =
    Run.step(waited, runner.flows["design_and_accept"], read.("use_case", reviewing), now)

  assert {summary.(ended), length(ended["pending"]["writes"])} ==
           {{"accepted", "completed", 4}, 1}

  [write] = ended["pending"]["writes"]
  values_of = Store.encode(config, ended)

  as_flow.(fn ->
    assert {:stored, _} =
             Talk.put(config["kind"], %{
               "op" => "change",
               "key" => stored["key"],
               "values" => values_of,
               "version" => stored["version"],
               "was" => Map.new(Map.keys(values_of), &{&1, stored["values"][&1]}),
               "by" => config["writer"]["by"]
             })

    assert {:stored, _} = Talk.put(write["kind"], write["content"], write["id"])
  end)

  accepted = read.("use_case", reviewing)
  assert accepted["values"]["design_status"] == "accepted"
  assert build.(reviewing) == nil

  # Restarted (Facts and Flow): the design run's owed write is the one Facts has (replayed
  # under its id, stored once); exactly one build run is made, which starts on its
  # predicate in break_down, on its own cursor; restarted again, the same one, and no other.
  facts = restart.(facts)
  engine = start_engine.(Model.AtlasEyra)
  paid = design.(reviewing)
  assert {summary.(paid), paid["pending"]["writes"]} == {{"accepted", "completed", 4}, []}
  assert read.("use_case", reviewing)["version"] == accepted["version"]
  started = build.(reviewing)
  assert summary.(started) == {"break_down", "active", 1}
  refute Map.has_key?(started["last_input"], "import")
  assert started["key"] != paid["key"]
  assert presents.(reviewing) == {"Break it down into issues", coordinator, "break_down"}
  stop_engine.(engine)
  engine = start_engine.(Model.AtlasEyra)
  assert build.(reviewing) == started
  assert run_of.("test_and_accept_use_case", reviewing, 2) == nil
  assert design.(reviewing) == paid

  # Its issues: one open under it, built; another, already merged, and its count says one
  # is open; the first one's pull request merged, none is: it is the decider's to test,
  # and its verdict is reset.
  open = issue.(3, reviewing, %{})
  round.(engine)
  assert summary.(build.(reviewing)) == {"building", "active", 2}
  assert presents.(reviewing) == {"Build it", coordinator, "building"}
  built = issue.(4, reviewing, %{})
  merged.(9401, built)
  round.(engine)
  round.(engine)
  assert build.(reviewing)["state"] == "building"
  assert presents.(reviewing) == {"Build it", coordinator, "building"}
  merged.(9301, open)
  round.(engine)
  round.(engine)
  tested = build.(reviewing)

  assert {tested["state"], tested["status"], tested["pending"]["writes"]} ==
           {"to_test", "active", []}

  fact = read.("use_case", reviewing)

  assert Map.take(fact["values"], ~w(children open_children verdict)) == %{
           "children" => 2,
           "open_children" => 0,
           "verdict" => "none"
         }

  assert presents.(reviewing) == {"Test it", decider, "to_test"}

  # Restart while it is tested (Facts and Flow): nothing moves.
  stop_engine.(engine)
  facts = restart.(facts)
  engine = start_engine.(Model.AtlasEyra)
  assert build.(reviewing) == tested
  assert presents.(reviewing) == {"Test it", decider, "to_test"}

  # The decider accepts it, as Control sends the answer: its run ends, nothing is
  # presented any more, and Facts completes it.
  accept.(reviewing)
  round.(engine)
  ended_build = build.(reviewing)
  assert summary.(ended_build) == {"accepted", "completed", tested["entry"] + 1}
  assert presents.(reviewing) == {nil, nil, nil}

  assert %{"fact" => %{"completion" => completion}} =
           Talk.read("use_case", %{"key" => reviewing, "incoming" => false})

  assert completion != nil

  # Reopened (accepted_by removed with a note), its design put back and accepted again:
  # neither run starts again and no new generation is made; only an explicit restart
  # would make one. Nothing presents it meanwhile.
  reopen.(reviewing)
  round.(engine)

  for status <- ["writing", "accepted"] do
    set.(reviewing, status)
    round.(engine)
  end

  assert build.(reviewing) == ended_build
  assert design.(reviewing) == paid
  assert run_of.("test_and_accept_use_case", reviewing, 2) == nil
  assert run_of.("design_and_accept", reviewing, 2) == nil
  assert presents.(reviewing) == {nil, nil, nil}

  # One writer per use case at every moment: the run of the selection that admits it,
  # presenting while it is active; never the legacy flow.
  for key <- all do
    fact = read.("use_case", key)
    assert {name, _} = Store.selected(config, "use_case", fact), key
    run = run_of.(name, key, 1)
    assert (run != nil and run["status"] == "active") == (presents.(key) != {nil, nil, nil}), key
  end

  # The scene: the decider accepts the tested one, as Control sends the answer: its run
  # ends, nothing is presented any more, and Facts completes it.
  tested = scene_run.(tested_scene, 1)
  accept_scene.(tested_scene)
  round.(engine)
  ended_scene = scene_run.(tested_scene, 1)
  assert summary.(ended_scene) == {"accepted", "completed", tested["entry"] + 1}
  assert scene_presents.(tested_scene) == {nil, nil, nil}

  assert %{"fact" => %{"completion" => scene_completion}} =
           Talk.read("scene", %{"key" => tested_scene, "incoming" => false})

  assert scene_completion != nil

  # A use case under it reopened after it was accepted: its build run stays completed
  # (explicit), so the count stays, and the scene's run neither moves nor starts again.
  reopen.(done)
  round.(engine)
  assert summary.(build.(done)) == {"accepted", "completed", 1}
  assert scene_run.(tested_scene, 1) == ended_scene
  assert scene_run.(tested_scene, 2) == nil
  fact = read.("scene", tested_scene)
  assert {fact["values"]["children"], fact["values"]["open_children"]} == {1, 0}

  # The scene reopened (accepted_by removed with a note), and open work added under it:
  # its count changes and is written, but no new generation starts; nothing presents it.
  reopen_scene.(tested_scene)
  round.(engine)
  added = use_case.(9, "writing")
  in_scene.(added, tested_scene)
  round.(engine)
  round.(engine)
  fact = read.("scene", tested_scene)
  assert {fact["values"]["children"], fact["values"]["open_children"]} == {2, 1}
  assert scene_run.(tested_scene, 1)["state"] == "accepted"
  assert scene_run.(tested_scene, 1)["status"] == "completed"
  assert scene_run.(tested_scene, 2) == nil
  assert scene_presents.(tested_scene) == {nil, nil, nil}

  # Only an explicit restart makes one: the next generation, stored as Flow stores a run
  # while no engine runs; the engine then drains it, its count moving it to building.
  stop_engine.(engine)

  {:ok, second} =
    Run.restart(
      scene_run.(tested_scene, 1),
      runner.flows["test_and_accept_scene"],
      read.("scene", tested_scene),
      now
    )

  assert {second["generation"], summary.(second)} == {2, {"break_down", "active", 1}}

  as_flow.(fn ->
    assert {:stored, _} =
             Talk.put(
               config["kind"],
               %{
                 "op" => "create",
                 "key" => second["key"],
                 "values" => Store.encode(config, second),
                 "by" => config["writer"]["by"]
               },
               Run.digest({second["key"], "create"})
             )
  end)

  engine = start_engine.(Model.AtlasEyra)
  restarted = scene_run.(tested_scene, 2)
  assert {restarted["state"], restarted["status"]} == {"building", "active"}
  assert scene_presents.(tested_scene) == {"Build it", coordinator, "building"}
  assert scene_run.(tested_scene, 1)["status"] == "completed"
  assert scene_run.(tested_scene, 3) == nil

  # One writer per scene at every moment: its latest run, presenting while it is active;
  # never the legacy flow.
  for key <- scenes do
    assert {"test_and_accept_scene", _} = Store.selected(config, "scene", read.("scene", key))
    run = scene_run.(key, 2) || scene_run.(key, 1)
    active? = run["status"] == "active"
    assert active? == (scene_presents.(key) != {nil, nil, nil}), key
  end

  stop_engine.(engine)
  GenServer.stop(facts)
  Agent.stop(clock)

  IO.puts(
    "flow-acceptance native proof: live presentations kept, none left to the legacy flow, " <>
      "design and build imports, restart while waiting, changes requested, design accepted " <>
      "once, one build run across a restart before it was made, issues built and tested " <>
      "across a restart, accepted by the decider, reopening starts no new generation; " <>
      "scenes: live presentations kept, uncounted before the cutover, imports and counts, " <>
      "restart in acceptance, accepted by the decider, a reopened use case, a reopened " <>
      "scene and open work start no new generation, an explicit restart does"
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
