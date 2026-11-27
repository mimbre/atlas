defmodule Model.DecisionOptionsTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DecisionOptions, as: Options
  @text File.read!(Path.expand("../../../e2e/fixtures/decision-options.json", __DIR__))
  @legacy File.read!(Path.expand("../../generator/test/legacy_d0105.json", __DIR__))
  @rule Model.AtlasEyra.__rela__(:description).extension["entities"]["decision"][
          "decision_options"
        ]
  @authority Model.AtlasEyra.__rela__(:description).extension["entities"]["decision"]["authority"]

  defp current(text \\ @text) do
    %{
      "values" => %{
        "title" => "Example",
        "decision" => "A proposed example",
        "options" => text,
        "status" => "proposed"
      },
      "links" => %{}
    }
  end

  defp check(current, values, actor \\ "ada", kind \\ "person", verdict \\ nil, op \\ "change") do
    lookup = %{
      "current" => fn -> current end,
      "fact" => fn of, key -> if of == kind, do: %{key: key, properties: %{}, links: %{}} end,
      "list" => fn
        "gate_verdict" when is_map(verdict) ->
          {:ok,
           [
             %{
               key: "GV-private",
               links: %{"about" => ["D-private"]},
               properties:
                 Map.merge(verdict, %{
                   "gate" => "accept_decision",
                   "subject" => "D-private",
                   "purpose" => "decider"
                 })
             }
           ]}

        _ ->
          {:ok, []}
      end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }

    Model.AtlasEyra.check(
      "decision",
      %{
        "op" => op,
        "key" => "D-private",
        "values" => values,
        "links" => %{"decided_by" => [actor]}
      },
      %{"by" => actor},
      lookup
    )
  end

  defp answer(id) do
    {:ok, definition} = Options.decode(@rule, @text)
    option = Enum.find(definition["options"], &(&1["id"] == id))

    Options.values(@rule, @text, option, current())
    |> Map.put("decided_at", "2026-11-16T12:00:00Z")
  end

  test "a semantic ID applies only its exact typed payload under actual authority" do
    for id <- ~w(files memory), do: assert(:ok == check(current(), answer(id)))
    assert {:refuse, _} = check(current(), answer("files"), "helper", "agent")
    assert {:refuse, _} = check(current(), Map.put(answer("files"), "decision", "Different rule"))

    assert {:refuse, _} = check(current(), Map.put(answer("files"), "selected_option", "0"))

    assert {:refuse, _} =
             check(current(), %{"status" => "accepted", "decided_at" => "2026-11-16T12:00:00Z"})
  end

  test "a gate authorizes the exact complete offer and candidate classification" do
    verdict = %{
      "verdict" => "agent",
      "fingerprint" =>
        AtlasBus.SubjectFingerprint.of(current(), @authority["decider"]["fingerprint"])
    }

    assert :ok == check(current(), answer("memory"), "helper", "agent", verdict)

    changed =
      put_in(
        current(),
        ["values", "options"],
        String.replace(@text, "Use files", "Use local files")
      )

    assert {:refuse, _} = check(changed, answer("files"), "helper", "agent", verdict)

    assert {:refuse, _} =
             check(
               current(),
               Map.put(answer("memory"), "force", "principle"),
               "helper",
               "agent",
               verdict
             )

    assert {:refuse, _} =
             check(
               current(),
               Map.put(
                 answer("memory"),
                 "options",
                 String.replace(@text, "Use memory", "Use RAM")
               )
             )
  end

  test "answered offers remain immutable; allowed later changes preserve them" do
    for id <- ~w(files memory) do
      old = %{
        current()
        | "values" => Map.merge(current()["values"], answer(id)),
          "links" => %{"decided_by" => ["ada"]}
      }

      assert :ok == check(old, %{"no_work" => true})

      assert {:refuse, _} =
               check(old, %{
                 "selected_definition" => String.replace(@text, "Use files", "Different offer")
               })

      assert {:refuse, _} = check(old, %{"selected_option" => "memory" <> id})
      assert {:refuse, _} = check(old, %{"options" => nil})
    end
  end

  test "definitions validate identities, recommendation, complete text and alternatives only" do
    {:ok, definition} = Options.decode(@rule, @text)
    # Cardinality belongs to the answer contract, not a terminal's single-digit keys.
    alternatives = for(n <- 1..11, do: Map.put(hd(definition["options"]), "id", "choice#{n}"))

    many = definition |> Map.put("options", alternatives) |> Map.put("recommended", "choice1")
    assert {:ok, _} = Options.decode(@rule, JSON.encode!(many))

    # Two alternatives, or one proposal: declining is always the decider's own answer,
    # with an alternative (D-0106).
    for options <- [definition["options"], [hd(definition["options"])]] do
      assert {:ok, _} =
               Options.decode(@rule, JSON.encode!(Map.put(definition, "options", options)))
    end

    # A "no" option is none of them: the form says Decline is always there.
    no =
      Map.update!(definition, "options", fn options ->
        options ++
          [
            %{
              "id" => "decline",
              "text" => "Do neither",
              "details" => "Do not adopt either storage rule.",
              "effect" => "decline",
              "rule" => "",
              "consequences" => ""
            }
          ]
      end)

    why = "A decision has no 'no' option; Decline is always available"
    assert {:error, ^why} = Options.decode(@rule, JSON.encode!(no))
    assert {:refuse, [^why]} = check(current(), %{"options" => JSON.encode!(no)})

    for change <- [
          Map.put(definition, "recommended", "missing"),
          Map.put(definition, "recommended", "memory"),
          put_in(definition, ["options", Access.at(1), "id"], "files"),
          put_in(definition, ["options", Access.at(1), "details"], " "),
          put_in(definition, ["options", Access.at(1), "effect"], "approve"),
          put_in(definition, ["options", Access.at(1), "rule"], ""),
          # Whose alternative it is, when it says so, is someone.
          put_in(definition, ["options", Access.at(1), "by"], " "),
          # No options are nothing to adopt.
          Map.put(definition, "options", [])
        ] do
      assert {:error, _} = Options.decode(@rule, JSON.encode!(change))
      assert {:refuse, _} = check(current(), %{"options" => JSON.encode!(change)})
    end
  end

  # Decisions proposed while a definition could hold a "no" option are rewritten without
  # it: the open decision takes the new definition, its history keeps the old one.
  test "an open decision whose stored definition has a no option takes one without it" do
    {:ok, definition} = Options.decode(@rule, @text)

    old =
      definition
      |> Map.update!("options", fn options ->
        options ++
          [
            %{
              "id" => "decline",
              "text" => "Do neither",
              "details" => "Do not adopt either storage rule.",
              "effect" => "decline",
              "rule" => "",
              "consequences" => ""
            }
          ]
      end)
      |> JSON.encode!()

    stored = current(old)
    assert :ok == check(stored, %{"options" => @text}, "melle")

    change = %{
      "op" => "change",
      "key" => "D-private",
      "values" => %{"options" => @text},
      "links" => %{}
    }

    [rewritten] =
      Model.AtlasEyra.with_change("decision", change, %{"current" => fn -> stored end})

    assert rewritten["values"]["options"] == @text
    assert [%{"definition" => ^old}] = JSON.decode!(rewritten["values"]["option_history"])
  end

  test "a decision may still be created without options and keeps its answers" do
    created = %{"title" => "New", "decision" => "Rule", "status" => "proposed"}
    assert :ok == check(nil, created, "ada", "person", nil, "create")

    with_options = Map.put(created, "options", @text)
    assert :ok == check(nil, with_options, "ada", "person", nil, "create")

    fact = %{"key" => "D-new", "values" => created, "links" => %{}}
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    presentation =
      decide.present("for_person", created)
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    parts = %{"assignment" => %{"presentation" => presentation}}
    todo = Model.AtlasEyra.todo("decision", fact, parts, %{key: "ada", kind: "person"})
    assert todo.choice == nil
    # Accept, Decline (with an alternative), Ask, Delegate (D-0106).
    assert Enum.map(todo.answers, & &1.key) == ~w(a f q l)
    assert Enum.map(todo.answers, & &1.label) == ~w(Accept Decline Ask Delegate)
    assert Enum.map(todo.answers, & &1.weight) == ~w(main decline other other)
  end

  # D-0106: a decline is no end. Whoever declines gives an alternative; the same Facts
  # write sends it back to its proposer (`revising`) with that alternative among its
  # options, theirs, and keeps the declined offer in the history.
  test "a decline sends it back to its proposer with the alternative as a new option" do
    decline = %{
      "op" => "change",
      "key" => "D-private",
      "by" => "melle",
      "values" => %{"status" => "revising", "alternative" => "Use the database we have"},
      "links" => %{"decided_by" => ["melle"]}
    }

    assert :ok == check(current(), decline["values"], "melle")

    [own] = Model.AtlasEyra.with_change("decision", decline, %{"current" => fn -> current() end})
    {:ok, before} = Options.decode(@rule, @text)
    {:ok, after_decline} = Options.decode(@rule, own["values"]["options"])

    # The offer as it was, then theirs: to adopt, its title only with a note whose it is,
    # its rule and consequences empty until the proposer works them out. The
    # recommendation stays the proposer's.
    assert Enum.drop(after_decline["options"], -1) == before["options"]
    assert after_decline["recommended"] == before["recommended"]

    assert List.last(after_decline["options"]) == %{
             "id" => "alternative",
             "text" => "Use the database we have",
             "details" => "melle's alternative, to be worked out by the proposer",
             "effect" => "adopt",
             "rule" => "",
             "consequences" => "",
             "by" => "melle"
           }

    assert [%{"definition" => @text}] = JSON.decode!(own["values"]["option_history"])
    assert own["values"]["status"] == "revising"

    # Nothing is selected: no answer is recorded, and it is no end.
    revised = %{
      current()
      | "values" => Map.merge(current()["values"], Map.delete(own["values"], "option_history"))
    }

    refute Options.open?(@rule, revised)
    assert revised["values"]["selected_option"] == nil

    # Not worked out, it is not proposed again.
    assert [why] = Options.check(@rule, "change", revised, %{"status" => "proposed"}, %{})
    assert why =~ "rule and consequences"

    # Its proposer works it out and sets the recommendation, while it is theirs.
    reworded =
      after_decline
      |> Map.put("options", Enum.reverse(after_decline["options"]))
      |> Map.put("recommended", "alternative")
      |> put_in(["options", Access.at(0), "rule"], "Store it in the database we have")
      |> put_in(["options", Access.at(0), "consequences"], "No second store to run")

    assert :ok == check(revised, %{"options" => JSON.encode!(reworded)}, "coordinator", "agent")

    assert [] ==
             Options.check(
               @rule,
               "change",
               revised,
               %{"options" => JSON.encode!(reworded), "status" => "proposed"},
               %{}
             )

    # A second decline adds a second alternative beside the first.
    again =
      Model.AtlasEyra.with_change(
        "decision",
        %{decline | "values" => %{decline["values"] | "alternative" => "Ask the team first"}},
        %{"current" => fn -> put_in(current(), ["values", "options"], JSON.encode!(reworded)) end}
      )

    [%{"values" => %{"options" => twice}}] = again
    ids = for o <- JSON.decode!(twice)["options"], do: o["id"]
    assert "alternative" in ids and "alternative-2" in ids
  end

  test "a decision without options keeps the alternative in its field" do
    legacy = %{
      "values" => %{"decision" => "Original rule", "status" => "proposed"},
      "links" => %{}
    }

    values = %{"status" => "revising", "alternative" => "Another rule"}
    assert :ok == check(legacy, values, "melle")

    change = %{"op" => "change", "key" => "D-private", "by" => "melle", "values" => values}
    [own] = Model.AtlasEyra.with_change("decision", change, %{"current" => fn -> legacy end})
    assert own["values"] == values
  end

  test "a question sends it back unanswered too; selecting stays the only answer" do
    asked = %{"status" => "answering", "question" => "What does it cost?"}
    assert :ok == check(current(), asked, "melle")

    # A status outside the offer's own, without a selection, is refused as before.
    assert {:refuse, _} = check(current(), %{"status" => "accepted"}, "melle")
  end

  test "a malformed stored history refuses the write that would extend it, without a crash" do
    broken = put_in(current(), ["values", "option_history"], "{not json")
    change = %{"op" => "change", "key" => "D-private", "by" => "ada", "values" => answer("files")}
    [own] = Model.AtlasEyra.with_change("decision", change, %{"current" => fn -> broken end})
    assert own["values"]["option_history"] == nil
    assert {:refuse, reasons} = check(broken, answer("files"))
    assert Enum.any?(reasons, &(&1 =~ "history is malformed"))

    edited = %{"options" => String.replace(@text, "Use files", "Use local files")}
    assert {:refuse, _} = check(broken, edited)
    assert {:refuse, _} = check(put_in(broken, ["values", "option_history"], "{}"), edited)
  end

  test "historical pending records still accept their existing answer without invented choices" do
    legacy = %{
      "values" => %{"decision" => "Original rule", "status" => "proposed"},
      "links" => %{}
    }

    assert :ok == check(legacy, %{"status" => "accepted", "decided_at" => "2026-11-16T12:00:00Z"})
    assert legacy["values"] == %{"decision" => "Original rule", "status" => "proposed"}

    historical = %{
      "verdict" => "agent",
      "fingerprint" =>
        AtlasBus.SubjectFingerprint.of(legacy, %{
          "fields" => ~w(title decision category scope reversibility force),
          "relations" => ["supersedes"]
        })
    }

    assert :ok ==
             check(
               legacy,
               %{"status" => "accepted", "decided_at" => "2026-11-16T12:00:00Z"},
               "helper",
               "agent",
               historical
             )

    assert {:refuse, _} = check(current(), answer("files"), "helper", "agent", historical)
  end

  test "Facts derives complete immutable prior offers in the same change" do
    before = current()
    edited = String.replace(@text, "Use files", "Use local files")

    change = %{
      "op" => "change",
      "key" => "D-private",
      "by" => "ada",
      "values" => %{"options" => edited},
      "links" => %{}
    }

    lookup = %{"current" => fn -> before end}
    [own] = Model.AtlasEyra.with_change("decision", change, lookup)
    assert own["values"]["options"] == edited
    assert [entry] = JSON.decode!(own["values"]["option_history"])
    assert entry["definition"] == @text
    assert entry["revision"] == Options.revision(@rule, @text, before)
    assert entry["values"]["decision"] == before["values"]["decision"]
    assert {:refuse, _} = check(before, %{"option_history" => "[]"})

    next = put_in(before, ["values"], Map.merge(before["values"], own["values"]))

    [later] =
      Model.AtlasEyra.with_change("decision", %{change | "values" => %{"options" => @text}}, %{
        "current" => fn -> next end
      })

    assert [^entry, second] = JSON.decode!(later["values"]["option_history"])
    assert second["definition"] == edited

    for id <- ~w(files memory) do
      [selected] =
        Model.AtlasEyra.with_change("decision", %{change | "values" => answer(id)}, lookup)

      assert [offered] = JSON.decode!(selected["values"]["option_history"])
      assert offered["definition"] == @text
      assert offered["revision"] == selected["values"]["selected_revision"]
    end
  end

  test "decision details group important fields and retain exact records in one collapsed section" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "decision", "D-private"}

    history =
      JSON.encode!([
        %{
          "definition" => @text,
          "revision" => "prior revision",
          "values" => %{"context" => "Earlier context", "scope" => "platform"},
          "links" => %{"supersedes" => ["D-early"]}
        },
        %{"definition" => @text, "revision" => "exact revision"}
      ])

    for status <- ["proposed", "accepted"] do
      fact =
        current()
        |> Map.put("key", "D-private")
        |> update_in(
          ["values"],
          &Map.merge(&1, %{
            "status" => status,
            "scope" => "software",
            "reversibility" => "one_way",
            "force" => "principle",
            "category" => "security",
            "enforced_by" => "A check",
            "unverified" => true,
            "option_history" => history,
            "selected_definition" => @text,
            "selected_revision" => "exact revision"
          })
        )

      reads = AtlasControl.Pages.reads(route, m)
      answers = [%{"fact" => fact} | for(_ <- tl(reads), do: %{"facts" => []})]
      page = AtlasControl.Pages.render(route, m, answers, %{by: "ada", by_kind: "person"})
      blocks = Map.new(page.blocks, &{&1["id"], &1})
      assert blocks["decision-detail-0"]["props"]["title"] == "Authority and status"
      assert blocks["decision-detail-1"]["props"]["title"] == "Scope and reversibility"
      assert blocks["decision-detail-2"]["props"]["title"] == "Usage and enforcement"
      fields = blocks["decision-history-1"]["props"]["fields"]

      assert Enum.any?(
               fields,
               &(&1["label"] == "Option 1 (recommended)" and &1["value"] == "Use files")
             )

      assert Enum.any?(fields, &(&1["label"] == "Rationale" and &1["value"] =~ "easy to inspect"))

      assert Enum.any?(
               fields,
               &(&1["label"] == "Details" and &1["value"] == "Keep the example as local files.")
             )

      assert Enum.any?(
               fields,
               &(&1["label"] == "Rule" and &1["value"] == "Store the private example in files.")
             )

      assert Enum.any?(
               fields,
               &(&1["label"] == "Consequences" and
                   &1["value"] == "Create the private example files.")
             )

      assert Enum.any?(fields, &(&1["value"] == "Earlier context"))
      assert Enum.any?(fields, &(&1["value"] == "platform"))
      assert Enum.any?(fields, &(&1["value"] == "D-early"))
      refute blocks["decision-history-2"]

      assert blocks["decision-raw-options"]["props"]["fields"] |> hd() |> Map.fetch!("value") ==
               @text

      assert blocks["decision-raw-option_history"]["props"]["fields"]
             |> hd()
             |> Map.fetch!("value") == history

      assert Enum.any?(page.markup, fn mark ->
               mark["kind"] == "section" and
                 mark["props"] == %{"title" => "Technical details", "collapsible" => true} and
                 mark["start"] == "decision-raw-options" and
                 mark["end"] == "decision-raw-option_history"
             end)

      assert Enum.any?(page.console_actions, &(&1.operation["name"] == "sections_toggle"))
    end

    legacy =
      current(nil)
      |> Map.put("key", "D-private")
      |> update_in(
        ["values"],
        &Map.merge(&1, %{"status" => "accepted", "option_history" => "not JSON"})
      )

    reads = AtlasControl.Pages.reads(route, m)
    answers = [%{"fact" => legacy} | for(_ <- tl(reads), do: %{"facts" => []})]
    page = AtlasControl.Pages.render(route, m, answers)
    blocks = Map.new(page.blocks, &{&1["id"], &1})
    refute blocks["decision-history-1"]
    refute blocks["decision-detail-1"]
    refute blocks["decision-raw-options"]
    assert hd(blocks["decision-raw-option_history"]["props"]["fields"])["value"] == "not JSON"
  end

  test "unselected current offers use full content identity, not definition text" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    route = {:item, "decision", "D-private"}

    fact =
      current() |> Map.put("key", "D-private") |> put_in(["values", "context"], "Current context")

    old = put_in(fact, ["values", "context"], "Earlier context")

    entry = fn item ->
      %{
        "definition" => @text,
        "revision" => Options.revision(@rule, @text, item),
        "values" =>
          Map.take(item["values"], @rule["content"])
          |> Map.reject(fn {_, v} -> v in [nil, ""] end),
        "links" =>
          Map.new(@rule["content_links"], &{&1, Enum.sort(get_in(item, ["links", &1]) || [])})
      }
    end

    fact = put_in(fact, ["values", "option_history"], JSON.encode!([entry.(old), entry.(fact)]))
    reads = AtlasControl.Pages.reads(route, m)
    answers = [%{"fact" => fact} | for(_ <- tl(reads), do: %{"facts" => []})]
    blocks = Map.new(AtlasControl.Pages.render(route, m, answers).blocks, &{&1["id"], &1})

    assert Enum.any?(
             blocks["decision-history-1"]["props"]["fields"],
             &(&1["value"] == "Earlier context")
           )

    refute blocks["decision-history-2"]
  end

  test "detail group metadata rejects malformed declarations before Control starts" do
    description = Model.AtlasEyra.__rela__(:description)
    path = ["entities", "decision", "decision_options", "details"]

    for malformed <- [
          %{},
          "wrong",
          [%{}],
          [%{"title" => "Group"}],
          [%{"title" => "", "fields" => []}],
          [%{"title" => "Group", "fields" => "scope"}],
          [%{"title" => "Group", "fields" => [42]}]
        ] do
      extension = put_in(description.extension, path, malformed)
      problems = RelaDSL.Description.Check.check(description.schema, extension)

      assert Enum.any?(problems, fn
               {_where, %RelaDSL.Problem{} = problem} ->
                 match?({:decision_details, _}, RelaDSL.Problem.key(problem))

               _ ->
                 false
             end),
             inspect(malformed)
    end
  end

  # The page a TUI opens from Assigned to you, as Control serves it to a Console client:
  # its blocks besides console actions, and how a key resolves on it.
  defp served(text, values \\ %{}, state \\ "for_person") do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    fact =
      text
      |> current()
      |> Map.put("key", "D-private")
      |> update_in(["values"], &Map.merge(&1, values))

    presentation =
      decide.present(state, fact["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    assignment = %{"key" => "AS-D-private", "values" => %{}, "presentation" => presentation}
    route = {:item, "decision", "D-private"}
    reads = AtlasControl.Pages.reads(route, m)

    answers =
      [%{"fact" => fact}] ++
        for(_ <- 2..(length(reads) - 1)//1, do: %{"facts" => []}) ++ [%{"fact" => assignment}]

    form = %{by: "ada", by_kind: "person"}
    page = AtlasControl.Pages.render(route, m, answers, form)

    message = %{
      "path" => "/k/decision/D-private",
      "blocks" => page.blocks,
      "markup" => page.markup
    }

    assert {:ok, projected} =
             AtlasControl.Console.project(message, Model.AtlasEyra.shell(%{})["tabs"])

    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)

    resolve = fn key, on ->
      at = %{path: "/k/decision/D-private", context: "browse", generation: 1, on: on, row: nil}
      assert {:ok, event} = AtlasBFFContract.Console.capture(projection, key, at)
      assert {:ok, action} = AtlasBFFContract.Console.resolve(projection, event, at)
      action["props"]["operation"]
    end

    note = fn to ->
      "/k/decision/D-private/answer/" <> name = to
      AtlasControl.Pages.render({:answer, "decision", "D-private", name}, m, answers, form).blocks
    end

    {for(b <- projected["blocks"], b["type"] != "console_action", do: b), resolve, note}
  end

  defp answers_of(blocks), do: Enum.find(blocks, &(&1["id"] == "answers"))["props"]["answers"]

  # The decider's own answers below the options (D-0106), each quiet but Decline, each with
  # what it does by name and in full: Ask, and Delegate, whose form chooses the proposer
  # or another person.
  defp assert_own_answers(answers) do
    assert [
             %{"label" => "Ask", "key" => "q", "note" => true, "weight" => "other"} = ask,
             %{"label" => "Delegate", "key" => "l", "weight" => "other"} = delegate
           ] = answers

    assert ask["icon"] == "question"
    assert ask["help"] == "Ask the proposer a question"
    assert delegate["icon"] == "delegate"
    assert delegate["help"] == "Let someone else decide: the proposer or another person"
    assert delegate["to"] == "/k/decision/D-private/answer/l"
    refute Map.has_key?(delegate, "note")
    refute Map.has_key?(delegate, "submit_to")
  end

  # Every action and answer a page offers explains itself (`help`, a client's tooltip):
  # the model's words for its own, Control's for the rest.
  defp assert_help(blocks) do
    assert Model.Offered.all(blocks) != []
    assert Model.Offered.unexplained(blocks) == []
  end

  defp assert_asks(note, to, prompt) do
    assert [
             %{
               "type" => "form",
               "props" => %{
                 "inputs" => [%{"name" => "note", "required" => true, "label" => ^prompt}]
               }
             }
           ] = note.(to)
  end

  test "the details show no field a main block already shows, and no title of their own" do
    definition = JSON.decode!(@text)
    [files | _] = definition["options"]

    {blocks, _resolve, _note} =
      served(@text, %{
        "decision" => files["rule"],
        "consequences" => files["consequences"],
        "context" => definition["rationale"],
        "category" => "interface"
      })

    {[item], main} = Enum.split_with(blocks, &(&1["id"] == "item"))
    values = Enum.map(item["props"]["fields"], & &1["value"])

    shown =
      for b <- main,
          {k, v} <- b["props"] || %{},
          text <-
            if(k in ["text", "title"], do: [v], else: []) ++
              for(%{"value" => fv} <- List.wrap(if(k == "fields", do: v)), do: fv),
          do: text

    for text <- [files["rule"], files["consequences"], definition["rationale"]] do
      assert text in shown
      refute text in values
    end

    # What only the details show stays there.
    usage = Enum.find(blocks, &(&1["id"] == "decision-detail-2"))
    assert Enum.any?(usage["props"]["fields"], &(&1["value"] in ["interface", "Interface"]))
    assert item["props"]["title"] == ""
  end

  test "alternatives: a card each with its own Choose, then Decline all with an alternative" do
    {blocks, resolve, note} = served(@text)

    # In order: the question, why, each alternative (recommended first), the answers, the
    # details.
    assert [
             %{"id" => "header", "type" => "header", "props" => header},
             %{"id" => "why", "type" => "text", "props" => why},
             %{"id" => "option-1", "type" => "option", "props" => files},
             %{"id" => "option-2", "type" => "option", "props" => memory},
             %{"id" => "answers", "type" => "answers"}
             | rest
           ] = blocks

    assert %{"eyebrow" => "YOUR DECISION", "key" => "D-private"} = header
    definition = JSON.decode!(@text)
    assert header["title"] == definition["question"]
    assert why["text"] == definition["rationale"]
    # The intro paragraph without a label: no page text starts with "Why:".
    assert why["text"] != "" and not Map.has_key?(why, "label")
    refute inspect(blocks) =~ "Why:"
    assert Enum.any?(rest, &(&1["id"] == "item"))
    refute Enum.any?(blocks, &(&1["type"] in ["single_choice", "panel"]))

    # Every card shows what it means: its rule and what follows.
    for o <- [files, memory] do
      assert [%{"label" => "Rule", "value" => r}, %{"label" => "Consequences", "value" => c}] =
               o["fields"]

      assert r != "" and c != ""
      refute Map.has_key?(o, "alone")
    end

    assert %{"n" => 1, "badge" => "★ Recommended", "tone" => "success"} = files
    refute Map.has_key?(memory, "badge")
    # The recommended Choose is the main answer, another Choose other.
    assert %{"label" => "Choose", "key" => "1", "weight" => "main"} = files["answer"]
    assert %{"label" => "Choose", "key" => "2", "weight" => "other"} = memory["answer"]

    # Decline all is the decider's own decline: it asks their alternative, and says
    # nothing beside it.
    assert [
             %{
               "label" => "Decline all",
               "key" => "f",
               "note" => true,
               "weight" => "decline",
               "icon" => "decline"
             } =
               decline_answer
             | own
           ] = answers_of(blocks)

    refute Map.has_key?(decline_answer, "detail")
    assert_own_answers(own)
    assert_help(blocks)

    # Each card's own button (and key) sends exactly that option's answer; `0` the
    # recommended one's; Decline all opens its form first, asking the alternative.
    for {o, id} <- [{files, "option-1"}, {memory, "option-2"}] do
      assert %{"name" => "invoke", "call" => call} = resolve.(o["answer"]["key"], id)
      assert call == o["answer"]["submit_to"]
    end

    refute files["answer"]["submit_to"] == memory["answer"]["submit_to"]
    assert resolve.("0", "option-1") == resolve.("1", "option-1")
    assert %{"name" => "open", "to" => to} = resolve.("f", "answers")
    assert to == decline_answer["to"]
    refute Map.has_key?(decline_answer, "submit_to")
    assert_asks(note, to, "What is your alternative?")

    [ask | _] = own
    assert_asks(note, ask["to"], "What do you need to know?")
  end

  test "one proposal: its card without an answer, then Accept and Decline (asking the alternative)" do
    definition = JSON.decode!(@text)
    [files, _memory] = definition["options"]

    {blocks, resolve, note} = served(JSON.encode!(Map.put(definition, "options", [files])))

    assert [%{"props" => card}] = Enum.filter(blocks, &(&1["type"] == "option"))
    # The only proposal: no badge (nothing to tell it from; clients show no number for
    # `alone`), its Rule and Consequences in full.
    assert %{"n" => 1, "alone" => true} = card
    refute Map.has_key?(card, "badge")
    refute Map.has_key?(card, "tone")

    assert [
             %{"label" => "Rule", "value" => rule},
             %{"label" => "Consequences", "value" => consequences}
           ] = card["fields"]

    assert rule == files["rule"] and consequences == files["consequences"]

    assert [
             %{"label" => "Accept", "key" => "1", "weight" => "main"} = accept,
             %{"label" => "Decline", "key" => "f", "note" => true, "weight" => "decline"} =
               decline_answer
             | own
           ] = answers_of(blocks)

    # One proposal: Decline stands as a decline next to Accept, without an icon, and
    # says nothing beside it.
    refute Map.has_key?(decline_answer, "icon")
    refute Map.has_key?(decline_answer, "detail")

    assert_own_answers(own)
    assert_help(blocks)

    # Accept sends the proposal's own answer; Decline opens its form.
    assert accept["submit_to"] == card["answer"]["submit_to"]
    assert %{"name" => "open", "to" => to} = resolve.("f", "answers")
    assert to == decline_answer["to"]
    assert_asks(note, to, "What is your alternative?")
  end

  test "an option added from a decline is marked as whoever gave it; not worked out, it shows no rule" do
    definition = JSON.decode!(@text)

    theirs = %{
      "id" => "alternative",
      "text" => "Use the database we have",
      "details" => "melle's alternative, to be worked out by the proposer",
      "effect" => "adopt",
      "rule" => "Use the database we have",
      "consequences" => "No second store to run",
      "by" => "melle"
    }

    for {option, labels, badge} <- [
          {theirs, ["Rule", "Consequences"], "melle's alternative"},
          {%{theirs | "rule" => "", "consequences" => ""}, [],
           "melle's alternative, to be worked out by the proposer"}
        ] do
      {blocks, _resolve, _note} =
        served(JSON.encode!(Map.update!(definition, "options", &(&1 ++ [option]))))

      assert [_files, _memory, %{"props" => card}] =
               Enum.filter(blocks, &(&1["type"] == "option"))

      assert %{"text" => "Use the database we have", "badge" => ^badge} = card
      assert for(f <- card["fields"], do: f["label"]) == labels
    end
  end

  test "stored D-0105 offers only its adoption and preserves its original definition" do
    {blocks, _, _} = served(@legacy)

    assert %{"props" => %{"title" => "Should a contract version difference block a client?"}} =
             Enum.find(blocks, &(&1["id"] == "header"))

    assert [%{"props" => %{"text" => "Tolerant clients; a version difference is a warning"}}] =
             Enum.filter(blocks, &(&1["type"] == "option"))

    fact = Map.put(current(@legacy), "key", "D-0105")
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    presentation =
      decide.present("for_person", fact["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    parts = %{"assignment" => %{"presentation" => presentation}}
    viewer = %{key: "ada", kind: "person"}
    item = %{"fact" => fact, "parts" => parts}
    todo = Model.AtlasEyra.todo("decision", fact, parts, viewer)

    assert todo.choice["question"] == "Should a contract version difference block a client?"
    assert Enum.map(todo.choice["options"], & &1["id"]) == ["tolerant"]
    assert Enum.map(todo.answers, & &1.key) == ~w(1 f q l)
    [choice | _] = todo.answers
    assert {:write, semantic} = Model.AtlasEyra.answer("decision", choice.name, item, viewer)

    assert {:ok, %{"values" => values}, _} =
             AtlasControl.Answers.change(semantic, "D-0105", "ada", "", ~U[2026-11-16 12:00:00Z])

    assert values["selected_option"] == "tolerant"
    assert values["selected_definition"] == @legacy
    assert :ok == check(fact, values)
    legacy_option = @legacy |> JSON.decode!() |> Map.fetch!("options") |> List.last()
    forged = Options.values(@rule, @legacy, legacy_option, fact)
    forged = Map.put(forged, "decided_at", "2026-11-16T12:00:00Z")
    assert {:refuse, _} = check(fact, forged)

    [chosen] =
      Model.AtlasEyra.with_change(
        "decision",
        %{"op" => "change", "key" => "D-0105", "values" => values, "links" => %{}},
        %{"current" => fn -> fact end}
      )

    assert [%{"definition" => @legacy}] = JSON.decode!(chosen["values"]["option_history"])

    assert {:refuse, _} =
             Model.AtlasEyra.answer(
               "decision",
               choice.name,
               put_in(item, ["fact", "values", "force"], "guardrail"),
               viewer
             )

    assert {:refuse, _} = check(fact, %{"options" => @legacy})

    assert {:write, declined} = Model.AtlasEyra.answer("decision", "f", item, viewer)

    assert {:ok, change, _} =
             AtlasControl.Answers.change(
               declined,
               "D-0105",
               "ada",
               "Another approach",
               ~U[2026-11-16 12:00:00Z]
             )

    assert :ok == check(fact, change["values"])
    change = Map.merge(change, %{"op" => "change", "key" => "D-0105", "by" => "ada"})
    [written] = Model.AtlasEyra.with_change("decision", change, %{"current" => fn -> fact end})
    assert [%{"definition" => @legacy}] = JSON.decode!(written["values"]["option_history"])
    revised = JSON.decode!(written["values"]["options"])
    assert Enum.map(revised["options"], & &1["id"]) == ~w(tolerant gate alternative)
    assert List.last(revised["options"])["text"] == "Another approach"
  end

  test "owner projection separates semantic answer identity from numeric shortcuts" do
    fact = Map.put(current(), "key", "D-private")
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    presentation =
      decide.present("for_person", fact["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    parts = %{"assignment" => %{"presentation" => presentation}}
    viewer = %{key: "ada", kind: "person"}
    todo = Model.AtlasEyra.todo("decision", fact, parts, viewer)
    # The options to adopt on their numbers, then the decider's own answers on their keys.
    assert Enum.map(todo.answers, & &1.key) == ~w(1 2 f q l)
    assert Enum.map(todo.choice["options"], & &1["id"]) == ~w(files memory)
    assert todo.choice["recommended"] == "files"
    assert todo.choice["rationale"] != ""
    item = %{"fact" => fact, "parts" => parts}

    assert {:write, semantic} =
             Model.AtlasEyra.answer("decision", hd(todo.answers).name, item, viewer)

    assert semantic["values"]["selected_option"] == "files"

    assert {:ok, content, _} =
             AtlasControl.Answers.change(
               semantic,
               "D-private",
               "ada",
               "",
               ~U[2026-11-16 12:00:00Z]
             )

    assert content["values"]["selected_definition"] == @text
    assert content["links"]["decided_by"] == ["ada"]

    # Declining asks an alternative (D-0106); without one the form asks again.
    assert Enum.map(todo.answers, & &1.note) == [false, false, true, true, false]

    assert {:write, %{"note" => true, "prompt" => "What is your alternative?"} = declined} =
             Model.AtlasEyra.answer("decision", "f", item, viewer)

    assert {:error, "What is your alternative?"} =
             AtlasControl.Answers.change(
               declined,
               "D-private",
               "ada",
               " ",
               ~U[2026-11-16 12:00:00Z]
             )

    assert {:ok, %{"values" => values, "links" => %{"decided_by" => ["ada"]}}, cause} =
             AtlasControl.Answers.change(
               declined,
               "D-private",
               "ada",
               "Use the database we have",
               ~U[2026-11-16 12:00:00Z]
             )

    assert values == %{"status" => "revising", "alternative" => "Use the database we have"}
    assert cause == "declined, with an alternative: Use the database we have"

    # Asking a question: its cause is what the history shows.
    assert {:write, asked} = Model.AtlasEyra.answer("decision", "q", item, viewer)

    assert {:ok, %{"values" => %{"status" => "answering", "question" => "Why now?"}},
            "asked: Why now?"} =
             AtlasControl.Answers.change(
               asked,
               "D-private",
               "ada",
               "Why now?",
               ~U[2026-11-16 12:00:00Z]
             )

    # Delegating to the proposer links its decider as the one who delegates.
    assert {:write, left} = Model.AtlasEyra.answer("decision", "l", item, viewer)

    assert {:ok, %{"values" => %{"left_to_proposer" => true}, "links" => links}, _} =
             AtlasControl.Answers.change(left, "D-private", "ada", "", ~U[2026-11-16 12:00:00Z])

    assert links == %{"delegated_by" => ["ada"]}

    # There is no Hand over of its own any more: Delegate's form hands it over too.
    for shortcut <- ~w(0 1 2 3 9 h),
        do: assert({:refuse, _} = Model.AtlasEyra.answer("decision", shortcut, item, viewer))

    assert {:refuse, _} =
             Model.AtlasEyra.answer("decision", hd(todo.answers).name, item, %{key: "other"})

    changed = put_in(item, ["fact", "values", "force"], "guardrail")

    assert {:refuse, _} =
             Model.AtlasEyra.answer("decision", hd(todo.answers).name, changed, viewer)

    accepted = put_in(fact, ["values", "status"], "accepted")
    follow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "follow_through"))

    next =
      follow.present("waiting", accepted["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    todo =
      Model.AtlasEyra.todo(
        "decision",
        accepted,
        %{"assignment" => %{"presentation" => next}},
        viewer
      )

    assert todo.choice == nil
    assert todo.answers == []
  end

  # D-0106: Delegate is one answer, whose form leaves nothing chosen: the proposer, who
  # decides as the decider delegates (the answer's own change), or another person, to
  # whom the page hands it over (they decide instead).
  test "Delegate's form chooses the proposer or another person; each sends its own write" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    fact =
      current() |> Map.put("key", "D-private") |> Map.put("links", %{"proposed_by" => ["melle"]})

    presentation =
      decide.present("for_person", fact["values"])
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    assignment = %{"key" => "AS-D-private", "values" => %{}, "presentation" => presentation}
    item_reads = AtlasControl.Pages.reads({:item, "decision", "D-private"}, m)
    route = {:answer, "decision", "D-private", "l"}
    # Its page reads whom it may be delegated to too: people.
    assert AtlasControl.Pages.reads(route, m) == item_reads ++ [{"person", %{}}]
    people = for key <- ~w(melle ada bob), do: %{"key" => key, "values" => %{}}

    answers =
      [%{"fact" => fact}] ++
        for(_ <- 2..(length(item_reads) - 1)//1, do: %{"facts" => []}) ++
        [%{"fact" => assignment}, %{"facts" => people}]

    form = %{by: "ada", by_kind: "person"}
    page = AtlasControl.Pages.render(route, m, answers, form)
    assert page.title == "Delegate D-private to…"

    assert [%{"type" => "form", "props" => %{"submit_label" => "Delegate", "inputs" => inputs}}] =
             page.blocks

    assert [to, person] = inputs
    assert %{"name" => "to", "kind" => "choice", "required" => true} = to
    refute Map.has_key?(to, "value")

    assert to["choices"] == [
             %{
               "value" => "proposer",
               "label" => "The proposer (melle) — decides on your behalf",
               "help" => "The proposer decides, as you delegate"
             },
             %{
               "value" => "other",
               "label" => "Another person",
               "help" => "The person you choose decides instead of you"
             }
           ]

    assert %{
             "name" => "whom",
             "kind" => "choice",
             "required" => true,
             "shown_when" => %{"name" => "to", "value" => "other"}
           } = person

    refute Map.has_key?(person, "value")
    # Anyone but the viewer.
    assert Enum.map(person["choices"], & &1["value"]) == ~w(bob melle)

    answer = AtlasControl.Pages.declared_answer(m, "decision", "l", answers, form)
    d = AtlasControl.Pages.delegation(m, "decision", answer, answers, form)

    # To the proposer: the answer's own change, delegated by the decider.
    assert {:answer, "l"} = AtlasControl.Pages.delegate_submit(d, %{"to" => "proposer"})

    assert {:write, %{"self" => "delegated_by", "values" => %{"left_to_proposer" => true}}} =
             Model.AtlasEyra.answer(
               "decision",
               "l",
               AtlasControl.Pages.answer_item(m, "decision", answers),
               %{key: "ada", kind: "person"}
             )

    # To someone else: the page's own hand-over of its assignment to them.
    assert {:link, "assignment", "AS-D-private", "assigned_to", "bob"} =
             AtlasControl.Pages.delegate_submit(d, %{"to" => "other", "whom" => "bob"})

    # Nothing without a choice the form offered.
    for raw <- [
          %{},
          %{"to" => ""},
          %{"to" => "other"},
          %{"to" => "other", "whom" => "ada"},
          %{"to" => "other", "whom" => "zoe"}
        ] do
      assert {:error, _} = AtlasControl.Pages.delegate_submit(d, raw)
    end

    # Proposed by an agent (no person linked), the proposer's choice names nobody.
    unlinked = List.replace_at(answers, 0, %{"fact" => Map.put(fact, "links", %{})})
    page = AtlasControl.Pages.render(route, m, unlinked, form)
    [%{"props" => %{"inputs" => [to | _]}}] = page.blocks
    assert hd(to["choices"])["label"] == "The proposer — decides on your behalf"
  end

  test "under a fixed person rule Delegate is the page's own hand-over, on its key" do
    {blocks, resolve, _note} = served(@text, %{}, "for_person_always")

    assert [_decline, %{"label" => "Ask"}, %{"label" => "Delegate", "key" => "l"} = delegate] =
             answers_of(blocks)

    assert delegate["to"] == "/k/assignment/AS-D-private/links/assigned_to"
    assert delegate["help"] == "Let another person decide"
    assert %{"name" => "open", "to" => to} = resolve.("l", "answers")
    assert to == delegate["to"]
    # No second Hand to… beside it.
    refute inspect(blocks) =~ "Hand to"
    assert_help(blocks)
  end

  # D-0106: leaving it to the proposer is its decider's own choice, made by them, in their
  # own session; then the proposer decides on their behalf, delegated.
  test "leaving it to the proposer is the decider's alone; the proposer then decides on their behalf" do
    fact = Map.put(current(), "key", "D-private")
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    waiting = fn state, values, owner ->
      decide.present(state, values) |> Map.merge(%{"owner" => [owner], "actionable" => true})
    end

    parts = %{"assignment" => %{"presentation" => waiting.("for_person", fact["values"], "ada")}}
    item = %{"fact" => fact, "parts" => parts}

    # Its decider may; an agent that assists them may not, nor anyone else.
    assert {:write, _} =
             Model.AtlasEyra.answer("decision", "l", item, %{key: "ada", kind: "person"})

    for viewer <- [
          %{key: "coordinator", kind: "agent", assists: "ada"},
          %{key: "dev1", kind: "agent", assists: "ada"},
          %{key: "bob", kind: "person"}
        ] do
      assert {:refuse, _} = Model.AtlasEyra.answer("decision", "l", item, viewer)
      # Nor declining or asking, which name the decider; an assistant may hand it over.
      assert {:refuse, _} = Model.AtlasEyra.answer("decision", "f", item, viewer)
    end

    # Facts refuses anyone but the delegating person setting delegated_by, to themselves.
    leave = %{"left_to_proposer" => true}

    refuse = fn actor, kind, delegator ->
      lookup = %{
        "current" => fn -> fact end,
        "fact" => fn of, key -> if of == kind, do: %{key: key, properties: %{}, links: %{}} end,
        "list" => fn _ -> {:ok, []} end,
        "incoming" => fn _, _, _ -> [] end,
        "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
      }

      Model.AtlasEyra.check(
        "decision",
        %{
          "op" => "change",
          "key" => "D-private",
          "values" => leave,
          "links" => %{"delegated_by" => [delegator]}
        },
        %{"by" => actor},
        lookup
      )
    end

    assert :ok == refuse.("ada", "person", "ada")
    assert {:refuse, _} = refuse.("coordinator", "agent", "ada")
    assert {:refuse, _} = refuse.("bob", "person", "ada")

    # Left to its proposer (the coordinator, as an agent put it in): it chooses through
    # Control, and its answer says it decided on the decider's behalf, delegated.
    delegated = put_in(fact, ["links"], %{"delegated_by" => ["ada"]})

    parts = %{
      "assignment" => %{
        "presentation" => waiting.("for_agent", delegated["values"], "coordinator")
      }
    }

    item = %{"fact" => delegated, "parts" => parts}
    coordinator = %{key: "coordinator", kind: "agent"}
    todo = Model.AtlasEyra.todo("decision", delegated, parts, coordinator)
    assert Enum.map(todo.answers, & &1.key) == ~w(1 2)

    assert {:write, chosen} =
             Model.AtlasEyra.answer("decision", hd(todo.answers).name, item, coordinator)

    assert {:ok, content, cause} =
             AtlasControl.Answers.change(
               chosen,
               "D-private",
               "coordinator",
               "",
               ~U[2026-11-16 12:00:00Z]
             )

    assert content["links"] == %{"decided_by" => ["coordinator"]}
    assert content["values"]["status"] == "accepted"
    assert cause =~ "decided by coordinator on behalf of ada, delegated"

    # Facts stores it, though its decider is decided_by already (they asked a question
    # first): the proposer it is assigned to takes their place. Nobody else does, and not
    # without the delegation.
    stored =
      put_in(fact, ["links"], %{
        "decided_by" => ["ada"],
        "delegated_by" => ["ada"],
        "assignment" => ["AS-D-private"]
      })

    verdict = %{
      "verdict" => "agent",
      "fingerprint" =>
        AtlasBus.SubjectFingerprint.of(stored, @authority["decider"]["fingerprint"])
    }

    kinds = %{"ada" => "person", "bob" => "person", "coordinator" => "agent", "dev1" => "agent"}

    stores = fn current, writer ->
      lookup = %{
        "current" => fn -> current end,
        "fact" => fn
          "assignment", "AS-D-private" ->
            %{key: "AS-D-private", properties: %{}, links: %{"assigned_to" => ["coordinator"]}}

          of, key ->
            if kinds[key] == of, do: %{key: key, properties: %{}, links: %{}}
        end,
        "list" => fn
          "gate_verdict" ->
            {:ok,
             [
               %{
                 key: "GV-private",
                 links: %{"about" => ["D-private"]},
                 properties:
                   Map.merge(verdict, %{
                     "gate" => "accept_decision",
                     "subject" => "D-private",
                     "purpose" => "decider"
                   })
               }
             ]}

          _ ->
            {:ok, []}
        end,
        "incoming" => fn _, _, _ -> [] end,
        "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
      }

      change = %{
        content
        | "links" => %{"decided_by" => [writer]}
      }

      Model.AtlasEyra.check(
        "decision",
        Map.put(change, "key", "D-private"),
        %{"by" => writer},
        lookup
      )
    end

    assert :ok == stores.(stored, "coordinator")

    for {current, writer} <- [
          {stored, "dev1"},
          {stored, "bob"},
          {put_in(stored, ["links", "delegated_by"], ["bob"]), "coordinator"},
          {update_in(stored, ["links"], &Map.delete(&1, "delegated_by")), "coordinator"}
        ] do
      assert {:refuse, reasons} = stores.(current, writer)

      assert "only the one who decides sets decided_by, to themselves; another only once its decider left it to them, its proposer" in reasons
    end

    # A worker agent is never its proposer: it gets nothing to answer.
    assert {:refuse, _} =
             Model.AtlasEyra.answer(
               "decision",
               hd(todo.answers).name,
               item,
               %{key: "dev1", kind: "agent", assists: "ada"}
             )
  end
end
