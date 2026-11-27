defmodule Model.DecisionOptionsTest do
  use ExUnit.Case, async: true
  alias RelaDSL.DecisionOptions, as: Options
  @text File.read!(Path.expand("../../../e2e/fixtures/decision-options.json", __DIR__))
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
    for id <- ~w(files memory decline), do: assert(:ok == check(current(), answer(id)))
    assert {:refuse, _} = check(current(), answer("files"), "helper", "agent")
    assert {:refuse, _} = check(current(), Map.put(answer("files"), "decision", "Different rule"))

    assert {:refuse, _} =
             check(current(), Map.put(answer("decline"), "decision", "Smuggled rule"))

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

  test "answered offers remain immutable even when declined; allowed later changes preserve them" do
    for id <- ~w(files memory decline) do
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

  test "definitions validate identities, recommendation, complete text and typed effects" do
    {:ok, definition} = Options.decode(@rule, @text)
    # Cardinality belongs to the answer contract, not a terminal's single-digit keys.
    alternatives =
      for(n <- 1..11, do: Map.put(hd(definition["options"]), "id", "choice#{n}")) ++
        [List.last(definition["options"])]

    many = definition |> Map.put("options", alternatives) |> Map.put("recommended", "choice1")
    assert {:ok, _} = Options.decode(@rule, JSON.encode!(many))

    assert {:ok, _} =
             Options.decode(
               @rule,
               JSON.encode!(
                 Map.put(definition, "options", [
                   hd(definition["options"]),
                   List.last(definition["options"])
                 ])
               )
             )

    # Two alternatives need no decline, nor does one proposal: declining is always the
    # decider's own answer, with an alternative (D-0106).
    for options <- [Enum.take(definition["options"], 2), [hd(definition["options"])]] do
      assert {:ok, _} =
               Options.decode(@rule, JSON.encode!(Map.put(definition, "options", options)))
    end

    for change <- [
          Map.put(definition, "recommended", "missing"),
          Map.put(definition, "recommended", "memory"),
          put_in(definition, ["options", Access.at(1), "id"], "files"),
          put_in(definition, ["options", Access.at(1), "details"], " "),
          put_in(definition, ["options", Access.at(1), "effect"], "approve"),
          put_in(definition, ["options", Access.at(2), "rule"], "Not a decline"),
          # Whose alternative it is, when it says so, is someone.
          put_in(definition, ["options", Access.at(1), "by"], " "),
          # No options, or declines alone, are nothing to adopt.
          Map.put(definition, "options", []),
          definition
          |> Map.put("options", [
            List.last(definition["options"]),
            Map.put(List.last(definition["options"]), "id", "decline2")
          ])
          |> Map.put("recommended", "decline")
        ] do
      assert {:error, _} = Options.decode(@rule, JSON.encode!(change))
      assert {:refuse, _} = check(current(), %{"options" => JSON.encode!(change)})
    end
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
    # Accept, Decline (with an alternative), Ask a question, Hand over, Leave it to the
    # proposer (D-0106).
    assert Enum.map(todo.answers, & &1.key) == ~w(a f q h l)
    assert Enum.map(todo.answers, & &1.weight) == ~w(main decline other other other)
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

    # The offer as it was, then theirs: to adopt, its rule and what follows the
    # alternative until the proposer words them. The recommendation stays the proposer's.
    assert Enum.drop(after_decline["options"], -1) == before["options"]
    assert after_decline["recommended"] == before["recommended"]

    assert List.last(after_decline["options"]) == %{
             "id" => "alternative",
             "text" => "Use the database we have",
             "details" => "melle's alternative",
             "effect" => "adopt",
             "rule" => "Use the database we have",
             "consequences" => "Use the database we have",
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

    # Its proposer words it and sets the recommendation, while it is theirs.
    reworded =
      after_decline
      |> Map.put("options", Enum.reverse(after_decline["options"]))
      |> Map.put("recommended", "alternative")
      |> put_in(["options", Access.at(0), "rule"], "Store it in the database we have")

    assert :ok == check(revised, %{"options" => JSON.encode!(reworded)}, "coordinator", "agent")

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

    for id <- ~w(files decline) do
      [selected] =
        Model.AtlasEyra.with_change("decision", %{change | "values" => answer(id)}, lookup)

      assert [offered] = JSON.decode!(selected["values"]["option_history"])
      assert offered["definition"] == @text
      assert offered["revision"] == selected["values"]["selected_revision"]
    end
  end

  # The page a TUI opens from Assigned to you, as Control serves it to a Console client:
  # its blocks besides console actions, and how a key resolves on it.
  defp served(text, values \\ %{}) do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))

    fact =
      text
      |> current()
      |> Map.put("key", "D-private")
      |> update_in(["values"], &Map.merge(&1, values))

    presentation =
      decide.present("for_person", fact["values"])
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
  # what it does: Ask a question, Hand over (the page's Hand to), Leave it to the proposer.
  defp assert_own_answers(answers) do
    assert [
             %{"label" => "Ask a question", "key" => "q", "note" => true, "weight" => "other"} =
               ask,
             %{"label" => "Hand over", "key" => "h", "weight" => "other"} = hand_over,
             %{"label" => "Leave it to the proposer", "key" => "l", "weight" => "other"} = leave
           ] = answers

    assert ask["icon"] == "question"
    assert hand_over["icon"] == "hand_over"
    assert hand_over["to"] == "/k/assignment/AS-D-private/links/assigned_to"
    assert leave["icon"] == "delegate"
    refute Map.has_key?(leave, "note")
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
    labels = Enum.map(item["props"]["fields"], & &1["label"])
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
    assert "interface" in values or "Interface" in values, inspect(labels)
    assert item["props"]["title"] == ""
  end

  test "alternatives: a card each with its own Choose, then Decline all with an alternative" do
    {blocks, resolve, note} = served(@text)

    # In order: the question, why, each alternative (recommended first), the answers, the
    # details. The decline is no card.
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
    assert why["label"] == "Why" and why["text"] != ""
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

    # Decline all is the decider's own decline: it asks their alternative; what the
    # definition's decline option said is the explanation beside it.
    decline = Enum.find(definition["options"], &(&1["effect"] == "decline"))

    assert [
             %{"label" => "Decline all", "key" => "f", "note" => true, "weight" => "decline"} =
               decline_answer
             | own
           ] = answers_of(blocks)

    assert decline_answer["detail"] == decline["text"]
    assert_own_answers(own)

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
    [files, _memory, decline] = definition["options"]

    # With the definition's decline option, or without one: Decline is always there.
    for {options, detail} <- [{[files, decline], decline["text"]}, {[files], nil}] do
      {blocks, resolve, note} = served(JSON.encode!(Map.put(definition, "options", options)))

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

      assert_own_answers(own)

      # Accept sends the proposal's own answer; Decline opens its form.
      assert accept["submit_to"] == card["answer"]["submit_to"]
      assert decline_answer["detail"] == detail
      assert %{"name" => "open", "to" => to} = resolve.("f", "answers")
      assert to == decline_answer["to"]
      assert_asks(note, to, "What is your alternative?")
    end
  end

  test "alternatives without a decline option: a card each with its Choose, and Decline all" do
    definition = JSON.decode!(@text)
    text = JSON.encode!(Map.update!(definition, "options", &Enum.take(&1, 2)))
    {blocks, _resolve, _note} = served(text)

    assert [_, _] = Enum.filter(blocks, &(&1["type"] == "option"))

    assert [%{"label" => "Decline all", "weight" => "decline"} = decline | own] =
             answers_of(blocks)

    refute Map.has_key?(decline, "detail")
    assert_own_answers(own)
  end

  test "an option added from a decline is marked as whoever gave it" do
    definition = JSON.decode!(@text)

    theirs = %{
      "id" => "alternative",
      "text" => "Use the database we have",
      "details" => "melle's alternative",
      "effect" => "adopt",
      "rule" => "Use the database we have",
      "consequences" => "Use the database we have",
      "by" => "melle"
    }

    {blocks, _resolve, _note} =
      served(JSON.encode!(Map.update!(definition, "options", &(&1 ++ [theirs]))))

    assert [_files, _memory, %{"props" => card}] =
             Enum.filter(blocks, &(&1["type"] == "option"))

    assert %{"text" => "Use the database we have", "badge" => "melle's alternative"} = card
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
    assert Enum.map(todo.answers, & &1.key) == ~w(1 2 f q h l)
    assert Enum.map(todo.choice["options"], & &1["id"]) == ~w(files memory decline)
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
    assert Enum.map(todo.answers, & &1.note) == [false, false, true, true, false, false]

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

    # Leaving it to the proposer links its decider as the one who delegates.
    assert {:write, left} = Model.AtlasEyra.answer("decision", "l", item, viewer)

    assert {:ok, %{"values" => %{"left_to_proposer" => true}, "links" => links}, _} =
             AtlasControl.Answers.change(left, "D-private", "ada", "", ~U[2026-11-16 12:00:00Z])

    assert links == %{"delegated_by" => ["ada"]}

    # Hand over is the page's own Hand to: no change of its own.
    assert {:refuse, _} = Model.AtlasEyra.answer("decision", "h", item, viewer)

    for shortcut <- ~w(0 1 2 3 9),
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
