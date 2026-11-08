defmodule AtlasRuntime.Agent.Native do
  @moduledoc """
  Owned official CLI execution using existing native authentication. Codex remains
  the default, with its read-only, workspace-write and dedicated-repository modes.
  Claude supports fresh restricted read-only assignments and explicit independent
  repository Bash execution, including managed provisioning and explicit saved continuation.
  Claude questions require explicit `questions_enabled: true`; answer delivery
  acknowledges a native stdin write, while processed evidence requires a tool result.
  Requires explicit `command`, `workspace` and `goal` agent settings. The Python
  runner owns a process group and reaps it on stop or parent loss. JSONL output,
  stderr and the final answer stay under `turns_dir/<turn key>`. Guidance is not
  supported. Success requires a successful native result and clean process exit.
  """
  use GenServer
  @behaviour AtlasRuntime.Agent

  alias AtlasRuntime.Interactions.NativeQuestion
  alias AtlasRuntime.Providers.NativeEvents

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def stop(pid) do
    GenServer.call(pid, :stop, 10_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
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
    python = System.find_executable("python3")
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

    valid_model =
      is_nil(model) ||
        (is_binary(model) && Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/, model))

    supported =
      backend == "codex" ||
        (backend == "claude" &&
           (is_nil(session) || (is_map(resume_context) && is_binary(model))) &&
           ((sandbox == "read-only" && is_nil(scope) && is_nil(repository)) ||
              (is_nil(sandbox) && is_map(scope) && scope["profile"] == "dedicated-repository")))

    if command && python &&
         AtlasRuntime.Workspaces.valid_request?(workspace, sandbox, scope, repository) &&
         is_binary(goal) && String.trim(goal) != "" && supported &&
         valid_model && is_boolean(questions_enabled) &&
         (not questions_enabled or backend == "claude") &&
         (is_nil(session) || (is_binary(session) && session != "")) do
      File.mkdir_p!(folder)
      helper = Path.join(:code.priv_dir(:atlas_runtime), "runtime/entrypoint.py")

      kept =
        ~w(HOME USER LOGNAME PATH TMPDIR LANG LC_ALL LC_CTYPE CODEX_HOME CLAUDE_CONFIG_DIR ATLAS_RUNTIME_EXECUTABLE)

      unset =
        for {key, _} <- System.get_env(), key not in kept, do: {String.to_charlist(key), false}

      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          {:line, 65_536},
          {:args,
           [
             helper,
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
         result: nil,
         process_exit: nil,
         stopping: nil
       }}
    else
      {:stop, :native_requires_supported_backend_permissions_command_workspace_goal_and_python}
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

  def handle_call(:stop, from, state) do
    state = %{state | question: NativeQuestion.clear(state.question)}
    write_control(state.port, "stop\n")
    {:noreply, %{state | stopping: from}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    state = %{state | question: NativeQuestion.clear(state.question)}
    write_control(state.port, "stop\n")
    {:noreply, %{state | stopping: :owner_gone}}
  end

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
      state.stopping != nil and status == 0 and is_integer(state.process_exit) ->
        if state.stopping != :owner_gone, do: GenServer.reply(state.stopping, :ok)
        {:stop, :normal, %{state | port: nil}}

      status == 0 and state.process_exit == 0 and state.completed and not state.failed and
          (state.backend == "codex" or (is_binary(state.model) and is_binary(state.session))) ->
        send(
          state.owner,
          {:agent, self(), {:ended, state.result || "#{state.backend} completed the goal"}}
        )

        {:stop, :normal, %{state | port: nil}}

      true ->
        failure = if state.backend == "codex", do: :codex_failed, else: :claude_failed
        {:stop, {failure, status, state.process_exit}, %{state | port: nil}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp write_control(port, bytes) do
    Port.command(port, bytes)
  rescue
    ArgumentError -> false
  end

  defp consume(%{"type" => "runtime.process_ended", "exit_code" => code} = record, state),
    do: %{NativeEvents.ended(record, state) | process_exit: code}

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
    state = NativeEvents.consume(record, state)

    if state.completed or state.failed,
      do: %{state | question: NativeQuestion.clear(state.question)},
      else: state
  end

  @impl true
  def terminate(_, state) do
    NativeQuestion.clear(state.question)
    # Closing stdin tells the helper to stop and reap its owned process group.
    if is_port(state.port), do: Port.close(state.port)
  rescue
    ArgumentError -> :ok
  end
end
