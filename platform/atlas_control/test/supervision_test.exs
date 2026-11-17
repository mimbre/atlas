defmodule AtlasControl.SupervisionTest do
  @moduledoc """
  Supervision's pages (work acquisition decision 2026-11-17, §5.6–5.8; M3b P4), from a
  neutral model with one supervised span (`AtlasControl.Shop.Supervised`): Open for you,
  Supervised by you, Pick up and Hand over… on a fact's page, and their confirm and form.
  Everything is asserted by structure (keys, paths, block types, calls), never by wording.
  """
  use ExUnit.Case, async: true

  alias AtlasControl.{Pages, Shop}

  @s AtlasControl.Model.catalog(Shop.Supervised)
  @plain AtlasControl.Model.catalog(Shop)

  @tui_ada %{by: "ada", by_kind: "member", client: "tui"}
  @tui_bob %{by: "bob", by_kind: "member", client: "tui"}
  @tui_nobody %{by: "agent", by_kind: nil, client: "tui"}
  @agent %{by: "agent", by_kind: nil, client: "agent"}
  @agent_as_ada %{by: "ada", by_kind: "member", client: "agent"}

  defp span, do: hd(Pages.open_for_you_rule(@s).spans)

  # How Facts presents the work on a widget: the run, its subflow, status, state and
  # supervisor.
  defp presented(opts \\ []) do
    s = span()

    %{
      "flow" => Keyword.get(opts, :flow, s.subflow),
      "run" => Keyword.get(opts, :run, "R-1"),
      "generation" => 1,
      "status" => Keyword.get(opts, :status, "active"),
      "state" => Keyword.get(opts, :state, hd(s.states)),
      "supervisor" => Keyword.get(opts, :supervisor, []),
      "owner" => Keyword.get(opts, :owner, []),
      "actionable" => true,
      "expected" => nil
    }
  end

  defp widget(key, presentation, extra \\ %{}) do
    Map.merge(
      %{"key" => key, "values" => %{"title" => key}, "links" => %{}, "version" => "v1"},
      Map.put(extra, "presentation", presentation)
    )
  end

  defp member(key), do: %{"key" => key, "values" => %{"name" => key}, "links" => %{}}

  defp job(key, of, outcome),
    do: %{
      "key" => key,
      "values" => %{"title" => key, "outcome" => outcome},
      "links" => %{"job_of" => [of]}
    }

  # The answers to an item page's reads: the fact, nothing pointing at it, and the members
  # last (the reads of a span subject end with them).
  defp item_answers(fact, members) do
    reads = Pages.reads({:item, "widget", fact["key"]}, @s)
    assert List.last(reads) == {"member", %{}}

    [%{"fact" => fact}] ++
      List.duplicate(%{"facts" => []}, length(reads) - 2) ++ [%{"facts" => members}]
  end

  defp keys_of(rows), do: for(%{"to" => to} <- rows, {:item, _, key} = Pages.route(to), do: key)

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))

  # The `to`s of the item's Pick up and Hand over… actions.
  defp supervision_tos(page) do
    for %{"to" => to} <- block(page, "item")["props"]["actions"] || [],
        elem(Pages.route(to), 0) in [:pick_up, :hand_over],
        do: to
  end

  test "Open for you: in the span, active, without a supervisor, not completed" do
    s = span()

    facts = [
      widget("W-1", presented()),
      widget("W-2", presented(supervisor: ["ada"])),
      widget("W-3", presented(state: "done")),
      widget("W-4", presented(status: "blocked")),
      widget("W-5", presented(flow: "elsewhere")),
      widget("W-6", presented(), %{"completion" => %{"done" => true}}),
      Map.delete(widget("W-7", nil), "presentation"),
      widget("W-8", presented(status: "completed"))
    ]

    assert Pages.reads({:open_for_you, "ada"}, @s) == [{s.subject, %{"presentation" => true}}]
    page = Pages.render({:open_for_you, "ada"}, @s, [%{"facts" => facts}])

    # One list per span, in the declared order, with the open facts' keys as its rows.
    lists = for b <- page.blocks, b["type"] == "list", do: b

    assert Enum.map(lists, & &1["id"]) ==
             for(s <- Pages.open_for_you_rule(@s).spans, do: "list:#{s.subflow}:#{s.span}")

    assert keys_of(hd(lists)["props"]["rows"]) == ["W-1"]

    # The Overview's main count is the number of rows.
    assert [main | _] = block(page, "summary")["props"]["fields"]
    assert main["value"] == "1"
  end

  test "Supervised by you: the client's, still in a span; its running work counted quietly" do
    facts = [
      widget("W-1", presented()),
      widget("W-2", presented(supervisor: ["ada"], owner: ["bot"])),
      widget("W-3", presented(supervisor: ["ada"], state: "done")),
      widget("W-4", presented(supervisor: ["bob"])),
      widget("W-5", presented(supervisor: ["ada"], status: "blocked")),
      widget("W-6", presented(supervisor: ["ada"], flow: "elsewhere"))
    ]

    jobs = [job("J-1", "W-2", ""), job("J-2", "P-1", nil), job("J-3", "W-2", "ok")]
    reads = Pages.reads({:supervised_by_you, "ada"}, @s)
    work = Pages.supervised_rule(@s).work
    assert List.last(reads) == {work.kind, %{"linked" => %{work.for => "ada"}}}

    answers = [%{"facts" => facts}, %{"facts" => jobs}]
    page = Pages.render({:supervised_by_you, "ada"}, @s, answers)
    list = block(page, "list")["props"]
    assert keys_of(list["rows"]) == ["W-2", "W-5"]

    {rows, running} = Pages.supervised_facts(@s, "ada", answers)
    assert length(rows) == 2
    assert Enum.map(running, & &1["key"]) == ["J-1", "J-2"]

    [main | more] = block(page, "summary")["props"]["fields"]
    assert main["value"] == "2"
    # The quiet count of running work: a pair whose value is the count, by the work's kind.
    jobs_k = @s.kinds[work.kind]
    assert %{"value" => "2"} = Enum.find(more, &(&1["label"] == jobs_k.plural))

    # Someone else supervises none of these.
    assert keys_of(
             block(Pages.render({:supervised_by_you, "bob"}, @s, answers), "list")["props"][
               "rows"
             ]
           ) == ["W-4"]
  end

  test "Pick up and Hand over…: offered exactly to whom the rules say" do
    open = widget("W-1", presented())
    mine = widget("W-1", presented(supervisor: ["ada"]))
    ada_bob = [member("ada"), member("bob")]
    pick = Pages.path({:pick_up, "widget", "W-1", "R-1"})
    hand = Pages.path({:hand_over, "widget", "W-1", "R-1"})

    cases = [
      {open, ada_bob, @tui_ada, [pick]},
      {open, ada_bob, @tui_nobody, []},
      {open, ada_bob, @agent, []},
      {open, ada_bob, @agent_as_ada, []},
      {mine, ada_bob, @tui_ada, [hand]},
      {mine, [member("ada")], @tui_ada, []},
      {mine, ada_bob, @tui_bob, []},
      {mine, ada_bob, @agent_as_ada, []},
      {widget("W-1", presented(state: "done")), ada_bob, @tui_ada, []},
      {widget("W-1", presented(status: "blocked")), ada_bob, @tui_ada, []},
      # Another subflow presents the work, in a state of the span: not in the span.
      {widget("W-1", presented(flow: "elsewhere")), ada_bob, @tui_ada, []},
      {widget("W-1", presented(flow: "elsewhere", supervisor: ["ada"])), ada_bob, @tui_ada, []}
    ]

    for {{fact, members, viewer, expected}, at} <- Enum.with_index(cases) do
      page = Pages.render({:item, "widget", "W-1"}, @s, item_answers(fact, members), viewer)
      assert supervision_tos(page) == expected, "case #{at}"
    end
  end

  test "the supervision actions take keys no other action on the page has" do
    members = [member("ada"), member("bob")]
    render = &Pages.render({:item, "widget", "W-1"}, @s, item_answers(&1, members), @tui_ada)
    # The same page without them: its work outside the span.
    without = block(render.(widget("W-1", presented(state: "done"))), "item")["props"]["actions"]
    assert supervision_tos(render.(widget("W-1", presented(state: "done")))) == []

    for fact <- [widget("W-1", presented()), widget("W-1", presented(supervisor: ["ada"]))] do
      page = render.(fact)
      actions = block(page, "item")["props"]["actions"]
      assert [_] = supervision_tos(page)
      # Every other action is still there (an action on the same key would give way)...
      assert Enum.reject(actions, &(&1["to"] in supervision_tos(page))) == without
      # ...and no two share a key.
      keys = Enum.map(actions, & &1["key"])
      assert keys == Enum.uniq(keys)
    end
  end

  test "the supervisor shows as a field, keys only, on the span subject's page" do
    fact = widget("W-1", presented(supervisor: ["ada"]))
    page = Pages.render({:item, "widget", "W-1"}, @s, item_answers(fact, []), @tui_bob)
    label = String.capitalize(@s.relations[Pages.open_for_you_rule(@s).relation].label)

    assert %{"value" => "ada"} =
             Enum.find(block(page, "item")["props"]["fields"], &(&1["label"] == label))
  end

  # A page that offers nothing and says why: a confirm with nowhere to confirm to.
  defp missing?(page),
    do:
      match?(
        [%{"type" => "confirm", "props" => props}] when not is_map_key(props, "confirm_to"),
        page.blocks
      )

  test "the Pick up page confirms to its endpoint; each stale case says why instead" do
    route = {:pick_up, "widget", "W-1", "R-1"}
    members = [member("ada")]
    page = Pages.render(route, @s, item_answers(widget("W-1", presented()), members), @tui_ada)
    assert [%{"type" => "confirm", "props" => %{"confirm_to" => call}}] = page.blocks
    assert {:ok, :pick_up, %{kind: "widget", key: "W-1", run: "R-1"}} = Pages.submit_call(call)

    for {fact, viewer} <- [
          {widget("W-1", presented(run: "R-2")), @tui_ada},
          {widget("W-1", presented(state: "done")), @tui_ada},
          {widget("W-1", presented(supervisor: ["bob"])), @tui_ada},
          {widget("W-1", presented()), @agent_as_ada},
          {widget("W-1", presented()), @tui_nobody}
        ] do
      assert missing?(Pages.render(route, @s, item_answers(fact, members), viewer))
    end
  end

  # The answers to the hand-over's reads: the item's, the parts of the widget, the jobs.
  defp hand_over_answers(fact, members, parts, jobs) do
    route = {:hand_over, "widget", fact["key"], "R-1", "ada"}
    reads = Pages.reads(route, @s)
    item = item_answers(fact, members)
    withs = length(reads) - length(item) - 1
    assert withs == 1
    item ++ [%{"facts" => parts}, %{"facts" => jobs}]
  end

  test "the Hand over… page: one choice of the members but the client, and the work that stops" do
    route = {:hand_over, "widget", "W-1", "R-1", "ada"}
    fact = widget("W-1", presented(supervisor: ["ada"]))

    part = %{
      "key" => "P-1",
      "values" => %{"title" => "P-1"},
      "links" => %{"of_widget" => ["W-1"]}
    }

    jobs = [
      job("J-1", "W-1", ""),
      job("J-2", "P-1", nil),
      job("J-3", "W-1", "done"),
      job("J-4", "W-9", "")
    ]

    answers = hand_over_answers(fact, [member("ada"), member("bob"), member("cy")], [part], jobs)
    page = Pages.render(route, @s, answers, @tui_ada)

    assert %{"type" => "form", "props" => form} = block(page, "form")
    assert [%{"name" => "hand_to", "choices" => choices}] = form["inputs"]
    assert Enum.map(choices, & &1["value"]) == ["bob", "cy"]

    assert {:ok, :hand_over, %{kind: "widget", key: "W-1", run: "R-1"}} =
             Pages.submit_call(form["submit_to"])

    refute Map.has_key?(form, "note")

    # The client's running work on the widget, or on a part of it, will stop.
    assert Enum.map(Pages.stopping_tasks(@s, route, answers), & &1["key"]) == ["J-1", "J-2"]
    assert keys_of(block(page, "stopping")["props"]["rows"]) == ["J-1", "J-2"]

    # Nobody else, a stale run, or not the supervisor: no form, it says why.
    alone = hand_over_answers(fact, [member("ada")], [], [])
    assert missing?(Pages.render(route, @s, alone, @tui_ada))

    moved =
      hand_over_answers(
        widget("W-1", presented(supervisor: ["ada"], run: "R-2")),
        [member("bob")],
        [],
        []
      )

    assert missing?(Pages.render(route, @s, moved, @tui_ada))

    assert missing?(
             Pages.render({:hand_over, "widget", "W-1", "R-1", "bob"}, @s, answers, @tui_bob)
           )

    assert missing?(Pages.render(route, @s, answers, @agent_as_ada))
  end

  test "every new route reads with a role per read, and its paths round-trip" do
    routes = [
      {:open_for_you, "ada"},
      {:supervised_by_you, "ada"},
      {:pick_up, "widget", "W-1", "R-1"},
      {:hand_over, "widget", "W-1", "R-1"},
      {:hand_over, "widget", "W-1", "R-1", "ada"},
      {:item, "widget", "W-1"}
    ]

    for route <- routes do
      assert length(Pages.read_roles(route, @s)) == length(Pages.reads(route, @s)), inspect(route)
      assert Pages.reads(route, @s) != []
    end

    for route <- [
          {:open_for_you, nil},
          {:supervised_by_you, nil},
          {:pick_up, "a b", "K/1", "R 1"},
          {:hand_over, "a", "K", "R"}
        ],
        do: assert(Pages.route(Pages.path(route)) == route)

    assert Pages.form?({:hand_over, "a", "K", "R"}) and
             Pages.form?({:hand_over, "a", "K", "R", "ada"})

    refute Pages.form?({:pick_up, "a", "K", "R"})
  end

  test "a model without supervision: no screens' reads, nothing extra on a fact's page" do
    assert Pages.open_for_you_rule(@plain) == nil and Pages.supervised_rule(@plain) == nil
    assert Pages.reads({:open_for_you, "ada"}, @plain) == []
    assert Pages.reads({:supervised_by_you, "ada"}, @plain) == []

    # Neither screen is routed, and rendered anyway it is the page of no page.
    none = Pages.render(:unknown, @plain, [])

    for screen <- [:open_for_you, :supervised_by_you] do
      assert Pages.resolve({screen, nil}, @s) == {screen, nil}
      assert Pages.resolve({screen, nil}, @plain) == :unknown
      assert Pages.render({screen, "ada"}, @plain, [], @tui_ada) == none
    end

    refute {"member", %{}} in Pages.reads({:item, "widget", "W-1"}, @plain)

    w = widget("W-1", presented())
    reads = Pages.reads({:item, "widget", "W-1"}, @plain)

    page =
      Pages.render(
        {:item, "widget", "W-1"},
        @plain,
        [%{"fact" => w} | for(_ <- tl(reads), do: %{"facts" => []})],
        @tui_ada
      )

    assert supervision_tos(page) == []
  end
end
