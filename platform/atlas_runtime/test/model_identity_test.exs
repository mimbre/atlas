defmodule AtlasRuntime.ModelIdentityTest do
  # F10 / D29: the first normalized top-level model is the turn's; a later different
  # top-level model stops it with model_changed; subagent records never count.
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.{ExecutionEvents, Provenance, Service}
  alias AtlasRuntime.Persistence.History
  alias AtlasRuntime.Providers.NativeEvents
  @moduletag :tmp_dir

  defmodule Agent do
    use GenServer
    def init(owner), do: {:ok, owner}

    def handle_call({:control, mode, :async}, _from, owner) do
      send(owner, {:control_write, self(), mode})
      {:reply, :ok, owner}
    end
  end

  defp assistant(model, parent \\ nil) do
    %{
      "type" => "runtime.event",
      "event" => %{
        "type" => "assistant",
        "parent_tool_use_id" => parent,
        "message" => %{"model" => model, "content" => []}
      }
    }
  end

  defp claude(model), do: %{owner: self(), backend: "claude", model: model}

  defp identities do
    receive do
      {:agent, _, {:identity, _, model}} -> [model | identities()]
    after
      0 -> []
    end
  end

  describe "native records" do
    test "[1m] and <synthetic> normalise as before" do
      state = NativeEvents.consume(assistant("claude-opus-5-5"), claude("claude-opus-5-5[1m]"))
      assert state.model == "claude-opus-5-5[1m]"
      state = NativeEvents.consume(assistant("<synthetic>"), state)
      assert state.model == "claude-opus-5-5[1m]"
      assert identities() == []
    end

    test "a subagent record with another model changes nothing" do
      state =
        NativeEvents.consume(assistant("claude-haiku-5-5", "toolu_01"), claude("claude-opus-5-5"))

      assert state.model == "claude-opus-5-5"
      assert identities() == []
    end

    test "a top-level record with another model is reported to the Service" do
      state = NativeEvents.consume(assistant("claude-sonnet-5-5"), claude("claude-opus-5-5"))
      assert state.model == "claude-sonnet-5-5"
      assert identities() == ["claude-sonnet-5-5"]
    end

    test "through the native host, a subagent model is no identity", %{tmp_dir: dir} do
      init = %{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "s",
        "model" => "claude-opus-5-5"
      }

      sub = assistant("claude-haiku-5-5", "toolu_01")["event"]

      result = %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "ok"
      }

      command = Path.join(dir, "native-fixture")

      File.write!(
        command,
        "#!/bin/sh\ncat <<'EVENTS'\n" <>
          Enum.map_join([init, sub, result], "\n", &JSON.encode!/1) <> "\nEVENTS\n"
      )

      File.chmod!(command, 0o700)

      {:ok, {pid, ref}} =
        Native.start_monitor(%{key: "claude-turn"},
          turns_dir: Path.join(dir, "turns"),
          agent: %{
            "backend" => "claude",
            "command" => command,
            "workspace" => dir,
            "goal" => "Go"
          }
        )

      assert_receive {:agent, ^pid, {:identity, "claude", "claude-opus-5-5"}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      refute_received {:agent, ^pid, {:identity, _, _}}
    end
  end

  describe "Service" do
    setup %{tmp_dir: dir} do
      {:ok, agent} = GenServer.start(Agent, self())
      on_exit(fn -> if Process.alive?(agent), do: Process.exit(agent, :kill) end)
      id = "turn-00000000000000c1"
      folder = Path.join([dir, "turns", id])
      File.mkdir_p!(folder)

      run = %{
        id: id,
        worker_id: "dev1",
        state: "running",
        backend: "claude",
        model: nil,
        requested_model: "claude-opus-5-5",
        selection: %{"reason" => "preferred"},
        session_id: "session",
        questions_enabled: false,
        pending_question: nil,
        last_answer: nil,
        started_at: "2026-11-16T10:00:00Z",
        artifacts: folder,
        cwd: dir,
        sandbox: "read-only"
      }

      File.write!(Path.join(folder, "turn.json"), JSON.encode!(run))

      state = %{
        dir: dir,
        events: ExecutionEvents.open(dir),
        workers: %{"dev1" => %{agent: agent, monitor: make_ref(), run: run}},
        stopping: false
      }

      %{state: state, agent: agent}
    end

    defp identity(state, agent, model) do
      {:noreply, next} = Service.handle_info({:agent, agent, {:identity, "claude", model}}, state)
      next
    end

    test "the first model is kept and the same one again changes nothing", context do
      state = identity(context.state, context.agent, "claude-opus-5-5")
      assert state.workers["dev1"].run.model == "claude-opus-5-5"
      assert identity(state, context.agent, "claude-opus-5-5") == state
      refute_received {:control_write, _, _}
    end

    test "a top-level change stops the turn with model_changed; the first model stays", context do
      agent = context.agent
      state = identity(context.state, agent, "claude-opus-5-5")
      state = identity(state, agent, "claude-sonnet-5-5")
      run = state.workers["dev1"].run

      assert_received {:control_write, ^agent, :stop}
      assert run.state == "stopping"
      assert run.model == "claude-opus-5-5"

      assert %{"first" => "claude-opus-5-5", "reported" => "claude-sonnet-5-5"} =
               Provenance.model_changed(run)

      # A further change while stopping records nothing new and signals nothing again.
      again = identity(state, agent, "claude-haiku-5-5")
      assert again.workers["dev1"].run.model_changed == run.model_changed
      refute_received {:control_write, _, _}

      {:noreply, ended} =
        Service.handle_info(
          {:agent, agent,
           {:terminated, %{"control" => "stop", "native_result" => false, "exit_code" => 0}}},
          again
        )

      saved = Path.join(run.artifacts, "turn.json") |> File.read!() |> JSON.decode!()
      assert ended.workers["dev1"].run.state == "stopped"
      assert saved["model"] == "claude-opus-5-5"
      assert saved["model_changed"]["reported"] == "claude-sonnet-5-5"
      assert Provenance.model_changed(saved)["first"] == "claude-opus-5-5"
      # Like every stop, the slot stays latched until its end is confirmed and released.
      assert History.latch(context.state.dir, "dev1")["turn_id"] == run.id
    end

    test "another vendor's identity is ignored", context do
      {:noreply, state} =
        Service.handle_info(
          {:agent, context.agent, {:identity, "codex", "gpt-6.1-sol"}},
          context.state
        )

      assert state == context.state
    end
  end
end
