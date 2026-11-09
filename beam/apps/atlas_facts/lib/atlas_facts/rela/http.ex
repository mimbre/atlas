defmodule AtlasFacts.Rela.Http do
  @moduledoc """
  The current rela (upstream v26.11.2) over HTTP. `config` is its API base URL, for
  example `http://127.0.0.1:7690/api/v1`.

  What this release does that Facts must work around (rela project's IS-02 handoff):
  it stores invalid data with 201/200 plus `warnings`; `dry_run` is safe on create only;
  a second create of an id answers 422 "entity already exists"; a deleted id stays
  reserved until rela purges it.
  """
  @behaviour AtlasFacts.Rela

  @page 100

  @impl true
  def description(base) do
    case request(:get, base <> "/_schema") do
      {:ok, 200, body, _} -> {:ok, body}
      other -> failure(other)
    end
  end

  @impl true
  def list(base, plural), do: list(base, plural, 1, [])

  defp list(base, plural, page, acc) do
    query = URI.encode_query(per_page: @page, page: page)

    case request(:get, "#{base}/#{plural}?#{query}") do
      {:ok, 200, %{"data" => data, "meta" => meta}, _} ->
        acc = acc ++ Enum.map(data, &fact(&1, nil))
        if meta["has_more"], do: list(base, plural, page + 1, acc), else: {:ok, acc}

      other ->
        failure(other)
    end
  end

  @impl true
  def get(base, plural, key) do
    case request(:get, "#{base}/#{plural}/#{URI.encode(key)}") do
      {:ok, 200, body, headers} -> {:ok, fact(body, headers["etag"])}
      other -> failure(other)
    end
  end

  @impl true
  def incoming(base, plural, key, relation) do
    url = "#{base}/#{plural}/#{URI.encode(key)}/relations/#{relation}?direction=incoming"

    case request(:get, url) do
      {:ok, 200, %{"data" => data}, _} -> {:ok, Enum.map(data, & &1["id"])}
      {:ok, 200, data, _} when is_list(data) -> {:ok, Enum.map(data, & &1["id"])}
      other -> failure(other)
    end
  end

  @impl true
  def check_create(base, plural, key, props, targets),
    do: write(:post, "#{base}/#{plural}?dry_run=true", body(key, props, targets))

  @impl true
  def create(base, plural, key, props, targets),
    do: write(:post, "#{base}/#{plural}", body(key, props, targets))

  defp body(key, props, targets) when targets == %{}, do: %{id: key, properties: props}

  defp body(key, props, targets) do
    relations =
      Map.new(targets, fn {relation, {kind, keys}} ->
        {relation, %{data: Enum.map(keys, &%{type: kind, id: &1})}}
      end)

    %{id: key, properties: props, relations: relations}
  end

  @impl true
  # A relation in `targets` is replaced as a whole: its keys become the given ones (a move).
  def change(base, plural, key, props, version, targets) do
    body = key |> body(props, targets) |> Map.delete(:id)
    write(:patch, "#{base}/#{plural}/#{URI.encode(key)}", body, if_match(version))
  end

  @impl true
  def delete(base, plural, key, version) do
    case request(:delete, "#{base}/#{plural}/#{URI.encode(key)}", nil, if_match(version)) do
      {:ok, status, _, _} when status in [200, 204] -> :ok
      other -> failure(other)
    end
  end

  defp write(method, url, body, headers \\ []) do
    case request(method, url, body, headers) do
      {:ok, status, body, _} when status in [200, 201] -> {:ok, warnings(body)}
      other -> failure(other)
    end
  end

  defp if_match(nil), do: []
  defp if_match(version), do: [{"if-match", version}]

  defp fact(body, version) do
    links =
      for {relation, keys} when is_list(keys) <- body["relations"] || %{},
          into: %{},
          do: {relation, keys}

    %{key: body["id"], properties: body["properties"] || %{}, links: links, version: version}
  end

  defp warnings(%{"warnings" => warnings}) when is_list(warnings) do
    Enum.map(warnings, fn w -> String.trim("#{w["path"]} #{w["detail"] || w["code"]}") end)
  end

  defp warnings(_body), do: []

  defp failure({:ok, 404, _, _}), do: {:error, :not_found}
  defp failure({:ok, 412, _, _}), do: {:error, :version_mismatch}

  defp failure({:ok, 422, %{"detail" => "entity already exists" <> _}, _}),
    do: {:error, :exists}

  defp failure({:ok, status, body, _}) when status in 400..499,
    do: {:error, {:invalid, [problem(body, status)]}}

  # rela answered, but failed: not "not reachable", and worth trying again later.
  defp failure({:ok, status, body, _}),
    do: {:error, {:failed, "rela answered #{status}: #{problem(body, status)}"}}

  defp failure({:error, _} = error), do: error

  # rela puts a JSON path in `detail` for some refusals; the message is then in `title`.
  defp problem(%{"detail" => "/" <> _, "title" => title}, _status) when is_binary(title),
    do: title

  defp problem(%{"detail" => detail}, _status) when is_binary(detail), do: detail
  defp problem(%{"title" => title}, _status) when is_binary(title), do: title
  defp problem(_body, status), do: "rela answered #{status}"

  defp request(method, url, body \\ nil, headers \\ []) do
    headers = Enum.map([{"accept", "application/json"} | headers], &charlists/1)

    request =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)},
        else: {String.to_charlist(url), headers}

    options = [timeout: 5_000, connect_timeout: 2_000]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, headers, raw}} ->
        headers = Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        {:ok, status, decode(raw), headers}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp charlists({k, v}), do: {String.to_charlist(k), String.to_charlist(v)}

  defp decode(""), do: nil

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, body} -> body
      {:error, _} -> nil
    end
  end
end
