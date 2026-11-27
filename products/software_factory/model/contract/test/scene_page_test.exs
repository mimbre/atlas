defmodule Model.ScenePageTest do
  @moduledoc """
  A scene's page as a stack of simple blocks (its `page`, D-0104), as Control serves it
  from the model: one main answer chosen from where its work stands (Design not picked
  up: Pick up; under way: Suggest a use case; its proposal ready: Accept or Decline; its
  use cases being built: Suggest a use case; all done: Accept); Suggest a use case, its
  producer's, adds the intent to the running Design or, once Design was accepted, hands
  the scene to an extra Design round; and its details, only what says something.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.Store
  alias Model.AtlasEyra

  @key "SC-Atlas-90"
  @since "2026-11-24T09:00:00Z"
  @actors %{"decider" => "bo"}

  defp catalog, do: AtlasControl.Model.catalog(AtlasEyra)

  defp flow(name), do: Enum.find(AtlasEyra.subflows(:test), &(&1.name() == name))

  defp scene(values \\ %{}, links \\ %{}) do
    %{
      "key" => @key,
      "values" =>
        Map.merge(
          %{
            "title" => "A newcomer finds their way",
            "description" =>
              "Ada opens Atlas for the first time and sees what is hers.\n\nAlready built: the Assigned to you tab.",
            "phase" => "break_down",
            "status" => "refine"
          },
          values
        ),
      "links" => Map.merge(%{"produced_by" => ["melle"], "assignment" => ["AS-" <> @key]}, links)
    }
  end

  # The work on the scene in `state` of `subflow`, as Facts presents it on its Assignment.
  defp work(subflow, state, values, extra) do
    Map.merge(
      flow(subflow).present(state, values)
      |> Map.merge(%{
        "flow" => subflow,
        "state" => state,
        "run" => "run-1",
        "status" => "active",
        "actionable" => true,
        "since" => @since,
        "owner" => [],
        "supervisor" => []
      }),
      extra
    )
  end

  defp assignment(presentation, assigned \\ []) do
    %{
      "key" => "AS-" <> @key,
      "values" => %{"of" => @key},
      "links" => %{"assigned_to" => assigned},
      "presentation" => presentation
    }
  end

  # The scene's page for `by`, from the reads Control makes for it: the scene, its use
  # cases, its Assignment, the decisions it may be based on; nothing else.
  defp page(fact, assignment, by, opts \\ []) do
    m = catalog()
    route = {:item, "scene", @key}

    answers =
      for {kind, read} <- AtlasControl.Pages.reads(route, m) do
        case {kind, read} do
          {"scene", %{"key" => _}} -> %{"fact" => fact}
          {"assignment", %{"key" => _}} -> %{"fact" => assignment}
          {"use_case", %{"linked" => %{"in_scene" => _}}} -> %{"facts" => opts[:use_cases] || []}
          {"decision", _} -> %{"facts" => opts[:decisions] || []}
          _ -> %{"facts" => []}
        end
      end

    form = %{by: by, by_kind: "person", client: "tui"}
    {AtlasControl.Pages.render(route, m, answers, form), answers, form}
  end

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))

  defp answers(page),
    do: (block(page, "answers") || %{"props" => %{"answers" => []}})["props"]["answers"]

  defp labels(page), do: for(a <- answers(page), do: {a["label"], a["weight"]})

  defp use_case(key, phase) do
    done = phase == "accepted"

    %{
      "key" => key,
      "values" => %{"title" => "Ada sees " <> key, "phase" => phase},
      "links" => %{"in_scene" => [@key]},
      "completion" => if(done, do: %{"done" => true})
    }
  end

  # -- The page ----------------------------------------------------------------------------

  test "the page is its header, intro, what is already built, its use cases, one answer, its actions and details" do
    fact = scene()
    shown = work("break_down_scene", "break_down", fact["values"], %{"supervisor" => ["bo"]})

    {page, _, _} =
      page(fact, assignment(shown, ["bo"]), "melle",
        use_cases: [use_case("UC-Atlas-91", "accepted"), use_case("UC-Atlas-92", "design")]
      )

    assert for(b <- page.blocks, do: b["id"]) ==
             ~w(header intro context items answers actions item)

    assert %{
             "eyebrow" => "SCENE",
             "key" => @key,
             "title" => "A newcomer finds their way",
             "detail" => "Break down · Refine",
             "since" => @since
           } = block(page, "header")["props"]

    assert block(page, "intro")["props"]["text"] ==
             "Ada opens Atlas for the first time and sees what is hers."

    assert %{
             "label" => "Already built",
             "role" => "context",
             "text" => "the Assigned to you tab."
           } =
             block(page, "context")["props"]

    items = block(page, "items")["props"]
    assert items["title"] == "Use cases"
    assert items["aside"] == "1 of 2 done"
    assert for(r <- items["rows"], do: r["id"]) == ~w(UC-Atlas-91 UC-Atlas-92)

    # Its toolbar: no create, however a use case may be made by hand.
    actions = block(page, "actions")["props"]["actions"]
    refute Enum.any?(actions, &String.contains?(&1["to"], "/new"))
    assert Enum.any?(actions, &(&1["icon"] == "edit"))
  end

  test "Design not picked up: Pick up, and with no use cases, what comes next" do
    fact = scene()

    {page, _, _} =
      page(fact, assignment(work("break_down_scene", "break_down", fact["values"], %{})), "melle")

    assert labels(page) == [{"Pick up", "main"}]

    assert block(page, "items")["props"]["empty"] ==
             "Once someone picks up its Design, its agent proposes the use cases here."

    refute block(page, "items")["props"]["aside"]
  end

  test "Design under way: its producer's Suggest a use case; nobody else's" do
    fact = scene()
    shown = work("break_down_scene", "break_down", fact["values"], %{"supervisor" => ["bo"]})
    {page, _, _} = page(fact, assignment(shown, ["bo"]), "melle")

    assert [%{"label" => "Suggest a use case", "weight" => "main", "note" => true} = suggest] =
             answers(page)

    assert suggest["to"] == "/k/scene/#{@key}/answer/s"
    assert suggest["icon"] == "suggest"

    assert block(page, "items")["props"]["empty"] =~ "working out the use cases"

    # Its supervisor, who is not its producer, has nothing to answer while its agent works.
    {page, _, _} = page(fact, assignment(shown, ["bo"]), "bo")
    assert answers(page) == []
  end

  test "Design's proposal ready: its supervisor's Accept and Decline" do
    fact = scene()

    shown =
      work("break_down_scene", "accepting", fact["values"], %{
        "owner" => ["bo"],
        "supervisor" => ["bo"]
      })

    {page, _, _} =
      page(fact, assignment(shown, ["bo"]), "bo", use_cases: [use_case("UC-Atlas-91", "design")])

    assert labels(page) == [{"Accept", "main"}, {"Decline", "decline"}]
  end

  test "while a proposal awaits acceptance its producer can suggest, including when supervising" do
    fact = scene()
    shown = work("break_down_scene", "accepting", fact["values"], %{
      "owner" => ["bo"],
      "supervisor" => ["bo"]
    })
    item = %{"fact" => fact, "parts" => %{"assignment" => assignment(shown, ["bo"])}}
    {page, _, _} = page(fact, assignment(shown, ["bo"]), "melle")
    assert labels(page) == [{"Suggest a use case", "main"}]
    assert {:write, _} =
             AtlasEyra.answer("scene", "s", item, %{key: "melle", kind: "person", assists: nil})
    assert {:refuse, _} =
             AtlasEyra.answer("scene", "s", item, %{key: "bo", kind: "person", assists: nil})

    shown = %{shown | "owner" => ["melle"], "supervisor" => ["melle"]}
    {page, _, _} = page(fact, assignment(shown, ["melle"]), "melle")
    assert labels(page) == [
             {"Accept", "main"},
             {"Decline", "decline"},
             {"Suggest a use case", "other"}
           ]
  end

  test "clarification shows the agent's questions before the producer answers" do
    fact = scene(%{"questions" => "Who is this for?\nWhat should they see?"})
    shown = work("break_down_scene", "clarifying", fact["values"], %{"owner" => ["melle"]})
    {page, _, _} = page(fact, assignment(shown, ["melle"]), "melle")

    assert %{"label" => "Its agent's questions", "text" => "Who is this for?\nWhat should they see?"} =
             block(page, "section")["props"]
    assert labels(page) == [{"Answered", "main"}, {"Suggest a use case", "other"}]
  end

  test "its use cases being built: its producer's Suggest a use case" do
    fact = scene(%{"phase" => "accept", "children" => 1, "open_children" => 1})
    shown = work("accept_scene", "building", fact["values"], %{})

    {page, _, _} =
      page(fact, assignment(shown), "melle", use_cases: [use_case("UC-Atlas-91", "design")])

    assert labels(page) == [{"Suggest a use case", "main"}]

    # Not to anyone who did not put the scene in.
    {page, _, _} =
      page(fact, assignment(shown), "bo", use_cases: [use_case("UC-Atlas-91", "design")])

    assert answers(page) == []
  end

  test "all done: its producer's Accept" do
    fact = scene(%{"phase" => "accept", "children" => 1, "open_children" => 0})
    shown = work("accept_scene", "to_accept", fact["values"], %{"owner" => ["melle"]})

    {page, _, _} =
      page(fact, assignment(shown, ["melle"]), "melle",
        use_cases: [use_case("UC-Atlas-91", "accepted")]
      )

    assert [{"Accept", "main"} | _] = labels(page)
    assert block(page, "items")["props"]["aside"] == "1 of 1 done"
  end

  # -- Suggest a use case ------------------------------------------------------------------

  test "Suggest a use case asks what a person should be able to do" do
    fact = scene()
    shown = work("break_down_scene", "break_down", fact["values"], %{"supervisor" => ["bo"]})
    {_page, answers, form} = page(fact, assignment(shown, ["bo"]), "melle")

    assert [%{"type" => "form", "props" => props}] =
             AtlasControl.Pages.render({:answer, "scene", @key, "s"}, catalog(), answers, form).blocks

    assert [
             %{
               "name" => "note",
               "required" => true,
               "label" => "What should a person be able to do?"
             }
           ] =
             props["inputs"]

    assert props["submit_label"] == "Suggest a use case"
  end

  test "under way, the intent is a line added to its producer's answers, which Design reads" do
    fact = scene(%{"answers" => "It is for newcomers."})
    shown = work("break_down_scene", "break_down", fact["values"], %{"supervisor" => ["bo"]})
    item = %{"fact" => fact, "parts" => %{"assignment" => assignment(shown, ["bo"])}}
    viewer = %{key: "melle", kind: "person", assists: nil}

    assert {:write, answer} = AtlasEyra.answer("scene", "s", item, viewer)

    assert {:ok, %{"values" => values, "links" => links}, cause} =
             AtlasControl.Answers.change(
               answer,
               @key,
               "melle",
               "Ada can ask who to ask",
               DateTime.utc_now()
             )

    assert values == %{
             "answers" => "It is for newcomers.\nSuggested use case: Ada can ask who to ask",
             "suggestions" => "Suggested use case: Ada can ask who to ask"
           }

    assert links == %{}
    assert cause == "Suggested a use case: Ada can ask who to ask"

    # Nobody else suggests for its producer.
    assert {:refuse, _} =
             AtlasEyra.answer("scene", "s", item, %{key: "bo", kind: "person", assists: nil})
  end

  test "the configured decider suggests for an older scene only when it has no producer" do
    fact = scene(%{}, %{"produced_by" => []})
    shown = work("break_down_scene", "accepting", fact["values"], %{"owner" => ["melle"]})
    item = %{"fact" => fact, "parts" => %{"assignment" => assignment(shown, ["melle"])}}
    decider = %{key: "bo", kind: "person", assists: nil, decider: "bo"}

    assert {:write, _} = AtlasEyra.answer("scene", "s", item, decider)
    assert {:refuse, _} = AtlasEyra.answer("scene", "s", item, %{decider | key: "other"})
    assert {:refuse, _} = AtlasEyra.answer("scene", "s", item, %{decider | decider: nil})
    assert {:refuse, _} = AtlasEyra.answer("scene", "s", put_in(item, ["fact", "links", "produced_by"], ["melle"]), decider)
  end

  test "answering Design's questions keeps suggestions made during its preceding task" do
    fact = scene(%{"answers" => "Suggested use case: Ada can ask who to ask"})
    shown = work("break_down_scene", "clarifying", fact["values"], %{"owner" => ["melle"]})
    item = %{"fact" => fact, "parts" => %{"assignment" => assignment(shown, ["melle"])}}

    assert {:write, answer} =
             AtlasEyra.answer("scene", "a", item, %{key: "melle", kind: "person", assists: nil})

    assert {:ok, %{"values" => values}, _} =
             AtlasControl.Answers.change(
               answer,
               @key,
               "melle",
               "For newcomers",
               DateTime.utc_now()
             )

    assert values == %{
             "verdict" => "answered",
             "answers" => "Suggested use case: Ada can ask who to ask\nFor newcomers"
           }
  end

  test "once Design was accepted, the intent is preserved for an extra Design round" do
    fact =
      scene(%{"phase" => "accept", "children" => 1, "open_children" => 1, "answers" => "Earlier"})

    shown = work("accept_scene", "building", fact["values"], %{})
    item = %{"fact" => fact, "parts" => %{"assignment" => assignment(shown)}}

    assert {:write, answer} =
             AtlasEyra.answer("scene", "s", item, %{key: "melle", kind: "person", assists: nil})

    assert {:ok, %{"values" => values}, _cause} =
             AtlasControl.Answers.change(
               answer,
               @key,
               "melle",
               "Ada can ask who to ask",
               DateTime.utc_now()
             )

    assert values == %{
             "verdict" => "suggest",
             "answers" => "Earlier\nSuggested use case: Ada can ask who to ask",
             "suggestions" => "Suggested use case: Ada can ask who to ask"
           }
  end

  describe "an extra Design round" do
    setup do
      Application.put_env(:atlas_bus, :store, "scene-page-#{System.unique_integer([:positive])}")
      environment = Application.get_env(:atlas_bus, :environment)
      Application.put_env(:atlas_bus, :environment, "test")

      on_exit(fn ->
        if environment,
          do: Application.put_env(:atlas_bus, :environment, environment),
          else: Application.delete_env(:atlas_bus, :environment)
      end)

      {:ok, _} = Application.ensure_all_started(:atlas_bus)
      start_supervised!(FakeFacts)
      :ok = AtlasBus.attach("flow")
      for p <- ~w(melle bo), do: FakeFacts.put("person", %{"key" => p})

      %{runner: AtlasFlow.Model.load(AtlasEyra, :test, @actors)}
    end

    defp put_scene(values) do
      FakeFacts.put("scene", %{
        "key" => @key,
        "values" =>
          Map.merge(
            %{"title" => "Newcomers", "phase" => "accept", "children" => 1, "open_children" => 1},
            values
          ),
        "links" => %{"assignment" => ["AS-" <> @key], "produced_by" => ["melle"]}
      })
    end

    defp reconcile(c) do
      {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)

      {:ok, runs} =
        Store.reconcile_subjects(c.runner.config, c.runner.flows, DateTime.utc_now(), known, [
          {"use_case", "UC-Atlas-91"},
          {"scene", @key}
        ])

      runs
    end

    defp run(runs, flow), do: Enum.find(runs, &(&1["flow"] == flow and &1["subject_key"] == @key))

    test "a suggestion while its use cases are built hands it back to Design, which proposes again",
         c do
      put_scene(%{})
      FakeFacts.put("assignment", %{"key" => "AS-" <> @key, "values" => %{"of" => @key}})

      FakeFacts.put("use_case", %{
        "key" => "UC-Atlas-91",
        "values" => %{"title" => "Ada sees what is hers", "phase" => "design"},
        "links" => %{"in_scene" => [@key]}
      })

      assert run(reconcile(c), "accept_scene")["state"] == "building"

      # Its producer's answer, as Control writes it.
      put_scene(%{
        "verdict" => "suggest",
        "answers" => "Suggested use case: Ada can ask who to ask",
        "suggestions" => "Suggested use case: Ada can ask who to ask"
      })

      runs = Enum.reduce(1..3, nil, fn _, _ -> reconcile(c) end)

      assert run(runs, "accept_scene")["state"] == "breaking_down"
      assert FakeFacts.get("scene", @key)["values"]["phase"] == "break_down"

      assert FakeFacts.get("scene", @key)["values"]["answers"] ==
               "Suggested use case: Ada can ask who to ask"

      assert run(runs, "break_down_scene")["state"] == "break_down"
    end
  end

  # -- Details -----------------------------------------------------------------------------

  test "its details: what says something, its decisions with their titles; no repeats, counts, empty fields, tasks or Assignment" do
    fact =
      scene(
        %{
          "children" => 2,
          "open_children" => 1,
          "pass_result" => "",
          "verdict" => "",
          "note" => "",
          "answers" => "It is for newcomers."
        },
        %{"based_on" => ["D-0060"]}
      )

    shown = work("break_down_scene", "break_down", fact["values"], %{"supervisor" => ["bo"]})

    decisions = [
      %{"key" => "D-0060", "values" => %{"title" => "Bounded workers"}, "links" => %{}},
      %{"key" => "D-0061", "values" => %{"title" => "Something else"}, "links" => %{}}
    ]

    {page, _, _} = page(fact, assignment(shown, ["bo"]), "melle", decisions: decisions)
    fields = block(page, "item")["props"]["fields"]

    assert for(f <- fields, do: f["label"]) ==
             [
               "Phase",
               "Flux group",
               "Assigned to",
               "Produced by",
               "Based on",
               "Its producer's answers"
             ]

    assert Enum.find(fields, &(&1["label"] == "Based on"))["value"] == "D-0060 Bounded workers"
    assert Enum.find(fields, &(&1["label"] == "Assigned to"))["value"] == "bo"

    # No list of its tasks or its Assignment on the page.
    refute Enum.any?(page.blocks, &(&1["type"] == "list" and &1["id"] != "items"))

    assert [
             %{
               "kind" => "part",
               "start" => "item",
               "end" => "item",
               "props" => %{"role" => "details"}
             }
           ] =
             page.markup
  end
end
