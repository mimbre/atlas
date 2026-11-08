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

  def validate_answers(%{questions: questions}, answers) when is_list(questions) and is_map(answers) do
    keys = Enum.map(questions, & &1["question"])

    if length(keys) in 1..4 and map_size(answers) == length(keys) and
         Enum.sort(Map.keys(answers)) == Enum.sort(keys) and
         Enum.all?(answers, fn {key, value} -> bounded_text?(key) and bounded_text?(value) end) and
         byte_size(JSON.encode!(answers)) <= 16_384,
      do: :ok,
      else: {:error, :invalid_answers}
  rescue
    _ -> {:error, :invalid_answers}
  end

  def validate_answers(_, _), do: {:error, :invalid_answers}

  defp bounded_text?(text),
    do: is_binary(text) and byte_size(text) <= 4_096 and String.valid?(text) and String.trim(text) != ""

  def permission_scope(workspace), do: workspace_request(["scope", workspace])

  def workspace_path(workspace), do: workspace_request(["path", workspace])

  def repository_request(home, url, branch),
    do: workspace_request(["request", home, url, branch])

  defp workspace_request(args) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")

    case System.cmd(executable, ["workspace" | args], stderr_to_stdout: true) do
      {scope, 0} -> JSON.decode!(scope)
      {error, _} -> raise(String.trim(error))
    end
  end

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

    valid_permissions =
      (is_nil(scope) && sandbox in ["read-only", "workspace-write"]) ||
        (is_map(scope) && is_nil(sandbox))

    if command && python && is_binary(workspace) &&
         (File.dir?(workspace) || is_map(repository)) &&
         (is_nil(repository) || (is_map(repository) && is_map(scope))) &&
         is_binary(goal) && String.trim(goal) != "" && valid_permissions && supported &&
         valid_model && is_boolean(questions_enabled) && (not questions_enabled or backend == "claude") &&
         (is_nil(session) || (is_binary(session) && session != "")) do
      File.mkdir_p!(folder)
      helper = Path.join(:code.priv_dir(:atlas_runtime), "native_runner.py")

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
         questions_enabled: questions_enabled,
         pending_question: nil,
         answer_waiter: nil,
         last_answer: nil,
         model: nil,
         session: nil,
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
    with true <- state.questions_enabled and is_nil(state.stopping) and not state.completed and not state.failed,
         %{id: ^question_id} = question <- state.pending_question,
         nil <- state.answer_waiter,
         :ok <- validate_answers(question, answers) do
      command = JSON.encode!(%{command: "answer", question_id: question_id, answers: answers})

      if write_control(state.port, command <> "\n") do
        timer = Process.send_after(self(), {:answer_timeout, question_id}, 5_000)
        {:noreply, %{state | answer_waiter: {question_id, from, timer}}}
      else
        {:stop, :native_transport_closed, {:error, :native_transport_closed}, clear_question(state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :no_matching_pending_question}, state}
    end
  end

  def handle_call(:stop, from, state) do
    state = clear_question(state)
    write_control(state.port, "stop\n")
    {:noreply, %{state | stopping: from}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    state = clear_question(state)
    write_control(state.port, "stop\n")
    {:noreply, %{state | stopping: :owner_gone}}
  end

  def handle_info({:answer_timeout, id}, %{answer_waiter: {id, _, _}} = state),
    do: {:stop, :answer_delivery_timeout, clear_question(state)}

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

  defp clear_question(state) do
    if state.answer_waiter do
      {_, from, timer} = state.answer_waiter
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :native_question_cancelled})
    end

    %{state | pending_question: nil, answer_waiter: nil}
  end

  defp consume(
         %{"type" => "runtime.question",
           "question" => %{"id" => id, "questions" => questions, "correlation" => correlation}},
         %{questions_enabled: true, pending_question: nil, answer_waiter: nil, stopping: nil,
           completed: false, failed: false} = state
       ) when is_binary(id) and is_list(questions) and is_map(correlation) do
    question = %{id: id, questions: questions, correlation: correlation}
    send(state.owner, {:agent, self(), {:question, question}})
    %{state | pending_question: question}
  end

  defp consume(
         %{"type" => "runtime.answer_delivered", "question_id" => id},
         %{answer_waiter: {id, from, timer}, pending_question: %{id: id}} = state
       ) do
    Process.cancel_timer(timer)
    evidence = %{question_id: id, status: "delivered"}
    GenServer.reply(from, {:ok, evidence})
    send(state.owner, {:agent, self(), {:answer, evidence}})
    %{state | answer_waiter: nil, pending_question: nil, last_answer: evidence}
  end

  defp consume(
         %{"type" => "runtime.answer_processed", "question_id" => id},
         %{last_answer: %{question_id: id, status: "delivered"}, stopping: nil} = state
       ) do
    evidence = %{question_id: id, status: "processed"}
    send(state.owner, {:agent, self(), {:answer, evidence}})
    %{state | last_answer: evidence}
  end

  defp consume(
         %{"type" => "runtime.answer_rejected", "question_id" => id, "error" => error},
         %{answer_waiter: {id, from, timer}} = state
       ) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:error, error})
    %{state | answer_waiter: nil}
  end
  defp consume(%{"type" => "runtime.process_ended", "exit_code" => code}, state),
    do: %{state | process_exit: code}

  defp consume(%{"type" => "runtime.repository_prepared", "repository" => repository}, state) do
    send(state.owner, {:agent, self(), {:repository, repository}})
    state
  end

  defp consume(
         %{"type" => "runtime.identity", "backend" => "codex", "model" => model},
         %{backend: "codex"} = state
       ),
       do: identify(state, model)

  defp consume(
         %{
           "type" => "runtime.event",
           "event" => %{
             "type" => "rate_limit_event",
             "rate_limit_info" => %{"status" => "rejected", "rateLimitType" => "seven_day"} = info
           }
         },
         %{backend: "claude"} = state
       ) do
    unavailable = info["isUsingOverage"] != true and info["overageStatus"] != "allowed"

    if unavailable and not state.quota_seen do
      reset = info["resetsAt"]
      reset = if is_number(reset) and reset > 0, do: reset, else: nil
      send(state.owner, {:agent, self(), {:quota, Map.put(info, "resetsAt", reset)}})
    end

    %{state | quota_seen: state.quota_seen or unavailable}
  end

  defp consume(
         %{
           "type" => "runtime.event",
           "event" => %{"type" => "thread.started", "thread_id" => id}
         },
         %{backend: "codex"} = state
       )
       when is_binary(id) and id != "" do
    send(state.owner, {:agent, self(), {:session, id}})
    state
  end

  defp consume(
         %{
           "type" => "runtime.event",
           "event" => %{
             "type" => "system",
             "subtype" => "init",
             "session_id" => id,
             "model" => model
           }
         },
         %{backend: "claude"} = state
       )
       when is_binary(id) and id != "" and is_binary(model) and model != "" do
    send(state.owner, {:agent, self(), {:session, id}})
    identify(%{state | session: id}, model)
  end

  defp consume(
         %{"type" => "runtime.event", "event" => %{"type" => "assistant", "message" => message}},
         %{backend: "claude"} = state
       )
       when is_map(message) do
    parts =
      Enum.flat_map(message["content"] || [], fn
        %{"type" => "text", "text" => text} when is_binary(text) ->
          [%{"kind" => "text", "text" => text}]

        %{"type" => "tool_use", "name" => name} ->
          [
            %{
              "kind" => "tool",
              "tool_name" => AtlasRuntime.Agent.tool_name(name),
              "status" => "started"
            }
          ]

        _ ->
          []
      end)

    AtlasRuntime.Agent.emit(state.owner, "claude: assistant activity", parts)
    identify(state, message["model"])
  end

  defp consume(
         %{"type" => "runtime.event", "event" => %{"type" => "result"} = event},
         %{backend: "claude"} = state
       ) do
    text = event["result"]
    success = event["subtype"] == "success" and event["is_error"] != true and is_binary(text)
    output = if is_binary(text), do: [%{"kind" => "text", "text" => text}], else: []

    AtlasRuntime.Agent.emit(
      state.owner,
      if(success, do: "claude: completed", else: "claude: failed"),
      output
    )

    %{
      clear_question(state)
      | completed: success,
        failed: state.failed or not success,
        result: if(is_binary(text), do: String.slice(text, 0, 2_000), else: nil)
    }
  end

  defp consume(%{"type" => "runtime.event", "event" => event}, %{backend: "claude"} = state) do
    AtlasRuntime.Agent.emit(state.owner, "claude: activity", [])
    state = if event["type"] == "error", do: clear_question(state), else: state
    %{state | failed: state.failed or event["type"] == "error"}
  end

  defp consume(%{"type" => "runtime.event", "event" => event}, state) do
    type = event["type"]
    item = if is_map(event["item"]), do: event["item"], else: %{}
    text = item["text"]
    AtlasRuntime.Agent.emit(state.owner, summary(type), output(type, item))
    state = if type == "turn.completed", do: %{state | completed: true}, else: state
    state = if type in ["turn.failed", "error"], do: %{state | failed: true}, else: state

    if type == "item.completed" and item["type"] == "agent_message" and is_binary(text),
      do: %{state | result: String.slice(text, 0, 2_000)},
      else: state
  end

  defp consume(_, state), do: state

  # Local Claude failures can carry a synthetic assistant instead of a model response.
  defp identify(state, "<synthetic>"), do: state

  # Keep the native context-window option when assistant records name only its base model.
  defp identify(%{backend: "claude", model: configured} = state, model)
       when is_binary(model) and configured == model <> "[1m]", do: state

  defp identify(state, model) when is_binary(model) and model != "" do
    if state.model != model,
      do: send(state.owner, {:agent, self(), {:identity, state.backend, model}})

    %{state | model: model}
  end

  defp identify(state, _), do: state

  # Native records remain in stream.jsonl. Only completed public assistant messages
  # and closed tool metadata cross the live-output boundary; reasoning is never text.
  defp output("item.completed", %{"type" => "agent_message", "text" => text})
       when is_binary(text),
       do: [%{"kind" => "text", "text" => text}]

  defp output(type, %{"type" => tool} = item)
       when type in ["item.started", "item.updated", "item.completed"] and
              tool in ["command_execution", "mcp_tool_call", "web_search", "file_change"] do
    status =
      cond do
        item["status"] == "failed" -> "failed"
        type == "item.completed" -> "completed"
        true -> "started"
      end

    [%{"kind" => "tool", "tool_name" => tool, "status" => status}]
  end

  defp output(_, _), do: []

  defp summary("turn.started"), do: "codex: turn started"
  defp summary("turn.completed"), do: "codex: turn completed"
  defp summary(type) when type in ["turn.failed", "error"], do: "codex: turn failed"
  defp summary("item.started"), do: "codex: item started"
  defp summary("item.updated"), do: "codex: item updated"
  defp summary("item.completed"), do: "codex: item completed"
  defp summary(_), do: "codex: activity"

  @impl true
  def terminate(_, state) do
    clear_question(state)
    # Closing stdin tells the helper to stop and reap its owned process group.
    if is_port(state.port), do: Port.close(state.port)
  rescue
    ArgumentError -> :ok
  end

end
