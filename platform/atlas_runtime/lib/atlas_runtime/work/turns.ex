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

  alias AtlasRuntime.Model.Work, as: M

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
        |> Map.merge(workspace(request.workspace, attempt))
  end

  # A base or from_work work runs in the folder the Runtime chose for it (`attempt.folder`,
  # B6, B7), materialized or composed: read-only on disk with the read-only sandbox, or
  # writable as a materialized folder (its record names the original base, §3.9).
  defp workspace(%kind{permissions: :read_only}, %{folder: folder})
       when kind in [M.Base, M.FromWork] and is_binary(folder),
       do: %{"cwd" => folder, "sandbox" => "read-only"}

  defp workspace(%kind{permissions: :workspace_write}, %{folder: folder})
       when kind in [M.Base, M.FromWork] and is_binary(folder),
       do: %{"cwd" => folder, "permissions" => "materialized-folder"}

  defp workspace(workspace, _attempt), do: workspace(workspace)

  defp workspace(%{url: url, branch: branch}),
    do: %{"repository" => url, "branch" => branch, "permissions" => "dedicated-repository"}

  defp workspace(%{path: path, permissions: :read_only}),
    do: %{"cwd" => path, "sandbox" => "read-only"}

  defp workspace(%{path: path, permissions: :workspace_write}),
    do: %{"cwd" => path, "sandbox" => "workspace-write"}

  defp workspace(%{path: path, permissions: :materialized_folder}),
    do: %{"cwd" => path, "permissions" => "materialized-folder"}

  @doc "The workspace permission a request's policy check uses (design §7 step 1)."
  def permission(%M.Base{permissions: :read_only}), do: "read-only"
  def permission(%M.Base{permissions: :workspace_write}), do: "materialized-folder"
  def permission(%M.FromWork{permissions: :read_only}), do: "read-only"
  def permission(%M.FromWork{permissions: :workspace_write}), do: "materialized-folder"
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
  answer}`. `quiescent` comes only from a group-gone result (`group_gone?/1`): a turn that
  ended without one (the helper died, for either harness) is not quiescent, and the probe
  or a `release` settles it later (I1).
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
      quiescent: group_gone?(turn),
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

  # Whether the turn's record proves its process group gone (design §3.7, I1; designer Q1:
  # `stop_confirmed` is the helper's group-gone probe, `host/host.go:607-617`). The helper
  # reports `runtime.process_ended` only once that probe found the group empty, so:
  #
  # - `finished`, `stopped`, `killed`: written only on that report (`{:ended, _}`,
  #   `{:terminated, _}` in `execution/service.ex`);
  # - `termination.confirmed_at`: the Runtime's record of the confirmation (any end);
  # - `recorded_state`: restart reconciliation's end of a turn whose process it found gone;
  # - a native failure that carries the reported exit (`{:claude_failed | :codex_failed,
  #   status, exit}` with an integer `exit`, or Codex's `{:codex_failed, "…"}`, which
  #   `host/native.ex` raises only after a reported exit 0).
  #
  # Anything else, such as `{:claude_failed, 137, nil}` for a helper killed mid-cancel while a
  # member still lives, proves nothing: not quiescent, whatever the error text contains.
  defp group_gone?(%{"state" => state}) when state in ~w(finished stopped killed), do: true
  defp group_gone?(%{"termination" => %{"confirmed_at" => at}}) when is_binary(at), do: true
  defp group_gone?(%{"recorded_state" => _}), do: true
  defp group_gone?(%{"error" => error}) when is_binary(error), do: reported_exit?(error)
  defp group_gone?(_), do: false

  defp reported_exit?(error),
    do:
      Regex.match?(~r/\A\{:(?:claude|codex)_failed, -?\d+, -?\d+\}\z/, error) or
        Regex.match?(~r/\A\{:codex_failed, "/, error)

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
