defmodule AtlasFacts.Freshness.Deps do
  @moduledoc """
  What a read answer depended on: its `deps` and `until` (docs/design/page-freshness.md
  §1.1). Recorded while the answer is built, in the reading process, by what Facts
  looks up for it: the facts it returns, the facts that point at one (`linked`), whole
  kinds (a kind read), what the model's derived values read (the facts that point at
  the facts worked out, `linked`, and those they point at, `key`), and the earliest
  instant a time-derived value in it changes.

  Wire forms: `["key", kind, key, fields]` (`fields` is `"*"` for now), `["linked",
  relation, target, "*"]`, `["kind", kind]`; `until` an ISO 8601 instant.

  A frame (`collect/1`) holds what its answer read; a frame inside another (a page's
  answer inside the page) adds what it read to the outer one too. Outside a frame
  nothing is recorded, so a write's lookups cost nothing.
  """

  @frames {__MODULE__, :frames}

  @doc "Run `fun` in a new frame: `{its result, %{deps, until}}`."
  def collect(fun) do
    Process.put(@frames, [%{deps: MapSet.new(), until: nil} | frames()])

    try do
      result = fun.()
      [frame | outer] = frames()

      case outer do
        [] ->
          Process.delete(@frames)

        [parent | rest] ->
          merged = %{
            deps: MapSet.union(parent.deps, frame.deps),
            until: earliest(parent.until, frame.until)
          }

          Process.put(@frames, [merged | rest])
      end

      {result, frame}
    rescue
      error ->
        pop()
        reraise error, __STACKTRACE__
    end
  end

  defp pop do
    case frames() do
      [_] -> Process.delete(@frames)
      [_ | outer] -> Process.put(@frames, outer)
      [] -> :ok
    end
  end

  @doc """
  `answer` with what `frame` recorded: `"deps"` (sorted) and, when one was found,
  `"until"`. An answer that is an error carries neither: it is no page to keep.
  """
  def attach(%{"error" => _} = answer, _frame), do: answer

  def attach(answer, frame) do
    answer = Map.put(answer, "deps", frame.deps |> MapSet.to_list() |> Enum.sort())

    case frame.until do
      nil -> answer
      at -> Map.put(answer, "until", DateTime.to_iso8601(at))
    end
  end

  @doc "The read returned, or looked up, the fact `key` of `kind` (all its fields)."
  def key(kind, key), do: add(["key", kind, key, "*"])

  @doc "The read asked for the facts that point at `target` through `relation`."
  def linked(relation, target), do: add(["linked", relation, target, "*"])

  @doc "The read depended on every fact of `kind`."
  def kind(kind), do: add(["kind", kind])

  @doc "A value in the answer changes at `at` (a DateTime or an ISO 8601 text); nil: none."
  def until(nil), do: :ok

  def until(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} -> until(at)
      _ -> :ok
    end
  end

  def until(%DateTime{} = at),
    do: update(fn frame -> %{frame | until: earliest(frame.until, at)} end)

  defp add(dep), do: update(fn frame -> %{frame | deps: MapSet.put(frame.deps, dep)} end)

  defp update(fun) do
    case frames() do
      [] -> :ok
      [frame | outer] -> Process.put(@frames, [fun.(frame) | outer])
    end

    :ok
  end

  defp frames, do: Process.get(@frames, [])

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
