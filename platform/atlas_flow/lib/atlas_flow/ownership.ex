defmodule AtlasFlow.Ownership do
  @moduledoc """
  Preserve an assignee of a declared kind, otherwise use the state default.

  `preserve_kind` names one kind, or a list of them (the kinds the owner relation may
  link). A link holds only a key, so each kind is read in the declared order and the
  first that has a fact by that key is the assignee's: it stays the owner, whichever
  kind it is. No kind having it leaves the default; a read Facts did not answer before
  one was found marks the owner unavailable, so nothing is moved on a guess.
  """

  def resolve(current, owners, read) do
    case {kinds(current["preserve_kind"]), owners} do
      {[_ | _] = kinds, [key]} -> preserve(current, kinds, key, read)
      _ -> current
    end
  end

  defp kinds(kind) when is_binary(kind), do: [kind]

  defp kinds(kinds) when is_list(kinds),
    do: if(Enum.all?(kinds, &is_binary/1), do: kinds, else: [])

  defp kinds(_), do: []

  defp preserve(current, [], _key, _read), do: current

  defp preserve(current, [kind | rest], key, read) do
    case read.(kind, key) do
      %{"fact" => %{}} -> Map.put(current, "owner", %{"kind" => kind, "key" => key})
      %{"fact" => nil} -> preserve(current, rest, key, read)
      _ -> Map.put(current, "owner_unavailable", true)
    end
  end
end
