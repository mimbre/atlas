defmodule AtlasLearn.Observations.WorkerPasses do
  @moduledoc """
  Worker passes: the turns a Runtime ran, read through Runtime's read API (`runtime.read/1`,
  the `turns` operation on `<runtime home>/read.sock`, docs/contracts/runtime-read.md). That
  API is read-only and projects each turn to its public summary: worker, state, backend,
  model, start and end, the turn it continued (`source_turn_id`), result and error. It never
  returns the assignment, so neither does this observation.

  A turn is in the window when it started or ended in it. Turns outside it stay available
  as context, so a follow-up chain that began earlier is still whole.

  Options: `runtime_home` (the folder holding `read.sock`), or `read`, a function of an
  operation name answering `{:ok, reply}` or `{:error, why}` (tests pass one).
  """
  alias AtlasLearn.{Observations, Window}

  @name "Worker passes"
  @api "runtime.read/1"
  @timeout 30_000

  def observe(window, opts) do
    {source, read} = reader(opts)

    case read && read.("turns") do
      nil ->
        Observations.not_asked(@name, "no Runtime home given")

      {:ok, %{"turns" => turns}} when is_list(turns) ->
        turns = Enum.map(turns, &turn/1)
        {inside, outside} = Enum.split_with(turns, &in_window?(&1, window))

        %{
          name: @name,
          source: source,
          status: :read,
          records: inside,
          context: outside,
          notes: ["Runtime's read API does not return a turn's assignment."]
        }

      {:ok, %{"error" => %{"code" => code}}} ->
        Observations.unavailable(@name, source, "Runtime refused the read: #{code}")

      {:ok, _other} ->
        Observations.unavailable(@name, source, "Runtime's reply has no turns")

      {:error, why} ->
        Observations.unavailable(@name, source, why)
    end
  end

  defp reader(opts) do
    cond do
      read = opts[:read] -> {"Runtime read API (given reader)", read}
      home = opts[:runtime_home] -> socket_reader(Path.join(home, "read.sock"))
      true -> {nil, nil}
    end
  end

  defp socket_reader(path),
    do: {"Runtime read API at #{path}", fn op -> read_socket(path, op) end}

  @doc false
  # One request per connection, one JSON line back (runtime.read/1, "Transport").
  def read_socket(path, op) do
    with {:ok, socket} <- connect(path) do
      try do
        :ok = :gen_tcp.send(socket, JSON.encode!(%{"api" => @api, "op" => op}) <> "\n")
        receive_line(socket, "")
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp connect(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], @timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, "cannot reach #{path}: #{:inet.format_error(reason)}"}
    end
  end

  defp receive_line(socket, buffer) do
    case :binary.split(buffer, "\n") do
      [line, _rest] ->
        decode(line)

      [_] ->
        case :gen_tcp.recv(socket, 0, @timeout) do
          {:ok, data} -> receive_line(socket, buffer <> data)
          {:error, :closed} when buffer != "" -> decode(buffer)
          {:error, reason} -> {:error, "Runtime did not answer: #{:inet.format_error(reason)}"}
        end
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, reply} when is_map(reply) -> {:ok, reply}
      _ -> {:error, "Runtime's reply is not one JSON object"}
    end
  end

  defp turn(summary),
    do: %{
      id: summary["turn_id"],
      worker: summary["worker_id"],
      state: summary["state"],
      recorded_state: summary["recorded_state"],
      backend: summary["backend"],
      model: summary["model"] || summary["requested_model"],
      source: summary["source_turn_id"],
      started_at: summary["started_at"],
      ended_at: summary["ended_at"],
      result: Observations.excerpt(summary["result"]),
      error: Observations.excerpt(summary["error"])
    }

  defp in_window?(turn, window),
    do: Window.within?(window, turn.started_at) or Window.within?(window, turn.ended_at)
end
