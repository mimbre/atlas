defmodule AtlasRuntime.Work.Turns do
  @moduledoc """
  How the work core uses the Service's turns: it starts, stops and releases them only
  through the Service's existing commands, follows the Service's events and reads the
  turn's own record. Nothing here changes a turn by itself.

  **Starting.** `start` (or `continue` for a resume) with `worker_id` = the slot and a
  `request_id` derived from the attempt (`request_id/2`): the Service's command admission
  makes a repeated request with that ID answer the first one's turn instead of starting
  again, so a crash between asking and recording never starts a turn twice.

  **Ends.** `outcome/2` maps a terminal turn to the attempt's result (the
  Service-event → attempt table of the D2 delivery):

  | Turn (`turn.json`) | Attempt |
  |---|---|
  | `model_changed` recorded (any end) | `failed: model_changed` |
  | `stopped`/`killed`/`failed`, cancel the core asked for | `cancelled` (`cancel`/`superseded`) or `failed: time_limit` |
  | `finished`, cancel still `requested` | `completed` (the result wins, §3.7) |
  | `finished` | `completed` |
  | `stopped`/`killed`, no cancel by the core (Service stop) | `interrupted` |
  | `failed` by restart reconciliation (`recorded_state`) | `interrupted` |
  | `failed` with Claude quota evidence | `failed: quota` |
  | `failed` with a native failure (`codex_failed`/`claude_failed`) | `failed` |
  | `failed`, anything else (the helper died) | `crashed` |
  """

  @live ~w(running stopping killing)
  @answer_bytes 8192

  @doc "The Service request ID of attempt `n` of a work: `w` and 63 hex digits of SHA-256."
  def request_id(work_id, attempt) do
    digest = :crypto.hash(:sha256, "#{work_id}:#{attempt}") |> Base.encode16(case: :lower)
    "w" <> binary_part(digest, 0, 63)
  end

  @doc "A Service command: `{:ok, reply}` or `{:error, why}` (a command error or no Service)."
  def command(service, request, timeout \\ 120_000) do
    case GenServer.call(service, request, timeout) do
      {%{command_error: why}, _shutdown?} -> {:error, why}
      {reply, _shutdown?} -> {:ok, reply}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "A Service read (`{:read, op, args}` or `{:follow, pid, cursor}`), answered as is."
  def read(service, request) do
    GenServer.call(service, request, 30_000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "The Service command that starts attempt `attempt` of `record` on `slot`."
  def start_request(record, attempt, slot, resume_turn) do
    request = record.request

    base = %{
      "request_id" => request_id(record.work_id, attempt.attempt),
      "worker_id" => slot,
      "assignment" => request.instructions
    }

    if resume_turn,
      do: Map.merge(base, %{"command" => "continue", "turn_id" => resume_turn}),
      else:
        base
        |> Map.merge(%{
          "command" => "start",
          "profile" => request.profile,
          "cost_class" => Atom.to_string(request.cost_class)
        })
        |> Map.merge(workspace(request.workspace))
  end

  defp workspace(%{url: url, branch: branch}),
    do: %{"repository" => url, "branch" => branch, "permissions" => "dedicated-repository"}

  defp workspace(%{path: path, permissions: :read_only}),
    do: %{"cwd" => path, "sandbox" => "read-only"}

  defp workspace(%{path: path, permissions: :workspace_write}),
    do: %{"cwd" => path, "sandbox" => "workspace-write"}

  defp workspace(%{path: path, permissions: :materialized_folder}),
    do: %{"cwd" => path, "permissions" => "materialized-folder"}

  @doc "The workspace permission a request's policy check uses (design §7 step 1)."
  def permission(%{url: _}), do: "dedicated-repository"
  def permission(%{permissions: :read_only}), do: "read-only"
  def permission(%{permissions: :workspace_write}), do: "workspace-write"
  def permission(%{permissions: :materialized_folder}), do: "materialized-folder"

  @doc "A turn's own record (`turns/<id>/turn.json`), or nil when there is none."
  def read_turn(dir, turn_id) do
    with true <- is_binary(turn_id) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, turn_id),
         {:ok, bytes} <- File.read(Path.join([dir, "turns", turn_id, "turn.json"])),
         {:ok, %{"id" => ^turn_id} = turn} <- JSON.decode(bytes) do
      turn
    else
      _ -> nil
    end
  end

  @doc "Whether the turn is still owned and running, as its record says."
  def live?(turn), do: turn["state"] in @live

  @doc """
  The attempt's end from a terminal turn: `%{kind, reason, native_outcome, quiescent,
  answer}`. `quiescent` is false only for a turn that ended without its group confirmed
  gone (the helper died); the probe settles it later.
  """
  def outcome(turn, attempt) do
    state = turn["state"]
    native = native_outcome(state)
    cancel = attempt.cancel_stage

    {kind, reason} =
      cond do
        is_map(turn["model_changed"]) -> {:failed, "model_changed"}
        cancel in [:signalled, :forced] -> cancelled(attempt)
        cancel == :requested and state != "finished" -> cancelled(attempt)
        state == "finished" -> {:completed, nil}
        state in ["stopped", "killed"] -> {:interrupted, nil}
        Map.has_key?(turn, "recorded_state") -> {:interrupted, nil}
        is_map(turn["quota"]) -> {:failed, "quota"}
        native_failure?(turn["error"]) -> {:failed, nil}
        true -> {:crashed, nil}
      end

    %{
      kind: kind,
      reason: reason,
      native_outcome: native,
      quiescent:
        state != "failed" or Map.has_key?(turn, "recorded_state") or
          native_failure?(turn["error"]),
      answer: if(state == "finished", do: answer(turn["result"]))
    }
  end

  defp cancelled(%{cancel_reason: :time_limit}), do: {:failed, "time_limit"}
  defp cancelled(%{cancel_reason: reason}), do: {:cancelled, Atom.to_string(reason || :cancel)}

  defp native_outcome(state) when state in ~w(finished failed stopped killed),
    do: String.to_existing_atom(state)

  defp native_outcome(_), do: nil

  defp native_failure?(error) when is_binary(error),
    do: String.contains?(error, ["codex_failed", "claude_failed"])

  defp native_failure?(_), do: false

  @doc "Whether a result kind and reason are advice to retry (design §3.5)."
  def retryable?(kind, reason),
    do: kind in [:crashed, :interrupted, :returned] or (kind == :failed and reason == "quota")

  @doc "The resume point a turn leaves: its conversation and workspace, or nil."
  def resume_point(turn) do
    if is_binary(turn["session_id"]) and turn["session_id"] != "" and is_binary(turn["cwd"]) do
      %{
        turn_id: turn["id"],
        conversation_id: turn["session_id"],
        workspace: %{path: turn["cwd"], branch: get_in(turn, ["repository", "branch"])}
      }
    end
  end

  @doc "The policy option a turn ran with, for a resume's check (design §7 step 2)."
  def option(turn) do
    case turn["selection"] do
      %{"option" => %{} = option} ->
        Map.take(option, ["provider", "harness", "model"])

      _ ->
        harness = turn["backend"] || "codex"
        provider = %{"claude" => "anthropic", "codex" => "openai"}[harness]
        model = turn["model"] || turn["requested_model"]

        if provider && model,
          do: %{"provider" => provider, "harness" => harness, "model" => model}
    end
  end

  # The final agent message, at most 8 KB, cut on a UTF-8 boundary.
  defp answer(text) when is_binary(text) and byte_size(text) > @answer_bytes,
    do: prefix(binary_part(text, 0, @answer_bytes))

  defp answer(text) when is_binary(text), do: text
  defp answer(_), do: nil

  defp prefix(text) do
    if String.valid?(text) or text == "",
      do: text,
      else: prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
