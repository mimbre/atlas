defmodule AtlasTui.Clipboard do
  @moduledoc """
  Copies text to the clipboard. On a Mac running the TUI itself, `pbcopy` takes it.
  Elsewhere (over SSH, on Linux) the terminal the TUI is shown in takes it through OSC 52
  (`ESC ] 52 ; c ; <base64> BEL`): Ghostty and other terminals do, and herdr passes it on.
  Inside tmux (`TMUX` set) the same sequence also goes wrapped in tmux's passthrough, which
  tmux forwards when `allow-passthrough` is on; the plain one is taken when
  `set-clipboard` is on.
  """

  @doc """
  Copies `text`: with `pbcopy` when the machine has it (`:pbcopy` overrides where it is,
  nil: none), else by writing `osc52/2` to the terminal.
  """
  def copy(text, opts \\ []) do
    case Keyword.get_lazy(opts, :pbcopy, &pbcopy/0) do
      nil ->
        IO.write(osc52(text, Keyword.get_lazy(opts, :tmux, fn -> System.get_env("TMUX") end)))

      path ->
        System.cmd("/bin/sh", ["-c", ~s|printf %s "$1" \| "$0"|, path, text])
    end

    :ok
  end

  # Only a Mac's own session: over SSH, pbcopy would fill the far Mac's clipboard.
  defp pbcopy do
    if match?({:unix, :darwin}, :os.type()) and System.get_env("SSH_CONNECTION") in [nil, ""],
      do: System.find_executable("pbcopy")
  end

  @doc "The bytes that copy `text`; `tmux` is the `TMUX` environment variable (nil outside tmux)."
  def osc52(text, tmux \\ System.get_env("TMUX")) do
    plain = "\e]52;c;" <> Base.encode64(text) <> "\a"

    if tmux in [nil, ""],
      do: plain,
      else: "\ePtmux;" <> String.replace(plain, "\e", "\e\e") <> "\e\\" <> plain
  end
end
