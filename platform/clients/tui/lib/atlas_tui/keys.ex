defmodule AtlasTui.Keys do
  @moduledoc """
  Turns raw terminal input into keys. An escape that is not followed by more input
  within a moment is the Escape key; the caller says when that moment has passed.
  """

  @doc """
  Parse `buffer`. Returns `{keys, rest}`; `rest` is an incomplete escape sequence to
  keep until more input arrives (or until `flush/1`).
  """
  def parse(buffer), do: parse(buffer, [])

  @doc "The moment has passed: whatever is left is Escape plus plain input."
  def flush(""), do: []
  def flush("\e" <> rest), do: [:esc | elem(parse(rest), 0)]
  def flush(rest), do: elem(parse(rest), 0)

  defp parse("", acc), do: {Enum.reverse(acc), ""}
  defp parse("\e[A" <> rest, acc), do: parse(rest, [:up | acc])
  defp parse("\e[B" <> rest, acc), do: parse(rest, [:down | acc])
  defp parse("\e[C" <> rest, acc), do: parse(rest, [:right | acc])
  defp parse("\e[D" <> rest, acc), do: parse(rest, [:left | acc])
  defp parse("\e[Z" <> rest, acc), do: parse(rest, [:shift_tab | acc])
  defp parse("\eOA" <> rest, acc), do: parse(rest, [:up | acc])
  defp parse("\eOB" <> rest, acc), do: parse(rest, [:down | acc])
  defp parse("\eOC" <> rest, acc), do: parse(rest, [:right | acc])
  defp parse("\eOD" <> rest, acc), do: parse(rest, [:left | acc])
  defp parse("\e[H" <> rest, acc), do: parse(rest, [:home | acc])
  defp parse("\e[F" <> rest, acc), do: parse(rest, [:end | acc])
  defp parse("\eOH" <> rest, acc), do: parse(rest, [:home | acc])
  defp parse("\eOF" <> rest, acc), do: parse(rest, [:end | acc])
  defp parse("\e[1~" <> rest, acc), do: parse(rest, [:home | acc])
  defp parse("\e[4~" <> rest, acc), do: parse(rest, [:end | acc])
  defp parse("\e[5~" <> rest, acc), do: parse(rest, [:page_up | acc])
  defp parse("\e[6~" <> rest, acc), do: parse(rest, [:page_down | acc])

  # Other CSI sequences (Delete, Page up, …) are ignored whole.
  defp parse("\e[" <> rest = buffer, acc) do
    case Regex.run(~r/^[0-9;]*[A-Za-z~]/, rest) do
      [seq] -> parse(binary_part(rest, byte_size(seq), byte_size(rest) - byte_size(seq)), acc)
      nil -> {Enum.reverse(acc), buffer}
    end
  end

  defp parse("\e", acc), do: {Enum.reverse(acc), "\e"}
  defp parse("\eO", acc), do: {Enum.reverse(acc), "\eO"}
  defp parse("\e\e" <> rest, acc), do: parse("\e" <> rest, [:esc | acc])
  defp parse("\e" <> rest, acc), do: parse(rest, [:esc | acc])
  defp parse("\r\n" <> rest, acc), do: parse(rest, [:enter | acc])
  defp parse("\r" <> rest, acc), do: parse(rest, [:enter | acc])
  defp parse("\n" <> rest, acc), do: parse(rest, [:enter | acc])
  defp parse("\t" <> rest, acc), do: parse(rest, [:tab | acc])
  defp parse(<<127, rest::binary>>, acc), do: parse(rest, [:backspace | acc])
  defp parse(<<8, rest::binary>>, acc), do: parse(rest, [:backspace | acc])
  defp parse(<<3, rest::binary>>, acc), do: parse(rest, [:ctrl_c | acc])
  defp parse(<<19, rest::binary>>, acc), do: parse(rest, [:ctrl_s | acc])
  defp parse(<<c, rest::binary>>, acc) when c < 32, do: parse(rest, acc)

  defp parse(buffer, acc) do
    case String.next_grapheme(buffer) do
      {g, rest} -> parse(rest, [{:char, g} | acc])
      nil -> {Enum.reverse(acc), ""}
    end
  end
end
