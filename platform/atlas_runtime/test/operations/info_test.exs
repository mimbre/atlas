defmodule AtlasRuntime.Operations.InfoTest do
  # Runtime info through the facade (design §13.1 Q13, O1 13): build and incarnation from
  # the work core's capacity, the policy's version and slots, busy as the core counts it.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntime.Boundary.Work, as: W
  alias AtlasRuntimeBoundary.Generator.NotPermitted

  @moduletag capture_log: true
  @operator {"local:test", [:inspect, :operate]}

  setup do
    %{bench: start!(%{"version" => 7})}
  end

  test "the incarnation and build are capacity's; slots are the policy's, busy as the core runs them",
       %{bench: bench} do
    work = submit!(bench, "hang on s2", %{slot: "s2"}, client("c1", [:choose_slot]))
    await_launch(bench, work)

    capacity = W.capacity(client())

    assert %F.Outcome.RuntimeInfo{
             runtime_build: build,
             incarnation: incarnation,
             mode: :open,
             policy_version: 7,
             slots: [%F.Slot{name: "s1", busy: false}, %F.Slot{name: "s2", busy: true}]
           } = F.runtime_info(@operator)

    assert incarnation == capacity.incarnation
    assert build == capacity.runtime_build
    W.cancel(client(), %{work_id: work.work_id, mode: "force"})
  end

  test "the slots and version follow a hand edit of policy.json", %{bench: bench} do
    write_policy!(bench.dir, %{"version" => 8, "slots" => ["a1", "s1", "s2"]})

    assert %F.Outcome.RuntimeInfo{policy_version: 8, slots: slots} = F.runtime_info(@operator)
    assert Enum.map(slots, & &1.name) == ["a1", "s1", "s2"]
  end

  test "the incarnation is new after a restart of the core, and still capacity's", %{
    bench: bench
  } do
    %{incarnation: before} = F.runtime_info(@operator)
    stop_work()
    start_work!(bench)

    %{incarnation: now} = F.runtime_info(@operator)
    refute now == before
    assert now == W.capacity(client()).incarnation
  end

  test "without the core: the work contract's stopped capacity, open", %{bench: _bench} do
    stop_work()

    assert %F.Outcome.RuntimeInfo{incarnation: "stopped", mode: :open, slots: []} =
             F.runtime_info(@operator)

    assert W.capacity(client()).incarnation == "stopped"
  end

  test "inspect is the right it needs" do
    assert %F.Outcome.RuntimeInfo{} = F.runtime_info({"remote:x", [:inspect]})

    assert %NotPermitted{capability: :runtime_info, right: :inspect} =
             F.runtime_info({"x", [:operate]})
  end
end
