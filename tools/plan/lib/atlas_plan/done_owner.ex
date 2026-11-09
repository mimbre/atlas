defmodule AtlasPlan.DoneOwner do
  @moduledoc """
  The IS-Atlas-88 one-off: a done fact has no owner (IS-Atlas-75's rule), also one that
  was done before Flow wrote owners and so kept the coordinator the IS-Atlas-52
  migration gave it.

  Done is what Flow says: Flow writes what is expected on every open fact's Assignment
  and clears it once the fact is done, and a done fact has no Flow process. So an
  Assignment with an owner and nothing expected belongs to a done fact. Of those, only an
  owner a migration set is removed (`by` of the fact that set it, read through Control),
  never one set by hand or by Flow. The IS-Atlas-78 migration moved every owner onto its
  Assignment, by migration, and kept who had set it in its cause ("moved from X, set …
  by who"); that earlier `by` is the one that counts. An owner whose cause does not say
  who set it is kept, and listed. Should an open fact be among them (Flow not yet
  round), nothing is lost: Flow gives it its owner again on its next look, as it does for
  any owner a migration set.

  It reads rela directly, read-only, and writes only through Control, as a client that
  says it is the migration: one change per Assignment, removing `assigned_to`, with the
  cause #{inspect("done: no owner (IS-Atlas-75's rule)")}. A dry run reads and prints the
  steps, and writes nothing. A second run finds nothing left to do.
  """

  @cause "done: no owner (IS-Atlas-75's rule)"
  @component "assignment"
  @owner "assigned_to"
  @owner_label "Assigned to"
  @expected "expected"

  @doc """
  The steps for the Assignments rela holds (`"id"`, `"properties"`, `"relations"`) and
  `origins`, `%{key => %{"by" => …}}`: who set each one's owner.
  """
  def steps(assignments, origins) do
    for part <- Enum.sort_by(candidates(assignments), & &1["id"]),
        set_by(origins[part["id"]]) == "migration",
        do: {:unassign, part["id"], hd(owner(part)), get_in(part, ["properties", "of"])}
  end

  @doc """
  Who set an owner: the `by` of the fact that set it, or, for one the IS-Atlas-78
  migration moved, who had set it before (in that migration's cause). Nil when nobody
  says.
  """
  def set_by(nil), do: nil

  def set_by(%{"by" => "migration", "cause" => cause}) when is_binary(cause) do
    cond do
      match = Regex.run(~r/moved from \S+, set \S+ by ([^:;]+)/, cause) ->
        String.trim(Enum.at(match, 1))

      String.contains?(cause, "moved from") ->
        nil

      true ->
        "migration"
    end
  end

  def set_by(origin), do: origin["by"]

  @doc "The candidates whose owner nobody says who set: kept, and listed."
  def unknown(assignments, origins) do
    for part <- Enum.sort_by(candidates(assignments), & &1["id"]),
        set_by(origins[part["id"]]) == nil,
        do: part["id"]
  end

  @doc "The Assignments with an owner and nothing expected: those of done facts."
  def candidates(assignments) do
    Enum.filter(assignments, fn part ->
      owner(part) != [] and get_in(part, ["properties", @expected]) in [nil, ""]
    end)
  end

  defp owner(part), do: get_in(part, ["relations", @owner]) || []

  @doc "One step as a line of text."
  def line({:unassign, key, owner, of}),
    do: "unassign #{key}  #{@owner} #{owner}  (#{of} is done)"

  @doc """
  Read rela (`url`, its API base) and run the steps through `client` (connected as the
  migration). `opts`: `dry_run`, `say` (prints a line).
  """
  def run(client, url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, schema} <- get(url, "_schema"),
         plural when is_binary(plural) <-
           get_in(schema, ["entities", @component, "plural"]) ||
             {:error, "rela has no #{@component} kind: does it run the new description?"},
         {:ok, parts} <- list(url, plural, 1, []) do
      origins = origins(client, candidates(parts))
      steps = steps(parts, origins)
      say.("IS-Atlas-88 one-off: #{length(steps)} steps; cause: #{@cause}")
      Enum.each(steps, &say.(line(&1)))

      for key <- unknown(parts, origins),
          do: say.("kept     #{key}: nothing says who set its owner")

      if Keyword.get(opts, :dry_run, false) do
        say.("Dry run: nothing was written.")
        {:ok, %{steps: steps, written: 0}}
      else
        write(client, steps, say)
      end
    end
  end

  # Who set each candidate's owner, as Control shows it (the fact that set the link).
  defp origins(client, parts) do
    for part <- parts,
        {:ok, %{"origins" => %{@owner_label => origin}}} <- [AtlasAgent.get(client, part["id"])],
        into: %{},
        do: {part["id"], Map.take(origin, ["since", "by", "cause"])}
  end

  defp write(client, steps, say) do
    Enum.reduce_while(steps, {:ok, 0}, fn {:unassign, key, _, _} = step, {:ok, n} ->
      case AtlasAgent.set(client, key, %{@owner => ""}, @cause) do
        {:ok, _} ->
          say.("done     " <> line(step))
          {:cont, {:ok, n + 1}}

        {:refused, reasons} ->
          {:halt, {:error, "#{line(step)}: refused: #{Enum.join(reasons, "; ")}"}}

        {:error, text} ->
          {:halt, {:error, "#{line(step)}: #{text}"}}
      end
    end)
    |> case do
      {:ok, n} ->
        say.("Done: #{n} of #{length(steps)} steps written.")
        {:ok, %{steps: steps, written: n}}

      error ->
        error
    end
  end

  # rela's API, read-only: every fact of a kind, page by page.
  defp list(url, plural, page, acc) do
    case get(url, "#{plural}?per_page=100&page=#{page}") do
      {:ok, %{"data" => data, "meta" => meta}} ->
        acc = acc ++ data
        if meta["has_more"], do: list(url, plural, page + 1, acc), else: {:ok, acc}

      {:ok, other} ->
        {:error, "rela answered #{plural} with #{inspect(other) |> String.slice(0, 200)}"}

      error ->
        error
    end
  end

  defp get(url, path) do
    address = String.to_charlist("#{url}/#{path}")

    case :httpc.request(:get, {address, [{~c"accept", ~c"application/json"}]}, [timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, JSON.decode!(body)}
      {:ok, {{_, status, _}, _, _}} -> {:error, "rela at #{url} answered #{status} to #{path}"}
      other -> {:error, "rela at #{url} did not answer #{path}: #{inspect(other)}"}
    end
  end
end
