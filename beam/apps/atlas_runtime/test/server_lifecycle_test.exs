defmodule AtlasRuntime.ServerLifecycleTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Integrations.AtlasServer.Lifecycle
  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, Output, OutputEndpoint, Service}
  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: Wire

  @moduletag capture_log: true
  @talk [talk: [tries: 1, wait: 300]]

  # Facts as the isolated proof showed it, for these kinds only: the sender must be the
  # turn's machine's Runtime; an execution must match its running turn's exact attempt.
  defmodule Store do
    use GenServer

    def description do
      %{
        "runtime" => %{
          "turn" => %{
            "kind" => "turn",
            "key" => "TU-{on}-{n}",
            "on" => "turn_on",
            "by" => "turn_by",
            "state" => "state",
            "running" => "running",
            "ended" => "ended",
            "machine" => "machine",
            "lease" => "lease_until",
            "activity" => "activity",
            "why" => "why",
            "ended_at" => "ended_at",
            "outcome" => "outcome",
            "attempt" => "attempt"
          }
        },
        "guidance" => %{"execution" => %{"kind" => "worker_execution"}}
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def facts(store), do: GenServer.call(store, :facts)

    def init(opts) do
      :ok = AtlasBus.attach(AtlasBus.store())

      {:ok,
       %{
         agents: opts[:agents],
         dir: opts[:dir],
         turns: %{},
         executions: %{},
         sent: [],
         position: 0
       }}
    end

    def handle_call(:facts, _from, s), do: {:reply, s, s}

    def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
      answer =
        case {e.kind, content} do
          {"_description", _} ->
            %{"description" => description()}

          {"turn", %{"key" => key}} ->
            %{"fact" => s.turns[key]}

          {"worker_execution", %{"turn" => turn, "attempt" => attempt}} ->
            case s.executions[{turn, attempt}] do
              nil -> %{"error" => "not_found"}
              fact -> %{"fact" => fact}
            end
        end

      :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
      {:noreply, s}
    end

    def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, content}, s) do
      s = %{s | sent: s.sent ++ [{e.kind, e.sender, content}]}

      case write(e, content, s) do
        {:ok, answer, s} ->
          s = %{s | position: s.position + 1}
          :ok = AtlasBus.send(Envelope.reply(e, "stored", position: s.position), answer)
          {:noreply, s}

        {:refused, reason} ->
          :ok = AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => [reason]})
          {:noreply, s}
      end
    end

    def handle_info(_, s), do: {:noreply, s}

    defp write(e, %{"op" => "create", "key" => key, "values" => v} = c, s) do
      cond do
        Map.has_key?(s.turns, key) ->
          {:refused, "exists"}

        e.sender != "runtime@" <> v["machine"] ->
          {:refused, "turn_authority"}

        not Enum.all?(c["links"]["turn_by"], &(&1 in s.agents)) ->
          {:refused, "unknown agent"}

        true ->
          # What the local service had persisted when the first remote write arrived.
          local = String.replace_prefix(key, "TU-" <> v["machine"] <> "-", "")

          saved =
            Path.join([s.dir, "turns", local, "turn.json"]) |> File.read!() |> JSON.decode!()

          fact = %{
            "key" => key,
            "values" => v,
            "links" => c["links"],
            "persisted" => saved["server"]
          }

          {:ok, Map.take(c, ~w(op key by)), put_in(s.turns[key], fact)}
      end
    end

    defp write(e, %{"op" => "change", "key" => key, "values" => v} = c, s) do
      case s.turns[key] do
        nil ->
          {:refused, "not_found"}

        %{"values" => old} = fact ->
          if e.sender == "runtime@" <> old["machine"],
            do:
              {:ok, Map.take(c, ~w(op key by)),
               put_in(s.turns[key], %{fact | "values" => Map.merge(old, v)})},
            else: {:refused, "turn_authority"}
      end
    end

    defp write(e, %{"op" => "register_execution", "values" => v}, s) do
      turn = s.turns[v["turn"]]

      if (turn && e.sender == "runtime@" <> v["machine"]) and
           turn["values"]["machine"] == v["machine"] and
           turn["values"]["attempt"] == v["attempt"] and v["worker"] in turn["links"]["turn_by"] and
           turn["values"]["state"] == "running" do
        fact = Map.put(v, "environment", e.environment)
        {:ok, %{"fact" => fact}, put_in(s.executions[{v["turn"], v["attempt"]}], fact)}
      else
        {:refused, "execution_authority"}
      end
    end
  end

  setup do
    # Short: the service's socket path must fit a Unix socket name.
    dir =
      Path.join(
        System.tmp_dir!(),
        "asl-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    bin = Path.join(dir, "bin")
    Enum.each([bin, Path.join(dir, "alpha"), Path.join(dir, "beta")], &File.mkdir_p!/1)
    AtlasRuntime.FakeNative.install!(Path.join(bin, "claude"), "peer")
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)

    on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp config(workers \\ ["alpha"]),
    do: %{
      environment: AtlasBus.environment(),
      machine: "box",
      host: "127.0.0.1",
      port: 4100,
      workers: workers
    }

  defp launch(dir, server) do
    {:ok, pid} = GenServer.start(Service, {dir, server, @talk})

    on_exit(fn ->
      if Process.alive?(pid) do
        agents = for {_, w} <- :sys.get_state(pid).workers, is_pid(w.agent), do: w.agent
        Process.exit(:sys.get_state(pid).server.reporter, :kill)
        Process.exit(pid, :kill)
        Enum.each(agents, &Native.stop/1)
      end
    end)

    pid
  end

  defp ok(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    reply
  end

  defp start(pid, worker, dir) do
    ok(pid, %{
      "command" => "start",
      "worker_id" => worker,
      "cwd" => Path.join(dir, worker),
      "assignment" => "Synthetic lifecycle fixture",
      "backend" => "claude"
    })
  end

  defp await(fun, remaining \\ 500) do
    case fun.() do
      result when result in [nil, false] ->
        if remaining == 0,
          do: flunk("condition not reached"),
          else:
            (
              Process.sleep(10)
              await(fun, remaining - 1)
            )

      result ->
        result
    end
  end

  defp status(pid, worker), do: ok(pid, %{"command" => "status", "worker_id" => worker})

  # The exact execution Output and Control key a reported turn's output by.
  defp execution(server),
    do: %{
      "worker" => Map.take(server, ~w(environment machine worker)),
      "turn" => server["turn"],
      "attempt" => server["attempt"]
    }

  defp events(%{"events" => events}), do: Enum.map(events, &Map.delete(&1, "sequence"))
  defp saved(run), do: Path.join(run.artifacts, "turn.json") |> File.read!() |> JSON.decode!()

  test "configuration is opt-in, exact, and keeps its token in the protected Runtime home", %{
    dir: dir
  } do
    assert Lifecycle.load!(dir) == nil
    token = Path.join(dir, "server.token")
    File.write!(token, "secret-link-token\n")
    File.chmod!(token, 0o600)

    good = %{
      "environment" => "test",
      "machine" => "box",
      "host" => "127.0.0.1",
      "port" => 4100,
      "token_file" => "server.token",
      "workers" => ["alpha"]
    }

    write = fn config -> File.write!(Path.join(dir, "server.json"), JSON.encode!(config)) end

    write.(good)
    config = Lifecycle.load!(dir)
    assert %{machine: "box", workers: ["alpha"], token: "secret-link-token"} = config

    assert Lifecycle.link(config) == %{
             "mode" => "client",
             "host" => "127.0.0.1",
             "port" => 4100,
             "machine" => "box",
             "token" => "secret-link-token"
           }

    write.(%{good | "token_file" => token})
    assert Lifecycle.load!(dir).token == "secret-link-token"

    outside = Path.join(System.tmp_dir!(), "asl-outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret-link-token")
    File.chmod!(outside, 0o600)
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(dir, "linked.token"))

    for {change, why} <- [
          {%{"token_file" => outside}, "inside the Runtime home"},
          {%{"token_file" => "../x"}, "inside the Runtime home"},
          {%{"token_file" => "linked.token"}, "no symbolic link"},
          {%{"token_file" => "missing.token"}, "cannot read token_file"},
          {%{"machine" => "this machine"}, "machine must be an explicit name"},
          {%{"workers" => []}, "workers must be"},
          {%{"workers" => ["alpha", "alpha"]}, "workers must be"},
          {%{"environment" => "staging"}, "environment must be"},
          {%{"port" => 0}, "port must be"},
          {%{"extra" => true}, "must have exactly"}
        ] do
      write.(Map.merge(good, change))
      error = assert_raise RuntimeError, fn -> Lifecycle.load!(dir) end
      assert error.message =~ why
      refute error.message =~ "secret-link-token"
    end

    File.chmod!(token, 0o640)
    write.(good)
    assert_raise RuntimeError, ~r/readable by its owner only/, fn -> Lifecycle.load!(dir) end
    File.write!(token, "  \n")
    File.chmod!(token, 0o600)
    assert_raise RuntimeError, ~r/token_file is empty/, fn -> Lifecycle.load!(dir) end
  end

  test "an allowlisted worker's turn is mirrored running then ended, with its exact identity", %{
    dir: dir
  } do
    store = start_supervised!({Store, agents: ["alpha", "beta"], dir: dir})
    pid = launch(dir, config())

    alpha = start(pid, "alpha", dir)
    beta = start(pid, "beta", dir)
    assert "turn-" <> _ = alpha.id
    server = alpha.server
    attempt = server["attempt"]
    key = "TU-box-" <> alpha.id

    assert Map.take(server, ~w(environment machine worker turn)) ==
             %{
               "environment" => AtlasBus.environment(),
               "machine" => "box",
               "worker" => "alpha",
               "turn" => key
             }

    refute Map.has_key?(beta, :server)

    alpha =
      await(fn ->
        (run = status(pid, "alpha")) && run.server["report"]["turn"] == "ended" && run
      end)

    assert alpha.state == "finished"
    assert alpha.server["attempt"] == attempt

    assert alpha.server["report"] == %{
             "turn" => "ended",
             "execution" => "registered",
             "error" => nil
           }

    assert saved(alpha)["server"] == alpha.server
    await(fn -> status(pid, "beta").state == "finished" end)

    facts = Store.facts(store)
    assert Map.keys(facts.turns) == [key]
    turn = facts.turns[key]
    # Persisted before the first remote write, with this exact attempt; no item, no outcome.
    assert turn["persisted"]["attempt"] == attempt
    assert turn["links"] == %{"turn_by" => ["alpha"]}

    assert %{
             "state" => "ended",
             "why" => "finished",
             "lease_until" => "",
             "machine" => "box",
             "attempt" => ^attempt
           } = turn["values"]

    refute Map.has_key?(turn["values"], "outcome")
    assert is_binary(turn["values"]["ended_at"])

    assert [{^key, ^attempt}] = Map.keys(facts.executions)

    assert facts.executions[{key, attempt}] == %{
             "environment" => AtlasBus.environment(),
             "worker" => "alpha",
             "turn" => key,
             "attempt" => attempt,
             "machine" => "box",
             "harness" => "claude",
             "harness_version" => "unknown",
             "configured_model" => "unknown",
             "capability_version" => "1",
             "queued_input" => false,
             "durable_accept_query" => false,
             "consumption_evidence" => false
           }

    assert Enum.all?(facts.sent, fn {_kind, sender, _} -> sender == "runtime@box" end)

    assert Enum.all?(facts.sent, fn {_kind, _, content} ->
             content["values"]["worker"] != "beta" and
               content["links"]["turn_by"] != ["beta"]
           end)

    # Exact reverse correlation: only this turn and attempt answer.
    :ok = AtlasBus.attach("runtime@box/probe-#{System.unique_integer([:positive])}")

    assert %{"fact" => %{"attempt" => ^attempt}} =
             AtlasRuntime.Talk.read("worker_execution", %{"turn" => key, "attempt" => attempt})

    assert %{"error" => "not_found"} =
             AtlasRuntime.Talk.read("worker_execution", %{"turn" => key, "attempt" => "wrong"})

    assert %{"error" => "not_found"} =
             AtlasRuntime.Talk.read("worker_execution", %{
               "turn" => alpha.id,
               "attempt" => attempt
             })
  end

  test "a refused report is recorded honestly and the local turn runs as before", %{dir: dir} do
    store = start_supervised!({Store, agents: ["someone-else"], dir: dir})
    pid = launch(dir, config())
    start(pid, "alpha", dir)

    run =
      await(fn ->
        (r = status(pid, "alpha")) && r.server["report"]["error"] && r.state == "finished" && r
      end)

    assert run.server["report"] == %{
             "turn" => "unconfirmed",
             "execution" => "unconfirmed",
             "error" => "turn not created: refused: unknown agent"
           }

    assert saved(run)["server"]["report"] == run.server["report"]
    facts = Store.facts(store)
    assert facts.turns == %{} and facts.executions == %{}
    # Nothing more is written for a turn Facts never created.
    Process.sleep(100)
    assert [{"turn", "runtime@box", %{"op" => "create"}}] = Store.facts(store).sent
  end

  test "a disconnected Server never blocks the native lifecycle", %{dir: dir} do
    pid = launch(dir, config())
    {micros, run} = :timer.tc(fn -> start(pid, "alpha", dir) end)
    assert micros < 2_000_000
    assert run.server["report"]["turn"] == "unconfirmed"

    run =
      await(fn ->
        (r = status(pid, "alpha")) && r.state == "finished" && r.server["report"]["error"] && r
      end)

    assert run.server["report"]["error"] == "turn not created: Facts did not answer"
    assert ok(pid, %{"command" => "output", "worker_id" => "alpha"}).state == "finished"
    # Output never waits for Server: it is retained, and closed, without one.
    assert {:ok, %{"stream" => %{"ended" => true}} = read} =
             Output.read(execution(run.server), nil)

    assert %{"kind" => "text", "text" => "Synthetic fixture completed"} in events(read)
  end

  test "a reported turn's public output is retained under its exact attempt and closed at its end",
       %{dir: dir} do
    start_supervised!({Store, agents: ["alpha", "beta"], dir: dir})
    pid = launch(dir, config())
    alpha = start(pid, "alpha", dir)
    beta = start(pid, "beta", dir)

    await(fn ->
      status(pid, "alpha").state == "finished" and status(pid, "beta").state == "finished"
    end)

    exact = execution(alpha.server)

    assert {:ok, %{"stream" => %{"execution" => ^exact, "ended" => true}, "more" => false} = read} =
             Output.read(exact, nil)

    # Only the provider's public projection: no native records, session or model input.
    assert %{"kind" => "text", "text" => "Synthetic fixture completed"} in events(read)
    assert Enum.all?(events(read), &(Map.keys(&1) -- ~w(kind text tool_name status) == []))

    for wrong <- [
          put_in(exact["attempt"], "other-attempt"),
          put_in(exact["worker"]["machine"], "elsewhere"),
          put_in(exact["worker"]["worker"], "beta"),
          put_in(exact["turn"], alpha.id)
        ],
        do: assert(Output.snapshot(wrong) == {:error, "output_unavailable"})

    # An unreported worker's turn keeps its local output only.
    rings = :sys.get_state(Output).rings

    refute Enum.any?(Map.keys(rings), fn key ->
             elem(key, 2) == "beta" or elem(key, 3) =~ beta.id
           end)

    # Control reads it through the existing exact-attempt route of the configured machine.
    client = "control/standalone-output-#{System.unique_integer([:positive])}"
    :ok = AtlasBus.attach(client)
    endpoint = start_supervised!({OutputEndpoint, machine: "box"})

    envelope = %{
      Envelope.new("request", "runtime.output")
      | sender: client,
        address: "runtime@box/output"
    }

    ask = fn operation, request ->
      send(
        endpoint,
        {:atlas_bus, envelope, Wire.request(operation, Map.put(request, :id, envelope.id))}
      )

      assert_receive {:atlas_bus, %Envelope{class: "answer", id: id}, reply}
      assert id == envelope.id
      Wire.decode_reply(operation, reply)
    end

    assert {:ok, :result, %{"cursor" => cursor}} =
             ask.(:runtime_output_snapshot, %{execution: exact})

    assert {:ok, :result, %{"stream" => %{"ended" => true}} = remote} =
             ask.(:runtime_output_read, %{execution: exact, cursor: cursor})

    assert events(remote) == events(read)

    assert {:ok, :error, %{"error" => %{"code" => "output_unavailable"}}} =
             ask.(:runtime_output_snapshot, %{
               execution: put_in(exact["attempt"], "other-attempt")
             })
  end

  describe "service reporting hooks" do
    setup %{dir: dir} do
      run = %{
        id: "turn-00000000000000a1",
        worker_id: "alpha",
        state: "running",
        backend: "claude",
        started_at: "2026-11-08T10:00:00Z",
        artifacts: Path.join([dir, "turns", "turn-00000000000000a1"]),
        server: Lifecycle.identity(config(), "alpha", "turn-00000000000000a1")
      }

      File.mkdir_p!(run.artifacts)
      File.write!(Path.join(run.artifacts, "turn.json"), JSON.encode!(run))
      agent = start_supervised!({Agent, fn -> nil end})

      state = %{
        dir: dir,
        policy: BackendPolicy.empty(),
        events: ExecutionEvents.open(dir),
        stopping: false,
        server: %{config: config(), reporter: self()},
        workers: %{"alpha" => %{agent: agent, monitor: Process.monitor(agent), run: run}}
      }

      %{state: state, run: run}
    end

    test "activity and ends go to the reporter after persistence; reports correlate exactly", %{
      state: state,
      run: run
    } do
      {:noreply, state} =
        Service.handle_info({:agent, state.workers["alpha"].agent, {:activity, "reading"}}, state)

      assert_received {:"$gen_cast", {:activity, %{id: "turn-00000000000000a1"}, "reading"}}

      attempt = run.server["attempt"]
      report = %{"turn" => "running", "execution" => "registered", "error" => nil}

      assert {:noreply, ^state} =
               Service.handle_info({:server_report, run.id, "other-attempt", report}, state)

      {:noreply, state} = Service.handle_info({:server_report, run.id, attempt, report}, state)
      assert state.workers["alpha"].run.server["report"] == report
      assert saved(state.workers["alpha"].run)["server"]["attempt"] == attempt

      {:noreply, state} =
        Service.handle_info({:agent, state.workers["alpha"].agent, {:ended, "done"}}, state)

      assert_received {:"$gen_cast", {:ended, %{id: "turn-00000000000000a1", state: "finished"}}}
      assert saved(state.workers["alpha"].run)["state"] == "finished"
      refute_received {:"$gen_cast", {:started, _}}
    end

    test "public output goes to the exact attempt's ring, closed by every terminal path",
         %{state: state, run: run} do
      agent = state.workers["alpha"].agent
      exact = execution(run.server)
      # No ring was opened (as when it was lost): the turn's own next event opens one.
      {:noreply, state} =
        Service.handle_info(
          {:agent, agent, {:output, %{"kind" => "text", "text" => "one"}}},
          state
        )

      {:noreply, state} =
        Service.handle_info(
          {:agent, agent,
           {:output, %{"kind" => "tool", "tool_name" => "Read", "status" => "started"}}},
          state
        )

      # Another process's output never reaches it.
      {:noreply, ^state} =
        Service.handle_info(
          {:agent, self(), {:output, %{"kind" => "text", "text" => "foreign"}}},
          state
        )

      assert {:ok, %{"stream" => %{"ended" => false}} = read} = Output.read(exact, nil)

      assert events(read) == [
               %{"kind" => "text", "text" => "one"},
               %{"kind" => "tool", "tool_name" => "Read", "status" => "started"}
             ]

      {:noreply, ended} = Service.handle_info({:agent, agent, {:ended, "done"}}, state)
      assert {:ok, %{"stream" => %{"ended" => true}}} = Output.snapshot(exact)
      assert ended.workers["alpha"].run.state == "finished"

      # A crashed agent's turn: the ring closes too, and later events are ignored.
      next = %{
        run
        | id: "turn-00000000000000a2",
          artifacts: Path.join(Path.dirname(run.artifacts), "turn-00000000000000a2"),
          server: Lifecycle.identity(config(), "alpha", "turn-00000000000000a2")
      }

      File.mkdir_p!(next.artifacts)

      crashing =
        start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :crashing_agent))

      ref = Process.monitor(crashing)
      state = put_in(state.workers["alpha"], %{agent: crashing, monitor: ref, run: next})

      {:noreply, state} =
        Service.handle_info(
          {:agent, crashing, {:output, %{"kind" => "text", "text" => "partial"}}},
          state
        )

      {:noreply, state} = Service.handle_info({:DOWN, ref, :process, crashing, :killed}, state)

      {:noreply, _} =
        Service.handle_info(
          {:agent, crashing, {:output, %{"kind" => "text", "text" => "late"}}},
          state
        )

      assert {:ok, %{"stream" => %{"ended" => true}} = read} =
               Output.read(execution(next.server), nil)

      assert events(read) == [%{"kind" => "text", "text" => "partial"}]
    end

    test "a late report changes a saved turn only for its exact attempt", %{
      state: state,
      run: run
    } do
      state = %{state | workers: %{}}
      ended = %{"turn" => "ended", "execution" => "registered", "error" => nil}

      {:noreply, ^state} =
        Service.handle_info({:server_report, run.id, "other-attempt", ended}, state)

      assert saved(run)["server"]["report"]["turn"] == "unconfirmed"

      {:noreply, ^state} =
        Service.handle_info({:server_report, run.id, run.server["attempt"], ended}, state)

      assert saved(run)["server"]["report"] == ended
      assert saved(run)["id"] == run.id
    end
  end

  test "the reporter renews activity and lease at most once per interval", %{dir: dir} do
    store = start_supervised!({Store, agents: ["alpha"], dir: dir})
    id = "turn-00000000000000b2"
    server = Lifecycle.identity(config(), "alpha", id)
    File.mkdir_p!(Path.join([dir, "turns", id]))

    File.write!(
      Path.join([dir, "turns", id, "turn.json"]),
      JSON.encode!(%{id: id, server: server})
    )

    run = %{id: id, state: "running", backend: "codex", requested_model: "gpt-x", server: server}

    {:ok, reporter} =
      Lifecycle.start(config(), Keyword.merge(@talk, lease: 200, silence: 600_000))

    on_exit(fn -> Process.exit(reporter, :kill) end)
    Lifecycle.started(reporter, run)

    assert_receive {:server_report, ^id, _, %{"turn" => "running", "execution" => "registered"}},
                   2_000

    Lifecycle.activity(reporter, run, "one")
    Lifecycle.activity(reporter, run, "two")
    Lifecycle.flush(reporter, 1_000)
    Process.sleep(300)
    Lifecycle.ended(reporter, %{run | state: "failed"} |> Map.put(:error, ":crashed"))
    assert_receive {:server_report, ^id, _, %{"turn" => "ended", "error" => nil}}, 2_000

    facts = Store.facts(store)
    key = server["turn"]
    changes = for {"turn", _, %{"op" => "change"} = c} <- facts.sent, do: c["values"]

    assert [
             %{"activity" => "two", "lease_until" => _},
             %{"state" => "ended", "why" => "failed: :crashed"}
           ] = changes

    assert facts.executions[{key, server["attempt"]}]["configured_model"] == "gpt-x"
  end
end
