defmodule RelaDSL.SupervisionTest do
  @moduledoc """
  Supervision (work acquisition design 2026-11-17, §5.6–5.8): a subflow declares its supervised spans
  (`supervise`); the composition maps them, with the relation to a run's human
  supervisor and the pickup and hand-over input fields, into the run mapping, beside the
  subflows, never in a subflow's definition; the start page offers the two supervision entries. The
  tests assert structure: what is refused, and the shape of what is compiled.
  """
  use ExUnit.Case, async: true

  alias RelaDSL.{Atlas, Composition, Problem}
  alias RelaDSL.Description.{Build, Check}

  # -- A subflow's spans (RelaDSL.Schema) ---------------------------------------------

  # The body sits at line 1 of the fixture file, after `defmodule … do use …`.
  defp compile!(body) do
    module = :"Elixir.RelaDSL.SupervisionFixture#{System.unique_integer([:positive])}"
    file = "supervision_#{System.unique_integer([:positive])}.ex"

    src =
      "defmodule #{inspect(module)} do use RelaDSL.Schema, " <>
        "gates: RelaDSL.Example.Gates\n#{body}end\n"

    [{^module, _}] = Code.compile_string(src, file)
    module
  end

  defp refused(body, message) do
    error = assert_raise CompileError, fn -> compile!(body) end
    assert error.description =~ message
    error
  end

  # A gate whose person verdict leads to `decide`; the `spans` vary.
  defp gated(spans) do
    """
    subflow :f, subject: :t do
      owner default: {:team, :desk}
      run_as "system:x"
      start :create
      initial :a
      #{spans}
      state :a do
        timer :t, "1d", to: :check
      end
      state :check do
        gate :size_limit, fits: :b, person: :decide
      end
      state :decide do
        timer :t, "1d", to: :b
      end
      final :b
    end
    """
  end

  test "a span is plain data of its subflow, in the order written" do
    [flow] =
      compile!(gated("supervise :work, label: \"Work\", states: [:a, :check, :decide]\n")).__flows__()

    assert [%{name: :work, label: "Work", states: [:a, :check, :decide], with: []}] = flow.spans

    [plain] = compile!(gated("")).__flows__()
    assert plain.spans == []
  end

  test "a span sits beside the subflow's definition: it changes nothing in it" do
    [spanned] = compile!(gated("supervise :work, states: [:a, :check, :decide]\n")).__flows__()
    [plain] = compile!(gated("")).__flows__()
    gates = RelaDSL.Example.Gates.__gates__()

    assert Atlas.definitions([spanned], gates) == Atlas.definitions([plain], gates)
    refute Atlas.flows_json([spanned], gates) =~ "\"spans\""
  end

  test "a span's shape is checked" do
    refused(gated("supervise :work, states: []\n"), "supervise work: needs states:")

    refused(
      gated("supervise :work, states: [:a], colour: :red\n"),
      "supervise work: knows no colour"
    )

    refused(gated("supervise :Work, states: [:a]\n"), "is not a valid name")
    refused(gated("supervise :work, states: [:a], label: 3\n"), "label: is a text")
    refused(gated("supervise :work, [:a]\n"), "takes states:, label: and with:")
  end

  test "a span names known states that are not final, each in one span, once" do
    refused(gated("supervise :work, states: [:z]\n"), "supervise work: names unknown state z")
    refused(gated("supervise :work, states: [:a, :b]\n"), "state b is final")

    refused(
      gated("supervise :work, states: [:a]\nsupervise :more, states: [:a]\n"),
      "state a lies in more than one span"
    )

    refused(
      gated("supervise :work, states: [:a]\nsupervise :work, states: [:check]\n"),
      "supervise work is given more than once"
    )
  end

  test "S3: a gate's person outcome lies in a span, or names its own owner" do
    # Outside every span: refused, at the gate's state.
    error = refused(gated("supervise :work, states: [:a, :check]\n"), "gate size_limit's person")
    assert error.description =~ "decide"

    # Inside a span: its escalation goes to the human supervisor.
    assert compile!(gated("supervise :work, states: [:a, :check, :decide]\n"))

    # Its own owner, such as the configured decider: the fallback is written.
    assert compile!(decider_owned())

    # A subflow without spans keeps today's rule: the decider is the fallback.
    assert compile!(gated(""))
  end

  # The person outcome outside the span, in a state that names the decider as its owner.
  defp decider_owned do
    """
    subflow :f, subject: :t do
      owner default: {:team, :desk}
      run_as "system:x"
      start :create
      initial :a
      supervise :work, states: [:a, :check]
      state :a do
        timer :t, "1d", to: :check
      end
      state :check do
        gate :size_limit, fits: :b, person: :decide
      end
      state :decide do
        owner default: {:person, config: :decider}
        timer :t, "1d", to: :b
      end
      final :b
    end
    """
  end

  # -- A composition's supervision ------------------------------------------------------

  defp model(parts) do
    p = "RelaDSL.SupervisionTest.M#{System.unique_integer([:positive])}"
    get = &Keyword.get(parts, &1, "")

    source = """
    #{desk(p, parts)}
    defmodule #{p}.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Desk]
    end
    defmodule #{p}.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"
      modules [#{p}.Mod]
      #{get.(:composition)}
      defcomposition :c do
        subflows([#{p}.Desk])
      end
    end
    """

    modules = Code.compile_string(source, "model.exs")
    {comp, _} = Enum.find(modules, fn {m, _} -> String.ends_with?(inspect(m), ".Comp") end)
    comp
  end

  # The concept the compositions above select: a case with its parts, the runs, their
  # inputs and the relation to a run's supervisor (`parts` change one thing at a time).
  defp desk(p, parts) do
    get = &Keyword.get(parts, &1, "")

    """
    defmodule #{p}.Desk do
      use RelaDSL
      type :op, values: [:choice, :pickup, :hand_over, :retry]
      entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
        field :name, :string
      end
      entity :run, label: "Run", plural: "runs", id_type: :manual do
        field :flow, :string
        field :state, :string
      end
      entity :input, label: "Input", plural: "inputs", id_type: :manual do
        field :run, :string
        field :operation, #{Keyword.get(parts, :operation_type, ":op")}
        field :hand_to, :string
      end
      entity :case, label: "Case", plural: "cases", id_type: :manual do
        field :title, :string
        #{get.(:case_fields)}
      end
      entity :part, label: "Part", plural: "parts", id_type: :manual do
        field :title, :string
      end
      relation :part_of, label: "part of", from: [:part], to: [:case], max_outgoing: 1
      relation :watched_by, label: "watched by", from: [:run], to: [:clerk]#{Keyword.get(parts, :max, ", max_outgoing: 1")}
      flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input#{Keyword.get(parts, :supervision, ", supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]")})
      subflow :case, subject: :case do
        owner #{Keyword.get(parts, :case_owner, "default: {:clerk, :desk}")}
        start :create
        initial :open
        #{Keyword.get(parts, :span, "supervise :work, label: \"Work\", states: [:open], with: [:part]")}
        state :open do
          timer :t, "1d", to: :done
        end
        final :done
      end
      subflow :part, subject: :part do
        owner default: {:clerk, :desk}
        start :create
        initial :open
        state :open do
          timer :t, "1d", to: :done
        end
        final :done
      end
      #{get.(:concept)}
    end
    """
  end

  defp model_refused(parts, message) do
    error = assert_raise CompileError, fn -> model(parts) end
    assert error.description =~ message
  end

  @entries """
  start_page(
    open_for_you: [title: "Open", count: "{count} open", empty: "None"],
    supervised_by_you: [title: "Yours", count: "{count} yours", empty: "None"]
  )
  """

  test "the run mapping holds the relation, the input fields and every subflow's spans" do
    comp = model([])

    assert %{
             "version" => 1,
             "relation" => "watched_by",
             "inputs" => %{
               "operation" => "operation",
               "hand_to" => "hand_to",
               "operations" => ["pickup", "hand_over", "retry"]
             },
             "spans" => %{
               "case" => [
                 %{"name" => "work", "label" => "Work", "states" => ["open"], "with" => ["part"]}
               ]
             }
           } = comp.supervision()

    refute Map.has_key?(comp.supervision()["spans"], "part")
    # The input fields are mapped as every other field of an input.
    assert %{"operation" => "operation", "hand_to" => "hand_to"} = comp.runs()["inputs"]["fields"]
  end

  test "without supervision: declared, nothing is supervised, and no span may be" do
    comp = model(supervision: "", span: "")
    assert comp.supervision() == nil
    model_refused([supervision: ""], "supervise work: flow_runtime declares no supervision:")
  end

  test "supervision names a relation from a run to one supervisor, and the input fields" do
    model_refused([max: ""], "relation watched_by must lead from run to one supervisor")

    model_refused(
      [operation_type: ":string"],
      "input.operation must be a field whose type has the values pickup, hand_over, retry"
    )

    model_refused(
      [
        supervision:
          ", supervision: [relation: :watched_by, operation: :operation, hand_to: :gone]"
      ],
      "input.gone must be a field"
    )

    model_refused(
      [supervision: ", supervision: [relation: :watched_by, colour: :red]"],
      "unknown keys colour"
    )
  end

  test "a span's with: names a running subflow whose subject points at the span's subject" do
    model_refused(
      [span: "supervise :work, states: [:open], with: [:ghost]"],
      "with: ghost is no subflow the composition runs"
    )

    model_refused(
      [span: "supervise :work, states: [:open], with: [:case]"],
      "with: case runs on case, which points at no case"
    )
  end

  test "the start page's supervision entries, from the spans and the relation" do
    comp = model(composition: @entries)

    assert %{
             open_for_you: %{
               title: "Open",
               count: "{count} open",
               empty: "None",
               spans: [
                 %{
                   subflow: "case",
                   subject: nil,
                   written_on: nil,
                   span: "work",
                   label: "Work",
                   states: ["open"],
                   with: ["part"]
                 }
               ]
             },
             supervised_by_you: %{relation: "watched_by", title: "Yours"}
           } = comp.start_page()

    # What Control needs to send a pickup or hand-over: the relation and the inputs'
    # kind, as the run mapping has them; and per span its with: subflows' subjects.
    %{open_for_you: open, supervised_by_you: mine} = comp.start_page()
    assert open.relation == comp.supervision()["relation"]
    assert open.inputs == comp.runs()["inputs"]["kind"]
    assert mine.inputs == open.inputs and mine.relation == open.relation
    assert Enum.all?(open.spans, &(length(&1.with_subjects) == length(&1.with)))

    plain = model([])

    assert %{open_for_you: nil, supervised_by_you: nil} = plain.start_page()
  end

  # The span's work written on a component of its subject (`on:`), or on the subject.
  @card """
  entity :card, label: "Card", plural: "cards", id_type: :manual, id_prefix: "CD-" do
    field :of, :string, required: true
    field :expected, :string, set_by: [:flow]
    field :flow_state, :string
    top(false)
  end
  relation :card, label: "card", from: [:case], to: [:card], max_outgoing: 1,
    component: [key: "CD-{key}", values: [of: "{key}"]]
  """

  test "a span names the kind its work is written on: the on: component's, else the subject's" do
    on_card =
      model(
        composition: @entries,
        concept:
          @card <>
            "select(:case, projection: [on: :card, state_field: :flow_state, field: :expected])"
      )

    assert [%{subflow: "case", subject: "case", written_on: "card"}] =
             on_card.start_page().open_for_you.spans

    on_case =
      model(
        composition: @entries,
        case_fields: "field :expected, :string, set_by: [:flow]\nfield :flow_state, :string",
        concept: "select(:case, projection: [state_field: :flow_state, field: :expected])"
      )

    assert [%{subflow: "case", subject: "case", written_on: "case"}] =
             on_case.start_page().open_for_you.spans

    unprojected = model(composition: @entries, concept: "select(:case, roles: [])")

    assert [%{subflow: "case", subject: "case", written_on: "case"}] =
             unprojected.start_page().open_for_you.spans
  end

  test "the start page's supervision entries need declared supervision and their keys" do
    model_refused(
      [supervision: "", span: "", composition: @entries],
      "start_page open_for_you: no flow_runtime declares supervision:"
    )

    model_refused(
      [composition: "start_page(open_for_you: [title: \"Open\", colour: \"red\"])"],
      "start.open_for_you: unknown keys colour"
    )
  end

  # -- The shell's screen tabs ------------------------------------------------------------

  defp keys(problems), do: Enum.map(problems, fn {_where, p} -> Problem.key(p) end)

  @screens [{"/_open", "open_for_you"}, {"/_supervised", "supervised_by_you"}]

  defp shell_with(tabs, start) do
    %{
      "shell" => %{
        "title" => "Desk",
        "tabs" => for({to, id} <- tabs, do: %{"id" => id, "label" => id, "to" => to})
      },
      "start" => start
    }
  end

  @entry %{"title" => "T", "count" => "{count}", "empty" => "E"}

  test "a tab opens a screen only when the start page has its entry" do
    for {to, entry} <- @screens do
      missing = keys(Check.check(%{}, shell_with([{to, entry}], %{})))
      assert {:tab_screen, [to, entry]} in missing

      present = keys(Check.check(%{}, shell_with([{to, entry}], %{entry => @entry})))
      refute Enum.any?(present, &match?({:tab_screen, _}, &1)), to
      refute Enum.any?(present, &match?({:tab_destination, _}, &1)), to
    end

    # The other screen's entry does not stand in for it.
    other =
      keys(Check.check(%{}, shell_with([{"/_open", "o"}], %{"supervised_by_you" => @entry})))

    assert {:tab_screen, ["/_open", "open_for_you"]} in other
  end

  test "a composition whose tab opens a screen without its entry is refused at compile time" do
    tabs = """
    shell(title: "Desk", tabs: [[id: :open, label: "Open", to: "/_open"]])
    """

    assert_raise CompileError, fn -> model(composition: tabs) end

    comp = model(composition: tabs <> @entries)
    assert %{"tabs" => [%{"id" => "open", "to" => "/_open"}]} = comp.shell(%{})
  end

  test "the shell's default names one of its tabs" do
    shell = fn default ->
      %{
        "shell" => %{
          "title" => "Desk",
          "tabs" => [%{"id" => "a", "label" => "A", "to" => "/k/x"}],
          "default" => default
        }
      }
    end

    defaults = fn x -> for {:shell_default, _} = k <- keys(Check.check(%{}, x)), do: k end

    assert defaults.(shell.("a")) == []
    assert defaults.(shell.("b")) == [{:shell_default, ["b"]}]
    assert defaults.(shell.(nil)) == [{:shell_default, [nil]}]

    no_default = update_in(shell.("a"), ["shell"], &Map.delete(&1, "default"))
    assert defaults.(no_default) == []
    refute Enum.any?(keys(Check.check(%{}, shell.("a"))), &match?({:unknown_keys, _}, &1))
  end

  # -- An item's producer (producer, SC-Atlas-09) ------------------------------------------

  # A case's producer: the clerk who supervised the run that made it, set by Flow alone;
  # and relations that break one rule each.
  @made_by """
  relation :made_by, label: "made by", from: [:case, :part], to: [:clerk], max_outgoing: 1, set_by: [:flow]
  relation :made_by_many, label: "made by many", from: [:case], to: [:clerk], set_by: [:flow]
  relation :made_by_hand, label: "made by hand", from: [:case], to: [:clerk], max_outgoing: 1
  relation :made_by_run, label: "made by run", from: [:case], to: [:run], max_outgoing: 1, set_by: [:flow]
  """

  test "the producer: the relation from an item to the supervisor of the run that made it" do
    comp = model(concept: @made_by, composition: "producer(relation: :made_by)")
    assert comp.supervision()["producer"] == "made_by"

    # Without it, supervision holds none, and the subflows are as they were.
    plain = model(concept: @made_by)
    refute Map.has_key?(plain.supervision(), "producer")
    assert Map.delete(comp.supervision(), "producer") == plain.supervision()
    definitions = &Atlas.definitions(&1.__flows__(), &1.__rela__(:gates))
    assert definitions.(comp) == definitions.(plain)
  end

  test "the producer leads to one of the supervisor's kind, set by Flow alone, given once" do
    problems = &work_problems(decl: @made_by <> &1)
    assert problems.("producer(relation: :made_by)") == []

    for relation <- [:made_by_many, :made_by_hand, :made_by_run, :ghost] do
      assert [{:producer_relation, [to_string(relation)]}] ==
               problems.("producer(relation: #{inspect(relation)})"),
             "#{relation}"
    end

    assert [{:producer, []}] = problems.("producer(relation: nil)")
    assert {:unknown_keys, ["colour"]} in problems.("producer(relation: :made_by, colour: :red)")

    assert [{:given_twice, ["producer"]}] =
             problems.("producer(relation: :made_by)\nproducer(relation: :made_by)")

    assert {:supervision_undeclared, ["producer"]} in work_problems(
             decl: @made_by <> "producer(relation: :made_by)",
             supervision: "",
             span: ""
           )
  end

  test "a state's owner may ask the subject's producer, the configured actor when none" do
    owner = "default: {:clerk, config: :decider, producer: :made_by}"
    comp = model(concept: @made_by, case_owner: owner)
    [flow | _] = comp.__flows__()
    assert flow.owner.default == %{kind: :clerk, config: :decider, producer: :made_by}

    owned = Atlas.definitions(comp.__flows__(), comp.__rela__(:gates))["case"]["owner"]

    assert owned["default"] == %{
             "kind" => "clerk",
             "config" => "decider",
             "producer" => "made_by"
           }

    # The relation leads from the subject to one of the default's kind.
    for {relation, why} <- [
          {:ghost, "producer ghost does not lead from case to one clerk"},
          {:made_by_many, "producer made_by_many does not lead from case to one clerk"},
          {:made_by_run, "producer made_by_run does not lead from case to one clerk"}
        ] do
      model_refused(
        [
          concept: @made_by,
          case_owner: "default: {:clerk, config: :decider, producer: #{inspect(relation)}}"
        ],
        why
      )
    end
  end

  # -- A supervisor's running work (supervised_work) ---------------------------------------

  # A job made for a case or its part, done for a clerk, with how it ended; and a
  # relation that leads elsewhere, to name wrongly.
  @job """
  entity :job, label: "Job", plural: "jobs", id_type: :manual do
    field :outcome, :string
  end
  relation :job_of, label: "job of", from: [:job], to: [:case, :part], max_outgoing: 1
  relation :done_for, label: "done for", from: [:job], to: [:clerk], max_outgoing: 1
  relation :job_run, label: "job run", from: [:job], to: [:run], max_outgoing: 1
  relation :part_job, label: "part job", from: [:part], to: [:job], max_outgoing: 1
  """

  @work [kind: :job, of: :job_of, for: :done_for, ended: :outcome]

  defp work_decl(work), do: "supervised_work(#{inspect(work) |> String.slice(1..-2//1)})"

  # The supervision problems of the desk with `work` (or the raw declaration `decl`), as
  # tags and names.
  defp work_problems(parts) do
    p = "RelaDSL.SupervisionTest.W#{System.unique_integer([:positive])}"
    concept = @job <> Keyword.get(parts, :decl, "")

    [{mod, _}] =
      p
      |> desk(Keyword.put(Keyword.delete(parts, :decl), :concept, concept))
      |> Code.compile_string("work.exs")

    items = mod.__rela__(:concept).items
    {schema, []} = Composition.resolve([%{path: "m.yaml", doc: Build.schema_doc(items)}])

    keys(
      for {_f, _l, problem} <- Build.supervision_problems(items, mod.__flows__(), schema),
          do: {nil, problem}
    ) ++
      keys(for {_f, _l, problem} <- Build.shape_problems(items), do: {nil, problem})
  end

  defp tags(problems), do: Enum.map(problems, &elem(&1, 0))

  test "the work: its kind, what it is part of, whom it is done for and how it ended" do
    comp = model(concept: @job, composition: @entries <> work_decl(@work))

    assert comp.supervision()["work"] ==
             %{"kind" => "job", "of" => "job_of", "for" => "done_for", "ended" => "outcome"}

    assert comp.start_page().supervised_by_you.work ==
             %{kind: "job", of: "job_of", for: "done_for", ended: "outcome"}

    # Without it, supervision holds no work and the start page none either.
    plain = model(concept: @job, composition: @entries)
    refute Map.has_key?(plain.supervision(), "work")
    assert plain.start_page().supervised_by_you.work == nil
  end

  test "the work's names resolve on the schema" do
    assert work_problems(decl: work_decl(@work)) == []

    # No such kind: that is the one reason, the names read on it are not blamed.
    assert tags(work_problems(decl: work_decl(Keyword.put(@work, :kind, :ghost)))) ==
             [:supervision_work_kind]

    for {key, value, tag} <- [
          {:of, :ghost, :supervision_work_of},
          {:of, :part_job, :supervision_work_of},
          {:of, :job_run, :supervision_work_of},
          {:for, :ghost, :supervision_work_for},
          {:for, :job_of, :supervision_work_for},
          # Right target, wrong source: these lead from another kind than the work's.
          {:for, :watched_by, :supervision_work_for},
          {:of, :part_of, :supervision_work_of},
          {:ended, :ghost, :supervision_work_ended}
        ] do
      problems = work_problems(decl: work_decl(Keyword.put(@work, key, value)))
      assert tags(problems) == [tag], "#{key}: #{value}"
    end
  end

  test "the work is given once, whole, and only with supervision" do
    assert [{:supervision_work, []}] =
             work_problems(decl: work_decl(Keyword.delete(@work, :ended)))

    assert {:unknown_keys, ["colour"]} in work_problems(decl: work_decl(@work ++ [colour: :red]))

    assert [{:given_twice, ["supervised_work"]}] =
             work_problems(decl: work_decl(@work) <> "\n" <> work_decl(@work))

    assert {:supervision_undeclared, ["supervised_work"]} in work_problems(
             decl: work_decl(@work),
             supervision: "",
             span: ""
           )
  end

  test "the work sits beside the subflows: it changes no subflow's definition" do
    with_work = model(concept: @job, composition: @entries <> work_decl(@work))
    without = model(concept: @job, composition: @entries)
    definitions = &Atlas.definitions(&1.__flows__(), &1.__rela__(:gates))

    assert definitions.(with_work) == definitions.(without)

    assert Map.delete(with_work.supervision(), "work") == without.supervision()
  end
end
