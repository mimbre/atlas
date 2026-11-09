defmodule AtlasRuntime.Inspection.Reads do
  @moduledoc """
  runtime.read/1: worker, turn, execution-event and public-output reads for viewers.

  Metadata is projected through explicit fields; nothing else from a turn record (its
  assignment, working directory, permissions, repository, native session, artifacts or
  Server configuration) is returned. Public output and the turn's answer are payloads and
  are returned as produced. Reads never change service state, renew output retention or
  reach Atlas Server. See docs/contracts/runtime-read.md.
  """
  alias AtlasRuntime.{ExecutionEvents, Output}
  alias AtlasRuntime.Persistence.History
  import AtlasRuntime.Execution.Identity

  @api "runtime.read/1"
  @fields %{
    "workers" => [],
    "turns" => [],
    "turn" => ["turn_id"],
    "events" => ["cursor", "limit"],
    "output" => ["turn_id", "cursor"]
  }
  @required %{"turn" => ["turn_id"], "output" => ["turn_id"]}
  @turn ~w(worker_id state recorded_state backend requested_model model questions_enabled
           source_turn_id started_at ended_at activity result error)
  @event ~w(sequence kind turn_id worker_id backend model operation timestamp question_id
            revision peer_worker_id peer_source_turn_id response_turn_id)
  @answer_bytes 1_048_576

  # Standalone output stays in its own buffer, which no Bus endpoint reads.
  @local AtlasRuntime.LocalOutput

  @doc "Admit a decoded request as `{:ok, op, args}`; anything but a known read is refused."
  def request(%{"op" => op} = request) when is_map_key(@fields, op) do
    args = Map.drop(request, ["api", "op"])

    cond do
      request["api"] != @api -> {:error, "unsupported_api"}
      Map.keys(args) -- @fields[op] != [] -> {:error, "invalid_request"}
      Enum.any?(Map.get(@required, op, []), &(not Map.has_key?(args, &1))) -> {:error, "invalid_request"}
      not valid_args?(args) -> {:error, "invalid_request"}
      true -> {:ok, op, args}
    end
  end

  def request(_), do: {:error, "not_a_read"}

  defp valid_args?(args) do
    Enum.all?(args, fn
      {"turn_id", id} -> is_binary(id)
      {"cursor", cursor} -> is_binary(cursor) and cursor != ""
      {"limit", limit} -> is_integer(limit) and limit in 1..100
    end)
  end

  @doc "Answer one admitted read from the service's state, which it never changes."
  def read(op, args, state) do
    case run(op, args, state) do
      {:ok, result} -> Map.merge(%{"api" => @api, "op" => op}, result)
      {:error, code} -> error(code)
    end
  rescue
    _ -> error("read_failed")
  end

  def error(code), do: %{"api" => @api, "error" => %{"code" => code, "message" => message(code)}}

  defp run("workers", _args, state) do
    workers =
      state.workers
      |> Enum.sort()
      |> Enum.map(fn {id, worker} ->
        run = string_keys(worker.run)
        %{"worker_id" => id, "state" => run["state"], "turn" => if(run["id"], do: turn(run))}
      end)

    {:ok,
     %{
       "service" => if(state.stopping, do: "stopping", else: "running"),
       "workers" => workers,
       "events_cursor" => ExecutionEvents.head(state.events)
     }}
  end

  defp run("turns", _args, state),
    do: {:ok, %{"turns" => Enum.map(History.list(state.dir, state.workers).turns, &turn/1)}}

  defp run("turn", %{"turn_id" => id}, state) do
    with {:ok, run} <- saved(id, state) do
      {answer, truncated} = answer(run["artifacts"])
      {:ok, %{"turn" => Map.merge(turn(run), %{"answer" => answer, "answer_truncated" => truncated})}}
    end
  end

  defp run("events", args, state) do
    with {:ok, page} <- ExecutionEvents.read(state.events, args["cursor"], Map.get(args, "limit", 50)) do
      {:ok, Map.update!(page, "events", fn events -> Enum.map(events, &Map.take(&1, @event)) end)}
    end
  end

  defp run("output", %{"turn_id" => id} = args, state) do
    with {:ok, run} <- saved(id, state),
         {server, execution} = output_stream(run),
         {:ok, page} <- read_output(execution, args["cursor"], server) do
      stream = Map.take(page["stream"], ~w(epoch first_sequence watermark ended))
      {:ok, Map.put(page, "stream", Map.merge(stream, %{"turn_id" => id, "worker_id" => run["worker_id"]}))}
    end
  end

  defp read_output(execution, cursor, server) do
    Output.read(execution, cursor, server)
  catch
    :exit, _ -> {:error, "output_unavailable"}
  end

  @doc """
  The output buffer and exact execution a turn's public output is retained under: a
  Server-reported turn's Server identity in `Output`, served to Control over Bus as before;
  otherwise a local identity (attempt = turn ID, never reported) in the local buffer.
  """
  def output_stream(run) do
    case run[:server] || run["server"] do
      %{} = server ->
        {Output,
         %{"worker" => Map.take(server, ~w(environment machine worker)), "turn" => server["turn"],
           "attempt" => server["attempt"]}}

      _ ->
        turn = run[:id] || run["id"]
        worker = run[:worker_id] || run["worker_id"]

        {@local,
         %{"worker" => %{"environment" => "local", "machine" => "local", "worker" => worker},
           "turn" => turn, "attempt" => turn}}
    end
  end

  defp saved(id, state) do
    if valid_id?(id) and File.dir?(Path.join([state.dir, "turns", id])),
      do: {:ok, History.historical(id, state.dir, state.workers)},
      else: {:error, "unknown_turn"}
  end

  defp turn(run) do
    run
    |> Map.take(@turn)
    |> Map.merge(%{
      "turn_id" => run["id"],
      "attempt" => get_in(run, ["server", "attempt"]),
      "pending_question" => pending(run["pending_question"])
    })
  end

  defp pending(%{} = question),
    do: %{"question_id" => question[:id] || question["id"], "revision" => question[:revision] || question["revision"]}

  defp pending(_), do: nil

  defp answer(folder) do
    case File.open(Path.join(folder, "answer.txt"), [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @answer_bytes + 1) do
            :eof -> {"", false}
            text when byte_size(text) > @answer_bytes -> {utf8_prefix(binary_part(text, 0, @answer_bytes)), true}
            text -> {text, false}
          end
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {nil, false}
    end
  end

  defp utf8_prefix(text, dropped \\ 0) do
    if String.valid?(text) or dropped == 3,
      do: text,
      else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1), dropped + 1)
  end

  defp message("not_a_read"), do: "read.sock serves only runtime.read/1 operations"
  defp message("unsupported_api"), do: "Requests must name api runtime.read/1"
  defp message("invalid_request"), do: "Malformed runtime.read/1 request"
  defp message("unknown_turn"), do: "No turn with this ID"
  defp message("invalid_cursor"), do: "Cursor does not identify a position in this stream"
  defp message("output_unavailable"), do: "Output is not retained for this turn"
  defp message(_), do: "Runtime could not read this state"
end
