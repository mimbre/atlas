defmodule AtlasBus.Digest do
  @moduledoc """
  Content digests, `sha256:` and lowercase hex: of bytes as they are (an evidence snapshot),
  or of a term as canonical JSON (object keys sorted), so the same data always gives the
  same digest.
  """

  @doc "The digest of `bytes`."
  def of_bytes(bytes) when is_binary(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc "The digest of `term` (maps, lists, strings, numbers, booleans, nil) as canonical JSON."
  def of_term(term), do: term |> canonical() |> IO.iodata_to_binary() |> of_bytes()

  @doc "`term` as canonical JSON: object keys sorted, no whitespace."
  def canonical(map) when is_map(map) do
    members =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ":", canonical(v)] end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  def canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  def canonical(value), do: JSON.encode!(value)
end
