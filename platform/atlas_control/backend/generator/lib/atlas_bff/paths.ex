defmodule AtlasBFF.Paths do
  @moduledoc """
  The rules of a contract's pages, as functions: part of the format, so of the generator.
  The targets give a server and a client `match/1` and `path/2` on these, with the
  contract's pages; a client in another language implements the same rules.

  A page's path is segments separated by `/`: a literal (`k`, `new`, `_kinds`) or a
  parameter `:name`, which takes any one segment. `/` alone is the root. A value in a
  path is percent-encoded (`W 1` is `W%201`), and decoded when matched.

  When two pages match one path, the one with a literal where the other has a parameter,
  at the first segment where they differ, wins: `/k/:kind/new` over `/k/:kind/:key`. Two
  pages with the same literals in the same places match the same paths; a contract
  refuses them.
  """

  @doc "The segments of a page's path: `{:ok, [{:literal, text} | {:param, atom}]}`."
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

  @doc "What decides which paths a page matches: its literals, and where its parameters are."
  def shape(segments),
    do:
      Enum.map(segments, fn
        {:param, _} -> :param
        literal -> literal
      end)

  @doc """
  The page `pages` (as `__schema__/0` lists them) has for `path`, and its parameters:
  `{:ok, name, %{param => value}}`, or `:error` when no page matches.
  """
  def match(pages, path) when is_binary(path) do
    given =
      case String.trim_leading(path, "/") do
        "" -> []
        rest -> String.split(rest, "/")
      end

    pages
    |> Enum.flat_map(fn page ->
      {:ok, segments} = parse(page.path)

      case bind(segments, given, %{}) do
        {:ok, params} -> [{rank(segments), page.name, params}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> case do
      [{_rank, name, params} | _] -> {:ok, name, params}
      [] -> :error
    end
  end

  def match(_pages, _path), do: :error

  @doc """
  The path of page `name` with `params` (a map or keyword list, values as text).
  Raises when the page does not exist or a parameter is missing.
  """
  def build(pages, name, params) do
    page = Enum.find(pages, &(&1.name == name)) || raise ArgumentError, "no page #{inspect(name)}"
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    {:ok, segments} = parse(page.path)

    parts =
      Enum.map(segments, fn
        {:literal, text} ->
          text

        {:param, param} ->
          case Map.fetch(params, Atom.to_string(param)) do
            {:ok, value} when is_binary(value) and value != "" -> encode(value)
            _ -> raise ArgumentError, "page #{inspect(name)} needs #{inspect(param)}"
          end
      end)

    "/" <> Enum.join(parts, "/")
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, text} | segments], [given | rest], params) do
    if URI.decode(given) == text, do: bind(segments, rest, params), else: :error
  end

  defp bind([{:param, name} | segments], [given | rest], params) when given != "",
    do: bind(segments, rest, Map.put(params, name, URI.decode(given)))

  defp bind(_segments, _given, _params), do: :error

  # Literals count before parameters, from the first segment on.
  defp rank(segments),
    do:
      Enum.map(segments, fn
        {:literal, _} -> 1
        {:param, _} -> 0
      end)

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
