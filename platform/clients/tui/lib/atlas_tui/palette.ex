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
  `:header` is the title bar, the same in both themes; inside it `:env_test` marks the
  environment name as an orange badge when it is not production, so a test Console is
  never mistaken for the real one. Production stays plain.
  `:pending_selected` is `:pending` inside the selection: yellow text cannot reach 4.5:1 on
  the selection background, so there the yellow is the background, under dark text.
  `:active` (the group shown) looks like `:selected` but is not the selected row.
  `:frame` is a frame in primary (a line, not text). `:key` names a key as a neutral
  keycap, grey1 on grey3 in both themes (9.9:1): a key carries no meaning of its own, so
  no colour. `:warning` warns (Prism's warning); in the light theme, where that colour is
  too faint as text on white, it is dark text on warninglight.
  The `:tone_*` roles draw a list row's kind icon (where its work stands): red when it needs
  the viewer, orange when under way, blue when planned or waiting, green when done. In dark
  the icon is the colour on the surface (≥3:1); in light, where those colours are too faint
  on white, the cell is the colour and the icon is drawn on it in white or grey1.
  `:error_frame` frames what went wrong in Prism's error (a line, not text); its heading
  is `:error` text.
  `:route` is a part of a route in an instruction (where to click in an app): bold, in
  `:info`'s colours, primarylight on dark and grey1 on primarylight in light, where
  primary text on white is under 4.5:1.
  `:rest_frame` is the thin line between two columns: grey2 in dark; in light grey1, as
  grey2 on white stays under 3:1 (2.85:1). `:lit` is the focused column's heading:
  white on primaryshade, with a visible focus marker.
  `:eyebrow` is a page's eyebrow ("◆ YOUR DECISION · D-0104"): bold light blue on the page,
  primarylight in dark, primaryshade in light (primary on white is under 4.5:1).

  Cards (`@card_surfaces`, a Prism gap): Prism's dark mode has no surfaces yet, so the two
  card surfaces, `:card` (slightly lighter than the page) and `:card_selected` (a light
  primary tint), are the only colours here that are not Prism tokens (light's selected
  surface is primarylight), until Prism supplies them; the same shim as the Mac's dark gap.
  A segment on a card is `{surface, role}`: the role's text colour on the surface where the
  role has the page's background, its own background (a key, a chip) where not. Where a
  role's colour would fall under 4.5:1 on a surface (the error colour on the selected one),
  it takes the theme's text colour; its words say what it is. `:card_edge` and
  `:card_selected_edge` draw a card's straight top and bottom rows: the surface colour as
  the foreground of half blocks on the page.
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

  # The Prism gap (see the moduledoc): the card surfaces, by theme. Dark: the card a step
  # above grey1, the selected one grey1 tinted towards primary (every text role ≥4.5:1 on
  # both); light: the card a step under white (the error colour still 4.6:1 on it), the
  # selected one Prism's primarylight.
  @card_surfaces %{
    dark: %{card: {44, 44, 44}, card_selected: {34, 44, 76}},
    light: %{card: {246, 246, 246}, card_selected: {227, 234, 253}}
  }
  @surfaces [:card, :card_selected]

  @doc "The card surfaces, the roles a segment on a card is wrapped in (`{surface, role}`)."
  def surfaces, do: @surfaces

  def theme(value) when value in [:light, "light"], do: :light
  def theme(_), do: :dark

  def colors({surface, style}, theme) when surface in @surfaces do
    {fg, bg} = colors(style, theme)
    {text, page} = colors(:plain, theme)

    if bg == page do
      card = @card_surfaces[theme(theme)][surface]
      {if(contrast(fg, card) < 4.5, do: text, else: fg), card}
    else
      {fg, bg}
    end
  end

  def colors(edge, theme) when edge in [:card_edge, :card_selected_edge] do
    surface = if edge == :card_edge, do: :card, else: :card_selected
    {_, page} = colors(:plain, theme)
    {@card_surfaces[theme(theme)][surface], page}
  end

  def colors({style, :muted}, theme), do: colors(style, theme)
  def colors(:muted, theme), do: colors(:dim, theme)

  def colors(style, theme) do
    dark = theme(theme) == :dark
    base = if dark, do: {:grey6, :grey1}, else: {:grey1, :white}

    {fg, bg} =
      case style do
        style when style in [:selected, :active] -> {:grey1, :primarylight}
        :cursor -> {:grey1, :tertiary}
        :header -> {:white, :primaryshade}
        :env_test -> {:grey1, :warning}
        :dim -> if dark, do: {:grey3, :grey1}, else: base
        :border -> if dark, do: {:grey2, :grey1}, else: {:grey2, :white}
        :frame -> if dark, do: {:primary, :grey1}, else: {:primary, :white}
        :error_frame -> if dark, do: {:error, :grey1}, else: {:error, :white}
        :rest_frame -> if dark, do: {:grey2, :grey1}, else: {:grey1, :white}
        :lit -> {:white, :primaryshade}
        :key -> {:grey1, :grey3}
        :warning -> if dark, do: {:warning, :grey1}, else: {:grey1, :warninglight}
        :ok -> if dark, do: {:success, :grey1}, else: {:grey1, :successlight}
        :pending -> if dark, do: {:tertiary, :grey1}, else: {:grey1, :warninglight}
        :tone_attention -> if dark, do: {:secondary, :grey1}, else: {:white, :error}
        :tone_active -> if dark, do: {:warning, :grey1}, else: {:grey1, :warning}
        :tone_waiting -> if dark, do: {:primary, :grey1}, else: {:white, :primaryshade}
        :tone_done -> if dark, do: {:success, :grey1}, else: {:grey1, :success}
        :pending_selected -> {:grey1, :tertiary}
        :error -> if dark, do: {:secondary, :grey1}, else: {:error, :white}
        :info -> if dark, do: {:primarylight, :grey1}, else: {:grey1, :primarylight}
        :eyebrow -> if dark, do: {:primarylight, :grey1}, else: {:primaryshade, :white}
        :route -> if dark, do: {:primarylight, :grey1}, else: {:grey1, :primarylight}
        _ -> base
      end

    {@tokens[fg], @tokens[bg]}
  end

  def ansi(style, theme) do
    {fg, bg} = colors(style, theme)
    role = role(style)

    weight =
      cond do
        muted?(role) -> "2;"
        role in [:bold, :selected, :active, :header, :env_test, :route, :lit, :eyebrow] -> "1;"
        true -> ""
      end

    ["\e[0;", weight, "38;2;", rgb(fg), ";48;2;", rgb(bg), "m"]
  end

  @doc "WCAG contrast ratio of two RGB colours."
  def contrast(a, b) do
    [dark, light] = Enum.sort([luminance(a), luminance(b)])
    (light + 0.05) / (dark + 0.05)
  end

  defp luminance({r, g, b}) do
    [r, g, b] =
      for c <- [r, g, b] do
        c = c / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  # The role a segment is drawn in, without the card it is on.
  defp role({surface, style}) when surface in @surfaces, do: role(style)
  defp role(style), do: style

  defp muted?(style), do: style == :muted or match?({_, :muted}, style)

  defp rgb({r, g, b}), do: "#{r};#{g};#{b}"
end
