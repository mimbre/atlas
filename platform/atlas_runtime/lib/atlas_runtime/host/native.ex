defmodule AtlasRuntime.Agent.Native do
  @moduledoc """
  Owned official CLI execution using existing native authentication. Codex remains
  the default, with its read-only, workspace-write, dedicated-repository,
  materialized-folder and review-packet modes.
  Claude supports fresh restricted read-only assignments, explicit independent
  repository Bash execution, including managed provisioning, materialized-folder and
  review-packet execution and explicit saved continuation.
  Claude questions require explicit `questions_enabled: true`; answer delivery
  acknowledges a native stdin write, while processed evidence requires a tool result.
  Requires explicit `command`, `workspace` and `goal` agent settings. The native
  host (Go `atlas-runtime native-host` of the launching CLI) owns a process group.
  `control/2` asks it to stop (one SIGINT, never escalated) or kill (SIGKILL); the
  owner hears `{:terminated, info}` only after the host confirmed the group gone and
  released its lock. Parent loss keeps the host's bounded interrupt-then-kill cleanup.
  JSONL output, stderr and the final answer
  stay under `turns_dir/<turn key>`. Guidance is not
  supported. Success requires a successful native result and clean process exit; a Codex
  turn whose stderr reported tool router errors and that executed no tool fails with
  `{:codex_failed, "every tool call failed before execution: …"}` even on exit 0.
  """
  use GenServer
  @behaviour AtlasRuntime.Agent

  require Logger

  alias AtlasRuntime.Interactions.NativeQuestion
  alias AtlasRuntime.Providers.NativeEvents

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def start_monitor(turn, opts),
    do: :gen_server.start_monitor(__MODULE__, {self(), turn, opts}, [])

  @doc """
  Internal cleanup for owners ending a turn, not the operator `stop`: interrupt, then kill
  if the group outlives a three-second grace period, and return after the confirmed end.
  """
  @impl AtlasRuntime.Agent
  def stop(pid) do
    case await_control(pid, :stop, 3_000) do
      :timeout -> await_control(pid, :kill, 10_000)
      reply -> reply
    end
  end

  defp await_control(pid, mode, timeout) do
    GenServer.call(pid, {:control, mode, :await}, timeout)
  catch
    :exit, {:timeout, _} when mode == :stop -> :timeout
    :exit, {reason, _} when reason in [:noproc, :normal] -> :ok
  end

  @doc """
  Writes one operator control to the host and returns once it is written; the confirmed end
  arrives later as `{:agent, pid, {:terminated, info}}`. Repeats are forwarded: the host
  signals once per control and re-attempts only a refused signal. Kill wins over stop.
  """
  def control(pid, mode) when mode in [:stop, :kill] do
    GenServer.call(pid, {:control, mode, :async}, 10_000)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> {:error, :native_execution_ended}
    :exit, reason -> {:error, reason}
  end

  def answer(pid, question_id, answers) when is_pid(pid) and is_binary(question_id) do
    GenServer.call(pid, {:answer, question_id, answers}, :infinity)
  catch
    :exit, reason -> {:error, {:native_unavailable, reason}}
  end

  def answer(_, _, _), do: {:error, :invalid_answer}

  @impl true
  def init({owner, turn, opts}) do
    settings = Keyword.fetch!(opts, :agent)
    folder = Path.join(Keyword.fetch!(opts, :turns_dir), turn.key)
    command = settings["command"] && System.find_executable(settings["command"])
    workspace = settings["workspace"]
    goal = settings["goal"]
    sandbox = Map.get(settings, "sandbox", "read-only")
    session = settings["session_id"]
    scope = settings["permissions"]
    repository = settings["repository"]
    backend = Map.get(settings, "backend", "codex")
    model = settings["model"]
    resume_context = settings["resume_context"]
    questions_enabled = Map.get(settings, "questions_enabled", false)

    # Every backend runs in the Go host of the launching CLI.
    host = System.get_env("ATLAS_RUNTIME_EXECUTABLE")

    valid_model =
      is_nil(model) ||
        (is_binary(model) && Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/, model))

    # Both backends refuse unknown profiles; a materialized folder or packet tree is never provisioned.
    supported =
      (backend == "codex" &&
         (is_nil(scope) ||
            (is_map(scope) &&
               scope["profile"] in [
                 "dedicated-repository",
                 "materialized-folder",
                 "review-packet"
               ]))) ||
        (backend == "claude" &&
           (is_nil(session) || (is_map(resume_context) && is_binary(model))) &&
           ((sandbox == "read-only" && is_nil(scope) && is_nil(repository)) ||
              (is_nil(sandbox) && is_map(scope) &&
                 (scope["profile"] == "dedicated-repository" ||
                    (scope["profile"] in ["materialized-folder", "review-packet"] &&
                       is_nil(repository))))))

    if command && host &&
         AtlasRuntime.Workspaces.valid_request?(workspace, sandbox, scope, repository) &&
         is_binary(goal) && String.trim(goal) != "" && supported &&
         valid_model && is_boolean(questions_enabled) &&
         (not questions_enabled or backend == "claude") &&
         (is_nil(session) || (is_binary(session) && session != "")) do
      File.mkdir_p!(folder)

      kept =
        ~w(HOME USER LOGNAME PATH TMPDIR LANG LC_ALL LC_CTYPE CODEX_HOME CLAUDE_CONFIG_DIR)

      unset =
        for {key, _} <- System.get_env(), key not in kept, do: {String.to_charlist(key), false}

      port =
        Port.open({:spawn_executable, host}, [
          :binary,
          :exit_status,
          {:line, 65_536},
          {:args,
           [
             "native-host",
             command,
             Path.expand(workspace),
             Path.expand(folder),
             goal,
             sandbox || "",
             session || "",
             JSON.encode!(scope),
             JSON.encode!(repository),
             backend,
             JSON.encode!(model),
             JSON.encode!(resume_context),
             JSON.encode!(questions_enabled)
           ]},
          {:env, unset}
        ])

      monitor = Process.monitor(owner)

      {:ok,
       %{
         owner: owner,
         backend: backend,
         folder: folder,
         question: NativeQuestion.new(questions_enabled),
         model: nil,
         session: nil,
         launch: nil,
         quota_seen: false,
         monitor: monitor,
         port: port,
         partial: "",
         completed: false,
         failed: false,
         tool_seen: false,
         router_error: nil,
         result: nil,
         process_exit: nil,
         ended_control: nil,
         stopping: nil
       }}
    else
      {:stop, :native_requires_supported_backend_permissions_command_workspace_goal_and_host}
    end
  end

  @impl true
  def handle_call({:answer, question_id, answers}, from, state) do
    with true <- is_nil(state.stopping) and not state.completed and not state.failed,
         :ok <- NativeQuestion.prepare_answer(state.question, question_id, answers) do
      command = JSON.encode!(%{command: "answer", question_id: question_id, answers: answers})

      if write_control(state.port, command <> "\n") do
        {:noreply,
         %{state | question: NativeQuestion.await_delivery(state.question, question_id, from)}}
      else
        {:stop, :native_transport_closed, {:error, :native_transport_closed},
         %{state | question: NativeQuestion.clear(state.question)}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :no_matching_pending_question}, state}
    end
  end

  def handle_call({:control, mode, wait}, from, state) do
    state = %{state | question: NativeQuestion.clear(state.question)}

    if write_control(state.port, "#{mode}\n") do
      previous = state.stopping || %{mode: nil, waiters: []}
      waiters = if wait == :await, do: [from | previous.waiters], else: previous.waiters
      stopping = %{mode: if(previous.mode == :kill, do: :kill, else: mode), waiters: waiters}
      state = %{state | stopping: stopping}
      if wait == :await, do: {:noreply, state}, else: {:reply, :ok, state}
    else
      {:reply, {:error, :native_transport_closed}, state}
    end
  end

  # Nobody can follow or kill this execution any more: closing the control input makes the
  # host interrupt, then kill after its bounded window, and reap the group before exiting.
  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, %{state | question: NativeQuestion.clear(state.question)}}

  def handle_info({:answer_timeout, id}, %{question: %{waiter: {id, _, _}}} = state),
    do:
      {:stop, :answer_delivery_timeout, %{state | question: NativeQuestion.clear(state.question)}}

  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state) do
    if byte_size(state.partial) + byte_size(part) > 2_097_152,
      do: {:stop, :native_event_too_large, state},
      else: {:noreply, %{state | partial: state.partial <> part}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case JSON.decode(state.partial <> line) do
      {:ok, record} -> {:noreply, consume(record, %{state | partial: ""})}
      _ -> {:stop, :invalid_native_runner_event, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    cond do
      # The host exits only after the group was confirmed gone and its lock released.
      state.stopping != nil and status == 0 and is_integer(state.process_exit) ->
        Enum.each(state.stopping.waiters, &GenServer.reply(&1, :ok))
        success = successful?(state)

        send(
          state.owner,
          {:agent, self(),
           {:terminated,
            %{
              "control" => state.ended_control,
              "exit_code" => state.process_exit,
              "native_result" => success,
              "result" => if(success, do: state.result || "#{state.backend} completed the goal")
            }}}
        )

        {:stop, :normal, %{state | port: nil}}

      status == 0 and successful?(state) ->
        send(
          state.owner,
          {:agent, self(), {:ended, state.result || "#{state.backend} completed the goal"}}
        )

        {:stop, :normal, %{state | port: nil}}

      # Otherwise clean, so the precise reason replaces the generic one.
      reason = status == 0 and state.process_exit == 0 and NativeEvents.dispatch_failure(state) ->
        {:stop, {:codex_failed, reason}, %{state | port: nil}}

      true ->
        failure = if state.backend == "codex", do: :codex_failed, else: :claude_failed
        {:stop, {failure, status, state.process_exit}, %{state | port: nil}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp successful?(state) do
    state.process_exit == 0 and state.completed and not state.failed and
      is_nil(NativeEvents.dispatch_failure(state)) and
      (state.backend == "codex" or (is_binary(state.model) and is_binary(state.session)))
  end

  defp write_control(port, bytes) do
    Port.command(port, bytes)
  rescue
    ArgumentError -> false
  end

  defp consume(%{"type" => "runtime.process_ended", "exit_code" => code} = record, state),
    do: %{
      NativeEvents.ended(record, state)
      | process_exit: code,
        ended_control: record["control"]
    }

  defp consume(%{"type" => "runtime.signal"} = record, state) do
    send(
      state.owner,
      {:agent, self(), {:signal, Map.take(record, ["control", "signal", "error"])}}
    )

    state
  end

  defp consume(%{"type" => "runtime.repository_prepared", "repository" => repository}, state) do
    send(state.owner, {:agent, self(), {:repository, repository}})
    state
  end

  defp consume(
         %{"type" => "runtime.question"} = record,
         %{stopping: nil, completed: false, failed: false} = state
       ),
       do: %{state | question: NativeQuestion.consume(record, state.question, state.owner)}

  defp consume(%{"type" => "runtime.answer_processed"} = record, %{stopping: nil} = state),
    do: %{state | question: NativeQuestion.consume(record, state.question, state.owner)}

  defp consume(%{"type" => type} = record, state)
       when type in ["runtime.answer_delivered", "runtime.answer_rejected"],
       do: %{state | question: NativeQuestion.consume(record, state.question, state.owner)}

  defp consume(record, state) do
    state = record |> persist_answer(state) |> then(&NativeEvents.consume(record, &1))

    if state.completed or state.failed,
      do: %{state | question: NativeQuestion.clear(state.question)},
      else: state
  end

  # Claude's final text is the turn answer, overwritten by each forwarded result
  # before terminal notification. Codex writes its own through --output-last-message.
  defp persist_answer(
         %{"type" => "runtime.event", "event" => %{"type" => "result", "result" => text}},
         %{backend: "claude"} = state
       )
       when is_binary(text) do
    case File.write(Path.join(state.folder, "answer.txt"), text) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("native: cannot save the Claude answer: #{inspect(reason)}")
        %{state | failed: true}
    end
  end

  defp persist_answer(_, state), do: state

  @impl true
  def terminate(_, state) do
    NativeQuestion.clear(state.question)
    # Closing stdin tells the helper to stop and reap its owned process group.
    if is_port(state.port), do: Port.close(state.port)
  rescue
    ArgumentError -> :ok
  end
end
