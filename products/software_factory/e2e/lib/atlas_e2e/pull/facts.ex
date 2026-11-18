defmodule AtlasE2E.Pull.Facts do
  @moduledoc """
  What the pull-e2e reads to assert: facts as rela stores them (rela's HTTP API on the
  instance's port, `GET /<plural>/<key>`: the exact values and links Facts wrote, no cache
  in between) and Flow's result store on disk. Reads only; nothing here writes.

  A fact is `%{"key", "values", "links"}` (links: relation → keys) or nil. The runs are
  `flow_run` facts; their structured fields (`pending`, …) are JSON text, decoded here.
  """
  @attempts_max 9

  def url(instance), do: instance.settings["rela"]["url"]

  @doc "One fact by plural and key, or nil."
  def get(url, plural, key) do
    case request("#{url}/#{plural}/#{URI.encode(key)}") do
      {200, body} -> fact(body)
      {404, _} -> nil
      {status, body} -> raise "rela answered #{plural}/#{key} with #{status}: #{inspect(body)}"
    end
  end

  @doc "Every fact of a plural."
  def list(url, plural), do: list(url, plural, 1, [])

  defp list(url, plural, page, acc) do
    case request("#{url}/#{plural}?" <> URI.encode_query(per_page: 200, page: page)) do
      {200, %{"data" => data, "meta" => meta}} ->
        acc = acc ++ Enum.map(data, &fact/1)
        if meta["has_more"], do: list(url, plural, page + 1, acc), else: acc

      {status, body} ->
        raise "rela answered #{plural} with #{status}: #{inspect(body)}"
    end
  end

  def task(url, key), do: get(url, "tasks", key)

  @doc "The task's attempts `TA-<task>-1`, `-2`, … as far as they exist."
  def attempts(url, task) do
    Enum.reduce_while(1..@attempts_max, [], fn n, acc ->
      case get(url, "task_attempts", "TA-#{task}-#{n}") do
        nil -> {:halt, Enum.reverse(acc)}
        fact -> {:cont, [fact | acc]}
      end
    end)
  end

  @doc "The latest run of `flow` on `subject_key`, its structured fields decoded, or nil."
  def run(url, flow, subject_key) do
    url
    |> list("flow_runs")
    |> Enum.filter(&(&1["values"]["flow"] == flow and &1["values"]["subject_key"] == subject_key))
    |> Enum.max_by(&(&1["values"]["generation"] || 0), fn -> nil end)
    |> case do
      nil -> nil
      run -> update_in(run["values"], &decode_structured/1)
    end
  end

  defp decode_structured(values) do
    Map.new(values, fn
      {k, v} when k in ~w(pending deadlines last_input) and is_binary(v) ->
        {k,
         case(JSON.decode(v),
           do: (
             {:ok, d} -> d
             _ -> v
           )
         )}

      kv ->
        kv
    end)
  end

  def value(nil, _field), do: nil
  def value(fact, field), do: fact["values"][field]

  def links(nil, _relation), do: []
  def links(fact, relation), do: fact["links"][relation] || []

  @doc "The To-Dos whose Assignment is assigned to `person`."
  def to_dos_for(url, person) do
    for to_do <- list(url, "to_dos"),
        assignment = get(url, "assignments", "AS-" <> to_do["key"]),
        person in links(assignment, "assigned_to"),
        do: Map.put(to_do, "assignment", assignment)
  end

  # ---- the result store ---------------------------------------------------------------

  @doc """
  The store at `dir` as `AtlasFlow.Results.Store.scan/1` sees it: `blobs` (`<aa>/<sha>`) and
  `manifests` (`manifests/<aa>/<sha>`), sha → size, and the names left in `tmp/`.
  """
  def store(dir) do
    %{blobs: files(dir), manifests: files(Path.join(dir, "manifests")), tmp: tmp(dir)}
  end

  defp files(root) do
    for path <- Path.wildcard(Path.join([root, "??", "*"])),
        sha = Path.basename(path),
        Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
        {:ok, %File.Stat{type: :regular, size: size}} <- [File.stat(path)],
        into: %{},
        do: {sha, size}
  end

  defp tmp(dir) do
    case File.ls(Path.join(dir, "tmp")) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  def blob_bytes(store), do: store.blobs |> Map.values() |> Enum.sum()

  # ---- rela ---------------------------------------------------------------------------

  defp fact(body) do
    links =
      for {relation, keys} <- body["relations"] || %{}, into: %{} do
        keys = if is_map(keys), do: keys["data"] || [], else: List.wrap(keys)
        {relation, Enum.map(keys, fn k -> if is_map(k), do: k["id"], else: k end)}
      end

    %{"key" => body["id"], "values" => body["properties"] || %{}, "links" => links}
  end

  defp request(url) do
    case :httpc.request(
           :get,
           {String.to_charlist(url), [{~c"accept", ~c"application/json"}]},
           [timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} ->
        {status,
         case(JSON.decode(body),
           do: (
             {:ok, d} -> d
             _ -> body
           )
         )}

      {:error, reason} ->
        raise "rela did not answer #{url}: #{inspect(reason)}"
    end
  end
end
