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

    for change <- [
          Map.put(definition, "recommended", "missing"),
          Map.put(definition, "recommended", "memory"),
          put_in(definition, ["options", Access.at(1), "id"], "files"),
          put_in(definition, ["options", Access.at(1), "details"], " "),
          put_in(definition, ["options", Access.at(1), "effect"], "approve"),
          put_in(definition, ["options", Access.at(2), "rule"], "Not a decline"),
          # Only adopting options would leave the decider no way to refuse.
          Map.put(definition, "options", Enum.take(definition["options"], 2))
        ] do
      assert {:error, _} = Options.decode(@rule, JSON.encode!(change))
      assert {:refuse, _} = check(current(), %{"options" => JSON.encode!(change)})
    end
  end

  test "a decision may still be created without options and keeps the a/f answers" do
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
    assert Enum.map(todo.answers, & &1.key) == ~w(a f)
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

  # The page a TUI opens from Assigned to you, as Control serves it to a Console client.
  test "a Console client is served the offer: 0 and 1 one call, decline asks for a note" do
    m = AtlasControl.Model.catalog(Model.AtlasEyra)
    decide = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "decide"))
    fact = Map.put(current(), "key", "D-private")

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

    assert {:ok, projected} = AtlasControl.Console.project(message, 3)
    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)

    [choice] = for %{"type" => "single_choice", "props" => p} <- projected["blocks"], do: p
    assert String.ends_with?(choice["instructions"], "\n0 selects recommended choice 1.")
    assert Enum.map(choice["options"], & &1["note"]) == [false, false, true]

    at = %{path: "/k/decision/D-private", context: "browse", generation: 1, on: "item", row: nil}

    [zero, one, two, three] =
      for key <- ~w(0 1 2 3) do
        assert {:ok, event} = AtlasBFFContract.Console.capture(projection, key, at)
        assert {:ok, action} = AtlasBFFContract.Console.resolve(projection, event, at)
        action["props"]["operation"]
      end

    assert %{"name" => "invoke", "call" => call} = zero
    assert one == zero
    assert call["params"]["answer"] == hd(choice["options"])["answer"]["params"]["answer"]
    assert %{"name" => "invoke"} = two
    refute two == one
    decline = List.last(choice["options"])["answer"]["params"]["answer"]
    assert three == %{"name" => "open", "to" => "/k/decision/D-private/answer/" <> decline}

    note =
      AtlasControl.Pages.render({:answer, "decision", "D-private", decline}, m, answers, form)

    assert [
             %{
               "type" => "form",
               "props" => %{"inputs" => [%{"name" => "note", "required" => true}]}
             }
           ] =
             note.blocks
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
    assert Enum.map(todo.answers, & &1.key) == ~w(1 2 3)
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

    # Declining is given with a note, as the a/f Reject is.
    assert Enum.map(todo.answers, & &1.note) == [false, false, true]
    decline = List.last(todo.answers).name

    assert {:write, %{"note" => true} = declined} =
             Model.AtlasEyra.answer("decision", decline, item, viewer)

    assert {:error, _} =
             AtlasControl.Answers.change(
               declined,
               "D-private",
               "ada",
               " ",
               ~U[2026-11-16 12:00:00Z]
             )

    assert {:ok, %{"values" => %{"selected_option" => "decline"}}, "Not now"} =
             AtlasControl.Answers.change(
               declined,
               "D-private",
               "ada",
               "Not now",
               ~U[2026-11-16 12:00:00Z]
             )

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
end
