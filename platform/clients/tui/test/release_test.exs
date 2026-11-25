defmodule AtlasTui.ReleaseTest do
  # IS-Atlas-76: a running TUI that Control closes as too old ends with the page it showed,
  # for bin/atlas to update it and start it again there; one that cannot be updated says
  # what is true and what to do, and stays closed. Without a terminal: the Console's
  # decisions and the CLI's handoff (console_transport_test.exs and the e2e launcher test
  # run them with a real TUI).
  use ExUnit.Case, async: true
  alias AtlasTui.{CLI, Console, Model, Protocol, View}

  @newer "99.0.0"

  defp welcome,
    do: %{
      "op" => "welcome",
      "env" => "test",
      "spec" => Protocol.version(),
      "surface" => "console"
    }

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

  defp too_old,
    do: %{
      "op" => "bye",
      "reason" => "too_old",
      "spec" => @newer,
      "text" =>
        "This client implements contract #{Protocol.version()}; Control test speaks #{@newer}, and no older one."
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

  test "started by bin/atlas, a TUI closed as too old ends with the page it showed" do
    {shown, "/k/widget"} = booted(model(:restart))
    shown = %{shown | path: "/k/widget/W1"}

    assert {closed, [{:too_old, "/k/widget/W1", @newer}]} = Console.receive(shown, too_old())
    assert closed.closed

    assert closed.notice.text =~
             "Control test speaks #{@newer}; this build is #{Protocol.version()}"
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

  test "a build bin/atlas could not update says what is true and what to do, and stays closed" do
    why = "the pull of develop failed (fatal: unable to access the remote)"
    once = "git -C /atlas pull --ff-only succeeds"
    {shown, _} = booted(model({:not_updated, why, once}))

    assert {closed, []} = Console.receive(shown, too_old())
    assert closed.closed

    text =
      "Control test speaks #{@newer}; this build is #{Protocol.version()} and could not be " <>
        "updated: #{why}. Quit and run atlas again once #{once}."

    assert closed.notice == %{tone: "error", text: text}

    # Also when it is refused at its very first hello (started on a build whose pull
    # failed), and the screen says it.
    assert {first, []} = Console.receive(model({:not_updated, why, once}), too_old())
    assert first.notice.text == text
    assert screen(first) =~ "could not be updated: #{why}"

    # In full, also on a narrow screen: the body says it, wrapped, in place of the page.
    narrow = screen(closed, 60)
    assert narrow |> String.replace(~r/\s+/, " ") =~ "Quit and run atlas again once #{once}."
    refute narrow =~ "First"
  end

  test "a TUI not started by bin/atlas tells its user to run atlas" do
    assert {%{notice: %{text: text}, closed: true}, []} = Console.receive(model(nil), too_old())

    assert text ==
             "Control test speaks #{@newer}; this build is #{Protocol.version()}. " <>
               "Quit and run atlas again: it takes the newest build."
  end

  test "another bye shows Control's text, and nothing restarts" do
    bye = %{"op" => "bye", "text" => "This is Control prod; it does not serve \"test\"."}
    assert {%{notice: %{text: text}, closed: true}, []} = Console.receive(model(:restart), bye)
    assert text == bye["text"]
  end

  test "bin/atlas says how the build takes a newer one; the handoff is the page and both contracts" do
    assert CLI.release(%{}) == nil

    assert CLI.release(%{"ATLAS_TUI_HANDOFF" => "/tmp/h", "ATLAS_UPDATE_FAILED" => ""}) ==
             :restart

    assert CLI.release(%{
             "ATLAS_TUI_HANDOFF" => "/tmp/h",
             "ATLAS_UPDATE_FAILED" => "why",
             "ATLAS_UPDATE_ONCE" => "once"
           }) == {:not_updated, "why", "once"}

    assert CLI.handoff("/k/widget/W1", @newer, "0.24.0") == "/k/widget/W1\n#{@newer}\n0.24.0\n"
    assert CLI.handoff(nil, @newer, "0.24.0") == "\n#{@newer}\n0.24.0\n"
    assert CLI.too_old_status() == 75
  end
end
