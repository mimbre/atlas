defmodule AtlasFacts.Late do
  @moduledoc """
  Whether a fact is late, worked out from the description on every read; nothing stores it
  and nobody sets it. Knows no kind by name.

  The rule is data (`entities.<kind>.late` in `rela/atlas.json`): `%{"after" => field,
  "while" => field}`. A fact is late while the time in `after` (an RFC 3339 instant) has
  passed and `while` is not empty (past its deadline while something is still expected,
  so not done). Nothing else changes when a fact is late.
  """

  @doc "The rule for `kind`, or nil."
  def rule(description, kind) do
    case get_in(description, ["entities", kind, "late"]) do
      %{"after" => after_field, "while" => while} = rule
      when is_binary(after_field) and is_binary(while) ->
        rule

      _ ->
        nil
    end
  end

  @doc """
  For a fact's `values` of `kind`, at `now`: true or false when its kind has a rule and the
  fact has a time in `after`; nil otherwise (nothing to say).
  """
  def of(description, kind, values, now \\ DateTime.utc_now()) do
    with %{"after" => after_field, "while" => while} <- rule(description, kind),
         text when is_binary(text) and text != "" <- (values || %{})[after_field],
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      DateTime.compare(now, at) == :gt and (values[while] || "") not in ["", nil]
    else
      _ -> nil
    end
  end
end
