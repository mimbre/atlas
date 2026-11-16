defmodule AtlasTui.Palette do
  @moduledoc """
  Small terminal mapping of Prism's color tokens. No generator/runtime dependency.
  Source: prism develop 7123c9782ec657e9c3837661e6b25a7abfae383e,
  design/lib/tokens.ex (verified against the remote develop ref).

  Both themes own their surface, so host terminal background cannot erase contrast.
  Light status backgrounds use dark text where Prism's saturated color would be
  too faint as small text. Labels and selection markers carry meaning without color.

  `:muted` is a modifier, not a colour: a muted segment keeps the colours of `:dim`, or
  of the role it wraps (`{:selected, :muted}`), and is drawn faint and never bold.
  `:header` is the title bar, the same in both themes; inside it `:prod` marks only the
  environment name as an inverted badge (the bar's colours swapped), so production stays
  recognisable.
  `:pending_selected` is `:pending` inside the selection: yellow text cannot reach 4.5:1 on
  the selection background, so there the yellow is the background, under dark text.
  """
  @tokens %{
    primary: {66, 114, 239},
    # Not a Prism token: primary scaled to 97%, the nearest same-hue shade where white text
    # reaches 4.5:1 (4.51:1; white on primary itself is 4.30:1).
    primaryshade: {64, 111, 232},
    primarylight: {227, 234, 253},
    secondary: {255, 94, 94},
    tertiary: {255, 207, 96},
    success: {82, 186, 18},
    successlight: {235, 255, 223},
    warning: {242, 141, 21},
    warninglight: {255, 239, 220},
    error: {219, 30, 30},
    grey1: {34, 34, 34},
    grey2: {153, 153, 153},
    grey3: {204, 204, 204},
    grey6: {250, 250, 250},
    white: {255, 255, 255}
  }

  def theme(value) when value in [:light, "light"], do: :light
  def theme(_), do: :dark

  def colors({style, :muted}, theme), do: colors(style, theme)
  def colors(:muted, theme), do: colors(:dim, theme)

  def colors(style, theme) do
    dark = theme(theme) == :dark
    base = if dark, do: {:grey6, :grey1}, else: {:grey1, :white}

    {fg, bg} =
      case style do
        :selected -> {:grey1, :primarylight}
        :cursor -> {:grey1, :tertiary}
        :header -> {:white, :primaryshade}
        :prod -> {:primaryshade, :white}
        :dim -> if dark, do: {:grey3, :grey1}, else: base
        :border -> if dark, do: {:grey2, :grey1}, else: {:grey2, :white}
        :ok -> if dark, do: {:success, :grey1}, else: {:grey1, :successlight}
        :pending -> if dark, do: {:tertiary, :grey1}, else: {:grey1, :warninglight}
        :pending_selected -> {:grey1, :tertiary}
        :error -> if dark, do: {:secondary, :grey1}, else: {:error, :white}
        :info -> if dark, do: {:primarylight, :grey1}, else: {:grey1, :primarylight}
        _ -> base
      end

    {@tokens[fg], @tokens[bg]}
  end

  def ansi(style, theme) do
    {fg, bg} = colors(style, theme)

    weight =
      cond do
        muted?(style) -> "2;"
        style in [:bold, :selected, :header, :prod] -> "1;"
        true -> ""
      end

    ["\e[0;", weight, "38;2;", rgb(fg), ";48;2;", rgb(bg), "m"]
  end

  defp muted?(style), do: style == :muted or match?({_, :muted}, style)

  defp rgb({r, g, b}), do: "#{r};#{g};#{b}"
end
