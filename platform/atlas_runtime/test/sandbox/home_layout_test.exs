defmodule AtlasRuntime.Sandbox.HomeLayoutTest do
  # S6 package A2e, §6 SP2: AtlasRuntime.Sandbox.HomeLayout is the checked-in
  # test/fixtures/s6/home_layout.json, which the Go side ties to the static census and to
  # sensitiveHomeNames (TestS6HomeLayout, review Y4); and a home the Runtime has run works in
  # holds no other top-level name (the runtime census, on the work bench). Not async: the
  # bench changes PATH.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.S6Fixture
  alias AtlasRuntime.Sandbox.HomeLayout

  @fixture Path.join(S6Fixture.dir(), "home_layout.json")
  @external_resource @fixture

  setup_all do
    layout = S6Fixture.read_json!(@fixture)

    assert Map.keys(layout) |> Enum.sort() ==
             ~w(atomic_temps chain denied note own sockets version)

    assert layout["version"] == 1
    %{layout: layout}
  end

  test "the denied names are the fixture's, in its deny order", %{layout: layout} do
    assert HomeLayout.denied() == layout["denied"]
    assert HomeLayout.sockets() == layout["sockets"]
    assert Enum.take(HomeLayout.denied(), 2) == HomeLayout.sockets()
  end

  test "the atomic temps are the fixture's, denied, after the denied names", %{layout: layout} do
    assert HomeLayout.atomic_temps() == layout["atomic_temps"]

    assert HomeLayout.atomic_temps() ==
             ~w(code.json.tmp server.json.tmp backends.json.tmp policy.json.tmp availability.json.tmp execution-events.json.tmp mode.json.tmp clients.json.tmp)

    assert HomeLayout.managed_denied() == HomeLayout.denied() ++ HomeLayout.atomic_temps()
    for name <- HomeLayout.atomic_temps(), do: refute(name in HomeLayout.denied(), name)
  end

  test "the chain names are the fixture's", %{layout: layout} do
    assert HomeLayout.chain() == layout["chain"]
    assert HomeLayout.workers() in HomeLayout.chain()
    assert layout["own"] == [HomeLayout.scratch() <> "/<turn>"]
    assert HomeLayout.scratch() in HomeLayout.denied()
  end

  test "every name is one segment, listed once, with one class" do
    names = HomeLayout.names()
    assert names == Enum.uniq(names)

    assert Enum.all?(
             names,
             &(&1 != "" and &1 not in [".", ".."] and not String.contains?(&1, "/"))
           )

    assert Enum.map(names, &HomeLayout.class/1) |> Enum.frequencies() == %{denied: 33, chain: 1}
    assert HomeLayout.class("not-a-home-name") == nil
  end

  test "the reserved and recently found names are denied (P0, SP5)" do
    for name <-
          ~w(backend.sock work admissions preparations packets submissions rebinds frozen execution-events.json mode.json clients.json availability.json.tmp execution-events.json.tmp),
        do: assert(HomeLayout.class(name) == :denied, name)
  end

  describe "runtime census" do
    # The work bench's own files in its home: the fake harnesses (bin), the folders works run
    # in (workspace), the fake Codex home (codex-home) and the fake harnesses' launch and end
    # logs (fake_native/main.go). Everything else is the Runtime's.
    @bench ~w(bin workspace codex-home work-launches.jsonl work-ends.jsonl)

    test "a home after read-only and workspace-write works holds only HomeLayout names" do
      bench = start!()

      for {instructions, permissions} <- [
            {"complete census read-only", "read-only"},
            {"complete census workspace-write", "workspace-write"}
          ] do
        request = request(bench, instructions)

        work =
          submit!(bench, instructions, %{
            workspace: %{request.workspace | permissions: permissions}
          })

        await_state(work.work_id, :completed)
      end

      entries = File.ls!(bench.dir) -- @bench
      assert entries != []
      assert Enum.reject(entries, &HomeLayout.class/1) == []
    end
  end
end
