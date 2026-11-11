defmodule AtlasE2E.Tui do
  @moduledoc """
  Console negotiation and contextual actions run against the same real Control as
  the native Console transport scenarios.
  One real TUI, started with `atlas tui --env test` in a tmux pane of its own (on a tmux server of
  this run only, so no session of anyone else is touched). Keys go in with
  `tmux send-keys`; the screen comes out with `tmux capture-pane`.
  """

  defstruct [:name, :socket, :label]

  @width 100
  @height 30

  def start(instance, socket, name, label) do
    command =
      Enum.map_join(instance.env, " ", fn {k, v} -> "#{k}=#{v}" end) <>
        " " <> Path.join(instance.root, "bin/atlas") <> " tui --env test"

    tmux!(socket, [
      "new-session",
      "-d",
      "-s",
      name,
      "-x",
      "#{@width}",
      "-y",
      "#{@height}",
      "env " <> command
    ])

    %__MODULE__{name: name, socket: socket, label: label}
  end

  @doc "Type text as it is (a leading `-` is text, not a flag)."
  def type(tui, text), do: tmux!(tui.socket, ["send-keys", "-t", tui.name, "-l", "--", text])

  @doc "Press keys by their tmux names: Enter, Escape, Up, Down, C-s, BSpace, NPage, …"
  def keys(tui, keys), do: tmux!(tui.socket, ["send-keys", "-t", tui.name | keys])

  @doc "Make the TUI's terminal `width` × `height`, as a person resizing the window does."
  def resize(tui, width, height),
    do:
      tmux!(tui.socket, [
        "resize-window",
        "-t",
        tui.name,
        "-x",
        "#{width}",
        "-y",
        "#{height}"
      ])

  def screen(tui) do
    {out, _} = tmux(tui.socket, ["capture-pane", "-p", "-t", tui.name])
    out
  end

  def kill_server(socket), do: tmux(socket, ["kill-server"])

  defp tmux!(socket, args) do
    case tmux(socket, args) do
      {_, 0} -> :ok
      {out, status} -> raise "tmux #{hd(args)} failed (#{status}): #{out}"
    end
  end

  defp tmux(socket, args),
    do: System.cmd("tmux", ["-L", socket | args], stderr_to_stdout: true)
end
