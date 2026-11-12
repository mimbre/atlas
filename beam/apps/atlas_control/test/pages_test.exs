defmodule AtlasControl.PagesTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{Pages, Shop}

  # The neutral model as Control serves it, and the same shop with one thing more or
  # different (`AtlasControl.Shop`).
  @d AtlasControl.Model.catalog(Shop)
  defp shop(variant), do: AtlasControl.Model.catalog(Module.concat(Shop, variant))

  defp fact(key, values, version \\ "v1"),
    do: %{"key" => key, "values" => values, "version" => version}

  test "failed reads preserve typed codes without deriving them from prose" do
    for code <- ["exact_identity_required", "store_error", nil] do
      failure = %{"error" => ":exact_identity_required"}
      failure = if code, do: Map.put(failure, "code", code), else: failure
      page = Pages.render({:list, "widget"}, @d, [failure])
      assert [%{"type" => "confirm", "props" => props}] = page.blocks
      assert props["code"] == code
      assert props["text"] =~ ":exact_identity_required"
    end
  end

  test "only kinds without a parent are on top; one top kind opens its list at once" do
    assert Pages.top_kinds(@d) == ["widget"]
    assert Pages.reads(:home, @d) == [{"widget", %{}}]
    page = Pages.render(:home, @d, [%{"facts" => []}])
    assert %{title: "Widgets", back: nil, blocks: [%{"type" => "list"}]} = page
  end

  test "routes and paths are each other's inverse" do
    for route <- [
          {:list, "widget"},
          {:new, "widget"},
          {:item, "widget", "W-1"},
          {:edit, "widget", "W 1"},
          {:delete, "widget", "W/1"}
        ] do
      assert Pages.route(Pages.path(route)) == route
    end
  end

  test "Control serves exactly the contract's pages: each one, and nothing else" do
    for page <- AtlasControl.Blocks.pages() do
      params = Map.new(page.params, &{&1, "x #{&1}"})
      path = AtlasControl.Blocks.path(page.name, params)
      route = Pages.route(path)

      refute route == :unknown, "page #{page.name} (#{path}) is not served"
      assert Pages.path(route) == path
    end

    for path <- ["/nothing", "/k", "/k/widget/W-1/sideways", "/k/widget/W-1/links", "/k/"] do
      assert Pages.route(path) == :unknown

      assert %{title: "No such page", blocks: [%{"props" => %{"text" => text}}]} =
               Pages.render(Pages.route(path), @d, [])

      assert text == "Control serves no page at this path."
    end
  end

  test "every destination a page names is a page of the contract" do
    widget = Map.put(fact("W-1", %{"title" => "One"}), "links", %{"checked_by" => ["ada"]})
    part = Map.put(fact("P-1", %{"title" => "Wheel"}), "links", %{"of_widget" => ["W-1"]})
    list = %{"facts" => [widget]}

    pages = [
      Pages.render(:home, @d, [list]),
      Pages.render(:kinds, @d, []),
      Pages.render({:list, "widget"}, @d, [list]),
      Pages.render({:new, "widget"}, @d, []),
      Pages.render({:new, "part", {"of_widget", "W-1"}}, @d, []),
      Pages.render({:item, "widget", "W-1"}, @d, [
        %{"fact" => widget, "incoming" => %{}},
        %{"facts" => [part]}
      ]),
      Pages.render({:item, "part", "P-1"}, @d, [%{"fact" => part}, %{"facts" => []}]),
      Pages.render({:edit, "part", "P-1"}, @d, [%{"fact" => part}, list]),
      Pages.render({:delete, "part", "P-1"}, @d, [%{"fact" => part, "incoming" => %{}}])
    ]

    destinations =
      for page <- pages,
          to <- [page.back | destinations(page.blocks)],
          is_binary(to),
          not String.contains?(to, "<key>"),
          do: to

    assert length(destinations) > 20

    for to <- destinations,
        do: assert({:ok, _, _} = AtlasControl.Blocks.match(to), "#{to} is no page")
  end

  test "every submit endpoint of the contract acts on a page; every form submits to one" do
    submits = for %{call: :submit} = e <- AtlasControl.Blocks.endpoints(), do: e

    for endpoint <- submits do
      params = Map.new(endpoint.params, &{&1, "x #{&1}"})
      route = Pages.submit_route(endpoint.name, params)

      # The page a submit endpoint acts on is the one at the same path: its form's own.
      assert Pages.route(Pages.path(route)) == route

      assert {:ok, endpoint.name, params} ==
               AtlasControl.Blocks.endpoint(:submit, Pages.path(route))

      assert %{takes: :values, replies: [%{name: :stored}, %{name: :refused}]} = endpoint
    end

    part = Map.put(fact("P-1", %{"title" => "Wheel"}), "links", %{"of_widget" => ["W-1"]})

    forms = [
      Pages.render({:new, "widget"}, @d, []),
      Pages.render({:new, "part", {"of_widget", "W-1"}}, @d, []),
      Pages.render({:edit, "part", "P-1"}, @d, [%{"fact" => part}, %{"facts" => []}]),
      Pages.render({:delete, "part", "P-1"}, @d, [%{"fact" => part, "incoming" => %{}}])
    ]

    submits_to =
      for page <- forms,
          %{"props" => props} <- page.blocks,
          to <- [props["submit_to"], props["confirm_to"]],
          is_map(to),
          do: to

    assert length(submits_to) == 4

    for to <- submits_to,
        do: assert({:ok, _, _} = Pages.submit_call(to), "#{inspect(to)} is no submit")

    assert AtlasControl.Blocks.endpoint(:submit, "/k/widget") == :error
  end

  defp destinations(value) when is_map(value) do
    Enum.flat_map(value, fn
      {key, to} when key in ~w(to back cancel_to submit_to confirm_to) and is_binary(to) -> [to]
      {_key, inner} -> destinations(inner)
    end)
  end

  defp destinations(value) when is_list(value), do: Enum.flat_map(value, &destinations/1)
  defp destinations(_value), do: []

  test "a list shows each fact's primary value, key and chosen values, sorted by key" do
    answer = %{
      "facts" => [
        fact("W-2", %{"title" => "Two", "done" => true}),
        fact("W-1", %{"title" => "One", "shade" => "dark"})
      ]
    }

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "widget"}, @d, [answer])

    assert [
             %{"id" => "W-1", "label" => "One", "detail" => "Dark", "to" => "/k/widget/W-1"},
             %{"id" => "W-2", "label" => "Two", "detail" => "done"}
           ] = list["rows"]

    assert [%{"key" => "c", "to" => "/k/widget/new", "label" => "Create widget"}] =
             list["actions"]
  end

  test "a row's detail: its choice by its label, then the flags set; also under a parent" do
    # As a row of a kind a connector fills reads "Open · draft".
    fitted = shop(Fitted)

    under = fn key, values ->
      Map.put(fact(key, Map.put(values, "title", key)), "links", %{"of_widget" => ["W-1"]})
    end

    parts = %{
      "facts" => [
        under.("P-1", %{"fit" => "tight", "spare" => true}),
        under.("P-2", %{"fit" => "loose", "spare" => false}),
        under.("P-3", %{})
      ]
    }

    widget = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{}}
    %{blocks: blocks} = Pages.render({:item, "widget", "W-1"}, fitted, [widget, parts])
    assert [list] = for(%{"type" => "list", "props" => %{"rows" => [_ | _]} = p} <- blocks, do: p)
    assert Enum.map(list["rows"], & &1["detail"]) == ["Tight · spare", "Loose", nil]

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "part"}, fitted, [parts])
    assert hd(list["rows"])["detail"] == "Tight · spare"
  end

  test "an item shows every described property, and a list of the facts that point at it" do
    answer = %{
      "fact" => fact("W-1", %{"title" => "One", "shade" => "light"}),
      "incoming" => %{"of_widget" => ["P-1"]}
    }

    parts = %{"facts" => [fact("P-1", %{"title" => "Wheel"})]}

    assert Pages.reads({:item, "widget", "W-1"}, @d) == [
             {"widget", %{"key" => "W-1"}},
             {"part", %{"linked" => %{"of_widget" => "W-1"}}}
           ]

    %{
      back: "/k/widget",
      blocks: [
        %{"id" => "item", "type" => "item", "props" => item},
        %{"id" => "list:of_widget", "type" => "list", "props" => list}
      ],
      markup: markup
    } =
      Pages.render({:item, "widget", "W-1"}, @d, [answer, parts])

    # Two parts, by what they hold: the main part (the fact) and the related part (the
    # related list, in a section that carries its title). Nothing about how they look.
    assert [
             %{
               "kind" => "part",
               "start" => "item",
               "end" => "item",
               "props" => %{"title" => "Content", "role" => "main"}
             },
             %{
               "kind" => "part",
               "start" => "list:of_widget",
               "end" => "list:of_widget",
               "props" => %{"title" => "References", "role" => "related"}
             },
             %{
               "kind" => "section",
               "start" => "list:of_widget",
               "end" => "list:of_widget",
               "props" => %{"title" => "Parts"}
             }
           ] = markup

    assert item["title"] == "Widget W-1: One"

    assert Enum.map(item["fields"], &{&1["label"], &1["value"]}) == [
             {"Id", "W-1"},
             {"Title", "One"},
             {"Shade", "Light"},
             {"Done", "no"},
             {"Notes", "—"}
           ]

    refute Map.has_key?(list, "title")
    assert [%{"label" => "Wheel", "to" => "/k/part/P-1"}] = list["rows"]

    assert [%{"label" => "Create part", "key" => "c", "to" => "/k/part/new/of_widget/W-1"}] =
             list["actions"]

    %{blocks: [_, %{"props" => none}]} =
      Pages.render({:item, "widget", "W-1"}, @d, [answer, %{"facts" => []}])

    assert none["empty"] == "No parts yet. Press c to create one."
  end

  test "a fact that points at a parent names it, and goes back and away to it" do
    part = %{
      "fact" => %{
        "key" => "P-1",
        "values" => %{"title" => "Wheel"},
        "links" => %{"of_widget" => ["W-1"]},
        "version" => "v1"
      }
    }

    %{back: "/k/widget/W-1", blocks: [%{"props" => item}, parent], markup: markup} =
      Pages.render({:item, "part", "P-1"}, @d, [part])

    assert {"Of widget", "W-1"} in Enum.map(item["fields"], &{&1["label"], &1["value"]})

    # Among its references, to open it from.
    assert %{"id" => "parent:of_widget", "type" => "list", "props" => %{"rows" => rows}} = parent
    assert [%{"id" => "W-1", "label" => "Widget", "to" => "/k/widget/W-1"} = row] = rows
    refute Map.has_key?(row, "detail")

    assert %{"kind" => "section", "props" => %{"title" => "Of widget"}} =
             Enum.find(markup, &(&1["start"] == "parent:of_widget" and &1["kind"] == "section"))

    assert Pages.after_delete(@d, "part", part) == {:item, "widget", "W-1"}
    assert Pages.after_delete(@d, "widget", %{"fact" => fact("W-1", %{})}) == {:list, "widget"}
  end

  test "a form to add a fact under its parent" do
    route = {:new, "part", {"of_widget", "W-1"}}
    assert Pages.route("/k/part/new/of_widget/W-1") == route
    %{back: "/k/widget/W-1", blocks: [%{"props" => form}]} = Pages.render(route, @d, [])
    assert form["title"] == "Create part in W-1"

    assert Pages.submit_call(form["submit_to"]) ==
             {:ok, :create_under, %{kind: "part", relation: "of_widget", parent: "W-1"}}

    assert form["cancel_to"] == "/k/widget/W-1"
  end

  test "a client that knows only the parent's key: _parent becomes the kind's parent relation" do
    route = Pages.route("/k/part/new/_parent/W-1")
    assert Pages.resolve(route, @d) == {:new, "part", {"of_widget", "W-1"}}

    assert Pages.resolve(Pages.route("/k/tag/new/_parent/P-1"), @d) ==
             {:new, "tag", {"on_part", "P-1"}}

    # A top kind belongs to no parent.
    assert Pages.resolve(Pages.route("/k/widget/new/_parent/W-1"), @d) == :unknown
    assert Pages.resolve({:list, "part"}, @d) == {:list, "part"}
  end

  test "a client that knows only a key: _ becomes the kind with that id prefix" do
    prefix = fn kind -> Pages.kind_view(@d, kind).id.prefix end
    part = prefix.("part") <> "07"
    assert Pages.resolve(Pages.route("/k/_/#{part}"), @d) == {:item, "part", part}
    assert Pages.resolve(Pages.route("/k/_/#{part}/edit"), @d) == {:edit, "part", part}
    assert Pages.resolve(Pages.route("/k/_/#{part}/delete"), @d) == {:delete, "part", part}
    # A key no prefix claims: the one kind without a prefix.
    assert Pages.resolve(Pages.route("/k/_/ada"), @d) == {:item, "member", "ada"}
  end

  test "the kinds page: per kind what a create asks, its id, its parent and its fields" do
    assert Pages.route("/_kinds") == :kinds
    assert Pages.path(:kinds) == "/_kinds"
    %{title: "Kinds", blocks: blocks} = Pages.render(:kinds, @d, [])
    items = for %{"type" => "item", "props" => props} <- blocks, do: props

    kinds =
      for item <- items,
          do: Enum.find_value(item["fields"], &(&1["label"] == "Kind" && &1["value"]))

    assert kinds == @d.kinds |> Map.keys() |> Enum.sort()

    part = Enum.find(items, &(&1["title"] =~ "(part)"))
    fields = Map.new(part["fields"], &{&1["label"], &1["value"]})
    assert fields["Belongs under"] == "widget"
    assert fields["Has under it"] == "tag"
    assert fields["Id"] =~ "P-"
    assert fields["Fields"] =~ "title: text; required"
    assert fields["Fields"] =~ "of_widget: the key of a widget; a change moves it there"

    widget = Enum.find(items, &(&1["title"] =~ "(widget)"))

    assert Enum.find_value(widget["fields"], &(&1["label"] == "Belongs under" && &1["value"])) ==
             "nothing; a top kind"
  end

  test "every action is Create, Update or Delete: the same words and keys everywhere" do
    widget = Pages.kind_view(@d, "widget")
    assert Pages.operation(:create, widget) == {"Create widget", "c"}
    assert Pages.operation(:update, widget) == {"Update widget", "u"}
    assert Pages.operation(:delete, widget) == {"Delete widget", "d"}
    assert Pages.operation(:update, nil) == {"Update", "u"}

    part = Map.put(fact("P-1", %{"title" => "Wheel"}), "links", %{"of_widget" => ["W-1"]})
    labels = fn actions -> Enum.map(actions, &{&1["key"], &1["label"]}) end

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "widget"}, @d, [%{"facts" => []}])
    assert labels.(list["actions"]) == [{"c", "Create widget"}]
    assert list["empty"] == "No widgets yet. Press c to create one."

    %{blocks: [%{"props" => item}, %{"props" => tags} | _]} =
      Pages.render({:item, "part", "P-1"}, @d, [%{"fact" => part}, %{"facts" => []}])

    assert labels.(item["actions"]) == [{"u", "Update part"}, {"d", "Delete part"}]
    assert labels.(tags["actions"]) == [{"c", "Create tag"}]

    %{title: "Create part in W-1", blocks: [%{"props" => create}]} =
      Pages.render({:new, "part", {"of_widget", "W-1"}}, @d, [])

    assert {create["title"], create["submit_label"]} == {"Create part in W-1", "Create"}

    %{title: "Update P-1", blocks: [%{"props" => update}]} =
      Pages.render({:edit, "part", "P-1"}, @d, [%{"fact" => part}, %{"facts" => []}])

    assert {update["title"], update["submit_label"]} == {"Update P-1", "Update"}

    %{title: "Delete P-1", blocks: [%{"props" => delete}]} =
      Pages.render({:delete, "part", "P-1"}, @d, [%{"fact" => part, "incoming" => %{}}])

    assert {delete["title"], delete["confirm_label"]} == {"Delete part P-1?", "Delete"}

    # What an agent's tools are called comes from the same place.
    %{blocks: kinds} = Pages.render(:kinds, @d, [])
    %{"props" => kind} = Enum.find(kinds, &(&1["props"]["title"] =~ "(part)"))

    assert Enum.map(kind["actions"], &{&1["key"], &1["label"], &1["to"]}) == [
             {"c", "Create part", "/k/part/new"},
             {"u", "Update part", "/k/_/<key>/edit"},
             {"d", "Delete part", "/k/_/<key>/delete"}
           ]

    # A page with a second related list creates there with the next free key.
    two = shop(Two)

    %{blocks: [_, %{"props" => first}, %{"props" => second}]} =
      Pages.render({:item, "widget", "W-1"}, two, [
        %{"fact" => fact("W-1", %{"title" => "One"})},
        %{"facts" => []},
        %{"facts" => []}
      ])

    assert {labels.(first["actions"]), labels.(second["actions"])} ==
             {[{"c", "Create part"}], [{"s", "Create spare"}]}

    assert second["empty"] == "No spares yet. Press s to create one."
  end

  # Widgets roll up their parts, parts their tags; a widget's shade is shown as "Look".
  @rolled AtlasControl.Model.catalog(Shop.Rolled)

  test "a list shows how far each fact is, as Facts works it out, in place of its own field" do
    answer = %{
      "facts" => [
        Map.put(fact("W-1", %{"title" => "One", "shade" => "dark"}), "progress", %{
          "value" => "fine",
          "label" => "Fine",
          "count" => 2,
          "of" => 3
        }),
        Map.put(
          fact("W-2", %{"title" => "Two", "shade" => "dark"}),
          "progress",
          %{
            "done" => true,
            "label" => "Done",
            "count" => 3,
            "of" => 3
          }
        ),
        Map.put(fact("W-3", %{"title" => "Three", "shade" => "dark"}), "progress", %{
          "value" => "dark",
          "label" => "Dark"
        }),
        fact("W-4", %{"title" => "Four", "shade" => "light"})
      ]
    }

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "widget"}, @rolled, [answer])

    assert Enum.map(list["rows"], & &1["detail"]) ==
             ["Fine · 2/3", "Done · 3/3", "Dark", nil]

    # A kind without a rule shows its fields as before.
    %{blocks: [%{"props" => list}]} = Pages.render({:list, "widget"}, @d, [answer])
    assert hd(list["rows"])["detail"] == "Dark"
  end

  test "a field shows under the description's label for it, on the page and in its form" do
    answer = %{"fact" => fact("W-1", %{"title" => "One", "shade" => "dark"}), "incoming" => %{}}

    %{blocks: [%{"props" => item} | _]} =
      Pages.render({:item, "widget", "W-1"}, @rolled, [answer, %{"facts" => []}])

    assert %{"label" => "Look", "value" => "Dark"} in item["fields"]

    %{blocks: [%{"props" => form}]} = Pages.render({:edit, "widget", "W-1"}, @rolled, [answer])
    assert "Look" in Enum.map(form["inputs"], & &1["label"])
  end

  describe "completion: done only when the fact itself is completed" do
    @completing AtlasControl.Model.catalog(Shop.Completing)

    test "the page says how far it is and why it is done, with the fact that did it" do
      origin = %{"since" => "2026-11-03T14:10:00Z", "by" => "ada", "cause" => "tested"}

      answer = %{
        "fact" => %{
          "key" => "W-1",
          "values" => %{"title" => "One"},
          "links" => %{"checked_by" => ["ada"]},
          "origins" => %{"checked_by" => origin},
          "progress" => %{"done" => true, "label" => "Done", "count" => 2, "of" => 2},
          "completion" => %{"done" => true, "by" => "checked_by", "keys" => ["ada"]},
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "widget", "W-1"}, @completing, [answer, %{"facts" => []}])

      assert %{"value" => "Done · 2/2 · checked by ada", "origin" => ^origin} =
               Enum.find(item["fields"], &(&1["label"] == "Progress"))

      part = %{
        "fact" => %{
          "key" => "P-1",
          "values" => %{"title" => "Wheel"},
          "links" => %{"of_widget" => ["W-1"]},
          "progress" => %{"done" => true, "label" => "Done"},
          "completion" => %{
            "done" => true,
            "over" => "on_part",
            "key" => "T-ok-1",
            "value" => "#ok/1"
          },
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "part", "P-1"}, @completing, [part, %{"facts" => []}])

      assert %{"value" => "Done · T-ok-1 #ok/1"} =
               Enum.find(item["fields"], &(&1["label"] == "Progress"))
    end

    test "showing something else while another fact holds: the page says why" do
      answer = %{
        "fact" => %{
          "key" => "P-1",
          "values" => %{"title" => "Wheel"},
          "links" => %{"of_widget" => ["W-1"]},
          "progress" => %{
            "value" => "fine",
            "label" => "Fine",
            "while" => %{
              "over" => "on_part",
              "key" => "T-a-1",
              "field" => "name",
              "value" => "open"
            }
          },
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "part", "P-1"}, @completing, [answer, %{"facts" => []}])

      assert %{"value" => "Fine · T-a-1 open"} =
               Enum.find(item["fields"], &(&1["label"] == "Progress"))
    end

    test "not done, without children: its own field says it; no Progress line" do
      answer = %{
        "fact" => %{
          "key" => "W-1",
          "values" => %{"title" => "One", "shade" => "dark"},
          "links" => %{},
          "progress" => %{"value" => "dark", "label" => "Dark"},
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "widget", "W-1"}, @completing, [answer, %{"facts" => []}])

      refute Enum.find(item["fields"], &(&1["label"] == "Progress"))
    end
  end

  test "a create form asks only what the kind's create rule asks; no id" do
    %{blocks: [%{"type" => "form", "props" => form}]} = Pages.render({:new, "widget"}, @d, [])
    assert Enum.map(form["inputs"], & &1["name"]) == ["title", "notes"]
    assert %{"required" => true} = hd(form["inputs"])
    # The description marks notes as text of several lines.
    assert Enum.map(form["inputs"], & &1["kind"]) == ["text", "multiline"]
    assert Pages.submit_call(form["submit_to"]) == {:ok, :create, %{kind: "widget"}}

    # Without a rule: every field a user may set, still no id.
    %{blocks: [%{"props" => plain}]} = Pages.render({:new, "part"}, @d, [])
    assert Enum.map(plain["inputs"], & &1["name"]) == ["title"]
  end

  test "a form shown again keeps what was typed and shows why it was refused" do
    page = Pages.render({:new, "widget"}, @d, [], %{values: %{"title" => "Mine"}, errors: ["no"]})
    %{blocks: [%{"props" => form}]} = page
    assert form["errors"] == ["no"]
    assert Enum.find(form["inputs"], &(&1["name"] == "title"))["value"] == "Mine"
  end

  test "a change form shows the id read-only and every field a user may set" do
    answer = %{"fact" => fact("W-01", %{"title" => "One", "ext_ref" => "X-9"})}
    %{blocks: [%{"props" => form}]} = Pages.render({:edit, "widget", "W-01"}, @d, [answer])
    inputs = Enum.map(form["inputs"], &{&1["name"], &1["kind"]})
    assert hd(inputs) == {"_key", "readonly"}
    assert Enum.map(inputs, &elem(&1, 0)) == ["_key", "title", "shade", "done", "notes"]

    assert %{
             "kind" => "choice",
             "choices" => [%{"value" => ""}, %{"value" => "light", "label" => "Light"}, _]
           } =
             Enum.find(form["inputs"], &(&1["name"] == "shade"))
  end

  test "a change form offers each parent relation: every fact of the parent's kind" do
    part = Map.put(fact("P-1", %{"title" => "Wheel"}), "links", %{"of_widget" => ["W-2"]})
    widgets = %{"facts" => [fact("W-2", %{"title" => "Two"}), fact("W-1", %{"title" => "One"})]}

    assert Pages.reads({:edit, "part", "P-1"}, @d) == [
             {"part", %{"key" => "P-1"}},
             {"widget", %{}}
           ]

    %{blocks: [%{"props" => form}]} =
      Pages.render({:edit, "part", "P-1"}, @d, [%{"fact" => part}, widgets])

    assert Enum.map(form["inputs"], & &1["name"]) == ["_key", "title", "of_widget"]

    # The current parent selected; a fact that has one keeps one, so no empty choice.
    assert %{
             "label" => "Of widget",
             "kind" => "choice",
             "value" => "W-2",
             "required" => true,
             "choices" => [
               %{"value" => "W-1", "label" => "W-1: One"},
               %{"value" => "W-2", "label" => "W-2: Two"}
             ]
           } = Enum.find(form["inputs"], &(&1["name"] == "of_widget"))

    # Without a parent: the empty choice first, and selected.
    loose = Map.put(part, "links", %{})

    %{blocks: [%{"props" => form}]} =
      Pages.render({:edit, "part", "P-1"}, @d, [%{"fact" => loose}, widgets])

    assert %{"value" => "", "required" => false, "choices" => [%{"value" => ""} | _]} =
             Enum.find(form["inputs"], &(&1["name"] == "of_widget"))

    assert Pages.parent_values(@d, "part", part) == %{"of_widget" => "W-2"}
  end

  test "text of several lines keeps its line breaks, on the page and in a change form" do
    notes = "## Why\n\nBecause.\n\n- one\n- two"
    answer = %{"fact" => fact("W-01", %{"title" => "One", "notes" => notes})}

    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "widget", "W-01"}, @d, [answer])
    assert Enum.find(item["fields"], &(&1["label"] == "Notes"))["value"] == notes

    %{blocks: [%{"props" => form}]} = Pages.render({:edit, "widget", "W-01"}, @d, [answer])

    assert %{"kind" => "multiline", "value" => ^notes} =
             Enum.find(form["inputs"], &(&1["name"] == "notes"))

    assert Pages.values_for(Pages.kind_view(@d, "widget"), %{"notes" => notes}) == %{
             "notes" => notes
           }
  end

  test "a field only a connector fills shows on the page only when it has a value" do
    labels = fn values ->
      %{blocks: [%{"props" => item}]} =
        Pages.render({:item, "widget", "W-01"}, @d, [%{"fact" => fact("W-01", values)}])

      Enum.map(item["fields"], & &1["label"])
    end

    refute "Ext ref" in labels.(%{"title" => "One"})
    assert "Ext ref" in labels.(%{"title" => "One", "ext_ref" => "X-9"})
  end

  test "a primary a connector fills names the fact once filled; until then its id's source" do
    d = shop(Named)

    tags = %{
      "facts" => [
        fact("T-a-1", %{"name" => "#a/1"}),
        fact("T-b-2", %{"name" => "#b/2", "note" => "Two"})
      ]
    }

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "tag"}, d, [tags])
    assert [%{"label" => "#a/1"}, %{"label" => "Two"}] = list["rows"]
  end

  test "a copy of an outside fact says when it was last read, and why a read failed" do
    last_read = fn copy ->
      answer = %{"fact" => fact("T-a-1", %{"name" => "#a/1", "note" => "x"}), "copy" => copy}
      %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "tag", "T-a-1"}, @d, [answer])
      Enum.find_value(item["fields"], &(&1["label"] == "Last read" && &1["value"]))
    end

    refute last_read.(nil)

    assert last_read.(%{"source" => "Outside", "read_at" => "2026-11-03T14:05:09Z"}) ==
             "2026-11-03 14:05 UTC from Outside"

    assert last_read.(%{
             "source" => "Outside",
             "read_at" => "2026-11-03T14:05:09Z",
             "failed_at" => "2026-11-03T14:10:00Z",
             "failure" => "it answered 503"
           }) ==
             "2026-11-03 14:05 UTC from Outside; the read at 2026-11-03 14:10 UTC failed: " <>
               "it answered 503; it is tried again"

    assert last_read.(%{
             "source" => "Outside",
             "read_at" => nil,
             "failed_at" => "2026-11-03T14:10:00Z",
             "failure" => "it answered 404"
           }) =~ "never from Outside; the read at 2026-11-03 14:10 UTC failed"
  end

  test "the next free key, and the values of a new fact" do
    spec = Pages.kind_view(@d, "widget")
    assert Pages.next_key(spec, []) == {"W-01", 1}
    assert Pages.next_key(spec, ["W-01", "W-07", "W-x", "Z-99"]) == {"W-08", 8}
    assert Pages.next_key(spec, ["W-01"], 4) == {"W-05", 5}

    # A ledger whose lower numbers are kept for facts added later starts at its first.
    ledger = Pages.kind_view(shop(Logged), "log")

    assert Pages.next_key(ledger, []) == {"L-0024", 24}
    assert Pages.next_key(ledger, ["L-0003", "L-0023"]) == {"L-0024", 24}
    assert Pages.next_key(ledger, ["L-0003", "L-0030"]) == {"L-0031", 31}

    assert Pages.create_values(@d, "widget", %{"title" => "One", "notes" => "", "shade" => "dark"}) ==
             %{"title" => "One", "notes" => "", "shade" => "light", "done" => false}
  end

  test "deleting asks first, and is refused while facts still hang under it" do
    free = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{"of_widget" => []}}
    %{blocks: [%{"props" => confirm}]} = Pages.render({:delete, "widget", "W-1"}, @d, [free])

    assert Pages.submit_call(confirm["confirm_to"]) ==
             {:ok, :delete, %{kind: "widget", key: "W-1"}}

    held = %{
      "fact" => fact("W-1", %{"title" => "One"}),
      "incoming" => %{"of_widget" => ["P-1", "P-2"]}
    }

    %{blocks: [%{"props" => refusal}]} = Pages.render({:delete, "widget", "W-1"}, @d, [held])
    refute Map.has_key?(refusal, "confirm_to")
    assert refusal["text"] =~ "still has 2 parts. Remove them first"

    one = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{"of_widget" => ["P-1"]}}
    %{blocks: [%{"props" => refusal}]} = Pages.render({:delete, "widget", "W-1"}, @d, [one])
    assert refusal["text"] =~ "still has 1 part. Remove it first"
    assert refusal["text"] =~ "never deletes it along with its parent"
  end

  test "a kind whose id is made from a property: the key is made, never typed or changed" do
    assert Shop.key("tag", %{"name" => " #a.b/12 "}) == {:ok, "T-a_b-12"}
    assert Shop.key("tag", %{"name" => "a.b"}) == {:error, "name must look like #word/1"}
    assert Pages.kind_view(@d, "tag").id.from == "name"
    assert Pages.kind_view(@d, "widget").id.from == nil

    %{blocks: [%{"props" => form}]} = Pages.render({:new, "tag", {"on_part", "P-1"}}, @d, [])
    assert Enum.map(form["inputs"], &{&1["name"], &1["kind"]}) == [{"name", "text"}]

    stored = %{"fact" => %{"key" => "T-a-1", "values" => %{"name" => "#a/1"}, "version" => "v1"}}

    # Shown, never changed: the id and the property it is made from.
    %{blocks: [%{"props" => edit}]} = Pages.render({:edit, "tag", "T-a-1"}, @d, [stored])

    assert Enum.map(edit["inputs"], &{&1["name"], &1["kind"], &1["value"]}) == [
             {"_key", "readonly", "T-a-1"},
             {"name", "readonly", "#a/1"},
             {"on_part", "choice", ""}
           ]

    # Labelled by that property; no field a user may set, but it can move to another part.
    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "tag", "T-a-1"}, @d, [stored])
    assert item["title"] == "Tag T-a-1: #a/1"
    assert Enum.map(item["actions"], & &1["key"]) == ["u", "d"]

    # A kind with nothing to set and no parent has nothing to change.
    loose = shop(Loose)
    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "tag", "T-a-1"}, loose, [stored])
    assert Enum.map(item["actions"], & &1["key"]) == ["d"]
  end

  test "a fact with a web address can be opened in a browser, on its page and on its row" do
    site = "https://example.org/tags/1"
    tag = fact("T-a-1", %{"name" => "#a/1", "site" => site})
    link = [%{"label" => "Open in browser", "key" => "o", "url" => site}]

    %{blocks: [%{"props" => item}]} =
      Pages.render({:item, "tag", "T-a-1"}, @d, [%{"fact" => tag}])

    assert item["links"] == link

    part = %{
      "fact" => fact("P-1", %{"title" => "Wheel"}),
      "incoming" => %{"on_part" => ["T-a-1"]}
    }

    page = Pages.render({:item, "part", "P-1"}, @d, [part, %{"facts" => [tag]}])
    [%{"props" => part_item}, %{"props" => tags}] = page.blocks
    refute Map.has_key?(part_item, "links")
    assert [%{"links" => ^link}] = tags["rows"]

    # Nothing to open without a value, nor anything but http and https.
    for values <- [%{"name" => "#a/1"}, %{"name" => "#a/1", "site" => "file:///etc/passwd"}] do
      %{blocks: [%{"props" => item}]} =
        Pages.render({:item, "tag", "T-a-1"}, @d, [%{"fact" => fact("T-a-1", values)}])

      refute Map.has_key?(item, "links")
    end
  end

  test "form text becomes the described types" do
    spec = Pages.kind_view(@d, "widget")

    assert Pages.values_for(spec, %{
             "_key" => "W-1",
             "title" => "x",
             "done" => "true",
             "shade" => ""
           }) ==
             %{"title" => "x", "done" => true, "shade" => ""}
  end

  # A record a client writes (as the agent keeps its requests): kept off the start page,
  # newest first, made by no key; its entries name the fact they changed.
  @logged AtlasControl.Model.catalog(Shop.Logged)

  test "a kind kept off the start page: an action there opens its list, newest first" do
    assert Pages.top_kinds(@logged) == ["widget"]
    %{blocks: [%{"props" => start}]} = Pages.render(:home, @logged, [%{"facts" => []}])

    assert [%{"key" => "c"}, %{"key" => "w", "label" => "What happened", "to" => "/k/log"}] =
             start["actions"]

    logs = %{
      "facts" => [fact("L-01", %{"title" => "First"}), fact("L-02", %{"title" => "Second"})]
    }

    %{back: "/", blocks: [%{"props" => list}]} = Pages.render({:list, "log"}, @logged, [logs])
    assert Enum.map(list["rows"], & &1["id"]) == ["L-02", "L-01"]
    assert list["actions"] == []
    refute list["empty"] =~ "Press"
  end

  # Helpers, kept off the start page and one key away from it; each row counts the widgets
  # and logs that point at it.
  @counted AtlasControl.Model.catalog(Shop.Counted)

  test "a kind whose rows count what points at it: one plain read per kind it comes from" do
    plain = %{"linked" => %{}, "plain" => true}

    assert Pages.reads({:list, "helper"}, @counted) == [
             {"helper", %{}},
             {"widget", plain},
             {"log", plain}
           ]

    assert Pages.reads({:list, "log"}, @counted) == [{"log", %{}}]

    %{blocks: [%{"props" => start}]} = Pages.render(:home, @counted, [%{"facts" => []}])
    assert %{"key" => "g", "label" => "Helpers", "to" => "/k/helper"} in start["actions"]

    helpers = %{"facts" => [fact("ada", %{"name" => "Ada"}), fact("bob", %{"name" => "Bob"})]}

    helped = fn key, by ->
      Map.put(fact(key, %{"title" => key}), "links", %{"helped_by" => by})
    end

    widgets = %{"facts" => [helped.("W-1", ["ada"]), helped.("W-2", ["ada"]), helped.("W-3", [])]}
    logs = %{"facts" => [helped.("L-01", ["ada"])]}

    %{blocks: [%{"props" => list}]} =
      Pages.render({:list, "helper"}, @counted, [helpers, widgets, logs])

    assert [%{"id" => "ada", "detail" => "3 helped"}, %{"id" => "bob", "detail" => "0 helped"}] =
             list["rows"]

    # A count whose read failed is left out, never shown as 0.
    %{blocks: [%{"props" => list}]} =
      Pages.render({:list, "helper"}, @counted, [helpers, widgets, %{"error" => "busy"}])

    assert [ada, _] = list["rows"]
    refute Map.has_key?(ada, "detail")

    # Every read of the list stands for its rows: which facts it counts matters.
    assert Pages.read_roles({:list, "helper"}, @counted) == [:rows, :rows, :rows]
  end

  # Tasks are made and deleted with something else, changed by hand only; each has an
  # optional time it is due, and is late (Facts says) once that has passed.
  @due AtlasControl.Model.catalog(Shop.Due)

  test "a kind changed by hand only, with a time it is due: shown, marked late, typed" do
    spec = Pages.kind_view(@due, "task")

    task =
      fact("T-1", %{"title" => "Wrap", "todo" => "Wrap it", "due" => "2026-11-04T11:00:00Z"})
      |> Map.put("late", true)

    answers =
      [
        %{"fact" => task}
        | for(_ <- tl(Pages.reads({:item, "task", "T-1"}, @due)), do: %{"facts" => []})
      ]

    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "task", "T-1"}, @due, answers)
    assert Enum.map(item["actions"], & &1["key"]) == ["u"]
    assert %{"label" => "Due", "value" => "2026-11-04 11:00 UTC · overdue"} in item["fields"]

    # Not late (Facts left it out): the time alone.
    answers = [%{"fact" => Map.delete(task, "late")} | tl(answers)]
    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "task", "T-1"}, @due, answers)
    assert %{"label" => "Due", "value" => "2026-11-04 11:00 UTC"} in item["fields"]

    # A list says that it is late, first, and when it was due; nothing to make one with.
    %{blocks: [%{"props" => list}]} =
      Pages.render({:list, "task"}, @due, [%{"facts" => [task]}])

    assert [%{"detail" => "Overdue · due 2026-11-04 11:00"}] = list["rows"]
    assert list["actions"] == []

    # A form's time is UTC, with or without the T and seconds; an offset is turned to UTC.
    assert Pages.values_for(spec, %{"due" => "2026-11-04 17:00"}) == %{
             "due" => "2026-11-04T17:00:00Z"
           }

    assert Pages.values_for(spec, %{"due" => "2026-11-04T18:00:00+01:00"}) == %{
             "due" => "2026-11-04T17:00:00Z"
           }

    assert Pages.values_for(spec, %{"due" => "tomorrow"}) == %{"due" => "tomorrow"}
    assert Pages.values_for(spec, %{"due" => ""}) == %{"due" => ""}
  end

  test "a fact Facts says is to be reviewed: the page says why, a list says it first" do
    task =
      fact("T-1", %{"title" => "Wrap", "todo" => "Wrap it"})
      |> Map.put("review", %{
        "label" => "Review: its pattern was replaced",
        "through" => "cut_from",
        "key" => "P-2",
        "field" => "status",
        "value" => "replaced"
      })

    answers =
      [
        %{"fact" => task}
        | for(_ <- tl(Pages.reads({:item, "task", "T-1"}, @due)), do: %{"facts" => []})
      ]

    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "task", "T-1"}, @due, answers)

    assert %{"label" => "Review: its pattern was replaced", "value" => "P-2 replaced"} in item[
             "fields"
           ]

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "task"}, @due, [%{"facts" => [task]}])
    assert [%{"detail" => "Review: its pattern was replaced · P-2"}] = list["rows"]

    # Nothing to review (Facts left it out): nothing said.
    answers = [%{"fact" => Map.delete(task, "review")} | tl(answers)]
    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "task", "T-1"}, @due, answers)
    refute Enum.any?(item["fields"], &(&1["label"] =~ "Review"))
  end

  # Checked by: an action that changes it whether it is set or not, asking the fact's
  # title with it, in one change with its own cause.
  @handed AtlasControl.Model.catalog(Shop.Handed)

  test "a change action: on the page with or without a link; its form asks its fields too" do
    hand = %{"key" => "h", "label" => "Hand to…", "to" => "/k/widget/W-1/links/checked_by"}

    answers = fn widget ->
      [
        %{"fact" => widget}
        | for(_ <- tl(Pages.reads({:item, "widget", "W-1"}, @handed)), do: %{"facts" => []})
      ]
    end

    for links <- [%{}, %{"checked_by" => ["ada"]}] do
      widget = Map.put(fact("W-1", %{"title" => "One"}), "links", links)

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "widget", "W-1"}, @handed, answers.(widget))

      assert hand in item["actions"]
    end

    widget = Map.put(fact("W-1", %{"title" => "One"}), "links", %{"checked_by" => ["ada"]})

    members = %{"facts" => [fact("ada", %{"name" => "Ada"}), fact("bob", %{"name" => "Bob"})]}

    %{title: title, blocks: [%{"props" => form}]} =
      Pages.render({:links, "widget", "W-1", "checked_by"}, @handed, [
        %{"fact" => widget},
        members
      ])

    assert title == "Hand to… One"
    assert Enum.map(form["inputs"], & &1["name"]) == ["_key", "to", "title", "note"]
    assert %{"name" => "to", "value" => "ada"} = Enum.at(form["inputs"], 1)
    assert %{"name" => "title", "value" => "One"} = Enum.at(form["inputs"], 2)

    change = Pages.change_action(@handed, "checked_by")
    assert Pages.change_cause(change, ["bob"], "melle", "") == "handed to bob by melle"
    assert Pages.change_cause(change, [], "melle", "") == "handed to nobody by melle"
    # A note says why in its own words.
    assert Pages.change_cause(change, ["bob"], "melle", "Bob builds it") == "Bob builds it"
    assert Pages.change_action(@d, "checked_by") == nil
  end

  test "a kind made by no key: its page has no actions, its entries no add" do
    answer = %{"fact" => fact("L-01", %{"title" => "First"})}
    entries = %{"facts" => [fact("E-01", %{"title" => "Made W-1", "about" => "W-1"})]}
    page = Pages.render({:item, "log", "L-01"}, @logged, [answer, entries])
    [item, entry_list] = for b <- page.blocks, do: b["props"]
    assert item["actions"] == []
    assert entry_list["actions"] == []
    assert [%{"id" => "E-01"}] = entry_list["rows"]
  end

  test "an item page lists the facts whose cause field names it" do
    # Every kind with a cause field (entries name what they changed; logs what they redo).
    assert Pages.reads({:item, "widget", "W-1"}, @logged) == [
             {"widget", %{"key" => "W-1"}},
             {"part", %{"linked" => %{"of_widget" => "W-1"}}},
             {"entry", %{}},
             {"log", %{}}
           ]

    answer = %{"fact" => fact("W-1", %{"title" => "One"})}

    entries = %{
      "facts" => [
        fact("E-01", %{"title" => "Made W-1", "about" => "W-1"}),
        fact("E-02", %{"title" => "Made W-2", "about" => "W-2"})
      ]
    }

    page =
      Pages.render({:item, "widget", "W-1"}, @logged, [
        answer,
        %{"facts" => []},
        entries,
        %{"facts" => []}
      ])

    assert %{"kind" => "section", "props" => %{"title" => "What happened here"}} =
             Enum.find(page.markup, &(&1["start"] == "cause:entry:about"))

    cause = Enum.find(page.blocks, &(&1["id"] == "cause:entry:about"))
    assert [%{"id" => "E-01", "to" => "/k/entry/E-01"}] = cause["props"]["rows"]

    # Nothing names it: no list.
    page =
      Pages.render({:item, "widget", "W-3"}, @logged, [
        answer,
        %{"facts" => []},
        entries,
        %{"facts" => []}
      ])

    refute Enum.any?(page.blocks, &String.starts_with?(&1["id"], "cause:"))
  end

  # A widget has a card, made and deleted with it (a made-up component, as the Assignment).
  @carded AtlasControl.Model.catalog(Shop.Carded)

  test "a fact's page shows its component's fields and associations as its own" do
    reads = Pages.reads({:item, "widget", "W-1"}, @carded)
    assert List.last(reads) == {"card", %{"key" => "C-W-1"}}

    widget = fact("W-1", %{"title" => "One"}) |> Map.put("links", %{"card" => ["C-W-1"]})

    card =
      fact("C-W-1", %{"of" => "W-1", "todo" => "Paint it"})
      |> Map.put("links", %{"held_by" => ["ada"]})
      |> Map.put("origins", %{
        "held_by" => %{"since" => "2026-11-03T10:00:00Z", "cause" => "hers"}
      })

    answers =
      for read <- reads do
        case read do
          {"widget", _} -> %{"fact" => widget}
          {"card", _} -> %{"fact" => card}
          _ -> %{"facts" => []}
        end
      end

    %{blocks: [item | references]} = Pages.render({:item, "widget", "W-1"}, @carded, answers)
    fields = Map.new(item["props"]["fields"], &{&1["label"], &1})

    assert fields["Todo"]["value"] == "Paint it"
    assert fields["Held by"]["value"] == "ada"
    assert fields["Held by"]["origin"]["cause"] == "hers"
    # Not the key it is made from, nor the link to it as a field; it opens from References.
    refute Map.has_key?(fields, "Of") or Map.has_key?(fields, "Card")
    assert Enum.any?(references, &(&1["id"] == "parent:card"))
    # What the component points at opens from the fact's page too.
    held = Enum.find(references, &(&1["id"] == "parent:held_by"))
    assert [%{"id" => "ada", "to" => "/k/member/ada"}] = held["props"]["rows"]

    # Without its component yet (before a migration), the fact's own fields only.
    answers = List.replace_at(answers, -1, %{"fact" => nil})
    %{blocks: [item | _]} = Pages.render({:item, "widget", "W-1"}, @carded, answers)
    refute Enum.any?(item["props"]["fields"], &(&1["label"] in ["Todo", "Held by"]))
  end

  test "the kinds page says which kinds are not made by hand" do
    by_layer = shop(ByLayer)
    %{blocks: blocks} = Pages.render(:kinds, by_layer, [])
    member = Enum.find(blocks, &(&1["id"] == "kind:member"))["props"]
    assert %{"label" => "By hand", "value" => "no"} in member["fields"]
    widget = Enum.find(blocks, &(&1["id"] == "kind:widget"))["props"]
    refute Enum.any?(widget["fields"], &(&1["label"] == "By hand"))
  end

  test "the kinds page says what a component is made with" do
    %{blocks: blocks} = Pages.render(:kinds, @carded, [])
    card = Enum.find(blocks, &(&1["id"] == "kind:card"))["props"]
    assert %{"label" => "Made with", "value" => "widget"} in card["fields"]
    widget = Enum.find(blocks, &(&1["id"] == "kind:widget"))["props"]
    refute Enum.any?(widget["fields"], &(&1["label"] == "Made with"))
  end

  test "a component is deleted with its fact, never alone" do
    widget = fact("W-1", %{"title" => "One"}) |> Map.put("links", %{"card" => ["C-W-1"]})
    answer = %{"fact" => widget, "incoming" => %{}}
    %{blocks: [confirm]} = Pages.render({:delete, "widget", "W-1"}, @carded, [answer])
    assert confirm["props"]["text"] =~ "will be deleted, with its Card C-W-1."

    card = %{"fact" => fact("C-W-1", %{"of" => "W-1"}), "incoming" => %{"card" => ["W-1"]}}
    # Its page goes back to its fact.
    others = List.duplicate(%{"facts" => []}, 9)
    assert %{back: "/k/_/W-1"} = Pages.render({:item, "card", "C-W-1"}, @carded, [card | others])

    %{blocks: [refused]} = Pages.render({:delete, "card", "C-W-1"}, @carded, [card])
    assert refused["props"]["text"] == "C-W-1 goes with W-1; delete that instead."
    refute refused["props"]["confirm_to"]
  end

  test "a component has its own page: its fields and links; back goes to its fact" do
    card =
      fact("C-W-1", %{"of" => "W-1", "todo" => "Paint it"})
      |> Map.put("links", %{"held_by" => ["ada"]})

    reads = Pages.reads({:item, "card", "C-W-1"}, @carded)

    answers =
      for read <- reads do
        case read do
          {"card", %{"key" => _}} -> %{"fact" => card, "incoming" => %{"card" => ["W-1"]}}
          _ -> %{"facts" => []}
        end
      end

    page = Pages.render({:item, "card", "C-W-1"}, @carded, answers)
    assert %{title: "Card C-W-1", back: "/k/_/W-1", blocks: [item | references]} = page
    assert item["props"]["title"] == "Card C-W-1: W-1"
    fields = Map.new(item["props"]["fields"], &{&1["label"], &1["value"]})
    assert %{"Of" => "W-1", "Todo" => "Paint it", "Held by" => "ada"} = fields

    assert [%{"props" => %{"rows" => [%{"id" => "ada", "to" => "/k/member/ada"}]}}] =
             Enum.filter(references, &(&1["id"] == "parent:held_by"))
  end

  test "each page offers the actions its kind allows" do
    widget = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{}}

    %{blocks: [%{"props" => item}, %{"props" => parts} | _]} =
      Pages.render({:item, "widget", "W-1"}, @d, [widget, %{"facts" => []}])

    assert Enum.map(item["actions"], &{&1["key"], &1["label"]}) ==
             [{"u", "Update widget"}, {"d", "Delete widget"}]

    assert Enum.map(parts["actions"], &{&1["key"], &1["label"]}) == [{"c", "Create part"}]

    %{title: create} = Pages.render({:new, "widget"}, @d, [])
    %{title: update} = Pages.render({:edit, "widget", "W-1"}, @d, [widget])
    assert {create, update} == {"Create widget", "Update W-1"}
  end

  test "an association a component holds is set on the component, from the fact's key" do
    assert Pages.resolve({:links, "widget", "W-1", "held_by"}, @carded) ==
             {:links, "card", "C-W-1", "held_by"}

    assert Pages.resolve({:links, "_", "W-1", "held_by"}, @carded) ==
             {:links, "card", "C-W-1", "held_by"}

    # The fact's own associations stay its own.
    assert Pages.resolve({:set, "widget", "W-1", "checked_by"}, @carded) ==
             {:set, "widget", "W-1", "checked_by"}
  end

  test "actions the description adds, only while a field has one of the values in when" do
    logged = @logged

    page = fn state ->
      answer = %{"fact" => fact("E-01", %{"title" => "One", "state" => state})}

      %{blocks: [item | _]} =
        Pages.render({:item, "entry", "E-01"}, logged, [answer, %{"facts" => []}])

      item["props"]["actions"]
    end

    assert [%{"key" => "x", "label" => "Undo", "to" => "agent:undo"}] = page.("done")
    assert page.("dropped") == []
  end

  test "a cause field may name a fact of its own kind" do
    logged = @logged

    assert {"log", %{}} in Pages.reads({:item, "log", "L-01"}, logged)
    answer = %{"fact" => fact("L-01", %{"title" => "First"})}
    redo = %{"facts" => [fact("L-02", %{"title" => "Again", "redoes" => "L-01"})]}
    reads = Pages.reads({:item, "log", "L-01"}, logged)

    answers =
      for {kind, content} <- tl(reads),
          do: if(kind == "log" and content == %{}, do: redo, else: %{"facts" => []})

    page = Pages.render({:item, "log", "L-01"}, logged, [answer | answers])
    redone = Enum.find(page.blocks, &(&1["id"] == "cause:log:redoes"))
    assert [%{"id" => "L-02"}] = redone["props"]["rows"]
  end

  # An association from two kinds to two kinds, as an owner is (made-up kinds).
  @held AtlasControl.Model.catalog(Shop.Held)

  test "a relation from several kinds: one list per kind on the page it points at" do
    reads = Pages.reads({:item, "keeper", "K-1"}, @held)
    assert {"widget", %{"linked" => %{"held_by" => "K-1"}}} in reads
    assert {"part", %{"linked" => %{"held_by" => "K-1"}}} in reads

    answer = %{"fact" => fact("K-1", %{"title" => "Keeps"})}
    widgets = %{"facts" => [fact("W-1", %{"title" => "One"})]}

    answers =
      for {kind, _} <- tl(reads), do: if(kind == "widget", do: widgets, else: %{"facts" => []})

    page = Pages.render({:item, "keeper", "K-1"}, @held, [answer | answers])

    held = Enum.find(page.blocks, &(&1["id"] == "list:held_by:widget"))
    assert [%{"id" => "W-1"}] = held["props"]["rows"]
    # An empty list of an association does not show.
    refute Enum.find(page.blocks, &(&1["id"] == "list:held_by:part"))

    assert %{"props" => %{"title" => "Holdings: Widgets"}} =
             Enum.find(
               page.markup,
               &(&1["kind"] == "section" and &1["start"] == "list:held_by:widget")
             )
  end

  test "a relation to several kinds: the row opens the kind Facts says the key is" do
    answer = %{
      "fact" =>
        fact("W-1", %{"title" => "One"})
        |> Map.put("links", %{"held_by" => ["K-1"]})
        |> Map.put("link_kinds", %{"held_by" => %{"K-1" => "keeper"}})
    }

    reads = Pages.reads({:item, "widget", "W-1"}, @held)

    page =
      Pages.render({:item, "widget", "W-1"}, @held, [
        answer | for(_ <- tl(reads), do: %{"facts" => []})
      ])

    held = Enum.find(page.blocks, &(&1["id"] == "parent:held_by"))

    assert [%{"id" => "K-1", "label" => "Keeper", "to" => "/k/keeper/K-1"}] =
             held["props"]["rows"]

    # The links page offers the facts of every kind it may point at.
    assert Pages.reads({:links, "widget", "W-1", "held_by"}, @held) == [
             {"widget", %{"key" => "W-1"}},
             {"tag", %{}},
             {"keeper", %{}}
           ]
  end

  # A start page of what is assigned to the client (made-up kinds and words).
  @assigning AtlasControl.Model.catalog(Shop.Assigning)

  defp kept(key, title, since, cause, extra \\ %{}) do
    fact(key, Map.merge(%{"title" => title}, extra))
    |> Map.put("origins", %{"kept_by" => %{"since" => since, "cause" => cause}})
  end

  # What is assigned is a component (a card, as the Assignment): the start page shows the
  # fact it belongs to, with what is expected on the card and why.
  @carded_start AtlasControl.Model.catalog(Shop.CardedStart)

  test "assigned components select only their owners from full owner lists" do
    assert Pages.reads({:assigned, "ada"}, @carded_start) == [
             {"card", %{"linked" => %{"held_by" => "ada"}}},
             {"widget", %{}}
           ]

    held = fn key, of, since, cause ->
      fact(key, %{"of" => of, "todo" => "Paint it"})
      |> Map.put("origins", %{"held_by" => %{"since" => since, "cause" => cause}})
    end

    cards = %{
      "facts" => [
        held.("C-W-1", "W-1", "2026-11-03T10:00:00Z", "hers"),
        held.("C-W-2", "W-2", "2026-11-03T12:00:00Z", "done one")
      ]
    }

    widgets = %{
      "facts" => [
        fact("W-1", %{"title" => "One"}) |> Map.put("links", %{"card" => ["C-W-1"]}),
        fact("W-2", %{"title" => "Two"})
        |> Map.put("links", %{"card" => ["C-W-2"]})
        |> Map.put("completion", %{"done" => true}),
        fact("W-3", %{"title" => "Not held"}) |> Map.put("links", %{"card" => ["C-W-3"]})
      ]
    }

    %{blocks: [%{"props" => list}]} =
      Pages.render({:assigned, "ada"}, @carded_start, [cards, widgets])

    # The fact, not its card; a completed one is not there; what the card expects, and why.
    assert [%{"id" => "W-1", "label" => "One", "to" => "/k/widget/W-1"} = row] = list["rows"]
    assert row["detail"] =~ ~r/^Paint it · since 3 Nov \d\d:00 · hers$/
    assert Pages.assigned_count(@carded_start, [cards, widgets]) == "1 held"

    selected_widgets = %{"facts" => Enum.take(widgets["facts"], 2)}

    assert Pages.render({:assigned, "ada"}, @carded_start, [cards, widgets]) ==
             Pages.render({:assigned, "ada"}, @carded_start, [cards, selected_widgets])

    assert Pages.assigned_facts(@carded_start, [%{"facts" => []}, widgets]) == []
    assert Pages.assigned_count(@carded_start, [%{"facts" => []}, widgets]) == "0 held"
  end

  # Open work: the list of the cards is what is held, for everyone; a card is due by a time.
  @open AtlasControl.Model.catalog(Shop.Open)

  test "open work: the same rows for everyone, with who holds each; late first" do
    assert Pages.open_work?(@open, "card")
    refute Pages.open_work?(@open, "widget")
    refute Pages.open_work?(@carded_start, "card")
    assert Pages.reads({:list, "card"}, @open) == [{"card", %{}}, {"widget", %{}}]
    # The cards are the rows; the widgets only resolve whose card each is.
    assert Pages.read_roles({:list, "card"}, @open) == [:rows, :lookup]

    card = fn key, by, values, since ->
      fact(key, Map.merge(%{"of" => String.replace_prefix(key, "C-", "")}, values))
      |> Map.put("links", %{"held_by" => by})
      |> Map.put("origins", %{"held_by" => %{"since" => since, "cause" => "why"}})
    end

    cards = %{
      "facts" => [
        card.("C-W-1", ["ada"], %{"todo" => "Paint it"}, "2026-11-03T12:00:00Z"),
        card.(
          "C-W-2",
          ["bob"],
          %{"todo" => "Sand it", "due" => "2020-01-02T12:00:00Z"},
          "2026-11-03T10:00:00Z"
        )
        |> Map.put("late", true),
        # Nobody holds it and nothing is expected: not open work.
        card.("C-W-3", [], %{}, nil),
        card.("C-W-4", ["ada"], %{"todo" => "Paint it"}, "2026-11-03T13:00:00Z")
      ]
    }

    widget = fn key, title ->
      fact(key, %{"title" => title}) |> Map.put("links", %{"card" => ["C-" <> key]})
    end

    widgets = %{
      "facts" => [
        widget.("W-1", "One"),
        widget.("W-2", "Two"),
        widget.("W-3", "Three"),
        widget.("W-4", "Done") |> Map.put("completion", %{"done" => true})
      ]
    }

    %{title: "All held", back: "/", blocks: [%{"props" => list}]} =
      Pages.render({:list, "card"}, @open, [cards, widgets])

    # Late first; each with who holds it, what is expected, and its time.
    assert [%{"id" => "W-2", "to" => "/k/widget/W-2"} = late, %{"id" => "W-1"} = one] =
             list["rows"]

    assert late["detail"] =~
             ~r/^bob · Sand it · Late · due 2020-01-02 12:00 · since 3 Nov \d\d:00$/

    assert one["detail"] =~ ~r/^ada · Paint it · since 3 Nov \d\d:00$/

    %{blocks: [%{"props" => empty}]} =
      Pages.render({:list, "card"}, @open, [%{"facts" => []}, %{"facts" => []}])

    assert empty["rows"] == [] and empty["empty"] == "Nothing is held."
  end

  test "open work exposes partial and total collection failures instead of authoritative rows" do
    description = shop(AssigningOpen)

    visible =
      kept("W-1", "Still open", "2026-11-03T12:00:00Z", "assigned")
      |> Map.put("links", %{"kept_by" => ["ada"]})

    success = %{"facts" => [visible]}

    failed = %{
      "error" => "Collection read failed",
      "error_kind" => "answered",
      "code" => "store_error"
    }

    for answers <- [[success, failed], [failed, success], [failed, failed]] do
      page = Pages.render({:list, "widget"}, description, answers)
      assert [%{"type" => "confirm", "props" => props}] = page.blocks
      assert props["text"] =~ failed["error"]
      assert props["code"] == "store_error"
      refute Map.has_key?(props, "confirm_to")
      refute JSON.encode!(page) =~ "Nothing is open."
    end
  end

  test "open work recovery restores current rows and only successful emptiness shows the empty message" do
    description = shop(AssigningOpen)

    failed = %{"error" => "Private backend unavailable", "error_kind" => "unreachable"}

    assert [%{"type" => "confirm"}] =
             Pages.render({:list, "widget"}, description, [failed, failed]).blocks

    current =
      kept("W-2", "Fresh work", "2026-11-03T13:00:00Z", "new assignment")
      |> Map.put("links", %{"kept_by" => ["ada"]})

    completed = Map.put(current, "completion", %{"done" => true})

    recovered =
      Pages.render({:list, "widget"}, description, [
        %{"facts" => [current]},
        %{"facts" => []}
      ])

    assert [
             %{
               "type" => "list",
               "props" => %{"rows" => [%{"id" => "W-2", "label" => "Fresh work"}]}
             }
           ] =
             recovered.blocks

    empty =
      Pages.render({:list, "widget"}, description, [
        %{"facts" => [completed]},
        %{"facts" => []}
      ])

    assert [%{"type" => "list", "props" => %{"rows" => [], "empty" => "Nothing is open."}}] =
             empty.blocks
  end

  # What to do (IS-Atlas-54): a flow on widgets, on their card; its state is the card's step.
  @todo AtlasControl.Model.catalog(Shop.Todo)

  test "a fact's owner sees what to do, first; anyone else does not" do
    notes = "Some intro.\n\nCheck: the paint is even\nand dry.\n\n## Later\nnot this"

    widget =
      fact("W-1", %{"title" => "One", "notes" => notes})
      |> Map.put("links", %{"card" => ["C-W-1"]})

    card =
      fact("C-W-1", %{"of" => "W-1", "todo" => "Check it", "step" => "check"})
      |> Map.put("links", %{"held_by" => ["ada"]})
      |> Map.put("origins", %{
        "held_by" => %{
          "since" => "2026-11-03T10:00:00Z",
          "by" => "flow",
          "cause" => "Flow f: painted → ada"
        }
      })

    answers =
      for read <- Pages.reads({:item, "widget", "W-1"}, @todo) do
        case read do
          {"widget", _} -> %{"fact" => widget}
          {"card", _} -> %{"fact" => card}
          _ -> %{"facts" => []}
        end
      end

    page = Pages.render({:item, "widget", "W-1"}, @todo, answers, %{by: "ada"})
    assert [%{"id" => "todo", "type" => "item", "props" => todo} | _] = page.blocks

    assert %{"start" => "todo", "props" => %{"title" => "Your move", "role" => "todo"}} =
             hd(page.markup)

    assert todo["title"] == "Your move: Check it"

    assert [
             %{
               "label" => "Because",
               "value" => "Flow f: painted → ada",
               "origin" => %{"by" => "flow"}
             },
             %{"label" => "How", "value" => "Look it over."},
             %{"label" => "Check", "value" => "the paint is even\nand dry."},
             %{"label" => "Keys", "value" => "a Approve"}
           ] = todo["fields"]

    # The state is not a field of the fact.
    item = Enum.find(page.blocks, &(&1["id"] == "item"))
    refute Enum.any?(item["props"]["fields"], &(&1["label"] == "Step"))

    # Not the owner, or no state written yet: no such part.
    for {form, answers} <- [
          {%{by: "bob"}, answers},
          {%{by: nil}, answers},
          {%{by: "ada"},
           List.replace_at(answers, -1, %{"fact" => put_in(card, ["values", "step"], nil)})}
        ] do
      page = Pages.render({:item, "widget", "W-1"}, @todo, answers, form)
      refute Enum.any?(page.blocks, &(&1["id"] == "todo"))
    end
  end

  # Answers (IS-Atlas-56): approve sets checked_by, a widget association; send back removes
  # it, also when it is not set.
  @answering AtlasControl.Model.catalog(Shop.Answering)

  defp answering_reads(route, card_owner) do
    widget = fact("W-1", %{"title" => "One"}) |> Map.put("links", %{"card" => ["C-W-1"]})

    card =
      fact("C-W-1", %{"of" => "W-1", "todo" => "Check it", "step" => "check"})
      |> Map.put("links", %{"held_by" => [card_owner]})

    for read <- Pages.reads(route, @answering) do
      case read do
        {"widget", %{"key" => _}} -> %{"fact" => widget}
        {"card", _} -> %{"fact" => card}
        _ -> %{"facts" => []}
      end
    end
  end

  test "the owner's answers are actions, in place of one on the same key; nobody else's" do
    route = {:item, "widget", "W-1"}

    page =
      Pages.render(route, @answering, answering_reads(route, "ada"), %{
        by: "ada",
        by_kind: "member"
      })

    item = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]

    assert [
             %{"key" => "v", "label" => "Approve", "to" => "/k/widget/W-1/set/checked_by"},
             %{"key" => "z", "label" => "Send back", "to" => "/k/widget/W-1/remove/checked_by"}
             | rest
           ] = item["actions"]

    refute Enum.any?(rest, &(&1["key"] in ["v", "z"]))

    page =
      Pages.render(route, @answering, answering_reads(route, "bob"), %{
        by: "ada",
        by_kind: "member"
      })

    item = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]
    # The association's own action, as before; no answers.
    assert %{"key" => "v", "label" => "Check", "to" => "/k/widget/W-1/set/checked_by"} in item[
             "actions"
           ]

    refute Enum.any?(item["actions"], &(&1["label"] == "Send back"))
  end

  test "an answer that removes asks for a note, also when nothing is set; else it is refused" do
    route = {:remove, "widget", "W-1", "checked_by"}
    form = %{by: "ada", by_kind: "member"}

    %{blocks: [%{"type" => "form", "props" => send_back}]} =
      Pages.render(route, @answering, answering_reads(route, "ada"), form)

    assert send_back["title"] == "Send back W-1"
    assert [%{"name" => "_key"}, %{"name" => "note", "kind" => "multiline"}] = send_back["inputs"]

    # Not the owner: nothing to remove, as before.
    %{blocks: [%{"type" => "confirm", "props" => refused}]} =
      Pages.render(route, @answering, answering_reads(route, "bob"), form)

    assert refused["text"] == "W-1 has no checked by."
  end

  test "a client of a kind the start's relation points at opens on what points at it" do
    assert Pages.assigned_start?(@assigning, "keeper")
    refute Pages.assigned_start?(@assigning, nil)
    refute Pages.assigned_start?(@d, "keeper")

    assert Pages.reads({:assigned, "K-1"}, @assigning) == [
             {"widget", %{"linked" => %{"kept_by" => "K-1"}}},
             {"part", %{"linked" => %{"kept_by" => "K-1"}}}
           ]

    widgets = %{
      "facts" => [
        kept("W-1", "Older", "2026-11-03T10:00:00Z", "first", %{"shade" => "dark"}),
        kept("W-2", "Done", "2026-11-03T12:00:00Z", "done")
        |> Map.put("completion", %{"done" => true})
      ]
    }

    parts = %{"facts" => [kept("P-1", "Newer", "2026-11-03T11:00:00Z", "second")]}
    answers = [widgets, parts]

    %{title: "Kept by you", back: nil, blocks: [%{"props" => list}]} =
      Pages.render({:assigned, "K-1"}, @assigning, answers)

    # Newest move first; a completed one is not there; what its flow expects, and why.
    assert [%{"id" => "P-1", "to" => "/k/part/P-1"}, %{"id" => "W-1"} = older] = list["rows"]
    assert older["detail"] =~ ~r/^dark · since 3 Nov \d\d:00 · first$/
    assert [%{"key" => "s", "label" => "Widgets", "to" => "/k/widget"}] = list["actions"]
    assert Pages.assigned_count(@assigning, answers) == "2 kept by you"

    %{blocks: [%{"props" => empty}]} =
      Pages.render({:assigned, "K-1"}, @assigning, [%{"facts" => []}, %{"facts" => []}])

    assert empty["rows"] == [] and empty["empty"] == "Nothing is kept by you."
  end

  test "with a start of assignments, the only top kind's list goes back to it" do
    answer = %{"facts" => []}
    assert %{back: nil} = Pages.render({:list, "widget"}, @assigning, [answer], %{by_kind: nil})

    assert %{back: "/"} =
             Pages.render({:list, "widget"}, @assigning, [answer], %{by_kind: "keeper"})
  end

  test "the kinds page names the kinds that hold a record" do
    %{blocks: blocks} =
      Pages.render(:kinds, @logged, [])

    log = Enum.find(blocks, &(&1["id"] == "kind:log"))["props"]
    assert %{"label" => "Agent record", "value" => "request"} in log["fields"]
  end

  test "a read that failed says what happened: no answer, no connection, or rela's error" do
    page = fn answer ->
      %{title: title, blocks: [%{"props" => confirm}]} =
        Pages.render({:list, "widget"}, @d, [answer])

      {title, confirm["text"]}
    end

    assert page.(%{"error" => "Facts did not answer"}) ==
             {"Facts did not answer",
              "Facts did not answer. Showing nothing rather than something old."}

    assert {"rela is not reachable", "rela is not reachable. " <> _} =
             page.(%{"error" => "rela is not reachable", "error_kind" => "unreachable"})

    older = "rela does not know widget: its description is older than this build; run x"

    assert {"rela answered with an error", ^older <> ". Showing nothing" <> _} =
             page.(%{"error" => older, "error_kind" => "answered"})
  end

  test "a page about a kind rela does not describe says so" do
    assert %{blocks: [%{"type" => "confirm"}]} =
             Pages.render({:list, "gadget"}, @d, [%{"facts" => []}])
  end

  describe "associations: a concept a kind has by being in a relation's from" do
    test "an association is no parent: it moves nothing on top, nor the way back" do
      # widget is in checked_by's from, at most one, and still on top; member is reached
      # only through what points at it.
      assert Pages.top_kinds(@d) == ["widget"]

      assert Pages.resolve(Pages.route("/k/part/new/_parent/W-1"), @d) ==
               {:new, "part", {"of_widget", "W-1"}}

      part = %{
        "fact" => %{
          "key" => "P-1",
          "values" => %{"title" => "Wheel"},
          "links" => %{"of_widget" => ["W-1"], "checked_by" => ["ada"]},
          "version" => "v1"
        }
      }

      assert %{back: "/k/widget/W-1"} = Pages.render({:item, "part", "P-1"}, @d, [part])
      assert Pages.after_delete(@d, "part", part) == {:item, "widget", "W-1"}
    end

    test "the page shows the link with the fact that set it: since, by, why" do
      origin = %{"since" => "2026-11-03T14:10:00Z", "by" => "ada", "cause" => "tested it"}

      answer = %{
        "fact" => %{
          "key" => "W-1",
          "values" => %{"title" => "One"},
          "links" => %{"checked_by" => ["ada"], "seen_in" => ["T-a-1", "T-b-2"]},
          "origins" => %{"checked_by" => Map.put(origin, "keys", ["ada"])},
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "widget", "W-1"}, @d, [answer, %{"facts" => []}])

      fields = Map.new(item["fields"], &{&1["label"], &1})
      assert %{"value" => "ada", "origin" => ^origin} = fields["Checked by"]
      assert %{"value" => "T-a-1, T-b-2"} = fields["Also seen in"]
      refute Map.has_key?(fields["Also seen in"], "origin")
    end

    test "a removed link shows as removed while that is the latest fact about it" do
      answer = %{
        "fact" => %{
          "key" => "W-1",
          "values" => %{"title" => "One"},
          "links" => %{},
          "origins" => %{"checked_by" => %{"keys" => [], "by" => "ada", "cause" => "broke"}},
          "version" => "v1"
        },
        "incoming" => %{}
      }

      %{blocks: [%{"props" => item} | _]} =
        Pages.render({:item, "widget", "W-1"}, @d, [answer, %{"facts" => []}])

      assert %{"value" => "—", "origin" => %{"cause" => "broke"}} =
               Enum.find(item["fields"], &(&1["label"] == "Checked by"))
    end

    test "facts that point here through an association are listed, with nothing to add" do
      answer = %{"fact" => fact("T-a-1", %{"name" => "#a/1"}), "incoming" => %{}}
      seen = %{"facts" => [fact("W-1", %{"title" => "One"})]}

      %{blocks: blocks} =
        Pages.render({:item, "tag", "T-a-1"}, @d, [answer, seen])

      assert [%{"props" => list}] = for(%{"type" => "list"} = b <- blocks, do: b)
      assert list["actions"] == []
      assert [%{"label" => "One"}] = list["rows"]

      # None: no list at all.
      %{blocks: blocks} =
        Pages.render({:item, "tag", "T-a-1"}, @d, [answer, %{"facts" => []}])

      assert for(%{"type" => "list"} = b <- blocks, do: b) == []
    end

    test "a form sets or removes the links of an association, with a note" do
      route = Pages.route("/k/widget/W-1/links/checked_by")
      assert route == {:links, "widget", "W-1", "checked_by"}
      assert Pages.path(route) == "/k/widget/W-1/links/checked_by"
      assert Pages.resolve(Pages.route("/k/_/W-1/links/checked_by"), @d) == route
      assert Pages.reads(route, @d) == [{"widget", %{"key" => "W-1"}}, {"member", %{}}]

      answer = %{
        "fact" =>
          %{fact("W-1", %{"title" => "One"}) | "version" => "v1"}
          |> Map.put("links", %{"checked_by" => ["ada"]})
      }

      members = %{"facts" => [fact("bob", %{"name" => "Bob"}), fact("ada", %{"name" => "Ada"})]}

      %{back: "/k/widget/W-1", blocks: [%{"type" => "form", "props" => form}]} =
        Pages.render(route, @d, [answer, members])

      inputs = Map.new(form["inputs"], &{&1["name"], &1})
      assert inputs["to"]["value"] == "ada"
      assert Enum.map(inputs["to"]["choices"], & &1["value"]) == ["", "ada", "bob"]
      assert inputs["note"]["kind"] == "multiline"

      assert Pages.submit_call(form["submit_to"]) ==
               {:ok, :link, %{kind: "widget", key: "W-1", relation: "checked_by"}}

      assert Pages.link_keys("ada, bob ada") == ["ada", "bob"]
      assert Pages.link_keys("") == []
    end

    test "a link a migration sets, or a parent, is never set through a form" do
      answer = %{"fact" => fact("W-1", %{"title" => "One"})}

      %{blocks: [%{"type" => "confirm", "props" => confirm}]} =
        Pages.render({:links, "widget", "W-1", "seen_in"}, @d, [answer, %{"facts" => []}])

      assert confirm["text"] =~ "only a migration sets it"
      refute Pages.settable_relation?(@d, "seen_in")
      refute Pages.settable_relation?(@d, "of_widget")
      assert Pages.settable_relation?(@d, "checked_by")
    end

    test "a member has no section on the start page, though no fact is above it" do
      assert Pages.top_kinds(@d) == ["widget"]
      assert Pages.reads(:home, @d) == [{"widget", %{}}]

      shown = shop(Shown)
      assert Enum.sort(Pages.top_kinds(shown)) == ["member", "widget"]
    end

    test "the kinds page lists a kind's associations" do
      %{blocks: blocks} = Pages.render(:kinds, @d, [])
      widget = Enum.find(blocks, &(&1["props"]["title"] =~ "(widget)"))
      links = Enum.find_value(widget["props"]["fields"], &(&1["label"] == "Links" && &1["value"]))
      assert links =~ "checked_by: to member, at most one; set checked_by=<key>"
      assert links =~ "seen_in: to tag; set by a migration, never by hand"
    end
  end

  describe "a link only one of its targets sets, to itself: approve and withdraw" do
    @member %{by: "ada", by_kind: "member"}
    @agent %{by: "agent", by_kind: nil}

    defp widget(links),
      do: %{
        "fact" => %{
          "key" => "W-1",
          "values" => %{"title" => "One"},
          "links" => links,
          "version" => "v1"
        },
        "incoming" => %{}
      }

    test "the page offers approve to a member, withdraw once approved; nothing to an agent" do
      keys = fn page ->
        %{blocks: [%{"props" => item} | _]} = page
        for a <- item["actions"], do: {a["key"], a["label"], a["to"]}
      end

      page = Pages.render({:item, "widget", "W-1"}, @d, [widget(%{}), %{"facts" => []}], @member)
      assert {"a", "Approve", "/k/widget/W-1/set/approved_by"} in keys.(page)

      approved = widget(%{"approved_by" => ["ada"]})
      page = Pages.render({:item, "widget", "W-1"}, @d, [approved, %{"facts" => []}], @member)
      # One action on one key: approve until approved, withdraw after.
      assert {"a", "Withdraw", "/k/widget/W-1/remove/approved_by"} in keys.(page)
      refute {"a", "Approve", "/k/widget/W-1/set/approved_by"} in keys.(page)

      page = Pages.render({:item, "widget", "W-1"}, @d, [widget(%{}), %{"facts" => []}], @agent)
      refute Enum.any?(keys.(page), &(elem(&1, 0) == "a"))
    end

    test "approve asks first, also while a fact under it is open (Facts says so); not an agent" do
      route = Pages.route("/k/widget/W-1/set/approved_by")
      assert route == {:set, "widget", "W-1", "approved_by"}
      assert Pages.resolve(Pages.route("/k/_/W-1/set/approved_by"), @d) == route
      assert Pages.reads(route, @d) == Pages.reads({:item, "widget", "W-1"}, @d)

      done = Map.put(fact("P-1", %{"title" => "Wheel"}), "completion", %{"done" => true})
      open = fact("P-2", %{"title" => "Spoke"})

      %{blocks: [%{"props" => confirm}]} =
        Pages.render(route, @d, [widget(%{}), %{"facts" => [done]}], @member)

      assert Pages.submit_call(confirm["confirm_to"]) ==
               {:ok, :accept, %{kind: "widget", key: "W-1", relation: "approved_by"}}

      assert confirm["text"] =~ "will be approved by ada"

      # What is under it is the model's rule for Facts (requires_completed_children).
      %{blocks: [%{"props" => confirm}]} =
        Pages.render(route, @d, [widget(%{}), %{"facts" => [done, open]}], @member)

      assert confirm["confirm_to"]

      %{blocks: [%{"props" => no}]} =
        Pages.render(route, @d, [widget(%{}), %{"facts" => []}], @agent)

      assert no["text"] =~ "only a member approves"
      refute no["confirm_to"]

      assert Pages.set_problem(@d, route, [widget(%{"approved_by" => ["ada"]})]) =~ "already"
      assert Pages.set_problem(@d, route, [widget(%{})]) == nil
    end

    test "withdraw asks for a note; an agent cannot" do
      route = Pages.route("/k/widget/W-1/remove/approved_by")
      approved = widget(%{"approved_by" => ["ada"]})

      %{blocks: [%{"type" => "form", "props" => form}]} =
        Pages.render(route, @d, [approved], @member)

      assert form["submit_label"] == "Withdraw"

      assert %{"kind" => "multiline", "required" => true} =
               Enum.find(form["inputs"], &(&1["name"] == "note"))

      %{blocks: [%{"type" => "confirm", "props" => no}]} =
        Pages.render(route, @d, [approved], @agent)

      assert no["text"] =~ "only a member approves"
    end

    test "the links form: only the member itself, or the migration" do
      route = {:links, "widget", "W-1", "approved_by"}

      %{blocks: [%{"type" => "confirm", "props" => no}]} =
        Pages.render(route, @d, [widget(%{}), %{"facts" => []}], @agent)

      assert no["text"] == "Approved by is not set here: only a member approves."
      # What the page offers; who may set it to what, Facts checks (only_target).
      assert Pages.may_link?(@d, "approved_by", "ada", "member")
      assert Pages.may_link?(@d, "approved_by", "migration", nil)
      refute Pages.may_link?(@d, "approved_by", "agent", nil)
    end

    test "approved by shows only once approved, with who did it; progress then says so" do
      approving = shop(Approving)

      fields = fn answer ->
        %{blocks: [%{"props" => item} | _]} =
          Pages.render({:item, "widget", "W-1"}, approving, [answer, %{"facts" => []}], @member)

        Map.new(item["fields"], &{&1["label"], &1})
      end

      refute Map.has_key?(fields.(widget(%{})), "Approved by")

      origin = %{"since" => "2026-11-03T14:10:00Z", "by" => "ada", "cause" => nil}

      approved =
        widget(%{"approved_by" => ["ada"]})
        |> put_in(["fact", "origins"], %{"approved_by" => origin})
        |> put_in(["fact", "progress"], %{
          "done" => true,
          "label" => "Done",
          "count" => 1,
          "of" => 1
        })
        |> put_in(["fact", "completion"], %{
          "done" => true,
          "by" => "approved_by",
          "keys" => ["ada"]
        })

      approved = fields.(approved)
      assert %{"value" => "ada", "origin" => %{"by" => "ada"}} = approved["Approved by"]
      assert %{"value" => "Done · 1/1 · approved by ada"} = approved["Progress"]
    end
  end

  test "generated owner answers are offered only in the declared states, with note-only rejection" do
    # A subflow reviews each widget: in its check state the card's holder accepts or
    # rejects, with a note.
    description = shop(Reviewed)

    route = {:item, "widget", "W-1"}
    reads = answering_reads(route, "ada")
    form = %{by: "ada", by_kind: "member"}
    page = Pages.render(route, description, reads, form)
    item = Enum.find(page.blocks, &(&1["id"] == "item"))["props"]

    assert [%{"key" => "a", "label" => "Accept"}, %{"key" => "f", "label" => "Reject"} | _] =
             item["actions"]

    assert inspect(page.blocks) =~ "a Accept   f Reject"

    assert Enum.find(item["actions"], &(&1["key"] == "f"))["to"] ==
             Pages.path({:answer, "widget", "W-1", "f"})

    assert Pages.declared_answer(description, "widget", "a", reads, %{by: "bob"}) == nil

    # Someone else sees the item, but neither the answers nor what to do.
    other = Pages.render(route, description, reads, %{by: "bob", by_kind: "member"})
    refute inspect(other.blocks) =~ "Accept"
    refute inspect(other.blocks) =~ "/answer/"

    for state <- ["machine", "final", "unknown"] do
      other =
        Enum.map(reads, fn
          %{"fact" => %{"key" => "C-W-1"} = card} ->
            %{"fact" => put_in(card, ["values", "step"], state)}

          answer ->
            answer
        end)

      assert Pages.declared_answer(description, "widget", "a", other, form) == nil
    end

    %{blocks: [%{"type" => "form", "props" => reject}]} =
      Pages.render({:answer, "widget", "W-1", "f"}, description, reads, form)

    assert [%{"name" => "note", "required" => true}] = reject["inputs"]

    %{blocks: [%{"type" => "confirm"}]} =
      Pages.render({:answer, "widget", "W-1", "a"}, description, reads, form)

    # What the answer writes: its values, linked to whoever answers; a reject needs a note.
    item = Pages.answer_item(description, "widget", reads)
    viewer = %{key: "ada", kind: "member"}

    assert {:write,
            %{"values" => %{"state" => "dropped"}, "self" => "checked_by", "note" => true}} =
             Shop.Reviewed.answer("widget", "f", item, viewer)

    assert {:refuse, _} = Shop.Reviewed.answer("widget", "f", item, %{key: "bob", kind: "member"})
    assert {:refuse, _} = Shop.Reviewed.answer("widget", "v", item, viewer)
  end
end
