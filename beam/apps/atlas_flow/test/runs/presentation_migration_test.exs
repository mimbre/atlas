defmodule AtlasFlow.PresentationTarget do
  defdelegate rela_flows_sha256(), to: AtlasFlow.FixtureTarget
  defdelegate check_rela_flows(bytes), to: AtlasFlow.FixtureTarget

  def flows do
    flow =
      AtlasFlow.FixtureTarget.flow()
      |> put_in(["states", "waiting", "owner"], %{
        "default" => %{"kind" => "clerk", "key" => "ada"},
        "preserve_kind" => "clerk"
      })
      |> put_in(["states", "waiting", "present", "deadline"], "retry")

    %{"sort" => flow}
  end
end

defmodule AtlasFlow.Runs.PresentationMigrationTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{Engine, FakeFacts, FixtureTarget, ManualClock, PresentationTarget}
  alias AtlasFlow.Runs.{Run, Store}
  @now ~U[2026-11-12 00:00:00Z]

  @tag :tmp_dir
  test "restart migrates live waits without resetting entries or deadlines, then repairs ownership",
       %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "presentation-#{System.unique_integer([:positive])}")
    flow = PresentationTarget.flows()["sort"]

    description =
      FakeFacts.run_description()
      |> put_in(["flow_runtime", "selection", "sort", "projection", "deadline_field"], "due")
      |> put_in(["flow_runtime", "selection", "sort", "migrations"], [
        %{
          "from" => Run.digest(FixtureTarget.flow()),
          "to" => Run.digest(flow),
          "states" => %{"waiting" => "waiting"},
          "preserve_entry" => true
        }
      ])

    config = description["flow_runtime"]
    start_supervised!({FakeFacts, description: description})
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    clock = start_supervised!({ManualClock, @now})

    originals =
      for {key, owners} <- [{"B-machine", ["sorter"]}, {"B-clerk", ["bob"]}, {"B-empty", []}],
          into: %{} do
        subject = %{
          "key" => key,
          "values" => %{"phase" => "first", "todo" => "Sort it"},
          "links" => %{"owned_by" => owners},
          "origins" => %{"owned_by" => %{"by" => "operator"}}
        }

        FakeFacts.put("box", subject)

        old =
          Run.new("sort", FixtureTarget.flow(), subject, [], @now)
          |> put_in(["pending", "writes"], [])

        FakeFacts.put("cursor", %{"key" => old["key"], "values" => Store.encode(config, old)})
        {key, old}
      end

    yaml = Path.join(dir, "flows.yaml")
    File.write!(yaml, "fixture\n")
    opts = [clock: {ManualClock, clock}, target: PresentationTarget, deployed_yaml: yaml]

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end)

    for _ <- 1..2 do
      engine = start_supervised!({Engine, opts})
      :ok = Engine.round(engine)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor) do
        send(pid, :look)
        :sys.get_state(pid)
      end

      for {key, old} <- originals do
        assert {:ok, migrated} = Store.decode(config, FakeFacts.get("cursor", old["key"]))
        assert migrated["definition_sha256"] == Run.digest(flow)

        assert Map.take(migrated, ~w(state entry entered_at deadlines)) ==
                 Map.take(old, ~w(state entry entered_at deadlines))

        assert length(migrated["pending"]["migrations"]) == 1
        fact = FakeFacts.get("box", key)
        assert fact["links"]["owned_by"] == [if(key == "B-clerk", do: "bob", else: "ada")]
        assert fact["values"]["due"] == hd(old["deadlines"]["timers"])["due"]
      end

      stop_supervised!(Engine)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
    end

    # The same instant stored with other precision is no change; a state that presents no
    # deadline (here: the run answered and final) clears it.
    kept = FakeFacts.get("box", "B-clerk")
    {:ok, due, _} = DateTime.from_iso8601(kept["values"]["due"])
    precise = DateTime.to_iso8601(%{due | microsecond: {0, 6}})
    assert precise != kept["values"]["due"]
    FakeFacts.put("box", put_in(kept, ["values", "due"], precise))
    answered = FakeFacts.get("box", "B-empty")
    FakeFacts.put("box", put_in(answered, ["values", "result"], "ok"))
    engine = start_supervised!({Engine, opts})
    :ok = Engine.round(engine)

    # An item whose run is final stops after its last write.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor) do
      send(pid, :look)

      try do
        :sys.get_state(pid)
      catch
        :exit, _ -> :stopped
      end
    end

    assert FakeFacts.get("box", "B-clerk")["values"]["due"] == precise

    assert {:ok, %{"state" => "done"}} =
             Store.decode(config, FakeFacts.get("cursor", originals["B-empty"]["key"]))

    assert FakeFacts.get("box", "B-empty")["values"]["due"] in [nil, ""]
    stop_supervised!(Engine)
  end
end
