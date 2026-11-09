defmodule AtlasRuntime.ProducerOutputTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Output, Turn}

  # A private adapter emits only what the test requests; it advertises no guidance.
  defmodule Port do
    use GenServer
    @behaviour AtlasRuntime.Agent

    def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})
    def stop(pid), do: GenServer.stop(pid)

    def init({owner, turn, opts}) do
      execution = %{
        "worker" => %{
          "environment" => turn.environment,
          "machine" => turn.machine,
          "worker" => turn.agent
        },
        "turn" => turn.key,
        "attempt" => turn.attempt
      }

      snapshot =
        if Process.whereis(Output),
          do: Output.snapshot(execution),
          else: {:error, "output_unavailable"}

      send(opts[:observer], {:adapter_started, self(), turn, snapshot})
      {:ok, %{owner: owner, monitor: Process.monitor(owner)}}
    end

    def handle_info({:emit, event}, state) do
      send(state.owner, {:agent, self(), {:output, event}})
      {:noreply, state}
    end

    def handle_info({:activity, text}, state) do
      send(state.owner, {:agent, self(), {:activity, text}})
      {:noreply, state}
    end

    def handle_info(:end, state) do
      send(state.owner, {:agent, self(), {:ended, "finished"}})
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
      do: {:stop, :normal, state}
  end

  # An adapter whose process has already exited, with a known reason, before its start
  # returns: the worst scheduling of an adapter that fails immediately after starting.
  # Started with the caller's monitor set atomically, the same exit reaches the owner.
  defmodule ExitingPort do
    use GenServer
    @behaviour AtlasRuntime.Agent

    def start(_turn, opts) do
      {:ok, pid} = GenServer.start(__MODULE__, opts)
      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, :process, ^pid, _} -> {:ok, pid})
    end

    def start_monitor(_turn, opts), do: :gen_server.start_monitor(__MODULE__, opts, [])
    def stop(_pid), do: :ok

    def init(opts), do: {:ok, opts, {:continue, :exit}}
    def handle_continue(:exit, opts), do: {:stop, opts[:reason], opts}
  end

  # Facts' Bus contract, with actual registration/read ordering rather than injecting
  # an output identity into Turn state. No model or external process is started.
  defmodule Store do
    use GenServer
    alias AtlasBus.Envelope

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def facts(pid), do: GenServer.call(pid, :facts)

    def init(opts) do
      :ok = AtlasBus.attach(AtlasBus.store())
      {:ok, %{facts: %{}, refuse: opts[:refuse] || false}}
    end

    def handle_call(:facts, _, state), do: {:reply, state.facts, state}

    def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, c}, state) do
      cond do
        c["op"] == "register_execution" and state.refuse ->
          :ok = AtlasBus.send(Envelope.reply(e, "refused"), %{"code" => "refused"})
          {:noreply, state}

        c["op"] == "register_execution" ->
          fact =
            Map.merge(c["values"], %{
              "key" => "execution",
              "environment" => AtlasBus.environment()
            })

          :ok = AtlasBus.send(Envelope.reply(e, "stored", position: 1), %{"fact" => fact})
          {:noreply, put_in(state.facts[{e.kind, "execution"}], fact)}

        true ->
          key = {e.kind, c["key"]}
          prior = state.facts[key] || %{"key" => c["key"], "values" => %{}, "links" => %{}}

          fact = %{
            prior
            | "values" => Map.merge(prior["values"], c["values"]),
              "links" => Map.merge(prior["links"], c["links"] || %{})
          }

          :ok = AtlasBus.send(Envelope.reply(e, "stored", position: 1), %{"fact" => fact})
          {:noreply, put_in(state.facts[key], fact)}
      end
    end

    def handle_info({:atlas_bus, %Envelope{class: "read"} = e, c}, state) do
      answer =
        case {e.kind, c} do
          {"work", _} -> %{"fact" => %{"values" => %{}, "links" => %{"owner" => ["worker"]}}}
          {_, %{"key" => key}} -> %{"fact" => state.facts[{e.kind, key}]}
          _ -> %{"facts" => [], "more" => false}
        end

      :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}
  end

  setup do
    previous = Application.get_env(:atlas_bus, :store)

    Application.put_env(
      :atlas_bus,
      :store,
      "producer-state-#{System.unique_integer([:positive])}"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atlas_bus, :store, previous),
        else: Application.delete_env(:atlas_bus, :store)
    end)

    :ok
  end

  defp start_turn(opts \\ []) do
    store = start_supervised!({Store, opts})
    key = "producer-turn-#{System.unique_integer([:positive])}"

    names = %{
      state: "state",
      running: "running",
      ended: "ended",
      machine: "machine",
      attempt: "attempt",
      lease: "lease",
      activity: "activity",
      why: "why",
      ended_at: "ended_at",
      on: "on",
      by: "by",
      outcome: "outcome"
    }

    turn = %{
      key: key,
      item: "item",
      kind: "work",
      agent: "worker",
      machine: "producer-machine",
      turn_kind: "turn",
      names: names,
      cause: "test producer",
      port: Keyword.get(opts, :port, Port),
      port_opts: Keyword.get(opts, :port_opts, observer: self()),
      silence: 60_000,
      max: 120_000,
      lease: 60_000,
      leave_grace: 0,
      guidance_every: :manual,
      ownership: %{"owner_relation" => "owner"},
      guidance_mapping: %{
        "execution" => %{"kind" => "execution"},
        "interaction" => %{"kind" => "interaction"},
        "receipt" => %{"kind" => "receipt"}
      }
    }

    pid = start_supervised!({Turn, turn})
    {pid, store, key}
  end

  defp started do
    assert_receive {:adapter_started, adapter, context, {:ok, snapshot}}, 3_000
    {adapter, context, snapshot}
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("producer state did not settle")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "the exact durable execution is open before the adapter starts and completion retains output" do
    {turn, store, key} = start_turn()
    {adapter, context, snapshot} = started()
    execution = snapshot["stream"]["execution"]
    durable = Store.facts(store)[{"execution", "execution"}]

    assert execution == %{
             "worker" => Map.take(durable, ~w(environment machine worker)),
             "turn" => key,
             "attempt" => context.attempt
           }

    assert durable["attempt"] == context.attempt
    assert is_binary(context.attempt) and context.attempt != ""
    refute snapshot["stream"]["ended"]

    send(adapter, {:emit, %{"kind" => "text", "text" => "Public answer"}})
    send(adapter, :end)
    ref = Process.monitor(turn)
    assert_receive {:DOWN, ^ref, :process, ^turn, _}, 3_000
    assert {:ok, page} = Output.read(execution, snapshot["cursor"])
    assert page["stream"]["ended"]
    assert Enum.any?(page["events"], &(&1["text"] == "Public answer"))
    assert Store.facts(store)[{"turn", key}]["values"]["state"] == "ended"
    assert {:error, "output_unavailable"} = Output.snapshot(%{execution | "attempt" => "other"})
  end

  test "viewer reads and output do not renew activity; only actual adapter activity does" do
    {turn, _store, _key} = start_turn()
    {adapter, _, snapshot} = started()
    execution = snapshot["stream"]["execution"]
    before = :sys.get_state(turn)
    send(adapter, {:emit, %{"kind" => "activity", "text" => "Public status"}})

    eventually(fn ->
      {:ok, page} = Output.read(execution, snapshot["cursor"])
      page["events"] != []
    end)

    for _ <- 1..3 do
      assert {:ok, _} = Output.snapshot(execution)
      assert {:ok, _} = Output.read(execution, snapshot["cursor"])
    end

    assert :sys.get_state(turn).active == before.active
    assert :sys.get_state(turn).written == before.written

    Process.sleep(2)
    send(adapter, {:activity, "safe activity"})
    eventually(fn -> :sys.get_state(turn).active > before.active end)
    {:ok, after_activity} = Output.read(execution, snapshot["cursor"])
    refute Enum.any?(after_activity["events"], &(&1["text"] == "safe activity"))

    # Expire the real producer lease while the viewer is still reading the ring.
    :sys.replace_state(turn, &%{&1 | active: System.system_time(:millisecond) - &1.silence})
    assert {:ok, _} = Output.snapshot(execution)
    ref = Process.monitor(turn)
    send(turn, :tick)
    assert_receive {:DOWN, ^ref, :process, ^turn, :normal}, 3_000
    assert {:ok, %{"stream" => %{"ended" => true}}} = Output.snapshot(execution)
  end

  test "a store restart reopens only on the same producer's next event, never on a viewer read" do
    {turn, store, _key} = start_turn()
    {adapter, _, snapshot} = started()
    execution = snapshot["stream"]["execution"]
    durable = Store.facts(store)[{"execution", "execution"}]
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, Output)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, Output)
    assert {:error, "output_unavailable"} = Output.snapshot(execution)

    send(turn, {:agent, self(), {:output, %{"kind" => "text", "text" => "wrong producer"}}})
    :sys.get_state(turn)
    assert {:error, "output_unavailable"} = Output.snapshot(execution)
    send(adapter, {:emit, %{"kind" => "text", "text" => "After restart"}})
    eventually(fn -> match?({:ok, _}, Output.snapshot(execution)) end)
    assert {:ok, recovered} = Output.snapshot(execution)
    assert recovered["stream"]["execution"] == execution
    refute recovered["stream"]["epoch"] == snapshot["stream"]["epoch"]
    assert Store.facts(store)[{"execution", "execution"}] == durable
    Turn.finish(turn, "explicit finish")
    ref = Process.monitor(turn)
    assert_receive {:DOWN, ^ref, :process, ^turn, _}, 3_000
    assert {:ok, %{"stream" => %{"ended" => true}}} = Output.snapshot(execution)
  end

  test "a temporarily unavailable output store does not end an eligible worker before startup" do
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, Output)

    on_exit(fn ->
      if Process.whereis(Output) == nil,
        do: Supervisor.restart_child(AtlasRuntime.Root, Output)
    end)

    {turn, store, key} = start_turn()
    assert_receive {:adapter_started, adapter, context, {:error, "output_unavailable"}}, 3_000
    assert Store.facts(store)[{"turn", key}]["values"]["state"] == "running"
    execution = :sys.get_state(turn).output_execution
    assert execution["attempt"] == context.attempt

    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, Output)
    send(adapter, {:emit, %{"kind" => "text", "text" => "Output recovered"}})

    eventually(fn ->
      case Output.snapshot(execution) do
        {:ok, snapshot} ->
          {:ok, page} = Output.read(execution, snapshot["cursor"])
          Enum.any?(page["events"], &(&1["text"] == "Output recovered"))

        {:error, "output_unavailable"} ->
          false
      end
    end)

    assert Store.facts(store)[{"execution", "execution"}]["attempt"] == context.attempt
    assert :sys.get_state(turn).output_execution == execution
  end

  test "failed durable registration cannot start an adapter or create an output ring" do
    {turn, store, key} = start_turn(refuse: true)
    ref = Process.monitor(turn)
    assert_receive {:DOWN, ^ref, :process, ^turn, _}, 3_000
    refute_received {:adapter_started, _, _, _}
    saved = Store.facts(store)[{"turn", key}]

    execution = %{
      "worker" => %{
        "environment" => AtlasBus.environment(),
        "machine" => "producer-machine",
        "worker" => "worker"
      },
      "turn" => key,
      "attempt" => saved["values"]["attempt"]
    }

    assert {:error, "output_unavailable"} = Output.snapshot(execution)
  end

  test "an abnormal owner death closes but retains its produced output" do
    {turn, _store, _key} = start_turn()
    {adapter, _, snapshot} = started()
    execution = snapshot["stream"]["execution"]
    send(adapter, {:emit, %{"kind" => "text", "text" => "Before owner death"}})

    eventually(fn ->
      {:ok, page} = Output.read(execution, snapshot["cursor"])
      page["events"] != []
    end)

    ref = Process.monitor(turn)
    Process.exit(turn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^turn, :killed}, 3_000

    eventually(fn ->
      {:ok, page} = Output.read(execution, snapshot["cursor"])
      page["stream"]["ended"] and Enum.any?(page["events"], &(&1["text"] == "Before owner death"))
    end)
  end

  test "an adapter that exits right after starting ends the turn with its own exit reason" do
    ExUnit.CaptureLog.capture_log(fn ->
      {turn, store, key} =
        start_turn(port: ExitingPort, port_opts: [reason: :adapter_failed_at_start])

      ref = Process.monitor(turn)
      assert_receive {:DOWN, ^ref, :process, ^turn, _}, 3_000
      values = Store.facts(store)[{"turn", key}]["values"]
      assert values["state"] == "ended"
      assert values["why"] == "the agent crashed: :adapter_failed_at_start"
    end)
  end
end
