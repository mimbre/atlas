defmodule AtlasTui.ConsoleTransportTest do
  use ExUnit.Case, async: false
  alias AtlasTui.Protocol

  @moduletag timeout: 30_000
  @moduletag skip: is_nil(System.find_executable("tmux"))

  defp send_message(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp read(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    JSON.decode!(line)
  end

  # `server` is the tmux socket's path, in the temp folder: an agent's sandbox may not write
  # tmux's default socket folder (/tmp/tmux-<uid>).
  defp tmux(server, args) do
    {output, 0} = System.cmd("tmux", ["-S", server | args], stderr_to_stdout: true)
    output
  end

  defp see(server, expected, attempts \\ 100) do
    screen = tmux(server, ["capture-pane", "-p", "-t", "console"])

    cond do
      String.contains?(screen, expected) ->
        screen

      attempts == 0 ->
        flunk("Expected #{inspect(expected)} on screen:\n#{screen}")

      true ->
        Process.sleep(30)
        see(server, expected, attempts - 1)
    end
  end

  defp action(id, key, name, extra \\ %{}) do
    %{
      "id" => id,
      "type" => "console_action",
      "props" => %{
        "label" => id,
        "keys" => [key],
        "operation" => Map.merge(%{"name" => name}, extra),
        "available" => true
      }
    }
  end

  defp content(path) do
    page =
      if path == "/k/widget/new" do
        %{
          "op" => "page",
          "path" => path,
          "title" => "New widget",
          "reason" => "open",
          "blocks" => [
            %{
              "id" => "form",
              "type" => "form",
              "props" => %{
                "title" => "New widget",
                "inputs" => [
                  %{"name" => "title", "label" => "Title", "kind" => "text", "value" => ""}
                ],
                "submit_label" => "Save",
                "submit_to" => %{"endpoint" => "create", "params" => %{"kind" => "widget"}}
              }
            },
            action("focus", "Tab", "focus_next"),
            action("back-focus", "Shift+Tab", "focus_previous")
          ],
          "markup" => [
            %{
              "kind" => "legend",
              "start" => "focus",
              "end" => "back-focus",
              "props" => %{"title" => "Editing", "context" => "form"}
            }
          ]
        }
      else
        %{
          "op" => "page",
          "path" => path,
          "title" => "Widgets",
          "reason" => "open",
          "blocks" => [
            %{
              "id" => "list",
              "type" => "list",
              "props" => %{
                "title" => "Widgets",
                "rows" => [
                  %{"id" => "W1", "label" => "First widget", "to" => "/k/widget/W1"},
                  %{"id" => "W2", "label" => "Second widget", "to" => "/k/widget/W2"}
                ]
              }
            },
            action("next", "Tab", "tab_next"),
            action("previous", "Shift+Tab", "tab_previous"),
            action("down", "Down", "move_next"),
            action("shelves", "g s", "open", %{"to" => "/k/shelf"}),
            action("new", "n", "open", %{"to" => "/k/widget/new"})
          ],
          "markup" => [
            %{
              "kind" => "legend",
              "start" => "next",
              "end" => "new",
              "props" => %{"title" => "Navigation", "context" => "browse"}
            }
          ]
        }
      end

    context = if path == "/k/widget/new", do: "form", else: "browse"

    page = Map.put(page, "actions_revision", "fixture")

    update_in(page["blocks"], fn blocks ->
      Enum.map(blocks, fn
        %{"type" => "console_action"} = action ->
          put_in(action, ["props", "scope"], %{
            "page" => path,
            "revision" => "fixture",
            "context" => context
          })

        block ->
          block
      end)
    end)
  end

  defp shell(target) do
    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => Protocol.version(),
      "revision" => "fixture",
      "initial_to" => target,
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget", "section" => "work"},
        %{"id" => "parts", "label" => "Parts", "to" => "/k/part", "section" => "work"},
        %{"id" => "open", "label" => "Open for you", "to" => "/_open", "section" => "work"},
        %{
          "id" => "shelves",
          "label" => "Shelves",
          "to" => "/k/shelf",
          "section" => "browse",
          "key" => "g s"
        }
      ]
    }
  end

  defp handshake(socket, target) do
    assert %{"op" => "hello", "surface" => "console", "env" => "test"} = read(socket)
    # No immediate reconnect open is sent before welcome/compatibility/boot.
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 60)

    send_message(socket, %{
      "op" => "welcome",
      "surface" => "console",
      "env" => "test",
      "spec" => Protocol.version()
    })

    send_message(socket, content("/"))
    assert %{"op" => "boot"} = read(socket)
    send_message(socket, shell(target))
    assert %{"op" => "open", "to" => ^target} = read(socket)
    send_message(socket, content(target))
  end

  test "group filters render and navigate in a real terminal" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    server = Path.join(System.tmp_dir!(), "atlas-filters-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :gen_tcp.close(listener)
      System.cmd("tmux", ["-S", server, "kill-server"], stderr_to_stdout: true)
    end)

    settings = %{"control" => %{"host" => "127.0.0.1", "port" => port}, "reconcile_seconds" => 60}
    expression = "AtlasTui.App.run(\"test\", #{inspect(settings)})"

    tmux(server, [
      "new-session",
      "-d",
      "-s",
      "console",
      "-x",
      "90",
      "-y",
      "24",
      "env ELIXIR_ERL_OPTIONS='+S 2:2' mix run -e '#{expression}'"
    ])

    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    handshake(socket, "/k/widget")
    see(server, "First widget")

    page = content("/k/widget")

    groups = %{
      "id" => "groups",
      "type" => "groups",
      "props" => %{
        "groups" => [
          %{"label" => "All", "count" => 2, "to" => "/k/widget", "active" => true},
          %{"label" => "Ready", "count" => 1, "to" => "/k/widget/ready", "active" => false}
        ]
      }
    }

    next =
      action("next-group", "]", "open", %{"to" => "/k/widget/ready"})
      |> put_in(["props", "scope"], %{
        "page" => "/k/widget",
        "revision" => "fixture",
        "context" => "browse"
      })

    page = %{
      page
      | "blocks" => [groups | page["blocks"]] ++ [next],
        "markup" =>
          page["markup"] ++
            [
              %{
                "kind" => "legend",
                "start" => "next-group",
                "end" => "next-group",
                "props" => %{"title" => "Filters", "context" => "browse"}
              }
            ]
    }

    send_message(socket, page)
    screen = see(server, "[• All 2] [Ready 1]")
    assert length(Regex.scan(~r/\[Ready 1\]/, screen)) == 1
    tmux(server, ["resize-window", "-t", "console", "-x", "48", "-y", "24"])
    see(server, "[• All 2] [Ready 1]")
    tmux(server, ["send-keys", "-t", "console", "-l", "]"])
    assert %{"op" => "open", "to" => "/k/widget/ready"} = read(socket)
    :gen_tcp.close(socket)
  end

  test "legacy details sections stay visible without a disclosure shortcut" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    server = Path.join(System.tmp_dir!(), "atlas-console-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :gen_tcp.close(listener)
      System.cmd("tmux", ["-S", server, "kill-server"], stderr_to_stdout: true)
    end)

    settings = %{"control" => %{"host" => "127.0.0.1", "port" => port}, "reconcile_seconds" => 60}
    expression = "AtlasTui.App.run(\"test\", #{inspect(settings)})"

    tmux(server, [
      "new-session",
      "-d",
      "-s",
      "console",
      "-x",
      "90",
      "-y",
      "35",
      "env ELIXIR_ERL_OPTIONS='+S 2:2' mix run -e '#{expression}'"
    ])

    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    handshake(socket, "/k/widget")

    item = fn id, value ->
      %{
        "id" => id,
        "type" => "item",
        "props" => %{"title" => value, "fields" => [%{"label" => "", "value" => value}]}
      }
    end

    page = content("/k/widget")
    scope = %{"page" => "/k/widget", "revision" => "fixture", "context" => "browse"}
    legacy = put_in(action("legacy-toggle", "d", "sections_toggle"), ["props", "scope"], scope)
    future = put_in(action("future", "z", "future_operation"), ["props", "scope"], scope)
    refresh = put_in(action("refresh", "r", "refresh"), ["props", "scope"], scope)

    page = %{
      page
      | "blocks" => [
          item.("main", "Summary"),
          item.("first", "First technical"),
          item.("second", "Second technical"),
          legacy,
          future,
          refresh
        ],
        "markup" => [
          %{
            "kind" => "part",
            "start" => "main",
            "end" => "main",
            "props" => %{"title" => "Main", "role" => "main"}
          },
          %{
            "kind" => "part",
            "start" => "first",
            "end" => "second",
            "props" => %{"title" => "Details", "role" => "details"}
          },
          %{
            "kind" => "section",
            "start" => "first",
            "end" => "second",
            "props" => %{"title" => "Technical details", "collapsible" => true}
          },
          %{
            "kind" => "legend",
            "start" => "legacy-toggle",
            "end" => "refresh",
            "props" => %{"title" => "Navigation", "context" => "browse"}
          }
        ]
    }

    send_message(socket, page)
    shown = see(server, "Second technical")
    assert shown =~ "First technical"
    assert shown =~ "Technical details"
    refute shown =~ "▸ Technical details"
    refute shown =~ "▾ Technical details"
    tmux(server, ["send-keys", "-t", "console", "d"])
    shown = see(server, "Second technical")
    assert shown =~ "First technical"
    tmux(server, ["send-keys", "-t", "console", "C-c"])
    :gen_tcp.close(socket)
  end

  test "native app negotiates boot, draws tabs, cycles, resizes and reconnects a real edited draft" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    server = Path.join(System.tmp_dir!(), "atlas-console-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :gen_tcp.close(listener)
      System.cmd("tmux", ["-S", server, "kill-server"], stderr_to_stdout: true)
    end)

    settings = %{"control" => %{"host" => "127.0.0.1", "port" => port}, "reconcile_seconds" => 60}
    expression = "AtlasTui.App.run(\"test\", #{inspect(settings)})"
    # Only the freshly compiled client and a loopback fixture server run here.
    args = [
      "new-session",
      "-d",
      "-s",
      "console",
      "-x",
      "90",
      "-y",
      "24",
      "env ELIXIR_ERL_OPTIONS='+S 2:2' mix run -e '#{expression}'"
    ]

    tmux(server, args)
    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    handshake(socket, "/k/widget")
    see(server, "First widget")
    see(server, "▸ Widgets")
    tmux(server, ["send-keys", "-t", "console", "Down"])
    see(server, "› W2")
    tmux(server, ["send-keys", "-t", "console", "BTab"])
    assert %{"op" => "open", "to" => "/_open"} = read(socket)
    send_message(socket, content("/_open"))
    see(server, "First widget")
    see(server, "▸ Open for you")
    tmux(server, ["resize-window", "-t", "console", "-x", "20", "-y", "24"])
    narrow = see(server, "▸ Open for you")
    assert narrow =~ "‹"
    tmux(server, ["resize-window", "-t", "console", "-x", "90", "-y", "24"])
    tmux(server, ["send-keys", "-t", "console", "Tab"])
    assert %{"op" => "open", "to" => "/k/widget"} = read(socket)
    send_message(socket, content("/k/widget"))
    see(server, "First widget")
    wide = see(server, "▸ Widgets")
    tmux(server, ["send-keys", "-t", "console", "n"])
    assert %{"op" => "open", "to" => "/k/widget/new"} = read(socket)
    send_message(socket, content("/k/widget/new"))
    see(server, "New widget")
    tmux(server, ["send-keys", "-t", "console", "-l", "draft? intact"])
    see(server, "draft? intact")
    :gen_tcp.close(socket)
    see(server, "stale shell")
    {:ok, reconnected} = :gen_tcp.accept(listener, 5_000)
    handshake(reconnected, "/k/widget/new")
    restored = see(server, "draft? intact")
    assert restored =~ "▸ Widgets"
    refute restored =~ "Home"

    if folder = System.get_env("ATLAS_CONSOLE_PROOF") do
      File.mkdir_p!(folder)

      for {name, screen} <- [
            {"native-wide", wide},
            {"native-narrow", narrow},
            {"native-restored-draft", restored}
          ],
          do: File.write!(Path.join(folder, "#{name}.txt"), screen)
    end

    tmux(server, ["send-keys", "-t", "console", "C-c"])
    :gen_tcp.close(reconnected)
  end

  test "tabs react before delayed replies and superseded content never replaces the selected tab" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    server = Path.join(System.tmp_dir!(), "atlas-tabs-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :gen_tcp.close(listener)
      System.cmd("tmux", ["-S", server, "kill-server"], stderr_to_stdout: true)
    end)

    settings = %{"control" => %{"host" => "127.0.0.1", "port" => port}, "reconcile_seconds" => 60}
    expression = "AtlasTui.App.run(\"test\", #{inspect(settings)})"

    tmux(server, [
      "new-session",
      "-d",
      "-s",
      "console",
      "-x",
      "90",
      "-y",
      "24",
      "env ELIXIR_ERL_OPTIONS='+S 2:2' mix run -e '#{expression}'"
    ])

    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    handshake(socket, "/k/widget")
    see(server, "First widget")

    tmux(server, ["send-keys", "-t", "console", "Tab"])
    assert %{"op" => "open", "to" => "/k/part"} = read(socket)
    pending = see(server, "Loading")
    assert pending =~ "▸ Parts"
    refute pending =~ "First widget"

    tmux(server, ["send-keys", "-t", "console", "Tab"])
    see(server, "▸ Open for you")
    tmux(server, ["send-keys", "-t", "console", "Tab"])
    see(server, "▸ Widgets")
    tmux(server, ["send-keys", "-t", "console", "BTab"])
    see(server, "▸ Open for you")
    # The server has not answered: no intermediate opens are queued.
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    send_message(socket, Map.put(content("/k/widget"), "reason", "hint"))
    send_message(socket, content("/k/part"))
    assert %{"op" => "open", "to" => "/_open"} = read(socket)
    superseded = see(server, "Loading")
    assert superseded =~ "▸ Open for you"
    refute superseded =~ "First widget"
    send_message(socket, Map.put(content("/k/part"), "reason", "reconcile"))
    send_message(socket, content("/_open"))
    loaded = see(server, "First widget")
    assert loaded =~ "▸ Open for you"
    assert loaded =~ "│   Shelves g s"

    # g then s opens the browse tab its key names; Tab from there is back to work.
    tmux(server, ["send-keys", "-t", "console", "g"])
    see(server, "g … · Esc to cancel")
    tmux(server, ["send-keys", "-t", "console", "s"])
    assert %{"op" => "open", "to" => "/k/shelf"} = read(socket)
    send_message(socket, content("/k/shelf"))
    see(server, "▸ Shelves")
    tmux(server, ["send-keys", "-t", "console", "Tab"])
    assert %{"op" => "open", "to" => "/k/widget"} = read(socket)

    if folder = System.get_env("ATLAS_CONSOLE_PROOF") do
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "tabs-pending.txt"), pending)
      File.write!(Path.join(folder, "tabs-superseded.txt"), superseded)
      File.write!(Path.join(folder, "tabs-loaded.txt"), loaded)
    end

    tmux(server, ["send-keys", "-t", "console", "C-c"])
    :gen_tcp.close(socket)
  end
end
