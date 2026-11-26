defmodule AtlasTui.Clipboard do
  @moduledoc """
  Copies text to the clipboard of the terminal the TUI is shown in, with OSC 52 (`ESC ]
  52 ; c ; <base64> BEL`): Ghostty and other terminals take it, over SSH too, and herdr
  passes it on. Inside tmux (`TMUX` set) the same sequence also goes wrapped in tmux's
  passthrough, which tmux forwards when `allow-passthrough` is on; the plain one is taken
  when `set-clipboard` is on.
  """

  @doc "The bytes that copy `text`; `tmux` is the `TMUX` environment variable (nil outside tmux)."
  def osc52(text, tmux \\ System.get_env("TMUX")) do
    plain = "\e]52;c;" <> Base.encode64(text) <> "\a"

    if tmux in [nil, ""],
      do: plain,
      else: "\ePtmux;" <> String.replace(plain, "\e", "\e\e") <> "\e\\" <> plain
  end
end
