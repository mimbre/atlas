defmodule AtlasRuntimeBackend.Generator.Paths do
  @moduledoc """
  The rules of a resource's path, as functions: part of the format, so of the generator.
  Copied from Control's generator (`AtlasBFF.Paths`); a client in another language
  implements the same rules.

  A path is segments separated by `/`: a literal (`v1`, `books`, `_kinds`) or a parameter
  `:name`, which takes any one nonempty segment. `/` alone is the root. A value in a path
  is percent-encoded (`W 1` is `W%201`), and decoded when matched.

  When two paths match one request path, the one with a literal where the other has a
  parameter, at the first segment where they differ, wins: `/books/:id/loans` over
  `/books/:id/:part`. Two paths with the same literals in the same places have the same
  `shape/1` and match the same request paths.
  """

  @doc "The segments of a path: `{:ok, [{:literal, text} | {:param, atom}]}` or `{:error, why}`."
  def parse("/" <> rest = path) when is_binary(path) do
    segments = if rest == "", do: [], else: String.split(rest, "/")

    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      cond do
        Regex.match?(~r/^:[a-z][a-z0-9_]*$/, segment) ->
          name = segment |> String.trim_leading(":") |> String.to_atom()

          if {:param, name} in acc,
            do: {:halt, {:error, "parameter #{segment} is in #{path} twice"}},
            else: {:cont, {:ok, acc ++ [{:param, name}]}}

        Regex.match?(~r/^[A-Za-z0-9_.~-]+$/, segment) ->
          {:cont, {:ok, acc ++ [{:literal, segment}]}}

        true ->
          {:halt, {:error, "#{inspect(segment)} in #{path} is neither a literal nor :name"}}
      end
    end)
  end

  def parse(path), do: {:error, "the path #{inspect(path)} does not start with /"}

  @doc "What decides which request paths a path matches: its literals, and where its parameters are."
  def shape(segments),
    do:
      Enum.map(segments, fn
        {:param, _} -> :param
        literal -> literal
      end)

  @doc """
  The best match among `candidates`, `[{key, segments}]`, for the request path's
  segments `given` (as `Plug.Conn.path_info` has them, still percent-encoded): every
  `{key, params}` whose shape is the best, in the order given, or `[]`. `params` maps
  each parameter's name to its decoded text.
  """
  def match(candidates, given) when is_list(given) do
    matched =
      for {key, segments} <- candidates,
          {:ok, params} <- [bind(segments, given, %{})],
          do: {rank(segments), key, params}

    case matched do
      [] ->
        []

      _ ->
        best = matched |> Enum.map(&elem(&1, 0)) |> Enum.max()
        for {^best, key, params} <- matched, do: {key, params}
    end
  end

  @doc "The path with `params` (a map of parameter name to text) in its parameters, percent-encoded."
  def build(segments, params) do
    parts =
      Enum.map(segments, fn
        {:literal, text} -> text
        {:param, name} -> encode(Map.fetch!(params, name))
      end)

    "/" <> Enum.join(parts, "/")
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, text} | segments], [given | rest], params) do
    if decode(given) == {:ok, text}, do: bind(segments, rest, params), else: :error
  end

  defp bind([{:param, name} | segments], [given | rest], params) when given != "" do
    case decode(given) do
      {:ok, value} -> bind(segments, rest, Map.put(params, name, value))
      :error -> :error
    end
  end

  defp bind(_segments, _given, _params), do: :error

  defp decode(segment) do
    {:ok, URI.decode(segment)}
  rescue
    ArgumentError -> :error
  end

  # Literals count before parameters, from the first segment on.
  defp rank(segments),
    do:
      Enum.map(segments, fn
        {:literal, _} -> 1
        {:param, _} -> 0
      end)

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
