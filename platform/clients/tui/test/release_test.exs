defmodule AtlasTui.ReleaseTest do
  # IS-Atlas-76, D-0105: any Control welcomes this TUI, whatever contract it speaks. One on
  # a newer contract makes a TUI started by bin/atlas end with the page it showed, for
  # bin/atlas to update it and start it again there; one that cannot be updated stays,
  # shows what it knows, and its status line says the versions and why. Without a terminal:
  # the Console's decisions and the CLI's handoff (console_transport_test.exs and the e2e
  # launcher test run them with a real TUI).
  use ExUnit.Case, async: true
  alias AtlasTui.{CLI, Console, Model, Protocol, View}

  @newer "99.0.0"

  defp welcome(spec \\ Protocol.version()),
    do: %{"op" => "welcome", "env" => "test", "spec" => spec, "surface" => "console"}

  defp page(path),
    do: %{
      "op" => "page",
      "path" => path,
      "title" => "Widgets",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "widgets",
          "type" => "list",
          "props" => %{"title" => "Widgets", "rows" => [%{"id" => "W1", "label" => "First"}]}
        }
      ]
    }

  defp boot,
    do: %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => Protocol.version(),
      "revision" => "rev1",
      "initial_to" => "/k/widget",
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget", "section" => "work"}
      ]
    }

  defp model(release, start_to \\ nil) do
    model = %{Model.new("test") | release: release}
    put_in(model.console.start_to, start_to)
  end

  # Welcome, the compatibility page, boot: what the TUI opens first.
  defp booted(model) do
    {model, []} = Console.receive(model, welcome())
    {model, [{:send, %{"op" => "boot"}}]} = Console.receive(model, page("/"))
    {model, [{:send, %{"op" => "open", "to" => to}}]} = Console.receive(model, boot())
    {model, _} = Console.receive(model, page(to))
    {model, to}
  end

  defp screen(model, width \\ 160), do: model |> View.render(width, 20, 5) |> View.plain()

  test "started by bin/atlas, a TUI welcomed by a newer Control ends with the page it showed" do
    {shown, "/k/widget"} = booted(model(:restart))
    shown = %{Console.disconnected(shown) | path: "/k/widget/W1"}

    assert {updating, [{:update, "/k/widget/W1", @newer}]} =
             Console.receive(shown, welcome(@newer))

    assert updating.connected
    assert screen(updating) =~ "test speaks 99.0, this TUI #{short()} · updating"
  end

  test "started on the page it showed, it opens that page after boot, once" do
    {model, to} = booted(model(:restart, "/k/widget/W1"))
    assert to == "/k/widget/W1"
    assert model.console.start_to == nil

    # A later reconnect opens what Control's boot says, as before.
    model = Console.disconnected(model)
    {model, []} = Console.receive(model, welcome())
    {model, [{:send, %{"op" => "boot"}}]} = Console.receive(model, page("/"))
    assert {_, [{:send, %{"op" => "open", "to" => "/k/widget"}}]} = Console.receive(model, boot())
  end

  test "a build bin/atlas could not update stays connected and says so in its status line" do
    why = "the pull of develop failed (fatal: unable to access the remote)"
    model = model({:not_updated, why})
    assert {connected, []} = Console.receive(model, welcome(@newer))
    assert connected.connected
    {connected, [{:send, %{"op" => "boot"}}]} = Console.receive(connected, page("/"))
    {connected, [{:send, %{"op" => "open", "to" => to}}]} = Console.receive(connected, boot())
    {connected, _} = Console.receive(connected, page(to))

    assert screen(connected, 240) =~
             "test speaks 99.0, this TUI #{short()} · not updated: #{why}; some parts may look plain"

    # Its pages still show.
    assert screen(connected, 240) =~ "First"
  end

  test "a TUI not started by bin/atlas stays, and says how to update" do
    assert {connected, []} = Console.receive(model(nil), welcome(@newer))
    assert screen(connected) =~ "some parts may look plain; run atlas again to update"
  end

  test "a TUI newer than Control stays, and says so; the same version says nothing" do
    assert {newer, []} = Console.receive(model(:restart), welcome("0.1.0"))
    assert newer.connected
    assert screen(newer) =~ "this TUI is newer than test (#{short()} vs 0.1)"

    assert {same, []} = Console.receive(model(:restart), welcome())
    refute screen(same) =~ "this TUI"
    refute screen(same) =~ "speaks"
  end

  defp short, do: String.replace_suffix(Protocol.version(), ".0", "")

  test "another bye shows Control's text, and nothing restarts" do
    bye = %{"op" => "bye", "text" => "This is Control prod; it does not serve \"test\"."}
    assert {%{notice: %{text: text}, closed: true}, []} = Console.receive(model(:restart), bye)
    assert text == bye["text"]
  end

  test "bin/atlas says how the build takes a newer one; the handoff is the page and both contracts" do
    assert CLI.release(%{}) == nil

    assert CLI.release(%{"ATLAS_TUI_HANDOFF" => "/tmp/h", "ATLAS_UPDATE_FAILED" => ""}) ==
             :restart

    assert CLI.release(%{"ATLAS_TUI_HANDOFF" => "/tmp/h", "ATLAS_UPDATE_FAILED" => "why"}) ==
             {:not_updated, "why"}

    assert CLI.handoff("/k/widget/W1", @newer, "0.24.0") == "/k/widget/W1\n#{@newer}\n0.24.0\n"
    assert CLI.handoff(nil, @newer, "0.24.0") == "\n#{@newer}\n0.24.0\n"
    assert CLI.update_status() == 75
  end
end
