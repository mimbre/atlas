defmodule RelaDSL.Facts.Reads do
  @moduledoc """
  A store's reads for what is worked out on a read (`RelaDSL.Facts.Derived`), over facts
  a test holds: `of(list)`, where `list.(kind)` gives every fact of a kind the test has
  (`{:ok, facts}`, or an error, given back as it is). The lookup answers `"linked"` (the
  facts that point at some keys) and `"facts"` (the facts with some keys) from it, as a
  store does. `asking(list, pid)` also tells `pid` of each read, `{:read, ask}`, with
  `ask` `{:linked, kind, relation, keys}` or `{:facts, kind, keys}`.
  """

  def of(list), do: asking(list, nil)

  def asking(list, pid) do
    %{
      "linked" => fn kind, relation, keys ->
        tell(pid, {:linked, kind, relation, Enum.sort(keys)})

        with {:ok, facts} <- list.(kind),
             do: {:ok, Enum.filter(facts, &Enum.any?(links(&1, relation), fn k -> k in keys end))}
      end,
      "facts" => fn kind, keys ->
        tell(pid, {:facts, kind, Enum.sort(keys)})
        with {:ok, facts} <- list.(kind), do: {:ok, Enum.filter(facts, &(&1.key in keys))}
      end
    }
  end

  defp links(fact, relation), do: (fact[:links] || %{})[relation] || []

  defp tell(nil, _ask), do: :ok
  defp tell(pid, ask), do: send(pid, {:read, ask})
end
