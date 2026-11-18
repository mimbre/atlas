defmodule AtlasE2E.Pull.Console do
  @moduledoc """
  The TUI as melle, for what only a TUI session does: Pick up and Hand over… (only a TUI
  session sets supervision, `AtlasControl.Session`). One real TUI in tmux
  (`AtlasE2E.Tui`, its socket under `<run>/tmp` through `TMPDIR`), and a tmux control-mode
  client (`tmux -C attach`) as a `Reader`: each `%output` line is a `:console` event, which
  is what re-reads the screen. No wait here sleeps: a key is followed by a wait for the
  screen to change (`AtlasE2E.Pull.Await`). The screen is used to navigate only; what a
  scenario asserts is read from facts.
  """
  alias AtlasE2E.{Tui}
  alias AtlasE2E.Pull.{Bench, Hub, Reader}

  defstruct [:tui, :socket, :reader, :server_pid]

  # The product's generated shell: the tabs a client opens with, as Control boots them
  # (`AtlasControl.Shell`). The bench finds a tab by its page, never by its words.
  @shell_file Path.expand(
                "../../../../model/targets/rela/atlas.json",
                __DIR__
              )
  @external_resource @shell_file
  @open_for_you "/_open"
  @supervised_by_you "/_supervised"

  @doc "The product shell's tabs, in order: `[%{\"id\", \"label\", \"to\"}]`."
  def tabs, do: @shell_file |> File.read!() |> JSON.decode!() |> get_in(["shell", "tabs"])

  @doc "The label of the shell's tab that opens `to` (a page path); raises when none does."
  def tab_label(tabs \\ tabs(), to) do
    case Enum.find(tabs, &(&1["to"] == to)) do
      %{"label" => label} -> label
      nil -> raise "the product's shell has no tab for #{to}: #{inspect(tabs)}"
    end
  end

  @doc """
  The tab the screen shows as active, as a label of `tabs`, or nil: the tab bar is the line
  that shows every tab's label, the active one marked `▸ `.
  """
  def active_tab(screen, tabs \\ tabs()) do
    labels = Enum.map(tabs, & &1["label"])

    with bar when is_binary(bar) <-
           screen
           |> String.split("\n")
           |> Enum.find(fn line -> Enum.all?(labels, &String.contains?(line, &1)) end) do
      Enum.find(labels, &String.contains?(bar, "▸ " <> &1))
    end
  end

  @doc """
  Move to the shell's tab that opens `to` (Tab, the Console's Next tab, one at a time, each
  waiting for the screen it causes), then wait until it is connected and showing it.
  """
  def tab(c, to) do
    tabs = tabs()
    label = tab_label(tabs, to)

    Enum.reduce_while(0..length(tabs), nil, fn _, _ ->
      if active_tab(ready(c), tabs) == label do
        {:halt, :active}
      else
        press(c, "Tab")
        {:cont, nil}
      end
    end) || raise "the TUI never showed the tab #{label}:\n#{screen(c)}"

    ready(c)
  end

  def start(run, instance) do
    socket = "pe-tui"
    sock_path = Tui.server(socket) |> List.last()
    Bench.record(run, "tmux_socket", %{socket: sock_path})
    # Tied to the run before it starts: a setup that fails from here on still ends it (a
    # kill-server with no server is only a status).
    Bench.started("tmux server", fn -> Tui.kill_server(socket) end)
    tui = Tui.start(instance, socket, "tui1", "TUI")

    {pid, 0} =
      Bench.bounded("tmux", Tui.server(socket) ++ ["display-message", "-p", "\#{pid}"],
        within: 10_000
      )

    server_pid = pid |> String.trim() |> String.to_integer()
    Bench.record(run, "tmux", %{pid: server_pid})

    {:ok, reader} =
      Reader.start_link(
        command: System.find_executable("tmux"),
        args: Tui.server(socket) ++ ["-C", "attach", "-t", "tui1"],
        source: :console,
        name: "tmux-control",
        stub: Path.join(run, "bin/pull-stub"),
        run: run
      )

    %__MODULE__{tui: tui, socket: socket, reader: reader, server_pid: server_pid}
  end

  def stop(%__MODULE__{} = c) do
    Reader.stop(c.reader)
    Tui.kill_server(c.socket)
    :ok
  end

  def screen(%__MODULE__{tui: tui}), do: Tui.screen(tui)

  @doc "The screen once `check` holds for it, re-read on every event."
  def await(%__MODULE__{} = c, check, label) do
    AtlasTestAwait.until(
      fn ->
        screen = screen(c)
        if check.(screen), do: screen
      end,
      wake: {:subscribe, fn -> Hub.subscribe() end},
      cap: Bench.remaining(),
      label: "the TUI to #{label}",
      state: fn -> %{screen: screen(c)} end
    )
  end

  @doc "Press keys and wait for the screen to change."
  def press(%__MODULE__{} = c, keys) do
    before = screen(c)
    Tui.keys(c.tui, List.wrap(keys))
    await(c, &(&1 != before), "change after #{inspect(keys)}")
  end

  @doc "Connected and showing content (not a loading page)."
  def ready(c) do
    await(
      c,
      fn s ->
        s =~ ~r/● connected · / and not String.contains?(s, ["Loading…", "Waiting for Control…"])
      end,
      "be connected"
    )
  end

  @doc """
  Open the row showing `text` on the current list (moving the selection down to it), then
  the page it leads to (which must show `key`).
  """
  def open_row(c, text, key) do
    await(c, &String.contains?(&1, text), "show #{text}")

    Enum.reduce_while(1..60, nil, fn _, _ ->
      screen = screen(c)

      if selected?(screen, text) do
        {:halt, :found}
      else
        press(c, "Down")
        {:cont, nil}
      end
    end) || raise "the TUI never selected the row #{text}:\n#{screen(c)}"

    press(c, "Enter")
    await(c, &String.contains?(&1, key), "open #{key}")
  end

  defp selected?(screen, text),
    do:
      screen
      |> String.split("\n")
      |> Enum.any?(&(String.contains?(&1, "› ") and String.contains?(&1, text)))

  @doc """
  Pick up the issue `subject` from Open for you (`p`, then the confirm's submit). An issue
  nobody supervises yet is listed there (Control's `/_open`: its run in the issue build's
  span, no human supervisor), not on the start page (Assigned to you: its Assignment names
  nobody; gatefix round 2).
  """
  def pick_up(c, subject) do
    home(c)
    tab(c, @open_for_you)
    open_row(c, subject.issue_title, subject.issue)
    press(c, "p")
    await(c, &String.contains?(&1, "#{subject.issue}?"), "ask to pick up #{subject.issue}")
    press(c, "C-s")
    :ok
  end

  @doc """
  Hand the issue `subject` over to `to` (its display name) from its page (`v`), reached
  from Supervised by you (Control's `/_supervised`), where an issue melle picked up is.
  """
  def hand_over(c, subject, to) do
    home(c)
    tab(c, @supervised_by_you)
    open_row(c, subject.issue_title, subject.issue)
    press(c, "v")
    await(c, &String.contains?(&1, to), "offer #{to}")

    Enum.reduce_while(1..20, nil, fn _, _ ->
      if selected?(screen(c), to),
        do: {:halt, :found},
        else:
          (
            press(c, "Down")
            {:cont, nil}
          )
    end) || raise "the hand-over form never selected #{to}:\n#{screen(c)}"

    press(c, "C-s")
    :ok
  end

  @doc """
  Back to the start page: the Keys legend (`?`) says whether Back is available; while it
  is, Escape, and wait for the page to change. Every key waits for the screen it causes.
  """
  def home(c) do
    Enum.reduce_while(1..30, nil, fn _, _ ->
      ready(c)
      legend = legend(c)

      if legend =~ "Back · unavailable" do
        {:halt, :home}
      else
        press(c, "Escape")
        {:cont, nil}
      end
    end) || raise "the TUI never got back to its start page:\n#{screen(c)}"

    ready(c)
  end

  defp legend(c) do
    press(c, "?")
    first = await(c, &String.contains?(&1, "Close keys"), "show its keys")

    pages =
      Enum.reduce_while(1..20, [first], fn _, [page | _] = pages ->
        if page =~ ~r/↓ \d+ below/, do: {:cont, [press(c, "NPage") | pages]}, else: {:halt, pages}
      end)

    press(c, "Escape")
    await(c, &(not String.contains?(&1, "Close keys")), "close its keys")
    pages |> Enum.reverse() |> Enum.join("\n")
  end
end
