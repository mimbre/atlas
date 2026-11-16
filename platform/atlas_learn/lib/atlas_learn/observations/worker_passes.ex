defmodule AtlasLearn.Observations.WorkerPasses do
  @moduledoc """
  Worker passes: the turns a Runtime ran, read through Runtime's history contract
  (`list_turns`: `GET /v1/turns` on `<runtime home>/backend.sock`), page by page. That
  contract is read-only and gives each turn's public summary: slot, state, harness, the
  configured and reported model, start and end. It never returns the assignment, so neither
  does this observation.

  Learn translates on its side: the worker is the turn's slot, the backend its harness, and
  the model the reported model, or the configured one when none was reported. The history
  turn has no continued turn, result, error or recorded state (RQ1), so those stay nil and
  the observation says so: follow-up chains and error reasons are not seen.

  A turn is in the window when it started or ended in it. Turns are asked for from a week
  before the window (`since`); those outside it stay available as context, so a follow-up
  chain that began earlier is still whole.

  Options: `runtime_home` (the folder holding `backend.sock`), or `read`, a function of one
  page's query (`"since"`, `"limit"`, and `"cursor"` after the first page) answering
  `{:ok, page}`, `{:refused, why}` or `{:error, why}` (tests pass one). A page is
  `%{"turns" => [...], "cursor" => ..., "more" => boolean}`.
  """
  alias AtlasLearn.{Observations, Window}

  @name "Worker passes"
  @context_seconds 7 * 24 * 3600
  @limit 100
  # A page with more turns must name a new cursor; this only bounds a runaway history.
  @max_pages 1_000
  @timeout 30_000
  @connect_timeout 5_000

  def observe(window, opts) do
    case reader(opts) do
      {nil, nil} ->
        Observations.not_asked(@name, "no Runtime home given")

      {source, with_read} ->
        since = window.from |> DateTime.add(-@context_seconds, :second) |> DateTime.to_iso8601()

        case with_read.(&pages(&1, %{"since" => since, "limit" => @limit}, [], @max_pages)) do
          {:ok, turns} ->
            turns = Enum.map(turns, &turn/1)
            {inside, outside} = Enum.split_with(turns, &in_window?(&1, window))

            %{
              name: @name,
              source: source,
              status: :read,
              records: inside,
              context: outside,
              notes: [
                "Runtime's history does not return a turn's assignment.",
                "Runtime's history does not return the turn a turn continued, its result or " <>
                  "error, or the state recorded before its service ended, so follow-up chains " <>
                  "and failure reasons are not seen."
              ]
            }

          {:refused, why} ->
            Observations.unavailable(@name, source, "Runtime refused the read: #{why}")

          {:error, why} ->
            Observations.unavailable(@name, source, why)
        end
    end
  end

  defp pages(_read, _query, _turns, 0), do: {:error, "Runtime's history has too many pages"}

  defp pages(read, query, turns, left) do
    case read.(query) do
      {:ok, %{"turns" => page, "more" => more} = reply} when is_list(page) and is_boolean(more) ->
        turns = turns ++ page
        cursor = reply["cursor"]

        cond do
          not more ->
            {:ok, turns}

          is_binary(cursor) and cursor != "" and cursor != query["cursor"] ->
            pages(read, Map.put(query, "cursor", cursor), turns, left - 1)

          true ->
            {:error, "Runtime's history page has more turns but no new cursor"}
        end

      {:ok, _other} ->
        {:error, "Runtime's reply is not a page of turns"}

      other ->
        other
    end
  end

  # {source, with_read}: with_read.(fun) calls fun with a read function and returns its result.
  defp reader(opts) do
    cond do
      read = opts[:read] -> {"Runtime history (given reader)", & &1.(read)}
      home = opts[:runtime_home] -> backend_reader(Path.join(home, "backend.sock"))
      true -> {nil, nil}
    end
  end

  defp backend_reader(path),
    do: {"Runtime history at #{path}", &with_backend(path, &1)}

  @doc false
  # OTP's :httpc over the Unix socket, in a profile of its own (its socket is a profile
  # option), stopped when the read ends.
  def with_backend(path, fun) do
    profile = :"atlas_learn_#{System.unique_integer([:positive])}"
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = :inets.start(:httpc, profile: profile)

    try do
      :ok = :httpc.set_options([ipfamily: :local, unix_socket: String.to_charlist(path)], profile)
      fun.(&get_turns(profile, path, &1))
    after
      :inets.stop(:httpc, profile)
    end
  end

  defp get_turns(profile, path, query) do
    url = String.to_charlist("http://localhost/v1/turns?" <> URI.encode_query(query))

    # No TLS is used; an explicit ssl option keeps :httpc from reading the OS CA store for
    # its TLS defaults, which fails where that store is not readable (a worker sandbox).
    options = [timeout: @timeout, connect_timeout: @connect_timeout, ssl: []]

    case :httpc.request(
           :get,
           {url, [{~c"accept", ~c"application/json"}]},
           options,
           [body_format: :binary],
           profile
         ) do
      {:ok, {{_, status, _}, _headers, body}} ->
        decode(status, body)

      {:error, {:failed_connect, _} = reason} ->
        {:error, "cannot reach #{path}: #{connect_error(reason)}"}

      {:error, reason} ->
        {:error, "Runtime did not answer: #{inspect(reason)}"}
    end
  end

  defp decode(status, body) do
    case JSON.decode(body) do
      {:ok, reply} when is_map(reply) and status in 200..299 ->
        {:ok, reply}

      {:ok, %{"type" => type}} when is_binary(type) ->
        {:refused, "#{type} (HTTP #{status})"}

      _ when status in 200..299 ->
        {:error, "Runtime's reply is not one JSON object"}

      _ ->
        {:refused, "HTTP #{status}"}
    end
  end

  defp connect_error({:failed_connect, details}) do
    case List.keyfind(details, :inet, 0) || List.keyfind(details, :local, 0) do
      {_, _, reason} when is_atom(reason) -> :inet.format_error(reason) |> to_string()
      _ -> inspect(details)
    end
  end

  # The RQ1 fields stay as nil keys: what reads a record (patterns, the report) still finds them.
  defp turn(summary),
    do: %{
      id: summary["turn_id"],
      worker: summary["slot"],
      state: summary["state"],
      recorded_state: nil,
      backend: summary["harness"],
      model: summary["reported_model"] || summary["configured_model"],
      source: nil,
      started_at: summary["started_at"],
      ended_at: summary["ended_at"],
      result: nil,
      error: nil
    }

  defp in_window?(turn, window),
    do: Window.within?(window, turn.started_at) or Window.within?(window, turn.ended_at)
end
