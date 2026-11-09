defmodule AtlasRuntime.Providers.NativeEvents do
  @moduledoc "Interpret official provider records without owning their process or transport."

  alias AtlasRuntime.Providers.Codex

  @doc """
  The host's process end. A confirmed Codex session that was not stopped looks up its
  actual model before the runner exits, so identity precedes terminal completion.
  """
  def ended(record, %{backend: "codex", folder: folder} = state) when is_binary(folder),
    do: identity(record, %{state | router_error: router_error(Path.join(folder, "stderr.log"))})

  def ended(record, state), do: identity(record, state)

  defp identity(
         %{"stopped" => false},
         %{backend: "codex", session: session, launch: %{} = launch} = state
       )
       when is_binary(session),
       do:
         identify(
           state,
           Codex.model(session, launch.workspace, launch.codex_home, launch.started_at)
         )

  defp identity(_, state), do: state

  # The host reports the exact launch time, workspace and Codex home its child received.
  def consume(
        %{
          "type" => "runtime.process_started",
          "started_at" => started_at,
          "workspace" => workspace,
          "codex_home" => home
        },
        %{backend: "codex"} = state
      )
      when is_binary(started_at) and is_binary(workspace) and is_binary(home) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _} ->
        %{state | launch: %{started_at: started_at, workspace: workspace, codex_home: home}}

      _ ->
        state
    end
  end

  def consume(
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

  def consume(
        %{
          "type" => "runtime.event",
          "event" => %{"type" => "thread.started", "thread_id" => id}
        },
        %{backend: "codex"} = state
      )
      when is_binary(id) and id != "" do
    send(state.owner, {:agent, self(), {:session, id}})
    %{state | session: id}
  end

  def consume(
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

  def consume(
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

  def consume(
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
      state
      | completed: success,
        failed: state.failed or not success,
        result: if(is_binary(text), do: String.slice(text, 0, 2_000), else: nil)
    }
  end

  def consume(%{"type" => "runtime.event", "event" => event}, %{backend: "claude"} = state) do
    AtlasRuntime.Agent.emit(state.owner, "claude: activity", [])
    %{state | failed: state.failed or event["type"] == "error"}
  end

  def consume(%{"type" => "runtime.event", "event" => event}, state) do
    type = event["type"]
    item = if is_map(event["item"]), do: event["item"], else: %{}
    text = item["text"]
    AtlasRuntime.Agent.emit(state.owner, summary(type), output(type, item))
    state = if type == "turn.completed", do: %{state | completed: true}, else: state
    state = if type in ["turn.failed", "error"], do: %{state | failed: true}, else: state
    state = track_tool(type, item, state)

    if type == "item.completed" and item["type"] == "agent_message" and is_binary(text),
      do: %{state | result: String.slice(text, 0, 2_000)},
      else: state
  end

  def consume(_, state), do: state

  @doc """
  The failure reason of a Codex turn whose tool calls all failed before execution, or nil.
  Codex 0.167.1 exits 0 with `turn.completed` and a normal-looking answer when its code-mode
  host is unreachable, and records no tool item for the failed calls. Each failed dispatch
  logs `<RFC3339> ERROR codex_core::tools::router: error=<error>` on stderr. Such a line with
  no tool item in the turn fails it, citing the first router error. Decided from that log
  level and target and from item types only, never from answer text; exec JSON `error`
  items are not dispatch evidence.
  """
  def dispatch_failure(%{tool_seen: false, router_error: error}) when is_binary(error),
    do: "every tool call failed before execution: " <> error

  def dispatch_failure(_), do: nil

  @tools ["command_execution", "mcp_tool_call", "web_search", "file_change"]

  # Any tool item means a call reached execution; its own status is the tool's outcome.
  defp track_tool(type, %{"type" => tool}, %{tool_seen: false} = state)
       when type in ["item.started", "item.updated", "item.completed"] and tool in @tools,
       do: %{state | tool_seen: true}

  defp track_tool(_, _, state), do: state

  @router ~r/\A\d{4}-\d\d-\d\dT\S+ +ERROR codex_core::tools::router: error=(.*\S)/

  @doc false
  # The first router error in Codex's stderr, which the host wrote completely before the
  # process end; an unreadable log reports none.
  def router_error(path) do
    path
    |> File.stream!(:line)
    |> Enum.find_value(fn line ->
      case Regex.run(@router, line, capture: :all_but_first) do
        [error] -> bounded(error)
        nil -> nil
      end
    end)
  rescue
    File.Error -> nil
  end

  defp bounded(text), do: text |> String.trim() |> String.slice(0, 300)

  # Local Claude failures can carry a synthetic assistant instead of a model response.
  defp identify(state, "<synthetic>"), do: state

  # Keep the native context-window option when assistant records name only its base model.
  defp identify(%{backend: "claude", model: configured} = state, model)
       when is_binary(model) and configured == model <> "[1m]",
       do: state

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
end
