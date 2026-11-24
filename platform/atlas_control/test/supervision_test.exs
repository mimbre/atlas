defmodule AtlasControl.SupervisionTest do
  @moduledoc """
  Supervision's pages (work acquisition decision 2026-11-17, §5.6–5.8; M3b P4), from a
  neutral model with one supervised span: Open for you, Supervised by you, Pick up and
  Hand over… on a fact's page, and their confirm and form. Each runs on both ways Facts
  may present the work: on the span's subject itself (`AtlasControl.Shop.Supervised`), and
  on the component it is written on, the widget's card (`AtlasControl.Shop.SupervisedOnCard`),
  as a model whose work is written on an Assignment.
  Everything is asserted by structure (keys, paths, block types, calls, read roles), never
  by wording.
  """
  use ExUnit.Case, async: true

  alias AtlasControl.{Pages, Shop}

  @s AtlasControl.Model.catalog(Shop.Supervised)
  @card AtlasControl.Model.catalog(Shop.SupervisedOnCard)
  @plain AtlasControl.Model.catalog(Shop)
  # The same pages, with the work on the widget and with the work on its card.
  @models [@s, @card]

  @tui_ada %{by: "ada", by_kind: "member", client: "tui"}
  @tui_bob %{by: "bob", by_kind: "member", client: "tui"}
  @tui_nobody %{by: "agent", by_kind: nil, client: "tui"}
  @agent %{by: "agent", by_kind: nil, client: "agent"}
  @agent_as_ada %{by: "ada", by_kind: "member", client: "agent"}

  defp span(m \\ @s), do: hd(Pages.open_for_you_rule(m).spans)

  # How Facts presents the work: the run, its subflow, status, state, supervisor and owner
  # (`manual`: set by hand, not Flow's default).
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
      "manual" => Keyword.get(opts, :manual, false),
      "actionable" => true,
      "expected" => Keyword.get(opts, :expected)
    }
  end

  # A widget whose work Facts presents as `presentation` (nil: not at all), where `m`
  # writes it: on the widget itself, or on its card, which the widget links to.
  # `{widget, card}`; the card is nil when the work is on the widget.
  defp work(m, key, presentation, extra \\ %{}) do
    widget =
      Map.merge(
        %{"key" => key, "values" => %{"title" => key}, "links" => %{}, "version" => "v1"},
        extra
      )

    shown = fn fact ->
      if presentation, do: Map.put(fact, "presentation", presentation), else: fact
    end

    case for({relation, "card", spec} <- Pages.components(m, "widget"), do: {relation, spec}) do
      [] ->
        {shown.(widget), nil}

      [{relation, spec}] ->
        card = %{"key" => Pages.part_key(spec, key), "values" => %{"of" => key}, "links" => %{}}
        {put_in(widget, ["links", relation], [card["key"]]), shown.(card)}
    end
  end

  defp member(key), do: %{"key" => key, "values" => %{"name" => key}, "links" => %{}}

  defp job(key, of, outcome),
    do: %{
      "key" => key,
      "values" => %{"title" => key, "outcome" => outcome},
      "links" => %{"job_of" => [of]}
    }

  # The answers to a screen's reads, by the kind each reads: the widgets, their cards, the
  # jobs.
  defp screen_answers(route, m, items, jobs \\ []) do
    by_kind = %{
      "widget" => for({w, _} <- items, do: w),
      "card" => for({_, c} <- items, c != nil, do: c),
      "job" => jobs
    }

    for {kind, _} <- Pages.reads(route, m), do: %{"facts" => by_kind[kind] || []}
  end

  # The answers to an item page's reads: the widget, nothing pointing at it, its card
  # when the work is on it, and the members last (the reads of a span subject end with
  # them).
  defp item_answers(m, {widget, card}, members) do
    [_ | reads] = Pages.reads({:item, "widget", widget["key"]}, m)
    assert List.last(reads) == {"member", %{}}

    middle =
      for {kind, read} <- Enum.drop(reads, -1) do
        if kind == "card" and is_map_key(read, "key"),
          do: %{"fact" => card},
          else: %{"facts" => []}
      end

    [%{"fact" => widget}] ++ middle ++ [%{"facts" => members}]
  end

  # The widgets' keys of rows, each row to a widget's page: never to a card's.
  defp keys_of(rows) do
    for %{"to" => to} <- rows do
      assert {:item, "widget", key} = Pages.route(to)
      key
    end
  end

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))

  # The `to`s of the item's Pick up, Hand over…, Retry and Remove actions.
  defp supervision_tos(page) do
    for %{"to" => to} <- block(page, "item")["props"]["actions"] || [],
        elem(Pages.route(to), 0) in [:pick_up, :hand_over, :retry, :remove_item],
        do: to
  end

  # The supervision actions a fact's page offers as its next step, and those under its
  # More… (its secondary menu, which reads as the page does).
  defp offered(m, answers, viewer) do
    next = supervision_tos(Pages.render({:item, "widget", "W-1"}, m, answers, viewer))
    {next, supervision_tos(Pages.render({:more, "widget", "W-1"}, m, answers, viewer))}
  end

  test "the two models differ only in the kind the span's work is written on" do
    assert span(@s).written_on == span(@s).subject
    assert span(@card).written_on == "card"
    assert Map.delete(span(@card), :written_on) == Map.delete(span(@s), :written_on)
  end

  test "Open for you: in the span, active, without a supervisor, not completed" do
    s = span()
    assert Pages.reads({:open_for_you, "ada"}, @s) == [{s.subject, %{"presentation" => true}}]

    assert Pages.reads({:open_for_you, "ada"}, @card) == [
             {"card", %{"presentation" => true}},
             {s.subject, %{}}
           ]

    for m <- @models do
      items = [
        # Flow's default holder of unpicked work, and an owner set by hand.
        work(m, "W-1", presented(owner: ["coordinator"])),
        work(m, "W-9", presented(owner: ["bob"], manual: true)),
        work(m, "W-2", presented(supervisor: ["ada"])),
        work(m, "W-3", presented(state: "done")),
        work(m, "W-4", presented(status: "blocked")),
        work(m, "W-5", presented(flow: "elsewhere")),
        work(m, "W-6", presented(), %{"completion" => %{"done" => true}}),
        work(m, "W-7", nil),
        work(m, "W-8", presented(status: "completed"))
      ]

      route = {:open_for_you, "ada"}
      page = Pages.render(route, m, screen_answers(route, m, items))

      # One list per span, in the declared order, with the open facts' keys as its rows.
      lists = for b <- page.blocks, b["type"] == "list", do: b

      assert Enum.map(lists, & &1["id"]) ==
               for(s <- Pages.open_for_you_rule(m).spans, do: "list:#{s.subflow}:#{s.span}")

      assert keys_of(hd(lists)["props"]["rows"]) == ["W-1", "W-9"], span(m).written_on

      # No Overview: the tab and the groups count. The span's title says the flow, so a row
      # does not; Flow's default holder is not shown, an owner set by hand is.
      refute block(page, "summary")
      details = Map.new(hd(lists)["props"]["rows"], &{&1["id"], &1["detail"]})
      assert details == %{"W-1" => "", "W-9" => "bob"}
    end
  end

  test "Open for you lists its rows by key, their numbers as numbers" do
    for m <- @models do
      items = for key <- ~w(W-100 W-11 W-07 W-9), do: work(m, key, presented())
      route = {:open_for_you, "ada"}
      page = Pages.render(route, m, screen_answers(route, m, items))
      [list | _] = for b <- page.blocks, b["type"] == "list", do: b
      assert keys_of(list["props"]["rows"]) == ~w(W-07 W-9 W-11 W-100), span(m).written_on
    end
  end

  test "Open for you and Supervised by you declare their groups: all, then one per span" do
    m = @s
    s = span(m)

    items = [
      work(m, "W-1", presented(expected: "Paint it")),
      work(m, "W-2", presented(state: "done")),
      work(m, "W-3", presented(supervisor: ["ada"], expected: "Paint it"))
    ]

    for {screen, all_to, mine, all_detail} <- [
          {:open_for_you, "/_open", "W-1", ""},
          {:supervised_by_you, "/_supervised", "W-3", m.start.flows[s.subflow]}
        ] do
      all = {screen, "ada"}
      page = Pages.render(all, m, screen_answers(all, m, items, []))

      # All first (the page itself, active), then each span with its count and its page.
      groups = block(page, "groups")["props"]["groups"]
      assert [%{"to" => ^all_to, "count" => 1, "active" => true}, group] = groups
      group_route = {:group, screen, {s.subflow, s.span}, nil}
      assert Pages.route(group["to"]) == group_route
      assert %{"count" => 1, "active" => false} = group
      assert Pages.resolve(group_route, m) == group_route
      assert Pages.resolve({:group, screen, {s.subflow, "nowhere"}, nil}, m) == :unknown

      # `[` and `]` open the previous and the next group.
      assert Enum.map(page.console_actions, & &1.operation["to"]) == [group["to"], group["to"]]

      # Each row shows its key; on Supervised by you's whole page, where flows mix in one
      # list, its flow's short name (never the sentence of what is expected). Open for you
      # titles each span's list with its flow, so its rows do not repeat it.
      assert is_binary(m.start.flows[s.subflow])
      rows = for %{"type" => "list"} = b <- page.blocks, row <- b["props"]["rows"], do: row
      assert [%{"id" => ^mine, "detail" => ^all_detail}] = rows

      # The group's page: the same groups, that one active, and only its span's items.
      group_route = {:group, screen, {s.subflow, s.span}, "ada"}
      page = Pages.render(group_route, m, screen_answers(group_route, m, items, []))
      assert Pages.reads(group_route, m) == Pages.reads(all, m)

      assert [%{"active" => false}, %{"active" => true}] =
               block(page, "groups")["props"]["groups"]

      # Its rows keep their key; the group's name says the flow, so they do not.
      lists = for %{"type" => "list"} = b <- page.blocks, do: b
      assert Enum.flat_map(lists, &keys_of(&1["props"]["rows"])) == [mine]
      assert [%{"id" => ^mine, "detail" => ""}] = Enum.flat_map(lists, & &1["props"]["rows"])
      assert page.back == all_to
    end
  end

  test "Supervised by you: the client's, still in a span; who holds it once it is picked up" do
    for m <- @models do
      items = [
        work(m, "W-1", presented()),
        work(m, "W-2", presented(supervisor: ["ada"], owner: ["bot"])),
        work(m, "W-3", presented(supervisor: ["ada"], state: "done")),
        work(m, "W-4", presented(supervisor: ["bob"])),
        work(m, "W-5", presented(supervisor: ["ada"], status: "blocked")),
        work(m, "W-6", presented(supervisor: ["ada"], flow: "elsewhere"))
      ]

      jobs = [job("J-1", "W-2", ""), job("J-2", "P-1", nil), job("J-3", "W-2", "ok")]
      route = {:supervised_by_you, "ada"}
      work = Pages.supervised_rule(m).work
      assert {work.kind, %{"linked" => %{work.for => "ada"}}} in Pages.reads(route, m)

      answers = screen_answers(route, m, items, jobs)
      page = Pages.render(route, m, answers)
      list = block(page, "list")["props"]
      assert keys_of(list["rows"]) == ["W-2", "W-5"], span(m).written_on

      {rows, running} = Pages.supervised_facts(m, "ada", answers)
      assert length(rows) == 2
      assert Enum.map(running, & &1["key"]) == ["J-1", "J-2"], span(m).written_on

      # No Overview: the tab and the groups count.
      refute block(page, "summary")
      jobs_k = m.kinds[work.kind]

      # A row the client's running work is on says that work (its kind), not the flow.
      details = Map.new(list["rows"], &{&1["id"], &1["detail"]})
      assert String.starts_with?(details["W-2"], jobs_k.label)
      refute details["W-5"] =~ jobs_k.label

      # A supervised row says who holds it.
      assert details["W-2"] =~ "bot"

      # Someone else supervises none of these.
      bob = {:supervised_by_you, "bob"}

      assert keys_of(
               block(Pages.render(bob, m, screen_answers(bob, m, items, [])), "list")["props"][
                 "rows"
               ]
             ) == ["W-4"]
    end
  end

  test "Pick up, Hand over…, Retry and Remove: offered exactly to whom the rules say" do
    for m <- @models do
      open = work(m, "W-1", presented())
      mine = work(m, "W-1", presented(supervisor: ["ada"]))
      ada_bob = [member("ada"), member("bob")]
      pick = Pages.path({:pick_up, "widget", "W-1", "R-1"})
      hand = Pages.path({:hand_over, "widget", "W-1", "R-1"})
      retry = Pages.path({:retry, "widget", "W-1", "R-1"})
      remove = Pages.path({:remove_item, "widget", "W-1", "R-1"})

      # Pick up and Retry are the flow's next step; Hand over… and Remove are under More….
      cases = [
        {open, ada_bob, @tui_ada, {[pick], []}},
        {open, ada_bob, @tui_nobody, {[], []}},
        {open, ada_bob, @agent, {[], []}},
        {open, ada_bob, @agent_as_ada, {[], []}},
        {mine, ada_bob, @tui_ada, {[retry], [hand, remove]}},
        {mine, [member("ada")], @tui_ada, {[retry], [remove]}},
        {mine, ada_bob, @tui_bob, {[], []}},
        {mine, ada_bob, @agent_as_ada, {[], []}},
        {work(m, "W-1", presented(state: "done")), ada_bob, @tui_ada, {[], []}},
        {work(m, "W-1", presented(status: "blocked")), ada_bob, @tui_ada, {[], []}},
        # A supervisor removes what it supervises in any state, and retries it in a span.
        {work(m, "W-1", presented(status: "blocked", supervisor: ["ada"])), ada_bob, @tui_ada,
         {[], [remove]}},
        # Another subflow presents the work, in a state of the span: not in the span.
        {work(m, "W-1", presented(flow: "elsewhere")), ada_bob, @tui_ada, {[], []}},
        {work(m, "W-1", presented(flow: "elsewhere", supervisor: ["ada"])), ada_bob, @tui_ada,
         {[], [remove]}}
      ]

      for {{item, members, viewer, expected}, at} <- Enum.with_index(cases) do
        assert offered(m, item_answers(m, item, members), viewer) == expected,
               "#{span(m).written_on}: case #{at}"
      end
    end
  end

  test "the supervision actions take keys no other action on the page has" do
    for m <- @models do
      members = [member("ada"), member("bob")]

      render =
        &Pages.render({:item, "widget", "W-1"}, m, item_answers(m, &1, members), @tui_ada)

      # The same page without them: its work outside the span.
      without =
        block(render.(work(m, "W-1", presented(state: "done"))), "item")["props"]["actions"]

      assert supervision_tos(render.(work(m, "W-1", presented(state: "done")))) == []

      for item <- [work(m, "W-1", presented()), work(m, "W-1", presented(supervisor: ["ada"]))] do
        page = render.(item)
        actions = block(page, "item")["props"]["actions"]
        assert supervision_tos(page) != []
        # Every other action is still there (an action on the same key would give way)...
        assert Enum.reject(actions, &(&1["to"] in supervision_tos(page))) == without
        # ...and no two share a key.
        keys = Enum.map(actions, & &1["key"])
        assert keys == Enum.uniq(keys)
      end
    end
  end

  test "nothing raw where the flow covers it: no Delete beside Remove, no Create of what it makes" do
    for m <- @models do
      tos = fn m, answers ->
        page = Pages.render({:more, "widget", "W-1"}, m, answers, @tui_ada)
        for %{"to" => to} <- block(page, "item")["props"]["actions"], do: elem(Pages.route(to), 0)
      end

      mine = item_answers(m, work(m, "W-1", presented(supervisor: ["ada"])), [member("ada")])
      assert :remove_item in tos.(m, mine)
      refute :delete in tos.(m, mine)
      # The span holds the runs of the widget's parts (`with:`): no Create part by hand.
      refute :new in tos.(m, mine)

      # Without a run, nothing removes it: Delete does.
      unrun = item_answers(m, work(m, "W-1", nil), [member("ada")])
      assert :delete in tos.(m, unrun)

      spans = fn m, change ->
        update_in(m, [:start, :open_for_you, :spans], fn spans -> Enum.map(spans, change) end)
      end

      # A span that holds no runs of parts leaves Create part...
      unheld = spans.(m, &%{&1 | with_subjects: []})
      assert :new in tos.(unheld, mine)

      # ...unless its subflow makes them.
      refute :new in tos.(spans.(unheld, &%{&1 | creates: ["part"]}), mine)
    end
  end

  test "the supervisor shows as a field, keys only, on the span subject's page" do
    for m <- @models do
      item = work(m, "W-1", presented(supervisor: ["ada"]))
      page = Pages.render({:item, "widget", "W-1"}, m, item_answers(m, item, []), @tui_bob)
      label = String.capitalize(m.relations[Pages.open_for_you_rule(m).relation].label)

      assert %{"value" => "ada"} =
               Enum.find(block(page, "item")["props"]["fields"], &(&1["label"] == label))
    end
  end

  # A page that offers nothing and says why: a confirm with nowhere to confirm to.
  defp missing?(page),
    do:
      match?(
        [%{"type" => "confirm", "props" => props}] when not is_map_key(props, "confirm_to"),
        page.blocks
      )

  test "the Pick up page confirms to its endpoint; each stale case says why instead" do
    for m <- @models do
      route = {:pick_up, "widget", "W-1", "R-1"}
      members = [member("ada")]
      answers = item_answers(m, work(m, "W-1", presented()), members)
      assert Pages.pick_up_problem(m, route, answers, @tui_ada) == nil
      page = Pages.render(route, m, answers, @tui_ada)
      assert [%{"type" => "confirm", "props" => %{"confirm_to" => call}}] = page.blocks
      assert {:ok, :pick_up, %{kind: "widget", key: "W-1", run: "R-1"}} = Pages.submit_call(call)

      for {item, viewer} <- [
            {work(m, "W-1", presented(run: "R-2")), @tui_ada},
            {work(m, "W-1", presented(state: "done")), @tui_ada},
            {work(m, "W-1", presented(supervisor: ["bob"])), @tui_ada},
            {work(m, "W-1", presented()), @agent_as_ada},
            {work(m, "W-1", presented()), @tui_nobody}
          ] do
        assert missing?(Pages.render(route, m, item_answers(m, item, members), viewer))
      end
    end
  end

  test "Retry and Remove say an outside copy stays open, and where, until its connector reads it ended" do
    for m <- @models do
      # The widget is copied from outside: its `ext_ref` is the address, `done` ends it.
      m =
        put_in(m, [:kinds, "widget", :connector], %{
          address: "ext_ref",
          system: "elsewhere",
          until: %{"done" => ["true"]}
        })

      url = "https://example.invalid/w/1"

      text = fn route, values ->
        item = work(m, "W-1", presented(supervisor: ["ada"]), %{"values" => values})
        page = Pages.render(route, m, item_answers(m, item, [member("ada")]), @tui_ada)
        assert [%{"type" => "confirm", "props" => %{"text" => text}}] = page.blocks
        text
      end

      for verb <- [:retry, :remove_item] do
        route = {verb, "widget", "W-1", "R-1"}
        open = text.(route, %{"title" => "W-1", "ext_ref" => url, "done" => false})
        assert open =~ url

        assert open ==
                 text.(route, %{"title" => "W-1"}) <>
                   Pages.stays_open(m, "widget", %{"values" => %{"ext_ref" => url}}, verb)

        # Ended outside, or never copied: nothing more is said.
        refute text.(route, %{"title" => "W-1", "ext_ref" => url, "done" => true}) =~ url
        assert Pages.open_outside(m, "widget", %{"values" => %{"ext_ref" => ""}}) == []
      end

      # A kind without a connector has nothing open outside.
      assert Pages.open_outside(@s, "widget", %{"values" => %{"ext_ref" => url}}) == []
    end
  end

  # The answers to the hand-over's reads: the item's, the parts of the widget, the jobs.
  defp hand_over_answers(m, item, members, parts, jobs) do
    {widget, _card} = item
    route = {:hand_over, "widget", widget["key"], "R-1", "ada"}
    reads = Pages.reads(route, m)
    answers = item_answers(m, item, members)
    withs = length(reads) - length(answers) - 1
    assert withs == 1
    answers ++ [%{"facts" => parts}, %{"facts" => jobs}]
  end

  test "the Hand over… page: one choice of the members but the client, and the work that stops" do
    for m <- @models do
      route = {:hand_over, "widget", "W-1", "R-1", "ada"}
      item = work(m, "W-1", presented(supervisor: ["ada"]))

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

      members = [member("ada"), member("bob"), member("cy")]
      answers = hand_over_answers(m, item, members, [part], jobs)
      assert Pages.hand_over_problem(m, route, answers, @tui_ada) == nil
      page = Pages.render(route, m, answers, @tui_ada)

      assert %{"type" => "form", "props" => form} = block(page, "form")
      assert [%{"name" => "hand_to", "choices" => choices}] = form["inputs"]
      assert Enum.map(choices, & &1["value"]) == ["bob", "cy"]

      assert {:ok, :hand_over, %{kind: "widget", key: "W-1", run: "R-1"}} =
               Pages.submit_call(form["submit_to"])

      refute Map.has_key?(form, "note")

      # The client's running work on the widget, or on a part of it, will stop.
      assert Enum.map(Pages.stopping_tasks(m, route, answers), & &1["key"]) == ["J-1", "J-2"]

      assert Enum.map(block(page, "stopping")["props"]["rows"], & &1["to"]) ==
               for(k <- ["J-1", "J-2"], do: Pages.path({:item, "job", k}))

      # Nobody else, a stale run, or not the supervisor: no form, it says why.
      alone = hand_over_answers(m, item, [member("ada")], [], [])
      assert missing?(Pages.render(route, m, alone, @tui_ada))

      moved =
        hand_over_answers(
          m,
          work(m, "W-1", presented(supervisor: ["ada"], run: "R-2")),
          [member("bob")],
          [],
          []
        )

      assert missing?(Pages.render(route, m, moved, @tui_ada))

      assert missing?(
               Pages.render({:hand_over, "widget", "W-1", "R-1", "bob"}, m, answers, @tui_bob)
             )

      assert missing?(Pages.render(route, m, answers, @agent_as_ada))
    end
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

    for m <- @models, route <- routes do
      assert length(Pages.read_roles(route, m)) == length(Pages.reads(route, m)), inspect(route)
      assert Pages.reads(route, m) != []
    end

    # The supervision screens' reads are all rows when the work is on the subject; when
    # it is on a component, they end with the one read of the subject, the lookup.
    for route <- [{:open_for_you, "ada"}, {:supervised_by_you, "ada"}] do
      assert Enum.uniq(Pages.read_roles(route, @s)) == [:rows]

      reads = Pages.reads(route, @card)
      assert List.last(reads) == {span(@card).subject, %{}}, inspect(route)

      assert Pages.read_roles(route, @card) ==
               List.duplicate(:rows, length(reads) - 1) ++ [:lookup],
             inspect(route)
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

    {w, nil} = work(@plain, "W-1", presented())
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
