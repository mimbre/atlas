# MIX_ENV=test mix run integration/lifecycle_native.exs
# Production compiled model, real Lifecycle -> Bus -> Facts, private disk store.
ExUnit.start(seed: 0)

defmodule LifecycleNativeProof do
  use ExUnit.Case, async: false
  alias AtlasFacts.{GuidanceStore, Rela}
  alias AtlasRuntime.Integrations.AtlasServer.Lifecycle

  setup do
    dir = Path.join(System.tmp_dir!(), "lifecycle-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :store, "lifecycle-native-facts")

    {:ok, backend} =
      GuidanceStore.start(Path.join(dir, "store.json"), Model.AtlasEyra.rela_schema())

    rela = {GuidanceStore, backend}
    assert {:ok, []} = Rela.create(rela, "agents", "worker", %{"name" => "Worker"}, %{})

    start_supervised!(
      {AtlasFacts.Server, rela: rela, data_dir: Path.join(dir, "ledger"), model: Model.AtlasEyra}
    )

    config = %{machine: "lifecycle-proof", environment: "test", workers: ["worker"]}
    server = Lifecycle.identity(config, "worker", "local")

    run = %{
      id: "local",
      state: "running",
      backend: "codex",
      requested_model: "synthetic",
      server: server
    }

    {:ok, reporter} = Lifecycle.start(config, model: Model.AtlasEyra, lease: 1, silence: 600_000)

    on_exit(fn ->
      if Process.alive?(reporter), do: GenServer.stop(reporter)
      if Process.alive?(backend), do: Agent.stop(backend)
      Application.put_env(:atlas_bus, :store, previous)
      File.rm_rf!(dir)
    end)

    %{rela: rela, reporter: reporter, run: run, server: server}
  end

  defp stored(c) do
    assert {:ok, fact} = Rela.get(c.rela, "turns", c.server["turn"])
    fact
  end

  defp start(c) do
    Lifecycle.started(c.reporter, c.run)

    assert_receive {:server_report, "local", _,
                    %{"turn" => "running", "execution" => "registered"}},
                   2000
  end

  defp seed(c, extra \\ %{}, links \\ %{}) do
    assert {:ok, []} =
             Rela.create(
               c.rela,
               "turns",
               c.server["turn"],
               Map.merge(
                 %{
                   "state" => "running",
                   "machine" => c.server["machine"],
                   "attempt" => c.server["attempt"]
                 },
                 extra
               ),
               Map.merge(%{"turn_by" => {"agent", ["worker"]}}, links)
             )
  end

  for existing <- [false, true] do
    test "#{if existing, do: "pre-upgrade", else: "new"} standalone attempt renews and completes",
         c do
      if unquote(existing), do: seed(c)
      start(c)
      assert stored(c).links["turn_on"] in [nil, []]
      Process.sleep(5)
      Lifecycle.activity(c.reporter, c.run, "working")
      Lifecycle.flush(c.reporter, 2000)
      assert stored(c).properties["activity"] == "working"
      assert stored(c).properties["lease_until"] not in [nil, ""]
      Lifecycle.model(c.reporter, c.run, "reported-model")
      Lifecycle.flush(c.reporter, 2000)
      assert stored(c).properties["model"] == "reported-model"
      # Service checkpoints the evolving report in the same persisted identity.
      run = %{
        c.run
        | server:
            Map.put(c.run.server, "report", %{"turn" => "running", "execution" => "registered"})
      }

      Lifecycle.ended(c.reporter, %{run | state: "finished"})
      assert_receive {:server_report, "local", _, %{"turn" => "ended"}}, 2000
      assert stored(c).properties["state"] == "ended"
      assert stored(c).properties["quiescent"] == true
      assert :sys.get_state(c.reporter).turns == %{}
    end
  end

  test "wrong attempt cannot adopt or complete an existing turn", c do
    seed(c, %{"attempt" => "other"})
    Lifecycle.started(c.reporter, c.run)
    assert_receive {:server_report, "local", _, %{"turn" => "unconfirmed"}}, 2000
    Lifecycle.ended(c.reporter, %{c.run | state: "finished"})
    Lifecycle.flush(c.reporter, 2000)
    assert stored(c).properties["state"] == "running"
    assert stored(c).properties["quiescent"] == nil
  end

  test "standalone registration cannot take a projected capacity reservation", c do
    assert {:ok, []} =
             Rela.create(
               c.rela,
               "assignments",
               "AS-reserved",
               %{"of" => "reserved", "expected" => "Build it", "capacity_entry" => "run:1:1"},
               %{"assigned_to" => {"agent", ["worker"]}}
             )

    Lifecycle.started(c.reporter, c.run)
    assert_receive {:server_report, "local", _, %{"turn" => "unconfirmed"}}, 2000
    assert {:error, :not_found} = Rela.get(c.rela, "turns", c.server["turn"])
  end

  test "native Turn retains refused completion and retries its original attempt", c do
    seed(c, %{"attempt" => "replacement"})
    :ok = AtlasBus.attach("runtime@lifecycle-proof/" <> c.server["turn"])
    names = Map.new(Model.AtlasEyra.turn(), fn {k, v} -> {String.to_atom(k), v} end)

    state = %{
      key: c.server["turn"],
      names: names,
      turn_kind: "turn",
      attempt: c.server["attempt"],
      agent_pid: self(),
      ref: make_ref(),
      port: nil,
      guidance: nil,
      output_execution: nil,
      leaving: nil,
      lease: 60000,
      silence: 600_000,
      confirmed_quiescent: false
    }

    assert {:noreply, pending} =
             AtlasRuntime.Turn.handle_info({:agent, self(), {:ended, "done"}}, state)

    assert pending.confirmed_quiescent
    assert pending.pending_end =~ "done"
    assert stored(c).properties["state"] == "running"

    assert {:ok, []} =
             Rela.change(
               c.rela,
               "turns",
               c.server["turn"],
               %{"attempt" => c.server["attempt"]},
               nil,
               %{}
             )

    assert {:stop, :normal, _} = AtlasRuntime.Turn.handle_info(:tick, pending)
    assert stored(c).properties["state"] == "ended"
    assert stored(c).properties["quiescent"] == true
  end

  test "stale activity and completion refuse and retain the local attempt", c do
    start(c)

    assert {:ok, []} =
             Rela.change(
               c.rela,
               "turns",
               c.server["turn"],
               %{"attempt" => "replacement"},
               nil,
               %{}
             )

    Process.sleep(5)
    Lifecycle.model(c.reporter, c.run, "stale-model")
    assert_receive {:server_report, "local", _, %{"error" => model_error}}, 2000
    assert model_error =~ "model not stored"
    assert stored(c).properties["model"] == "synthetic"
    Lifecycle.activity(c.reporter, c.run, "stale")
    assert_receive {:server_report, "local", _, %{"error" => activity_error}}, 2000
    assert activity_error =~ "activity not stored"
    Lifecycle.ended(c.reporter, %{c.run | state: "finished"})

    assert_receive {:server_report, "local", _, %{"turn" => "running", "error" => end_error}},
                   2000

    assert end_error =~ "end not stored"
    assert stored(c).properties["state"] == "running"
    assert stored(c).properties["quiescent"] == nil
    assert :sys.get_state(c.reporter).turns["local"].completion.state == "finished"

    assert {:ok, []} =
             Rela.change(
               c.rela,
               "turns",
               c.server["turn"],
               %{"attempt" => c.server["attempt"]},
               nil,
               %{}
             )

    Lifecycle.ended(c.reporter, %{c.run | state: "finished"})
    assert_receive {:server_report, "local", _, %{"turn" => "ended"}}, 2000
    assert stored(c).properties["quiescent"] == true
  end

  for binding <- [:pick, :worker, :item] do
    test "attempt identity alone cannot adopt a different #{binding} binding", c do
      case unquote(binding) do
        :pick -> seed(c, %{"pick" => "allocation"})
        :worker -> seed(c, %{}, %{"turn_by" => {"agent", ["different-worker"]}})
        :item -> seed(c, %{}, %{"turn_on" => {"assignment", ["AS-different"]}})
      end

      Lifecycle.started(c.reporter, c.run)
      assert_receive {:server_report, "local", _, %{"turn" => "unconfirmed"}}, 2000
    end
  end

  test "late local events for a different attempt do not finish the tracked turn", c do
    start(c)
    wrong = %{c.run | server: Map.put(c.run.server, "attempt", "old-attempt")}
    Lifecycle.model(c.reporter, wrong, "wrong-model")
    Lifecycle.activity(c.reporter, wrong, "wrong-activity")
    Lifecycle.ended(c.reporter, %{wrong | state: "finished"})
    Lifecycle.flush(c.reporter, 2000)
    assert stored(c).properties["state"] == "running"
    assert stored(c).properties["model"] == "synthetic"
    assert stored(c).properties["activity"] == "started"
    assert :sys.get_state(c.reporter).turns["local"].completion == nil
  end

  test "expired lease and reporter loss preserve uncertainty and reserve the worker", c do
    seed(c, %{"lease_until" => "2000-01-01T00:00:00Z"})
    start(c)
    GenServer.stop(c.reporter)
    assert stored(c).properties["quiescent"] == nil
    :ok = AtlasBus.attach("runtime@lifecycle-proof/" <> c.server["turn"])

    assert {:refused, _} =
             AtlasRuntime.Talk.fact("turn", %{
               "op" => "create",
               "key" => "TU-next",
               "values" => %{
                 "state" => "running",
                 "machine" => c.server["machine"],
                 "attempt" => "next"
               },
               "links" => %{"turn_by" => ["worker"]},
               "by" => "runtime"
             })
  end

  test "monitor failure reports no quiescence", c do
    start(c)
    Lifecycle.ended(c.reporter, Map.put(%{c.run | state: "failed"}, :error, "reporter lost"))
    assert_receive {:server_report, "local", _, %{"turn" => "ended"}}, 2000
    assert stored(c).properties["quiescent"] == nil
  end

  test "each lifecycle field requires both exact preconditions", c do
    seed(c)
    :ok = AtlasBus.attach("runtime@lifecycle-proof/" <> c.server["turn"])

    for values <- [
          %{"activity" => "working"},
          %{"model" => "updated-model"},
          %{"lease_until" => "2099-01-01T00:00:00Z"},
          %{"state" => "ended", "quiescent" => true}
        ] do
      content = %{
        "op" => "change",
        "key" => c.server["turn"],
        "values" => values,
        "by" => "runtime"
      }

      for was <- [
            nil,
            %{"attempt" => c.server["attempt"]},
            %{"pick" => "wrong", "attempt" => c.server["attempt"]},
            %{"pick" => nil, "attempt" => "wrong"}
          ] do
        assert {:refused, _} = AtlasRuntime.Talk.fact("turn", Map.put(content, "was", was))
      end

      assert {:stored, _, _} =
               AtlasRuntime.Talk.fact(
                 "turn",
                 Map.put(content, "was", %{"pick" => nil, "attempt" => c.server["attempt"]})
               )
    end
  end
end
