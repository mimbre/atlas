defmodule AtlasLearn.Observations.Decisions do
  @moduledoc """
  Decisions: the facts of the decision ledger, read through Control with the `atlas` client
  (`atlas list <kind> --json`, then `atlas get <key> --json` per fact), on the environment
  the caller names (`test` or `prod`). Learn names no kind itself: the caller says which
  kind holds the ledger, and which of its fields hold the status and the decided time.

  A fact is in the window when its decided time is. Every other fact is context: still
  open, or decided before. Facts of the same kind a fact links to (the decisions it
  replaces) come with it, by the title of the list Control shows them in.

  Options: `kind` (required to observe), `env` (required with it), `status_field` and
  `time_field` (default `status` and `decided_at`), and either `atlas` (the client
  executable, default `atlas` on PATH) or `client`, a function of the client's arguments
  answering `{:ok, decoded JSON}` or `{:error, why}` (tests pass one).
  """
  alias AtlasLearn.{Observations, Window}

  @name "Decisions"

  def observe(window, opts) do
    kind = opts[:kind]
    env = opts[:env]

    cond do
      is_nil(kind) ->
        Observations.not_asked(@name, "no decision kind given")

      env not in ["test", "prod"] ->
        Observations.unavailable(@name, "Control", "the environment must be test or prod")

      true ->
        client = opts[:client] || (&atlas(opts[:atlas] || "atlas", &1))
        source = "Control, #{env}, facts of kind #{kind}"
        fields = {opts[:status_field] || "status", opts[:time_field] || "decided_at"}

        case read(client, kind, env, fields) do
          {:ok, facts} ->
            {inside, outside} = Enum.split_with(facts, &Window.within?(window, &1.at))

            %{
              name: @name,
              source: source,
              status: :read,
              records: inside,
              context: outside,
              notes: [
                "Control shows no creation time, so a fact still open cannot be dated.",
                "A replaced fact is dated by the fact that replaces it."
              ]
            }

          {:error, why} ->
            Observations.unavailable(@name, source, why)
        end
    end
  end

  defp read(client, kind, env, fields) do
    with {:ok, rows} when is_list(rows) <- client.(["list", kind, "--env", env, "--json"]) do
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, facts} ->
        case client.(["get", row["key"], "--env", env, "--json"]) do
          {:ok, %{} = item} -> {:cont, {:ok, [fact(row, item, kind, fields) | facts]}}
          {:ok, _} -> {:halt, {:error, "Control's answer for #{row["key"]} is no fact"}}
          {:error, why} -> {:halt, {:error, why}}
        end
      end)
      |> case do
        {:ok, facts} -> {:ok, Enum.reverse(facts)}
        error -> error
      end
    else
      {:ok, _} -> {:error, "Control's answer is no list"}
      error -> error
    end
  end

  defp fact(row, item, kind, {status, time}) do
    values = item["values"] || %{}
    prefix = "/k/#{kind}/"

    %{
      id: row["key"],
      title: item["title"] || row["label"],
      status: blank(values[status]),
      at: blank(values[time]),
      links:
        for(
          list <- item["lists"] || [],
          linked <- list["rows"] || [],
          String.starts_with?(linked["path"] || "", prefix),
          do: %{list: list["title"], key: linked["key"]}
        )
    }
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  # The `atlas` client prints one JSON value with --json; exit 1 is a refusal, 2 an error.
  defp atlas(executable, args) do
    case System.cmd(executable, args) do
      {out, 0} ->
        case JSON.decode(out) do
          {:ok, value} -> {:ok, value}
          _ -> {:error, "atlas #{hd(args)} printed no JSON"}
        end

      {out, status} ->
        why =
          case JSON.decode(out) do
            {:ok, %{"error" => text}} -> text
            {:ok, %{"refused" => reasons}} -> Enum.join(List.wrap(reasons), "; ")
            _ -> "exit status #{status}"
          end

        {:error, "atlas #{hd(args)} failed: #{why}"}
    end
  rescue
    error in ErlangError -> {:error, "cannot run #{executable}: #{inspect(error.original)}"}
  end
end
