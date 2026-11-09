defmodule AtlasRuntime.ServiceTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, QuestionRecords, Service}
  alias AtlasRuntime.Workspaces

  @moduletag :tmp_dir

  defmodule OwnedProcess do
    use GenServer
    def init(reply), do: {:ok, reply}

    def handle_call(:stop, _from, {:delay, milliseconds, reply} = state) do
      Process.sleep(milliseconds)
      {:reply, reply, state}
    end

    def handle_call(:stop, _from, reply), do: {:reply, reply, reply}
    # Native.control/2: the reply is only the write; the test confirms the end separately.
    def handle_call({:control, mode, :async}, {caller, _}, reply) do
      send(caller, {:control_write, self(), mode})
      {:reply, if(match?({:error, _}, reply), do: reply, else: :ok), reply}
    end

    def handle_call({:answer, question_id, answers}, {caller, _}, reply) do
      send(caller, {:answer_write, question_id, answers})

      result =
        case reply do
          {:inspect_admission, path, result} ->
            send(caller, {:admission_before_write, JSON.decode!(File.read!(path))})
            result

          _ ->
            :delivered
        end

      evidence =
        if result == :delivered,
          do: {:ok, %{question_id: question_id, status: "delivered"}},
          else: {:error, :response_lost}

      {:reply, evidence, reply}
    end
  end

  setup %{tmp_dir: dir} do
    %{
      state: %{
        dir: dir,
        policy: BackendPolicy.empty(),
        events: ExecutionEvents.open(dir),
        workers: %{},
        stopping: false
      }
    }
  end

  defp call(state, request) do
    {:reply, {reply, shutdown?}, next} = Service.handle_call(request, {self(), make_ref()}, state)
    {reply, next, shutdown?}
  end

  defp error(state, request, text) do
    assert {%{command_error: message}, ^state, false} = call(state, request)
    assert message =~ text
  end

  defp worker(state, name, number, opts \\ []) do
    id = "turn-" <> String.pad_leading(Integer.to_string(number, 16), 16, "0")
    folder = Path.join([state.dir, "turns", id])
    File.mkdir_p!(folder)

    run = %{
      id: id,
      worker_id: name,
      state: Keyword.get(opts, :state, "running"),
      backend: Keyword.get(opts, :backend, "codex"),
      model: nil,
      session_id: nil,
      questions_enabled: Keyword.get(opts, :questions_enabled, false),
      pending_question: nil,
      last_answer: nil,
      started_at: "2026-11-07T10:00:00Z",
      artifacts: folder,
      cwd: Keyword.get(opts, :cwd, state.dir),
      sandbox: "read-only"
    }

    File.write!(Path.join(folder, "turn.json"), JSON.encode!(run))

    {pid, ref} =
      if run.state == "running" do
        {:ok, pid} = GenServer.start(OwnedProcess, Keyword.get(opts, :stop_reply, :ok))
        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        {pid, Process.monitor(pid)}
      else
        {nil, nil}
      end

    entry = %{agent: pid, monitor: ref, run: run}
    %{state | workers: Map.put(state.workers, name, entry)}
  end

  defp events(state), do: ExecutionEvents.query(state.events, nil, 100)["events"]

  defp stop(state, name, command \\ "stop"),
    do:
      call(state, %{
        "command" => command,
        "worker_id" => name,
        "turn_id" => state.workers[name].run.id
      })

  # The host's confirmed end: the group is gone and the lock released.
  defp confirm(state, name, control, native_result \\ false) do
    agent = state.workers[name].agent

    {:noreply, next} =
      Service.handle_info(
        {:agent, agent,
         {:terminated,
          %{
            "control" => control,
            "exit_code" => 0,
            "native_result" => native_result,
            "result" => if(native_result, do: "done")
          }}},
        state
      )

    next
  end

  defp question do
    %{
      id: "question-ab12",
      questions: [%{"question" => "Choose?"}],
      correlation: %{
        "session_id" => "00000000-0000-4000-8000-000000000001",
        "model" => "claude-sonnet-4-6",
        "tool_use_id" => "tool-use-1",
        "request_id" => "request-1",
        "native_pid" => 12345
      }
    }
  end

  defp saved(state, number, values) do
    id =
      "turn-" <> String.pad_leading(Integer.to_string(number, 16) |> String.downcase(), 16, "0")

    folder = Path.join([state.dir, "turns", id])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "turn.json"), JSON.encode!(values))
    id
  end

  test "interaction commands own admission and delivery without the service coordinator", %{
    state: state
  } do
    alias AtlasRuntime.Interactions.Commands
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    worker = state.workers["alpha"]

    {run, journal} =
      Commands.observe({:question, question()}, worker.run, "alpha", state.dir, state.events)

    workers = Map.put(state.workers, "alpha", %{worker | run: run})

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => run.id,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    {evidence, journal, workers} = Commands.execute(request, state.dir, journal, workers)
    assert evidence.admission == "accepted"
    assert evidence.transport == "delivered"
    assert workers["alpha"].run.pending_question == nil
    assert_received {:answer_write, "question-ab12", %{"Choose?" => "yes"}}

    assert {^evidence, ^journal, ^workers} =
             Commands.execute(request, state.dir, journal, workers)

    refute_received {:answer_write, _, _}
  end

  test "history owns current and saved projections without the service coordinator", %{
    state: state
  } do
    alias AtlasRuntime.Persistence.History
    state = worker(state, "alpha", 1)
    id = state.workers["alpha"].run.id
    assert History.historical(id, state.dir, state.workers)["state"] == "running"
    saved = History.historical(id, state.dir, %{})
    assert saved["state"] == "unknown"
    assert saved["recorded_state"] == "running"
    assert %{turns: [^saved]} = History.list(state.dir, %{})
    assert History.owned_saved_turn!(state.dir, id, "alpha")["state"] == "running"

    assert_raise RuntimeError, "Turn belongs to worker alpha, not beta", fn ->
      History.owned_saved_turn!(state.dir, id, "beta")
    end
  end

  test "empty and sole-worker defaults never choose by activity", %{state: state} do
    assert {%{worker_id: "default", state: "idle"}, ^state, false} =
             call(state, %{"command" => "status"})

    error(state, %{"command" => "stop"}, "Stop requires exactly --worker and --turn")
    error(state, %{"command" => "kill", "worker_id" => "default"}, "Unknown worker")

    sole = worker(state, "alpha", 1, state: "finished")

    assert {%{worker_id: "alpha", state: "finished"}, ^sole, false} =
             call(sole, %{"command" => "status"})

    multiple = worker(sole, "beta", 2)

    for command <- ["start", "status", "output", "stop", "continue"] do
      error(multiple, %{"command" => command}, "Multiple workers")
    end

    assert {%{worker_id: "alpha", state: "finished"}, ^multiple, false} =
             call(multiple, %{"command" => "status", "worker_id" => "alpha"})

    assert {%{workers: workers}, ^multiple, false} =
             call(multiple, %{"command" => "service-status"})

    assert Map.keys(workers) |> Enum.sort() == ["alpha", "beta"]
    assert workers["beta"].state == "running"
    assert events(multiple) == []
  end

  test "invalid and unknown workers never fall through to another worker", %{state: state} do
    state = worker(state, "alpha", 1)

    for id <- [
          nil,
          "",
          "Upper",
          "../alpha",
          "a/b",
          "a\n",
          1,
          true,
          %{},
          String.duplicate("a", 65)
        ],
        command <- ["start", "status", "output", "stop", "continue"] do
      error(state, %{"command" => command, "worker_id" => id}, "Invalid worker ID")
    end

    for command <- ["status", "output", "stop", "continue"] do
      error(state, %{"command" => command, "worker_id" => "missing"}, "Unknown worker")
    end

    for command <- ["events", "turns", "preferences", "service-status", "service-stop"] do
      error(state, %{"command" => command, "worker_id" => "alpha"}, "does not accept a worker")
    end
  end

  test "duplicate active worker rejects start and continue without touching another worker", %{
    state: state
  } do
    state = state |> worker("alpha", 1) |> worker("beta", 2, state: "finished")

    error(
      state,
      %{
        "command" => "start",
        "worker_id" => "alpha",
        "cwd" => state.dir,
        "assignment" => "assignment"
      },
      "already has an active agent"
    )

    error(
      state,
      %{"command" => "continue", "worker_id" => "alpha", "assignment" => "next"},
      "already has an active agent"
    )

    error(
      state,
      %{
        "command" => "start",
        "worker_id" => "alpha",
        "repository" => "https://github.com/owner/repo",
        "branch" => "task",
        "permissions" => "dedicated-repository",
        "assignment" => "next"
      },
      "already has an active agent"
    )
  end

  test "live historical reads search every worker and enforce saved ownership first", %{
    state: state
  } do
    state = state |> worker("alpha", 1, state: "finished") |> worker("beta", 2)
    id = state.workers["beta"].run.id

    assert {%{"state" => "running", "worker_id" => "beta"}, ^state, false} =
             call(state, %{"command" => "output", "turn_id" => id})

    for command <- ["output", "continue"] do
      error(
        state,
        %{"command" => command, "turn_id" => id, "worker_id" => "alpha", "assignment" => "next"},
        "Turn belongs to worker beta, not alpha"
      )
    end

    error(
      state,
      %{"command" => "continue", "turn_id" => id, "assignment" => "next"},
      "already has an active agent"
    )

    assert {%{turns: turns}, ^state, false} = call(state, %{"command" => "turns"})
    assert Enum.find(turns, &(&1["id"] == id))["state"] == "running"
    assert Enum.map(turns, & &1["worker_id"]) |> Enum.sort() == ["alpha", "beta"]
  end

  test "legacy saved turns belong to default and restart does not resume", %{state: state} do
    id =
      saved(state, 1, %{
        "state" => "running",
        "session_id" => "old-session",
        "pending_question" => %{
          "id" => "question-ab12",
          "questions" => [%{"question" => "Choose?"}]
        }
      })

    assert {%{
              "state" => "unknown",
              "recorded_state" => "running",
              "worker_id" => "default",
              "pending_question" => nil,
              "questions_enabled" => false
            }, ^state,
            false} =
             call(state, %{"command" => "output", "turn_id" => id})

    for command <- ["output", "continue"] do
      error(
        state,
        %{"command" => command, "turn_id" => id, "worker_id" => "other", "assignment" => "next"},
        "Turn belongs to worker default, not other"
      )
    end

    error(
      state,
      %{"command" => "continue", "turn_id" => id, "assignment" => "next"},
      "finished, stopped or killed turn"
    )

    assert state.workers == %{}
    assert events(state) == []

    invalid = saved(state, 2, %{"state" => "finished", "worker_id" => "../bad"})
    error(state, %{"command" => "output", "turn_id" => invalid}, "Invalid saved worker ID")
  end

  test "without server.json a turn carries no Server identity and nothing reports", %{
    state: state
  } do
    state = worker(state, "alpha", 1)
    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:activity, "active"}}, state)
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:ended, "done"}}, state)
    {:noreply, state} = Service.handle_info({:server_report, alpha.run.id, "attempt", %{}}, state)
    refute Map.has_key?(state, :server)
    refute Map.has_key?(state.workers["alpha"].run, :server)

    refute Map.has_key?(
             JSON.decode!(File.read!(Path.join(alpha.run.artifacts, "turn.json"))),
             "server"
           )

    refute_received {:"$gen_cast", _}
  end

  test "owned pid and exact monitor route identity, activity, completion and failure", %{
    state: state
  } do
    state = state |> worker("alpha", 1) |> worker("beta", 2, backend: "claude")
    alpha = state.workers["alpha"]
    beta = state.workers["beta"]
    assert {:noreply, ^state} = Service.handle_info({:agent, self(), {:ended, "foreign"}}, state)

    assert {:noreply, ^state} =
             Service.handle_info({:agent, alpha.agent, {:identity, "claude", "wrong"}}, state)

    assert {:noreply, ^state} =
             Service.handle_info({:DOWN, alpha.monitor, :process, beta.agent, :wrong}, state)

    assert {:noreply, ^state} =
             Service.handle_info({:DOWN, make_ref(), :process, alpha.agent, :wrong}, state)

    {:noreply, state} =
      Service.handle_info({:agent, alpha.agent, {:identity, "codex", "alpha-model"}}, state)

    {:noreply, state} =
      Service.handle_info({:agent, beta.agent, {:session, "beta-session"}}, state)

    {:noreply, state} =
      Service.handle_info({:agent, alpha.agent, {:activity, "alpha-active"}}, state)

    {:noreply, state} =
      Service.handle_info({:agent, beta.agent, {:repository, %{"branch" => "beta"}}}, state)

    assert state.workers["alpha"].run.model == "alpha-model"
    assert state.workers["alpha"].run.session_id == nil
    assert state.workers["alpha"].run.activity == "alpha-active"
    assert state.workers["beta"].run.session_id == "beta-session"
    refute Map.has_key?(state.workers["beta"].run, :activity)
    refute Map.has_key?(state.workers["alpha"].run, :repository)
    assert events(state) == []

    {:noreply, state} =
      Service.handle_info({:agent, alpha.agent, {:ended, "alpha-result"}}, state)

    assert state.workers["alpha"].agent == nil
    assert state.workers["alpha"].run.state == "finished"
    assert state.workers["beta"].agent == beta.agent
    assert state.workers["beta"].run.state == "running"

    assert {:noreply, ^state} =
             Service.handle_info({:agent, alpha.agent, {:session, "stale"}}, state)

    assert {:noreply, ^state} =
             Service.handle_info({:agent, alpha.agent, {:ended, "duplicate"}}, state)

    assert {:noreply, ^state} =
             Service.handle_info({:DOWN, alpha.monitor, :process, alpha.agent, :normal}, state)

    {:noreply, state} =
      Service.handle_info({:DOWN, beta.monitor, :process, beta.agent, :crashed}, state)

    assert state.workers["beta"].run.state == "failed"
    assert state.workers["beta"].run.error == ":crashed"

    assert Enum.map(events(state), &{&1["sequence"], &1["worker_id"], &1["kind"]}) ==
             [{1, "alpha", "execution_finished"}, {2, "beta", "execution_failed"}]

    assert JSON.decode!(File.read!(Path.join(alpha.run.artifacts, "turn.json")))["model"] ==
             "alpha-model"

    assert JSON.decode!(File.read!(Path.join(beta.run.artifacts, "turn.json")))["session_id"] ==
             "beta-session"
  end

  test "quota is global while its evidence belongs only to the emitting worker", %{state: state} do
    state = state |> worker("alpha", 1) |> worker("beta", 2, backend: "claude")

    evidence =
      Path.join(__DIR__, "fixtures/claude_weekly_quota.json") |> File.read!() |> JSON.decode!()

    message = {:quota, evidence["rate_limit_info"]}

    assert {:noreply, ^state} =
             Service.handle_info({:agent, state.workers["alpha"].agent, message}, state)

    {:noreply, next} = Service.handle_info({:agent, state.workers["beta"].agent, message}, state)
    assert next.policy["claude_quota"]["turn_id"] == state.workers["beta"].run.id
    assert next.workers["beta"].run.quota == next.policy["claude_quota"]
    assert next.workers["alpha"] == state.workers["alpha"]
    assert JSON.decode!(File.read!(Path.join(state.dir, "backends.json"))) == next.policy
    assert events(next) == []
  end

  test "targeted stop changes one worker and service-stop stops all without duplicate events", %{
    state: state
  } do
    state = state |> worker("alpha", 1) |> worker("beta", 2)
    beta = state.workers["beta"]
    alpha = state.workers["alpha"].agent

    assert {%{worker_id: "alpha", state: "stopping", termination: %{"mode" => "stop"}}, state,
            false} =
             stop(state, "alpha")

    assert_received {:control_write, ^alpha, :stop}
    assert state.workers["beta"] == beta
    assert state.workers["alpha"].agent == alpha
    # The latch is durable and the turn is persisted as stopping, without a transition event.
    assert %{"turn_id" => "turn-0000000000000001"} =
             JSON.decode!(
               File.read!(Path.join([state.dir, "workers", "alpha", "admission-latch.json"]))
             )

    assert JSON.decode!(File.read!(Path.join(state.workers["alpha"].run.artifacts, "turn.json")))[
             "state"
           ] == "stopping"

    assert events(state) == []
    requested = state.workers["alpha"].run.termination["stop_requested_at"]

    assert {%{state: "stopping", termination: %{"stop_requested_at" => ^requested}}, state, false} =
             stop(state, "alpha")

    state = confirm(state, "alpha", "stop")

    assert %{state: "stopped", termination: %{"confirmed_at" => confirmed}} =
             state.workers["alpha"].run

    assert is_binary(confirmed)
    assert {%{state: "stopped"}, ^state, false} = stop(state, "alpha")
    assert {%{state: "stopped"}, ^state, false} = stop(state, "alpha", "kill")

    assert {%{
              command_error: "Service stop pending: still owned executions: beta (stopping)" <> _
            }, state,
            false} =
             call(state, %{"command" => "service-stop"})

    assert state.stopping
    state = confirm(state, "beta", "stop")

    assert {%{service: "stopping", workers: workers}, state, true} =
             call(state, %{"command" => "service-stop"})

    assert workers["alpha"].state == "stopped"
    assert workers["beta"].state == "stopped"

    assert Enum.map(events(state), &{&1["worker_id"], &1["kind"]}) ==
             [{"alpha", "execution_stopped"}, {"beta", "execution_stopped"}]

    assert Enum.all?(state.workers, fn {_, worker} ->
             worker.agent == nil and worker.monitor == nil
           end)
  end

  test "kill wins over stop, stays responsive while stopping and ends killed", %{state: state} do
    state = worker(state, "alpha", 1)
    agent = state.workers["alpha"].agent
    {_, state, false} = stop(state, "alpha")

    assert {%{
              state: "killing",
              termination: %{
                "mode" => "kill",
                "stop_requested_at" => stopped,
                "kill_requested_at" => killed
              }
            }, state, false} = stop(state, "alpha", "kill")

    assert is_binary(stopped) and is_binary(killed)
    assert_received {:control_write, ^agent, :stop}
    assert_received {:control_write, ^agent, :kill}
    # A later stop cannot downgrade the kill and sends nothing.
    assert {%{state: "killing", termination: %{"mode" => "kill"}}, ^state, false} =
             stop(state, "alpha")

    refute_received {:control_write, _, _}

    {:noreply, state} =
      Service.handle_info(
        {:agent, agent, {:signal, %{"control" => "kill", "signal" => "SIGKILL", "error" => nil}}},
        state
      )

    assert is_binary(state.workers["alpha"].run.termination["kill_signalled_at"])
    state = confirm(state, "alpha", "kill")
    assert state.workers["alpha"].run.state == "killed"
    assert [%{"kind" => "execution_killed", "worker_id" => "alpha"}] = events(state)
    saved = JSON.decode!(File.read!(Path.join(state.workers["alpha"].run.artifacts, "turn.json")))
    assert saved["state"] == "killed"
    assert saved["termination"]["mode"] == "kill"
    assert is_binary(saved["termination"]["confirmed_at"])
  end

  test "stop and kill require the exact current turn and refuse stale targets", %{state: state} do
    old =
      saved(state, 9, %{
        "worker_id" => "alpha",
        "state" => "finished",
        "session_id" => "s",
        "cwd" => state.dir,
        "sandbox" => "read-only"
      })

    killed = saved(state, 10, %{"worker_id" => "alpha", "state" => "killed"})
    state = worker(state, "alpha", 1)

    for command <- ["stop", "kill"] do
      error(
        state,
        %{"command" => command, "worker_id" => "alpha"},
        "requires exactly --worker and --turn"
      )

      error(
        state,
        %{"command" => command, "turn_id" => old},
        "requires exactly --worker and --turn"
      )

      error(
        state,
        %{"command" => command, "worker_id" => "alpha", "turn_id" => old},
        "has no execution owned by this Runtime service to #{command} (finished)"
      )

      error(
        state,
        %{
          "command" => command,
          "worker_id" => "beta",
          "turn_id" => state.workers["alpha"].run.id
        },
        "Turn belongs to worker alpha, not beta"
      )

      error(
        state,
        %{"command" => command, "worker_id" => "alpha", "turn_id" => "turn-ffffffffffffffff"},
        "Unknown turn"
      )

      assert {%{"state" => "killed"}, ^state, false} =
               call(state, %{"command" => command, "worker_id" => "alpha", "turn_id" => killed})
    end

    refute_received {:control_write, _, _}
    refute File.exists?(Path.join([state.dir, "workers", "alpha", "admission-latch.json"]))

    # After restart nothing is owned: a turn recorded as stopping is unknown and cannot be signalled.
    {_, stopping, false} = stop(state, "alpha")
    restarted = %{stopping | workers: %{}}
    id = stopping.workers["alpha"].run.id

    assert {%{"state" => "unknown", "recorded_state" => "stopping"}, ^restarted, false} =
             call(restarted, %{"command" => "output", "turn_id" => id})

    error(
      restarted,
      %{"command" => "kill", "worker_id" => "alpha", "turn_id" => id},
      "has no execution owned by this Runtime service to kill (unknown)"
    )
  end

  test "the latch persists before signalling, survives restart and only release clears it", %{
    state: state
  } do
    state = worker(state, "alpha", 1)
    blocker = Path.join([state.dir, "workers", "alpha", "admission-latch.json.tmp"])
    File.mkdir_p!(blocker)

    error(
      state,
      %{"command" => "stop", "worker_id" => "alpha", "turn_id" => state.workers["alpha"].run.id},
      ""
    )

    refute_received {:control_write, _, _}
    File.rmdir!(blocker)
    {_, state, false} = stop(state, "alpha")

    error(
      state,
      %{"command" => "release", "worker_id" => "alpha"},
      "still owns turn turn-0000000000000001 (stopping)"
    )

    state = confirm(state, "alpha", "stop")
    id = state.workers["alpha"].run.id

    start = %{
      "command" => "start",
      "worker_id" => "alpha",
      "cwd" => state.dir,
      "assignment" => "next"
    }

    continue = %{
      "command" => "continue",
      "worker_id" => "alpha",
      "turn_id" => id,
      "assignment" => "next"
    }

    for request <- [start, continue, Map.put(start, "request_id", "after-stop")] do
      error(
        state,
        request,
        "Worker alpha is latched after stopping turn #{id}; run atlas-runtime release --worker alpha first"
      )
    end

    refute File.exists?(Path.join(state.dir, "admissions/after-stop.json"))
    restarted = %{state | workers: %{}}

    assert {%{admission_latch: %{"turn_id" => ^id}}, ^restarted, false} =
             call(restarted, %{"command" => "status", "worker_id" => "alpha"})

    error(restarted, %{"command" => "status", "worker_id" => "missing"}, "Unknown worker")
    error(restarted, start, "is latched after stopping turn")

    for request <- [
          %{"command" => "release"},
          %{"command" => "release", "worker_id" => "alpha", "turn_id" => id}
        ] do
      error(restarted, request, "Release requires exactly --worker")
    end

    turns = File.ls!(Path.join(state.dir, "turns"))

    assert {%{worker_id: "alpha", released: %{"turn_id" => ^id}, admission_latch: nil},
            ^restarted,
            false} =
             call(restarted, %{"command" => "release", "worker_id" => "alpha"})

    # Release launched nothing; a repeat is idempotent.
    assert restarted.workers == %{}
    assert File.ls!(Path.join(state.dir, "turns")) == turns

    assert {%{released: nil}, ^restarted, false} =
             call(restarted, %{"command" => "release", "worker_id" => "alpha"})

    # Without registration or latch the worker is unknown again after restart.
    error(restarted, %{"command" => "status", "worker_id" => "alpha"}, "Unknown worker")
    File.write!(Path.join([state.dir, "workers", "alpha", "admission-latch.json"]), "not JSON")
    error(restarted, start, "Invalid admission latch")
    error(restarted, %{"command" => "release", "worker_id" => "alpha"}, "Invalid admission latch")
  end

  test "signalling errors stay recorded and the execution stays owned", %{state: state} do
    state = worker(state, "alpha", 1, stop_reply: {:error, :refused})

    assert {%{state: "stopping", termination: %{"error" => "stop not delivered: :refused"}},
            state,
            false} =
             stop(state, "alpha")

    agent = state.workers["alpha"].agent
    assert state.workers["alpha"].agent

    {:noreply, state} =
      Service.handle_info(
        {:agent, agent,
         {:signal,
          %{"control" => "stop", "signal" => "SIGINT", "error" => "operation not permitted"}}},
        state
      )

    assert state.workers["alpha"].run.termination["error"] ==
             "SIGINT refused: operation not permitted"

    assert JSON.decode!(File.read!(Path.join(state.workers["alpha"].run.artifacts, "turn.json")))[
             "termination"
           ]["error"] ==
             "SIGINT refused: operation not permitted"

    # Host failure while stopping is a failed turn with its termination error, never stopped.
    {:noreply, state} =
      Service.handle_info(
        {:DOWN, state.workers["alpha"].monitor, :process, agent, :native_failed},
        state
      )

    assert %{state: "failed", termination: %{"error" => ":native_failed"}} =
             state.workers["alpha"].run

    assert [%{"kind" => "execution_failed"}] = events(state)
  end

  test "natural completion races keep the honest outcome", %{state: state} do
    # Completion reached the service first: the stop finds a finished turn and changes nothing.
    state = worker(state, "alpha", 1)
    alpha = state.workers["alpha"]
    {:noreply, finished} = Service.handle_info({:agent, alpha.agent, {:ended, "done"}}, state)

    error(
      finished,
      %{"command" => "stop", "worker_id" => "alpha", "turn_id" => alpha.run.id},
      "(finished)"
    )

    refute File.exists?(Path.join([state.dir, "workers", "alpha", "admission-latch.json"]))

    # Completion already sent while the stop was written: the turn still finishes, request recorded.
    {_, stopping, false} = stop(state, "alpha")
    {:noreply, ended} = Service.handle_info({:agent, alpha.agent, {:ended, "done"}}, stopping)

    assert %{state: "finished", result: "done", termination: %{"mode" => "stop"}} =
             ended.workers["alpha"].run

    # The host ended the execution before it applied the control.
    natural = confirm(stopping, "alpha", nil, true)

    assert %{
             state: "finished",
             result: "done",
             termination: %{"confirmed_at" => _, "native_result" => true}
           } =
             natural.workers["alpha"].run

    failed = confirm(stopping, "alpha", nil)

    assert %{state: "failed", error: "Native execution ended before the stop was applied"} =
             failed.workers["alpha"].run
  end

  test "a service stop waiting for owned executions keeps inspection and kill available", %{
    state: state
  } do
    state = state |> worker("alpha", 1) |> worker("beta", 2, state: "finished")
    {%{command_error: message}, state, false} = call(state, %{"command" => "service-stop"})
    assert message =~ "alpha (stopping)"
    assert state.stopping

    assert {%{service: "stopping", workers: %{"alpha" => %{state: "stopping"}}}, ^state, false} =
             call(state, %{"command" => "service-status"})

    assert {%{state: "stopping"}, ^state, false} =
             call(state, %{"command" => "status", "worker_id" => "alpha"})

    assert {%{"events" => []}, ^state, false} = call(state, %{"command" => "events"})

    for request <- [
          %{
            "command" => "start",
            "worker_id" => "gamma",
            "cwd" => state.dir,
            "assignment" => "next"
          },
          %{
            "command" => "start",
            "request_id" => "retry-1",
            "cwd" => state.dir,
            "assignment" => "next"
          },
          %{"command" => "continue", "worker_id" => "beta", "assignment" => "next"},
          %{"command" => "release", "worker_id" => "alpha"},
          %{"command" => "service-stop", "worker_id" => "alpha"}
        ] do
      error(state, request, "Runtime service is stopping")
    end

    assert {%{command_error: "Service stop pending" <> _}, ^state, false} =
             call(state, %{"command" => "service-stop"})

    {%{state: "killing"}, state, false} = stop(state, "alpha", "kill")
    assert_received {:control_write, _, :kill}
    state = confirm(state, "alpha", "kill")

    assert {%{service: "stopping", workers: %{"alpha" => %{state: "killed"}}}, _, true} =
             call(state, %{"command" => "service-stop"})

    assert Enum.map(events(state), &{&1["worker_id"], &1["kind"]}) == [
             {"alpha", "execution_killed"}
           ]
  end

  test "workspace preflight blocks identical, nested, parent and symlink aliases in every sandbox",
       %{state: state} do
    root = Path.join(state.dir, "workspace")
    nested = Path.join(root, "nested")
    File.mkdir_p!(nested)
    alias_path = Path.join(state.dir, "alias")
    File.ln_s!(root, alias_path)
    state = worker(state, "alpha", 1, cwd: Workspaces.workspace_path(root))

    for cwd <- [root, nested, state.dir, alias_path, Path.join(alias_path, "nested")],
        sandbox <- ["read-only", "workspace-write"] do
      error(
        state,
        %{
          "command" => "start",
          "worker_id" => "beta",
          "cwd" => cwd,
          "sandbox" => sandbox,
          "assignment" => "next"
        },
        "Workspace overlaps active worker alpha"
      )
    end

    old =
      saved(state, 2, %{
        "worker_id" => "beta",
        "state" => "finished",
        "session_id" => "saved-session",
        "cwd" => Workspaces.workspace_path(nested),
        "sandbox" => "read-only"
      })

    error(
      state,
      %{"command" => "continue", "turn_id" => old, "assignment" => "next"},
      "Workspace overlaps active worker alpha"
    )

    assert events(state) == []
  end

  test "saved continuation keeps backend, session and permission validation", %{state: state} do
    base = %{
      "worker_id" => "beta",
      "state" => "finished",
      "backend" => "codex",
      "session_id" => "saved-session",
      "cwd" => state.dir,
      "sandbox" => "read-only"
    }

    invalid = [
      {%{"backend" => "other"}, "Unknown saved backend"},
      {%{"state" => "failed"}, "finished, stopped or killed turn"},
      {%{"state" => "stopping"}, "finished, stopped or killed turn"},
      {%{"session_id" => nil}, "no confirmed native session"},
      {%{"cwd" => "relative"}, "no valid saved working directory"},
      {%{"sandbox" => "unrestricted"}, "no valid saved working directory"},
      {%{"backend" => "claude"}, "no confirmed model"},
      {%{"backend" => "claude", "model" => "claude-sonnet-4-6"}, "no such file or directory"}
    ]

    for {{changes, message}, number} <- Enum.with_index(invalid, 1) do
      id = saved(state, number, Map.merge(base, changes))
      error(state, %{"command" => "continue", "turn_id" => id, "assignment" => "next"}, message)
    end

    id = saved(state, 20, base)

    for field <- ["backend", "cwd", "sandbox", "permissions", "questions_enabled"] do
      error(
        state,
        %{"command" => "continue", "turn_id" => id, "assignment" => "next", field => "changed"},
        "working directory and permissions cannot change"
      )
    end

    active = worker(state, "beta", 21)

    error(
      active,
      %{"command" => "continue", "turn_id" => id, "assignment" => "next"},
      "already has an active agent"
    )

    assert events(state) == []
  end

  test "question capability is opt-in, boolean and never changes backend selection", %{
    state: state
  } do
    request = %{"command" => "start", "cwd" => state.dir, "assignment" => "Read"}
    error(state, Map.put(request, "questions_enabled", true), "only by Claude")

    for value <- [nil, "true", 1, %{}] do
      error(state, Map.put(request, "questions_enabled", value), "must be a boolean")
    end

    for request <- [request, Map.put(request, "questions_enabled", false)] do
      occupied = worker(state, "alpha", 1)
      error(occupied, Map.put(request, "worker_id", "beta"), "Workspace overlaps")
    end

    id =
      saved(state, 20, %{"state" => "finished", "backend" => "codex", "questions_enabled" => true})

    error(
      state,
      %{"command" => "continue", "turn_id" => id, "assignment" => "Read"},
      "only by Claude"
    )

    legacy = saved(state, 21, %{"state" => "finished"})

    assert {%{"questions_enabled" => false, "pending_question" => nil}, _, false} =
             call(state, %{"command" => "output", "turn_id" => legacy})
  end

  test "answer requires every exact selector and bounded exact question keys before writing", %{
    state: state
  } do
    state =
      state |> worker("alpha", 1, backend: "claude", questions_enabled: true) |> worker("beta", 2)

    alpha = state.workers["alpha"]
    question = question()
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => question.id,
      "answers" => %{"Choose?" => "custom"}
    }

    for key <- ["worker_id", "turn_id", "question_id", "answers"] do
      error(state, Map.delete(request, key), "requires exactly")
    end

    for key <- ["permissions", "updatedPermissions", "questions_enabled", "backend"] do
      error(state, Map.put(request, key, true), "requires exactly")
    end

    error(state, %{request | "worker_id" => "missing"}, "belongs to worker")
    error(state, %{request | "worker_id" => "beta"}, "belongs to worker")
    error(state, %{request | "turn_id" => "turn-ffffffffffffffff"}, "record unavailable")
    error(state, %{request | "question_id" => "question-dead"}, "record unavailable")

    for value <- [nil, "", 1, true, %{}] do
      error(state, %{request | "worker_id" => value}, "Invalid worker ID")
      error(state, %{request | "turn_id" => value}, "Invalid turn ID")
      error(state, %{request | "question_id" => value}, "Invalid question ID")
    end

    for answers <- [
          nil,
          [],
          %{},
          %{"Other?" => "x"},
          %{"Choose?" => nil},
          %{"Choose?" => " "},
          %{"Choose?" => 1},
          %{"Choose?" => String.duplicate("x", 4097)},
          %{"Choose?" => "yes", "updatedPermissions" => "allow"}
        ] do
      error(state, %{request | "answers" => answers}, "Invalid answers")
    end

    refute_received {:answer_write, _, _}

    assert {%{
              worker_id: "alpha",
              turn_id: turn_id,
              question_id: "question-ab12",
              status: "delivered"
            }, state,
            false} =
             call(state, request)

    assert turn_id == alpha.run.id
    assert_received {:answer_write, "question-ab12", %{"Choose?" => "custom"}}
    assert state.workers["alpha"].run.pending_question == nil
    assert state.workers["alpha"].run.last_answer.status == "delivered"
    assert {duplicate, ^state, false} = call(state, request)
    assert duplicate == state.workers["alpha"].run.last_answer
    refute_received {:answer_write, _, _}
    error(state, %{request | "answers" => %{"Choose?" => "different"}}, "Conflicting answer")

    {:noreply, state} =
      Service.handle_info(
        {:agent, alpha.agent, {:answer, %{question_id: question.id, status: "processed"}}},
        state
      )

    assert state.workers["alpha"].run.last_answer.status == "processed"

    assert {:noreply, ^state} =
             Service.handle_info(
               {:agent, alpha.agent, {:answer, %{question_id: question.id, status: "delivered"}}},
               state
             )

    assert Enum.map(events(state), & &1["kind"]) ==
             ["question_available", "answer_accepted", "answer_delivered", "answer_processed"]
  end

  test "pending questions clear on every terminal path and old pid cannot affect a successor", %{
    state: state
  } do
    for {terminal, number} <- Enum.with_index([:stop, :finish, :loss, :service_stop], 1) do
      current = worker(state, "alpha", number, backend: "claude", questions_enabled: true)
      alpha = current.workers["alpha"]
      question = question()

      {:noreply, current} =
        Service.handle_info({:agent, alpha.agent, {:question, question}}, current)

      current =
        case terminal do
          :stop ->
            {_, next, false} = stop(current, "alpha")
            confirm(next, "alpha", "stop")

          :service_stop ->
            {_, next, false} = call(current, %{"command" => "service-stop"})
            confirm(next, "alpha", "stop")

          :finish ->
            {:noreply, next} =
              Service.handle_info({:agent, alpha.agent, {:ended, "done"}}, current)

            next

          :loss ->
            {:noreply, next} =
              Service.handle_info({:DOWN, alpha.monitor, :process, alpha.agent, :lost}, current)

            next
        end

      assert current.workers["alpha"].run.pending_question == nil
      record = QuestionRecords.load(current.dir, alpha.run.id, question.id)
      assert record["active"] == false
      assert record["outcome"] == "invalidated"
      assert record["transport"] == "not_attempted"

      assert List.last(events(current))["kind"] in [
               "execution_stopped",
               "execution_finished",
               "execution_failed"
             ]

      late = %{
        "command" => "answer",
        "worker_id" => "alpha",
        "turn_id" => alpha.run.id,
        "question_id" => question.id,
        "answers" => %{"Choose?" => "x"}
      }

      assert {%{command_error: _}, ^current, false} = call(current, late)

      successor =
        worker(%{current | stopping: false}, "alpha", number + 10,
          backend: "claude",
          questions_enabled: true
        )

      for message <- [
            {:question, question},
            {:answer, %{question_id: question.id, status: "processed"}},
            {:ended, "stale"},
            {:session, "stale"}
          ] do
        assert {:noreply, ^successor} =
                 Service.handle_info({:agent, alpha.agent, message}, successor)
      end
    end
  end

  test "lost response records admission before one native send and reconnect never sends twice",
       %{state: state} do
    turn = "turn-0000000000000001"
    path = Path.join(state.dir, QuestionRecords.reference(turn, "question-ab12"))

    state =
      worker(state, "alpha", 1,
        backend: "claude",
        questions_enabled: true,
        stop_reply: {:inspect_admission, path, :lost}
      )

    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question()}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => turn,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    {first, state, false} = call(state, request)
    assert first.status == "accepted"
    assert first.admission == "accepted"
    assert first.transport == "unknown"
    assert first.processing == "unknown"
    assert_received {:answer_write, "question-ab12", %{"Choose?" => "yes"}}

    assert_received {:admission_before_write,
                     %{"admission" => "accepted", "answers" => %{"Choose?" => "yes"}}}

    assert {^first, ^state, false} = call(state, request)
    error(state, %{request | "answers" => %{"Choose?" => "no"}}, "Conflicting answer")
    refute_received {:answer_write, _, _}

    query = request |> Map.delete("answers") |> Map.put("command", "question")
    {record, state, false} = call(state, query)
    assert record["original_input"] == %{"questions" => question().questions}
    assert record["correlation"] == question().correlation
    assert record["answers"] == request["answers"]
    assert record["record_ref"] == first.record_ref
    assert record["transport"] == "unknown"
    error(state, Map.put(query, "worker_id", "other"), "belongs to worker")

    for key <- ["worker_id", "turn_id", "question_id"] do
      error(state, Map.delete(query, key), "requires exactly")
    end

    error(state, Map.put(query, "answers", %{}), "requires exactly")

    events = QuestionRecords.recover(state.dir, ExecutionEvents.open(state.dir))
    restarted = %{state | workers: %{}, events: events}
    {record, ^restarted, false} = call(restarted, query)
    assert record["active"] == false
    assert record["admission"] == "accepted"
    assert record["transport"] == "unknown"
    assert record["processing"] == "unknown"
    assert record["outcome"] == "unknown"
    {duplicate, ^restarted, false} = call(restarted, request)
    assert duplicate.admission == "accepted"
    assert duplicate.transport == "unknown"
    error(restarted, %{request | "answers" => %{"Choose?" => "no"}}, "Conflicting answer")
    refute_received {:answer_write, _, _}

    assert Enum.map(events(restarted), & &1["kind"]) ==
             ["question_available", "answer_accepted", "question_invalidated"]
  end

  test "late delivery and processing preserve a newer pending question", %{state: state} do
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    alpha = state.workers["alpha"]
    first = question()
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, first}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => first.id,
      "answers" => %{"Choose?" => "yes"}
    }

    {_, state, false} = call(state, request)
    second = %{first | id: "question-ab13"}
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, second}}, state)

    for status <- ["delivered", "processed"] do
      {:noreply, next} =
        Service.handle_info(
          {:agent, alpha.agent, {:answer, %{question_id: first.id, status: status}}},
          state
        )

      assert next.workers["alpha"].run.pending_question.id == second.id
    end
  end

  test "journal failure after admission fails closed before transport and restart flushes admission",
       %{state: state} do
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question()}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    blocker = Path.join(state.dir, "execution-events.json.tmp")
    File.mkdir!(blocker)
    assert_raise QuestionRecords.StorageError, fn -> call(state, request) end
    refute_received {:answer_write, _, _}
    record = QuestionRecords.load(state.dir, alpha.run.id, "question-ab12")
    assert record["admission"] == "accepted"
    assert record["transport"] == "unknown"
    assert record["published_revision"] == 1
    assert [%{"kind" => "answer_accepted", "revision" => 2}] = record["transitions"]
    File.rmdir!(blocker)
    store = QuestionRecords.recover(state.dir, ExecutionEvents.open(state.dir))
    restarted = %{state | workers: %{}, events: store}
    {duplicate, ^restarted, false} = call(restarted, request)
    assert duplicate.status == "accepted"
    assert duplicate.transport == "unknown"
    assert duplicate.processing == "unknown"
    refute_received {:answer_write, _, _}

    assert Enum.map(events(restarted), & &1["kind"]) ==
             ["question_available", "answer_accepted", "question_invalidated"]
  end

  test "record write failure cannot send and corrupt records cannot be treated as absent", %{
    state: state
  } do
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question()}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    path = Path.join(state.dir, QuestionRecords.reference(alpha.run.id, "question-ab12"))
    File.mkdir!(path <> ".tmp")
    assert_raise QuestionRecords.StorageError, fn -> call(state, request) end
    refute_received {:answer_write, _, _}

    assert QuestionRecords.load(state.dir, alpha.run.id, "question-ab12")["admission"] ==
             "pending"

    File.rmdir!(path <> ".tmp")
    File.write!(path, "not JSON")
    assert_raise QuestionRecords.StorageError, fn -> call(state, request) end
    query = request |> Map.delete("answers") |> Map.put("command", "question")
    assert_raise QuestionRecords.StorageError, fn -> call(state, query) end
    refute_received {:answer_write, _, _}
  end

  test "legacy question history is explicitly unavailable rather than reconstructed", %{
    state: state
  } do
    turn =
      saved(state, 1, %{
        "state" => "finished",
        "worker_id" => "alpha",
        "last_answer" => %{"question_id" => "question-ab12", "status" => "delivered"}
      })

    query = %{
      "command" => "question",
      "worker_id" => "alpha",
      "turn_id" => turn,
      "question_id" => "question-ab12"
    }

    error(state, query, "record unavailable")

    error(
      state,
      query |> Map.put("command", "answer") |> Map.put("answers", %{"Choose?" => "yes"}),
      "record unavailable"
    )

    refute_received {:answer_write, _, _}
  end

  test "stopping delivered work preserves evidence and historical duplicate admission", %{
    state: state
  } do
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question()}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    {delivered, state, false} = call(state, request)
    assert delivered.status == "delivered"
    assert_received {:answer_write, "question-ab12", %{"Choose?" => "yes"}}
    {_, state, false} = stop(state, "alpha")
    state = confirm(state, "alpha", "stop")
    stopped = state.workers["alpha"].run
    evidence = state.workers["alpha"].run.last_answer
    assert stopped == state.workers["alpha"].run
    assert stopped.last_answer == evidence
    assert evidence.admission == "accepted"
    assert evidence.transport == "delivered"
    assert evidence.processing == "unknown"
    assert evidence.outcome == "unknown"
    assert evidence.active == false
    assert {^evidence, ^state, false} = call(state, request)

    restarted = %{
      state
      | workers: %{},
        events: QuestionRecords.recover(state.dir, ExecutionEvents.open(state.dir))
    }

    assert {^evidence, ^restarted, false} = call(restarted, request)

    {historical, ^restarted, false} =
      call(
        restarted,
        %{"command" => "output", "worker_id" => "alpha", "turn_id" => alpha.run.id}
      )

    assert historical["last_answer"]["transport"] == "delivered"
    assert historical["last_answer"]["active"] == false
    assert historical["last_answer"]["processing"] == "unknown"
    refute_received {:answer_write, _, _}
  end

  test "service-stop returns finalized accepted evidence without duplicate terminal events", %{
    state: state
  } do
    state = worker(state, "alpha", 1, backend: "claude", questions_enabled: true)
    alpha = state.workers["alpha"]
    {:noreply, state} = Service.handle_info({:agent, alpha.agent, {:question, question()}}, state)

    request = %{
      "command" => "answer",
      "worker_id" => "alpha",
      "turn_id" => alpha.run.id,
      "question_id" => "question-ab12",
      "answers" => %{"Choose?" => "yes"}
    }

    {accepted, state, false} = call(state, request)
    assert accepted.active == true
    assert_received {:answer_write, "question-ab12", %{"Choose?" => "yes"}}
    {_, state, false} = call(state, %{"command" => "service-stop"})
    state = confirm(state, "alpha", "stop")
    {reply, state, true} = call(state, %{"command" => "service-stop"})
    assert reply.workers["alpha"] == state.workers["alpha"].run
    assert reply.agent == state.workers["alpha"].run
    evidence = reply.agent.last_answer
    assert evidence.active == false
    assert evidence.revision == accepted.revision + 1
    assert evidence.admission == "accepted"
    assert evidence.transport == "delivered"
    assert evidence.processing == "unknown"
    assert evidence.outcome == "unknown"

    assert Enum.map(events(state), & &1["kind"]) ==
             [
               "question_available",
               "answer_accepted",
               "answer_delivered",
               "question_invalidated",
               "execution_stopped"
             ]

    refute_received {:answer_write, _, _}
  end
end
