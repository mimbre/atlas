defmodule AtlasFlowGenerator.DefinitionDigest do
  @moduledoc "The identity of a published subflow: SHA-256 of its canonical JSON data."

  def of(definition),
    do: :crypto.hash(:sha256, canonical(definition)) |> Base.encode16(case: :lower)

  @doc "Sorted object keys, compact JSON, unchanged array order and scalar values."
  def canonical(definition), do: definition |> encode() |> IO.iodata_to_binary()

  defp encode(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, value} when is_binary(key) ->
        [JSON.encode!(key), ":", encode(value)]
      end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp encode(list) when is_list(list),
    do: ["[", Enum.intersperse(Enum.map(list, &encode/1), ","), "]"]

  defp encode(value), do: JSON.encode!(value)
end
