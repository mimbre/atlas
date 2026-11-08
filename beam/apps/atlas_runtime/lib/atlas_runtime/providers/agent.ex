defmodule AtlasRuntime.Agent do
  @moduledoc """
  The port to the agent behind a turn (architecture v4, section 13: the agents are outside
  BEAM, and Runtime starts, watches and ends them). A port starts the agent for one turn
  and returns the process that stands for it. That process tells the turn, its caller:

  - `{:agent, pid, {:activity, what}}`: the agent did something (output, a tool, a fact);
  - `{:agent, pid, {:output, event}}`: a closed, string-keyed public projection:
    `kind: text` or `activity` with `text`, or `kind: tool` with `tool_name` and `status`.
    It never includes reasoning, native records, tool input/results or environment.
    Output is optional, is not guidance evidence, and does not itself renew a lease;
  - `{:agent, pid, {:ended, why}}`: the agent ended its turn itself.

  An agent that crashes is a process that exits abnormally; the turn monitors it. `stop/1`
  ends the agent's turn from Runtime's side (silent, too long, no longer the owner).

  The ports: `stub` (synthetic), `claude` (Claude Code headless), and `codex`
  (official Codex CLI, one explicitly configured goal; read-only unless write permissions are selected).
  """

  @doc "Start the agent for `turn` (`%{key, item, agent}`); messages go to the caller."
  @callback start(turn :: map, opts :: keyword) :: {:ok, pid} | {:error, term}

  @doc "End the agent's turn."
  @callback stop(pid) :: :ok

  @doc "Versioned guidance capabilities. Missing callbacks mean unsupported."
  @callback capabilities(pid) :: {:ok, map} | {:error, term}
  @doc "Admit literal queued guidance once, returning durable evidence."
  @callback accept(pid, map) :: {:ok, map} | {:error, term}
  @doc "Look up exact-target evidence; absence is explicit, never inferred from failure."
  @callback query(pid, map) :: {:ok, map} | {:not_admitted, map} | {:error, term}
  @doc "Side-effect-free pre-start descriptor; machine control is never prompt text."
  @callback describe(map, keyword) :: {:ok, map} | {:error, term}
  @doc "Typed admission deadline in wall-clock milliseconds; checked before new admission."
  @callback accept(pid, map, integer) :: {:ok, map} | {:error, term}
  @callback close_input(pid) :: :ok | {:error, term}
  @doc "Open historical evidence without starting a model or activating an attempt."
  @callback recover_input(map, keyword) :: {:ok, pid} | {:error, term}
  @optional_callbacks capabilities: 1,
                      accept: 2,
                      query: 2,
                      describe: 2,
                      accept: 3,
                      close_input: 1,
                      recover_input: 2

  def describe(port, turn, opts) do
    case invoke(port, :describe, [turn, opts]) do
      {:ok, descriptor} when is_map(descriptor) ->
        # Use the same validation as live capabilities, without starting the port.
        validate_descriptor(port, descriptor)

      _ ->
        {:error, :unsupported}
    end
  end

  def runtime_input?(port),
    do:
      Enum.all?(
        [{:describe, 2}, {:accept, 3}, {:close_input, 1}, {:recover_input, 2}],
        fn {name, arity} ->
          Code.ensure_loaded?(port) and function_exported?(port, name, arity)
        end
      )

  def stop(port, pid), do: invoke(port, :stop, [pid])

  def close_input(port, pid), do: invoke(port, :close_input, [pid])

  def recover_input(port, turn, opts) do
    case invoke(port, :recover_input, [turn, opts]) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> error(reason)
      _ -> {:error, :uncertain}
    end
  end

  def accept(port, pid, request, deadline) when is_integer(deadline) do
    with true <- runtime_input?(port),
         {:ok, _} <- capabilities(port, pid),
         :ok <- AtlasRuntime.Agent.Input.validate(request) do
      evidence_result(
        invoke(port, :accept, [pid, request, deadline]),
        Map.drop(request, ["body", "mode"])
      )
    else
      false -> {:error, :unsupported}
      error -> error
    end
  end

  @doc "Only this version's complete evidence contract enables the input interface."
  def capabilities(port, pid) do
    case invoke(port, :capabilities, [pid]) do
      {:ok, descriptor} when is_map(descriptor) -> validate_descriptor(port, descriptor)
      {:error, reason} -> error(reason)
      _ -> {:error, :unsupported}
    end
  end

  defp validate_descriptor(port, result) do
    case result do
      %{"capability_version" => "1"} = descriptor ->
        if bounded?(descriptor, 8_192) and
             Enum.all?(
               ~w(harness harness_version),
               &AtlasRuntime.Agent.Input.identifier?(descriptor[&1])
             ) and
             Enum.all?(~w(configured_model reported_model), fn key ->
               descriptor[key] == nil or AtlasRuntime.Agent.Input.identifier?(descriptor[key])
             end) and
             Enum.all?(
               ~w(queued_input durable_accept_query consumption_evidence literal_text),
               &(descriptor[&1] == true)
             ) and Enum.all?([:accept, :query], &function_exported?(port, &1, 2)),
           do:
             {:ok,
              Map.take(
                descriptor,
                ~w(capability_version harness harness_version configured_model reported_model queued_input durable_accept_query consumption_evidence literal_text)
              )},
           else: {:error, :unsupported}

      {:error, reason} ->
        error(reason)

      _ ->
        {:error, :unsupported}
    end
  end

  def accept(port, pid, request) do
    with {:ok, _} <- capabilities(port, pid),
         :ok <- AtlasRuntime.Agent.Input.validate(request) do
      evidence_result(invoke(port, :accept, [pid, request]), Map.drop(request, ["body", "mode"]))
    end
  end

  def query(port, pid, identity) do
    with {:ok, _} <- capabilities(port, pid),
         :ok <- AtlasRuntime.Agent.Input.validate_identity(identity) do
      case invoke(port, :query, [pid, identity]) do
        {:not_admitted, ^identity} = absent -> absent
        result -> evidence_result(result, identity)
      end
    end
  end

  defp evidence_result({:ok, %{"identity" => identity} = evidence}, identity) do
    if AtlasRuntime.Agent.Input.valid_evidence?(evidence, identity),
      do: {:ok, evidence},
      else: {:error, :uncertain}
  end

  defp evidence_result({:error, reason}, _), do: error(reason)
  defp evidence_result(_, _), do: {:error, :uncertain}

  defp error(reason)
       when reason in [
              :unsupported,
              :uncertain,
              :unavailable,
              :invalid_input,
              :invalid_identity,
              :conflict,
              :stale,
              :wrong_environment,
              :record_too_large
            ],
       do: {:error, reason}

  defp error(_), do: {:error, :uncertain}

  defp invoke(port, callback, args) do
    if Code.ensure_loaded?(port) and function_exported?(port, callback, length(args)),
      do: apply(port, callback, args),
      else: {:error, :unsupported}
  rescue
    _ -> {:error, :uncertain}
  catch
    _, _ -> {:error, :uncertain}
  end

  @doc "Bounded normalized activity; activity never serves as admission/consumption proof."
  def activity(kind, summary) when kind in ~w(status output tool) and is_binary(summary) do
    if String.valid?(summary) and byte_size(summary) <= 1_024,
      do: {:ok, %{"version" => "1", "kind" => kind, "summary" => summary}},
      else: {:error, :invalid_activity}
  end

  def activity(_, _), do: {:error, :invalid_activity}

  @doc """
  Report real adapter activity beside its safe public output. Summaries must be generic;
  events must already be projected, never native records. Owners without output support
  may ignore the additional messages. Native artifact and continuation formats are unchanged.
  """
  def emit(owner, summary, events \\ []) do
    send(owner, {:agent, self(), {:activity, summary}})

    events = if events == [], do: [%{"kind" => "activity", "text" => summary}], else: events
    Enum.each(events, &send(owner, {:agent, self(), {:output, &1}}))
    :ok
  end

  @doc false
  def tool_name(name) when is_binary(name) do
    if byte_size(name) <= 128 and Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.:-]*\z/, name),
      do: name,
      else: "tool"
  end

  def tool_name(_), do: "tool"

  defp bounded?(value, limit) do
    byte_size(JSON.encode!(value)) <= limit
  rescue
    _ -> false
  end

  @ports %{
    "stub" => AtlasRuntime.Agent.Stub,
    "claude" => AtlasRuntime.Agent.Claude,
    "codex" => AtlasRuntime.Agent.Native
  }

  @doc "The port a machine's settings name for an agent, or nil."
  def port(%{"port" => name}), do: @ports[name]
  def port(_), do: nil
end
