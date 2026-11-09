defmodule AtlasTui.ModeGenerationTest do
  # Synthetic widget page captured from actual AtlasControl.Console.project at
  # IS120 1f95321. Shared Contract.compile/capture/resolve run unchanged here.
  # No server, Facts, Runtime or agent process is started.
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Interactions}

  defp ready do
    model = Model.new("test")

    model = %{
      model
      | connected: true,
        console: %{
          model.console
          | phase: :ready,
            stale: false,
            shell: %{"revision" => "shell1", "tabs" => []}
        }
    }

    page = Path.join(__DIR__, "fixtures/console-actions.json") |> File.read!() |> JSON.decode!()
    {model, []} = Console.receive(model, page)
    assert model.console.projection != nil
    model
  end

  test "captured send must expire after cancelling and reopening request editor" do
    {old, []} = Model.key(ready(), {:char, ":"})
    {old, []} = Model.key(old, {:char, "A"})
    event = Interactions.capture(old, :enter)
    assert event != nil
    {cancelled, []} = Model.key(old, :esc)
    {reopened, []} = Model.key(cancelled, {:char, ":"})
    {reopened, []} = Model.key(reopened, {:char, "B"})
    assert reopened.ask == "B"
    # The captured action from editor A must never submit editor B.
    {after_dispatch, effects} = Interactions.dispatch(reopened, event)
    assert effects == []
    assert after_dispatch == reopened
  end

  test "captured browse event must expire after a complete request editor cycle" do
    model = ready()
    event = Interactions.capture(model, {:char, ":"})
    {ask, []} = Model.key(model, {:char, ":"})
    {back, []} = Model.key(ask, :esc)
    {after_dispatch, effects} = Interactions.dispatch(back, event)
    assert effects == []
    assert after_dispatch.ask == nil
  end

  test "actual request draft survives compatibility, failed boot and successful reconnect" do
    {draft, []} = Model.key(ready(), {:char, ":"})
    {draft, []} = Model.key(draft, {:char, "?"})
    model = Model.disconnected(draft)

    welcome = %{
      "op" => "welcome",
      "env" => "test",
      "spec" => AtlasTui.Protocol.version(),
      "surface" => "console"
    }

    {model, []} = Console.receive(model, welcome)
    page = Path.join(__DIR__, "fixtures/console-actions.json") |> File.read!() |> JSON.decode!()
    {model, [_]} = Console.receive(model, Map.put(page, "path", "/"))
    assert model.ask == "?"
    {model, []} = Console.receive(model, %{"op" => "boot", "error" => "private unavailable"})
    assert model.console.stale
    assert model.ask == "?"
    {model, [_]} = Console.refresh(model)

    shell = %{
      "op" => "boot",
      "title" => "Private",
      "env" => "test",
      "spec" => AtlasTui.Protocol.version(),
      "revision" => "new",
      "initial_to" => "/k/widget",
      "tabs" => [%{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"}]
    }

    {model, [_]} = Console.receive(model, shell)
    {model, []} = Console.receive(model, page)
    assert model.ask == "?"
    assert model.console.phase == :ready
    assert model.console.generation > draft.console.generation
  end

  test "capture denies new context and disconnected execution immediately" do
    model = ready()
    event = Interactions.capture(model, {:char, ":"})
    {ask, []} = Model.key(model, {:char, ":"})
    assert Interactions.dispatch(ask, event) == {ask, []}
    disconnected = Model.disconnected(model)
    assert Interactions.dispatch(disconnected, event) == {disconnected, []}
  end

  defp proposal do
    %{
      "op" => "plan",
      "block" => %{
        "type" => "plan",
        "props" => %{
          "title" => "Proposal",
          "request" => "example",
          "state" => "proposed",
          "steps" => [
            %{
              "n" => 1,
              "label" => "Example",
              "state" => "proposed",
              "inputs" => [
                %{"name" => "title", "label" => "Title", "kind" => "text", "value" => "One"}
              ]
            }
          ]
        }
      }
    }
  end

  defp proposed do
    {planning, [_]} = Model.agent_action(ready(), "example", "example")
    Model.agent(planning, proposal())
  end

  test "step save and cancel cycles expire old editor and proposal events" do
    for exit <- [:esc, :ctrl_s] do
      model = proposed()
      edit = Interactions.capture(model, {:char, "e"})
      assert edit != nil
      {editing, []} = Model.key(model, {:char, "e"})
      save = Interactions.capture(editing, :ctrl_s)
      assert save != nil
      {editing, []} = Model.key(editing, {:char, "!"})
      {back, []} = Model.key(editing, exit)
      assert Interactions.dispatch(back, edit) == {back, []}
      {reopened, []} = Model.key(back, {:char, "e"})
      {reopened, []} = Model.key(reopened, {:char, "?"})
      assert Interactions.dispatch(reopened, save) == {reopened, []}
      assert reopened.values["title"] == if(exit == :ctrl_s, do: "One!?", else: "One?")
      assert reopened.focus == 0
      assert reopened.console.generation > editing.console.generation
    end
  end

  test "replacement plans and plan cancellation never revive an old proposed action" do
    model = proposed()
    run = Interactions.capture(model, :enter)
    assert run != nil
    replaced = Model.agent(model, proposal())
    assert Interactions.dispatch(replaced, run) == {replaced, []}
    {closed, [_]} = Model.key(replaced, :esc)
    {planning, [_]} = Model.agent_action(closed, "example", "example")
    reopened = Model.agent(planning, proposal())
    assert Interactions.dispatch(reopened, run) == {reopened, []}
    failed = Model.agent_gone(planning, "fixture stopped")
    assert failed.console.generation > planning.console.generation
    assert Interactions.context(failed) == "plan_done"
  end
end
