defmodule AtlasLearn.Window do
  @moduledoc "The stretch of time Learn looks at: from `from` (inclusive) to `until` (exclusive)."
  defstruct [:from, :until]

  def ending(%DateTime{} = until, hours) when is_integer(hours) and hours > 0,
    do: %__MODULE__{from: DateTime.add(until, -hours * 3600, :second), until: until}

  @doc "Whether a moment (a `DateTime` or an ISO 8601 text) lies in the window; nil never does."
  def within?(window, %DateTime{} = at),
    do: DateTime.compare(at, window.from) != :lt and DateTime.compare(at, window.until) == :lt

  def within?(window, text) when is_binary(text) do
    case moment(text) do
      nil -> false
      at -> within?(window, at)
    end
  end

  def within?(_window, _), do: false

  @doc "An ISO 8601 text as a `DateTime`, or nil."
  def moment(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  def moment(_), do: nil
end
