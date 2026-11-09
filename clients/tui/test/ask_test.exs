defmodule AtlasTui.AskTest do
  @moduledoc "`:` asks the agent; its plan shows over the page (UC-Atlas-17)."
  use ExUnit.Case, async: true

  alias AtlasTui.{ConsoleProjectionFixture, Interactions, Model, View}

  # A page, and what the agent sends, by hand; the kind is made up.
  @page %{
    "op" => "page",
    "path" => "/k/thing/T-1",
    "title" => "Thing T-1",
    "back" => "/k/thing",
    "reason" => "open",
    "blocks" => [
      %{
        "type" => "item",
        "props" => %{"title" => "Thing T-1: First", "fields" => [], "actions" => []}
      }
    ]
  }

  defp step(n, title, state \\ "proposed") do
    %{
      "n" => n,
      "label" => "Create part in T-1",
      "state" => state,
      "why" => "Asked.",
      "inputs" => [
        %{"name" => "title", "label" => "Title", "kind" => "text", "value" => title},
        %{"name" => "notes", "label" => "Notes", "kind" => "multiline", "value" => "n#{n}"}
      ]
    }
  end

  defp plan(state, steps, extra \\ %{}) do
    props =
      Map.merge(
        %{"title" => "Proposed", "request" => "make parts", "state" => state, "steps" => steps},
        extra
      )

    %{"op" => "plan", "block" => %{"id" => "plan", "type" => "plan", "props" => props}}
  end

  defp model, do: ConsoleProjectionFixture.model(@page)

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {m, effects} ->
      {m, more} = Model.key(m, key)
      {m, effects ++ more}
    end)
  end

  defp type(text), do: Enum.map(String.graphemes(text), &{:char, &1})
  defp screen(model), do: model |> View.render(100, 40, 5) |> View.plain()

  defp asked do
    {m, [{:agent, ask}]} = press(model(), [{:char, ":"}] ++ type("make parts") ++ [:enter])
    {m, ask}
  end

  test "`:` opens the request line; enter asks about the page, esc closes it" do
    {m, []} = press(model(), [{:char, ":"}] ++ type("make partz") ++ [:backspace, {:char, "s"}])
    assert m.ask == "make parts"
    assert Interactions.capture(m, :enter) != nil

    {closed, []} = press(m, [:esc])
    assert closed.ask == nil

    {m, ask} = asked()
    assert ask == %{"op" => "ask", "request" => "make parts", "on" => "/k/thing/T-1"}
    assert screen(m) =~ "Planning…"
    assert {%{plan: nil}, [{:agent, %{"op" => "cancel"}}]} = press(m, [:esc])
  end

  test "the plan shows each step with its form's title and values" do
    {m, _} = asked()

    m =
      Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")], %{"by" => "a stand-in"}))

    text = screen(m)
    assert text =~ "You asked       make parts"
    assert text =~ "By              a stand-in"
    assert text =~ "› [✓] 1. Create part in T-1"
    assert text =~ "Title"
    assert text =~ "Two"
    assert text =~ "why: Asked."
  end

  test "drop one, edit another, enter runs the kept ones with the edited values" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two"), step(3, "Three")]))

    # Drop step 2; edit step 3's title in the step's form, keep it with ctrl-s.
    {m, []} = press(m, [:down, {:char, " "}, :down, {:char, "e"}])
    assert screen(m) =~ "Step 3: Create part in T-1"
    assert screen(m) =~ "[ Keep ]"
    {m, []} = press(m, type("!") ++ [:ctrl_s])
    assert m.steps.editing == nil
    text = screen(m)
    assert text =~ "[ ] 2. Create part in T-1"
    assert text =~ "Three!"

    {_, [{:agent, run}]} = press(m, [:enter])

    assert run == %{
             "op" => "run",
             "steps" => [
               %{"n" => 1, "values" => %{"title" => "One", "notes" => "n1"}},
               %{"n" => 3, "values" => %{"title" => "Three!", "notes" => "n3"}}
             ]
           }
  end

  test "esc in a step's form leaves its values as they were" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One")]))
    {m, []} = press(m, [{:char, "e"}] ++ type("xx") ++ [:esc])
    assert m.steps.editing == nil
    {_, [{:agent, %{"steps" => [%{"values" => %{"title" => "One"}}]}}]} = press(m, [:enter])
  end

  test "background page updates preserve a step's draft, including an empty title" do
    for reason <- ["hint", "reconcile"] do
      {m, _} = asked()
      m = Model.agent(m, plan("proposed", [step(1, "One")]))
      {m, []} = press(m, [{:char, "e"}, :backspace, :backspace, :backspace])
      assert m.values == %{"title" => "", "notes" => "n1"}

      {m, []} = ConsoleProjectionFixture.receive(m, Map.put(@page, "reason", reason))
      assert m.values == %{"title" => "", "notes" => "n1"}
      assert m.steps.editing == 1
      {m, []} = press(m, [:ctrl_s])
      {_, [{:agent, run}]} = press(m, [:enter])
      assert run["steps"] == [%{"n" => 1, "values" => %{"title" => "", "notes" => "n1"}}]
    end
  end

  test "a step that cannot run is shown with why, and enter asks to drop it" do
    {m, _} = asked()
    blocked = Map.put(step(1, "One", "blocked"), "detail", "no field colour")
    m = Model.agent(m, plan("proposed", [blocked]))
    assert screen(m) =~ "[!] 1."
    assert screen(m) =~ "no field colour"
    {m, []} = press(m, [:enter])
    assert m.notice.text =~ "Step 1 cannot run"
    {m, []} = press(m, [{:char, " "}, :enter])
    assert m.notice.text =~ "Every step is dropped"
  end

  test "while it runs each step shows its state; esc asks the agent to stop" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")]))
    stored = Map.put(step(1, "One", "stored"), "detail", "Stored as T-7.")
    m = Model.agent(m, plan("running", [stored, step(2, "Two", "running")]))
    assert screen(m) =~ "Stored as T-7."
    assert screen(m) =~ "[…] 2."
    assert {_, [{:agent, %{"op" => "stop"}}]} = press(m, [:esc])

    done =
      Model.agent(
        m,
        plan("done", [stored, Map.put(step(2, "Two", "stored"), "detail", "Stored as T-8.")])
      )

    assert {%{plan: nil}, []} = press(done, [:enter])
  end

  test "running shows the agent's count; esc asks to stop, and a stopped plan keeps what was stored" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")]))
    stored = Map.put(step(1, "One", "stored"), "detail", "Stored as T-7.")

    running =
      plan("running", [stored, step(2, "Two", "running")], %{"title" => "Running: 1 of 2 stored"})

    m = Model.agent(m, running)
    assert screen(m) =~ "Running: 1 of 2 stored"
    # A running plan is not closed by enter; only esc stops it, after the current step.
    assert {^m, []} = press(m, [:enter])
    {m, [{:agent, %{"op" => "stop"}}]} = press(m, [:esc])
    assert m.notice == %{tone: "pending", text: "Stopping after this step…"}
    assert m.plan.state == "running"

    not_run = Map.put(step(2, "Two", "not_run"), "detail", "Not run: stopped before it.")
    m = Model.agent(m, plan("stopped", [stored, not_run], %{"title" => "Stopped: 1 of 2 stored"}))
    assert m.notice == nil
    text = screen(m)
    assert text =~ "Stopped: 1 of 2 stored"
    assert text =~ "Stored as T-7."
    assert text =~ "Not run: stopped before it."
    assert {%{plan: nil}, []} = press(m, [:enter])
  end

  test "after a run, closing the plan shows the page as hints left it" do
    empty = "No parts yet. Press c to create one."
    list = %{"type" => "list", "props" => %{"title" => "Parts", "rows" => [], "empty" => empty}}
    page = update_in(@page, ["blocks"], &(&1 ++ [list]))
    m = ConsoleProjectionFixture.model(page)
    assert screen(m) =~ empty

    {m, [{:agent, _}]} = press(m, [{:char, ":"}] ++ type("make parts") ++ [:enter])
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")]))
    {m, [{:agent, %{"op" => "run"}}]} = press(m, [:enter])

    # While the plan is shown, hints redraw the page underneath it.
    rows = [
      %{"label" => "One", "detail" => "T-7", "to" => "/k/thing/T-7"},
      %{"label" => "Two", "detail" => "T-8", "to" => "/k/thing/T-8"}
    ]

    hinted = put_in(page, ["blocks", Access.at(1), "props", "rows"], rows)
    {m, []} = ConsoleProjectionFixture.receive(m, Map.put(hinted, "reason", "hint"))

    done =
      for {n, key} <- [{1, "T-7"}, {2, "T-8"}],
          do: Map.put(step(n, "x", "stored"), "detail", "Stored as #{key}.")

    m = Model.agent(m, plan("done", done, %{"title" => "Done: 2 of 2 stored"}))
    assert screen(m) =~ "Done: 2 of 2 stored"
    refute screen(m) =~ "Parts · 2"

    {m, []} = press(m, [:enter])
    text = screen(m)
    assert text =~ "Parts · 2"
    assert text =~ "T-8"
    refute text =~ empty
  end

  test "undeclared request shortcuts do not replace a proposal, and cancelled asks ignore late plans" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One")]))
    assert press(m, [{:char, ":"}]) == {m, []}

    {m, _} = press(model(), [{:char, ":"}] ++ type("x") ++ [:enter, :esc])
    assert Model.agent(m, plan("proposed", [step(1, "One")])).plan == nil
  end

  test "a plan after a refusal says what happened before" do
    {m, _} = asked()
    before = "Step 2 (New part in T-1) was refused: T-1 does not exist."
    m = Model.agent(m, plan("planning", [], %{"before" => before}))
    assert screen(m) =~ "Before          Step 2 (New part in T-1) was refused"
    m = Model.agent(m, plan("proposed", [step(1, "Three")], %{"before" => before}))
    assert screen(m) =~ "T-1 does not exist."
    assert {_, [{:agent, %{"op" => "run"}}]} = press(m, [:enter])
  end

  test "a declared agent action sends its supplied intent and label" do
    page =
      put_in(@page, ["blocks", Access.at(0), "props", "actions"], [
        %{"label" => "Undo", "key" => "x", "to" => "agent:undo"}
      ])

    m = ConsoleProjectionFixture.model(page)
    {m, [{:agent, ask}]} = press(m, [{:char, "x"}])

    assert ask == %{
             "op" => "ask",
             "request" => "Undo",
             "on" => "/k/thing/T-1",
             "intent" => "undo"
           }

    assert screen(m) =~ "Planning…"
  end

  test "when the agent stops, a plan it was making says so" do
    {m, _} = asked()
    m = Model.agent_gone(m, "it exited with 1")
    assert m.plan.state == "failed"
    assert screen(m) =~ "The agent stopped"
  end
end
