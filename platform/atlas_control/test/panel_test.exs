defmodule AtlasControl.PanelTest do
  # A page where its owner decides, in the state a kind's `panel` names, sends that panel:
  # what to accept (the items under it, each with its details), what to ship (its checks)
  # and what to do with stuck work (what went wrong, and a choice), filled from the fact,
  # what points at it and its latest records (`Shop.Paneled`).
  use ExUnit.Case, async: false

  alias AtlasControl.{FakeStore, Shop}

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!({FakeStore, model: Shop.Paneled})
    start_supervised!(AtlasControl.FakeFlow)
    name = :"gateway_#{System.unique_integer([:positive])}"
    start_supervised!({AtlasControl.Gateway, port: 0, name: name, model: Shop.Paneled})

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    Application.put_env(:atlas_control, :tui_user, "ada")
    on_exit(fn -> Application.delete_env(:atlas_control, :tui_user) end)
    FakeStore.put("ada", %{"name" => "Ada"}, "member")
    FakeStore.put("C-W-1", %{"of" => "W-1"}, "card", %{"held_by" => ["ada"]})

    FakeStore.origin("card", "C-W-1", "held_by", %{
      "since" => "2026-11-26T09:00:00Z",
      "by" => "flow",
      "cause" => "its parts are proposed"
    })

    %{port: AtlasControl.Gateway.port(name)}
  end

  @since "2026-11-26T09:00:00Z"

  # The work on W-1 in `state`, held by Ada, as Facts presents it.
  defp in_state(state) do
    shown = Enum.find(Shop.Paneled.presentation(), &(&1["kind"] == "card"))["states"][state]
    FakeStore.put("C-W-1", %{"of" => "W-1", "step" => state}, "card", %{"held_by" => ["ada"]})

    FakeStore.present("card", "C-W-1", %{
      "flow" => "review",
      "status" => "active",
      "state" => state,
      "actionable" => true,
      "reopened" => false,
      "expected" => shown["expected"],
      "why" => shown["why"],
      "todo" => shown["todo"],
      "owner" => ["ada"],
      "manual" => false,
      "handover" => nil,
      "deadline" => nil
    })
  end

  defp open(port, path) do
    {:ok, s} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    on_exit(fn -> :gen_tcp.close(s) end)
    put(s, %{
      "op" => "hello",
      "env" => "test",
      "client" => "tui",
      "surface" => "console",
      "spec" => AtlasControl.Blocks.version()
    })
    next(s, "page")
    put(s, %{"op" => "open", "to" => path})
    {s, next(s, "page")}
  end

  defp put(s, message), do: :ok = :gen_tcp.send(s, [JSON.encode!(message), "\n"])

  defp next(s, op) do
    {:ok, line} = :gen_tcp.recv(s, 0, 5_000)

    case JSON.decode!(line) do
      %{"op" => ^op} = message -> message
      _ -> next(s, op)
    end
  end

  defp panel(page), do: Enum.find(page["blocks"], &(&1["type"] == "panel"))["props"]

  defp keys(page),
    do: for(%{"type" => "console_action"} = a <- page["blocks"], do: a["props"]["keys"])

  test "to accept: the items under it in order, each with what, done and needs; a and n", %{
    port: port
  } do
    FakeStore.put("W-1", %{"title" => "Lamp", "state" => "open"}, "widget", %{
      "card" => ["C-W-1"]
    })

    FakeStore.put(
      "P-2",
      %{"title" => "Switch", "rank" => 2, "notes" => "Turns it on. Done when: it clicks"},
      "part",
      %{"of_widget" => ["W-1"]}
    )

    FakeStore.put("P-1", %{"title" => "Base", "rank" => 1, "notes" => "Holds it."}, "part", %{
      "of_widget" => ["W-1"]
    })

    for {key, kind} <- [{"I-1", "plan"}, {"I-2", "plan"}, {"I-3", "inspect"}],
        do:
          FakeStore.put(key, %{"title" => key, "kind" => kind}, "inspection", %{
            "inspection_of" => ["W-1"]
          })

    in_state("check")
    {_s, page} = open(port, "/k/widget/W-1")
    p = panel(page)

    assert p["heading"] == "TO ACCEPT"
    assert p["title"] == "Parts of W-1 · Lamp"
    assert p["aside"] == "2 parts"

    assert p["byline"] == [
             %{"text" => "Proposed by I-2"},
             %{"text" => "", "since" => @since},
             %{"text" => "built in this order"}
           ]

    assert [base, switch] = p["items"]
    assert {base["key"], base["label"], base["to"]} == {"P-1", "Base", "/k/part/P-1"}

    assert base["details"] == [
             %{"label" => "What", "value" => "Holds it."},
             %{"label" => "Done", "value" => "—"},
             %{"label" => "Needs", "value" => "—"}
           ]

    assert switch["details"] == [
             %{"label" => "What", "value" => "Turns it on."},
             %{"label" => "Done", "value" => "it clicks"},
             %{"label" => "Needs", "value" => "P-1"}
           ]

    # The answers are the page's own: Accept at once, Not accepted with a note (its form).
    assert [
             %{"key" => "a", "label" => "Accept", "to" => "/k/widget/W-1/answer/a"} = yes,
             %{"key" => "n", "label" => "Not accepted", "note" => true} = no
           ] = p["answers"]

    refute Map.has_key?(yes, "note")
    refute Map.has_key?(no, "submit_to")
    assert p["actions"] == [%{"label" => "Full proposal", "key" => "i", "to" => "/k/inspection/I-2"}]
    assert ["a"] in keys(page) and ["n"] in keys(page) and ["i"] in keys(page)

    # The panel lists the parts: no list of them besides it.
    refute Enum.any?(page["blocks"], &(&1["id"] == "list:of_widget"))
  end

  test "not accepted asks its note first, then answers with it", %{port: port} do
    FakeStore.put("W-1", %{"title" => "Lamp", "state" => "open"}, "widget", %{
      "card" => ["C-W-1"]
    })

    in_state("check")
    {s, _page} = open(port, "/k/widget/W-1")
    put(s, %{"op" => "open", "to" => "/k/widget/W-1/answer/n"})
    form = Enum.find(next(s, "page")["blocks"], &(&1["type"] == "form"))
    assert Enum.any?(form["props"]["inputs"], &(&1["name"] == "note"))

    put(s, %{"op" => "submit", "to" => "/k/widget/W-1/answer/n", "values" => %{"note" => "Too dim"}})
    assert %{"reason" => "stored"} = next(s, "page")
    assert %{"cause" => "Too dim", "values" => %{"state" => "dropped"}} = List.last(FakeStore.sent())
  end

  test "to ship: its checks from the fact and its latest inspection, its link and record", %{
    port: port
  } do
    FakeStore.put(
      "W-1",
      %{"title" => "Lamp", "shade" => "light", "site" => "https://example.invalid/w/605"},
      "widget",
      %{"card" => ["C-W-1"]}
    )

    FakeStore.put("I-1", %{"title" => "I-1", "kind" => "inspect"}, "inspection", %{
      "inspection_of" => ["W-1"]
    })

    in_state("ship")
    {_s, page} = open(port, "/k/widget/W-1")
    p = panel(page)

    assert p["heading"] == "TO SHIP"
    assert p["title"] == "#605 Lamp"

    assert p["byline"] == [
             %{"text" => "W-1"},
             %{"text" => "by I-1"},
             %{"text" => "waiting", "since" => @since}
           ]

    # An inspection without its verdict says nothing yet.
    assert p["checks"] == [
             %{"label" => "Shade", "state" => "success", "text" => "Light"},
             %{"label" => "Inspection", "state" => "none", "text" => "—"}
           ]

    assert p["answers"] == []
    assert p["links"] == [%{"label" => "Open its site", "key" => "o", "url" => "https://example.invalid/w/605"}]
    assert p["actions"] == [%{"label" => "Full inspection", "key" => "r", "to" => "/k/inspection/I-1"}]

    # One o on the page: the panel's.
    assert Enum.count(keys(page), &(&1 == ["o"])) == 1

    FakeStore.put(
      "I-2",
      %{"title" => "I-2", "kind" => "inspect", "verdict" => "faulty", "answer" => "\n  It flickers.\nMore."},
      "inspection",
      %{"inspection_of" => ["W-1"]}
    )

    {_s, page} = open(port, "/k/widget/W-1")

    assert %{"label" => "Inspection", "state" => "error", "text" => "Faulty · It flickers."} =
             Enum.at(panel(page)["checks"], 1)
  end

  test "stuck: what went wrong, and the answers as a choice, the first recommended", %{
    port: port
  } do
    FakeStore.put(
      "W-1",
      %{"title" => "Lamp", "failure" => "The bulb did not fit."},
      "widget",
      %{"card" => ["C-W-1"]}
    )

    FakeStore.put("I-1", %{"title" => "I-1", "kind" => "inspect", "attempt" => "2"}, "inspection", %{
      "inspection_of" => ["W-1"]
    })

    in_state("stuck")
    {_s, page} = open(port, "/k/widget/W-1")
    p = panel(page)

    assert p["heading"] == "YOUR DECISION"
    assert p["title"] == "W-1 is stuck: what now?"

    assert p["byline"] == [
             %{"text" => "inspect"},
             %{"text" => "attempt 2 failed"},
             %{"text" => "stuck", "since" => @since}
           ]

    assert p["box"] == %{"title" => "What went wrong", "text" => "The bulb did not fit.", "tone" => "error"}
    assert p["choose"] == true

    assert [
             %{"key" => "r", "label" => "Retry", "recommended" => true, "detail" => "Inspects it again."},
             %{"key" => "c", "label" => "Close it", "detail" => "Ends it."} = close
           ] = p["answers"]

    refute Map.has_key?(close, "recommended")
    assert p["actions"] == [%{"label" => "Inspector's log", "key" => "l", "to" => "/k/inspection/I-1"}]
    assert ["r"] in keys(page) and ["c"] in keys(page) and ["l"] in keys(page)

    # Nothing recorded of what went wrong: it says so.
    FakeStore.put("W-1", %{"title" => "Lamp", "failure" => "none"}, "widget", %{"card" => ["C-W-1"]})
    {_s, page} = open(port, "/k/widget/W-1")
    assert panel(page)["box"]["text"] == "—"
  end

  test "someone who does not hold the work sees no panel", %{port: port} do
    FakeStore.put("W-1", %{"title" => "Lamp"}, "widget", %{"card" => ["C-W-1"]})
    in_state("check")
    Application.put_env(:atlas_control, :tui_user, "bob")
    {_s, page} = open(port, "/k/widget/W-1")
    refute Enum.any?(page["blocks"], &(&1["type"] == "panel"))
  end
end
