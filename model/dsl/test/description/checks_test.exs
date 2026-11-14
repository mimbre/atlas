defmodule RelaDSL.Description.ChecksTest do
  use ExUnit.Case, async: true

  alias RelaDSL.{Composition, Problem, RunIdentity}
  alias RelaDSL.Description.{Build, Check, Subflows}

  # A small concept, compiled from text with one change at a time. A concept alone is not
  # checked against a composition, so each test runs the composition's checks on what the
  # concept declares, as plain data, and compares what is wrong (tag) and what it names.
  defp concept(parts) do
    p = "RelaDSL.ChecksTest.M#{System.unique_integer([:positive])}"
    get = &Keyword.get(parts, &1, "")

    source = """
    defmodule #{p}.Thing do
      use RelaDSL
      type :thing_state, values: [:open, :done]
      entity :thing, label: "Thing", plural: "things", id_type: :manual do
        field :title, :string
        field :state, :thing_state
        field :flow_state, :string
        field :expected, :string
        field :handover, :string
        #{get.(:entity)}
      end
      entity :keeper, label: "Keeper", plural: "keepers", id_type: :manual do
        field :name, :string
      end
      relation :kept_by, label: "kept by", from: [:thing], to: [:keeper], max_outgoing: 1#{get.(:relation)}
      #{get.(:concept)}
    end
    """

    {mod, _} =
      source
      |> Code.compile_string("model.exs")
      |> Enum.find(fn {m, _} -> String.ends_with?(inspect(m), ".Thing") end)

    items = mod.__rela__(:concept).items
    {extension, _origins, merged} = Build.merge(Build.fragments(items))
    {schema, defined} = Composition.resolve([%{path: "m.yaml", doc: Build.schema_doc(items)}])
    [] = merged ++ defined

    %{
      items: items,
      schema: schema,
      extension: extension,
      flows: if(function_exported?(mod, :__flows__, 0), do: mod.__flows__(), else: [])
    }
  end

  defp keys(problems) do
    Enum.map(problems, fn
      {_where, %Problem{} = p} -> Problem.key(p)
      {_file, _line, %Problem{} = p} -> Problem.key(p)
    end)
  end

  defp checked(c, extension \\ nil), do: keys(Check.check(c.schema, extension || c.extension))

  defp shape(c), do: keys(Build.shape_problems(c.items))

  @subflow """
  subflow :thing, subject: :thing do
    run_as "system:t"
    owner relation: :kept_by, default: {:keeper, :desk}
    start :create
    initial :open
    state :open do
      wait_for [:judge], on: :state, reset: false, done: :closed
    end
    final :closed
  end
  """
  @acl %{roles: %{"t-flow" => %{}, "judge" => %{}}, assignments: %{"system:t" => "t-flow"}}
  @composition %{file: "c.exs", links: [], counts: [], tallies: []}

  defp subflows(c, acl \\ @acl), do: keys(Subflows.check(c.flows, @composition, c.schema, acl))

  defp selects(c), do: keys(Subflows.selects(selects_of(c), c.flows, c.schema, c.extension))

  defp selects_of(c), do: for(%{kind: :select} = i <- c.items, do: i)

  defp select(opts), do: concept(concept: @subflow <> "\nselect :thing#{opts}")

  test "the small concept passes every check, with a subflow and its roles" do
    c = concept(concept: @subflow <> "\nselect :thing, choices: [:state]")
    assert checked(c) == []
    assert shape(c) == []
    assert subflows(c) == []
    assert selects(c) == []
  end

  test "a name a rule gives must resolve to a field, relation or value" do
    assert checked(concept(entity: "create ask: [:colour]")) ==
             [{:unknown_field, ["thing", "colour"]}]

    assert checked(
             concept(entity: ~s(requires when: [state: [:gone]], fields: [:title], error: "x"))
           ) == [{:unknown_value, ["thing", "state"]}]

    # A relation's review reads the kinds it leads to.
    assert checked(concept(relation: ~s(, review: [field: :state, value: :gone, label: "x"]))) ==
             [{:unknown_field, ["keeper", "state"]}]

    assert checked(concept(entity: ~s(late after: :due, while: :expected, label: "late"))) ==
             [{:unknown_field, ["thing", "due"]}]

    assert checked(concept(entity: ~s(late after: :title, while: :colour, label: "late"))) ==
             [{:unknown_field, ["thing", "colour"]}]

    # The name a list of them has is a text.
    c = concept(entity: ~s(plural_label "Things to keep"))
    assert checked(c) == []
    kinds = RelaDSL.Control.Model.kinds(RelaDSL.Control.Model.merge(c.schema, c.extension))
    assert Enum.find(kinds, &(&1.name == "thing")).plural == "Things to keep"
    assert Enum.find(kinds, &(&1.name == "keeper")).plural == "Keepers"
    assert checked(concept(entity: "plural_label 3")) == [{:plural_label, ["thing"]}]
  end

  test "each leaf has one author, and each rule is given once" do
    c = concept(entity: "primary :title")
    again = %{kind: :extend_entity, value: {:thing, [primary: :title]}, file: "c.exs", line: 9}
    {_, _, twice} = Build.merge(Build.fragments(c.items ++ [again]))

    # Refused where the second author wrote it.
    assert [{"c.exs", 9, p}] = twice
    assert Problem.key(p) == {:leaf_twice, ["entities", "thing", "primary"]}

    assert shape(concept(entity: "top false\n top true")) == [{:given_twice, ["thing", "top"]}]
  end

  test "a key no construct holds is refused where it is written" do
    colour = %{kind: :extend_entity, value: {:thing, [colour: :red]}, file: "c.exs", line: 3}

    assert keys(Build.shape_problems([colour])) == [{:unknown_keys, ["thing", "colour"]}]

    assert shape(concept(entity: "field :size, :integer, wide: true")) ==
             [{:unknown_keys, ["thing", "size", "wide"]}]

    item = %{file: "c.exs", line: 2}

    for key <- [:worlds, :default_world] do
      assert keys(Composition.schema_problems([{:version, "1.0"}, {key, []}], item)) ==
               [{:unused_key, [to_string(key)]}]
    end
  end

  test "a kind or relation is defined once, and a relation leads between kinds of the composition" do
    doc = fn label ->
      {:ordered, [{"relations", {:ordered, [{"kept_by", {:ordered, [{"label", label}]}}]}}]}
    end

    {_, twice} =
      Composition.resolve([
        %{path: "a.yaml", doc: doc.("kept")},
        %{path: "b.yaml", doc: doc.("again")}
      ])

    assert [{"b.yaml", 1, p}] = twice
    assert Problem.key(p) == {:defined_twice, ["relations", "kept_by"]}

    c = concept(concept: ~s(relation :lost, label: "lost", from: [:thing], to: [:ghost]))
    assert [{"model.exs", _line, p}] = Composition.ends(c.schema, c.items, "c.exs")
    assert Problem.key(p) == {:not_a_kind, ["lost", "ghost"]}
  end

  defp model(parts) do
    p = "RelaDSL.ChecksTest.M#{System.unique_integer([:positive])}"
    get = &Keyword.get(parts, &1, "")

    """
    defmodule #{p}.Thing do
      use RelaDSL
      type :thing_state, values: [:open, :done]
      entity :thing, label: "Thing", plural: "things", id_type: :manual do
        field :title, :string
        field :state, :thing_state
        field :flow_state, :string
        field :expected, :string
        field :handover, :string
        #{get.(:entity)}
      end
      entity :keeper, label: "Keeper", plural: "keepers", id_type: :manual do
        field :name, :string
      end
      relation :kept_by, label: "kept by", from: [:thing], to: [:keeper], max_outgoing: 1#{get.(:relation)}
      #{get.(:concept)}
    end
    defmodule #{p}.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Thing]
    end
    defmodule #{p}.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"#{get.(:schema)}
      modules [#{p}.Mod]
      #{get.(:composition)}
      defcomposition :c do
        subflows([#{if parts[:flows], do: "#{p}.Thing"}])
      end
    end
    """
  end

  defp compiles(parts), do: Code.compile_string(model(parts), "model.exs")

  test "a frozen rule's tallied fields are fields only Flow writes" do
    schema = %{
      "types" => %{"thing_state" => %{"values" => ["open", "done"]}},
      "entities" => %{
        "thing" => %{
          "properties" => %{
            "title" => %{"type" => "string"},
            "state" => %{"type" => "thing_state"},
            "cited" => %{"type" => "integer"}
          }
        }
      }
    }

    problems = fn tallied, writers ->
      extension = %{
        "entities" => %{
          "thing" => %{
            "properties" => %{"cited" => %{"set_by" => writers}},
            "frozen" => %{
              "when" => %{"state" => ["done"]},
              "only" => %{"state" => ["done"]},
              "tallied" => [tallied],
              "error" => "x"
            }
          }
        }
      }

      for {path, _} <- RelaDSL.Description.Check.check(schema, extension), do: path
    end

    at = ["entities", "thing", "frozen"]
    assert at in problems.("title", ["flow"])
    refute at in problems.("cited", ["flow"])

    for writers <- [["flow", "human"], ["human", "flow"], ["flow", "flow"], ["human"], [], nil] do
      assert at in problems.("cited", writers)
    end
  end

  test "a frozen tally with additional writers is refused when its DSL composition compiles" do
    entity = fn writers ->
      """
      field :cited, :integer, set_by: #{inspect(writers)}
      frozen when: [state: [:done]], only: [state: [:done]], tallied: [:cited], error: "frozen"
      """
    end

    assert [_ | _] =
             compiles(
               entity: entity.([:flow]),
               composition: "flow_runtime runs: :keeper, writer: [by: :flow, sender: :flow]"
             )

    for writers <- [[:flow, :human], [:human, :flow], [:flow, :flow]] do
      error = assert_raise CompileError, fn -> compiles(entity: entity.(writers)) end
      assert error.file == "model.exs"
    end
  end

  test "frozen tallies require their field guard in the final assembled runtime" do
    entity = """
    field :cited, :integer, set_by: [:flow]
    frozen when: [state: [:done]], only: [state: [:done]], tallied: [:cited], error: "frozen"
    """

    for config <- [
          "",
          "flow_runtime runs: :keeper",
          "flow_runtime runs: :keeper, writer: [by: :other, sender: :other]",
          "flow_runtime runs: :keeper, writer: [by: :flow]"
        ] do
      assert_raise CompileError, fn -> compiles(entity: entity, composition: config) end
    end

    # The concept and module compile before the composition supplies their runtime.
    compiled =
      compiles(
        entity: entity,
        composition: "flow_runtime runs: :keeper, writer: [by: :flow, sender: :flow]"
      )

    {model, _} = List.last(compiled)
    current = %{"values" => %{"state" => "done", "cited" => 2, "title" => "Kept"}, "links" => %{}}

    check = fn actor, values ->
      model.check("thing", %{"op" => "change", "key" => "T-1", "values" => values}, actor, %{
        "current" => fn -> current end
      })
    end

    for count <- [0, 3] do
      assert :ok = check.(%{"by" => "flow", "sender" => "flow"}, %{"cited" => count})

      for actor <- [
            %{"by" => "human", "sender" => "control/session"},
            %{"by" => "flow", "sender" => "control/session"}
          ] do
        assert {:refuse, [_ | _]} = check.(actor, %{"cited" => count})
      end

      assert {:refuse, [_ | _]} =
               check.(%{"by" => "flow", "sender" => "flow"}, %{
                 "cited" => count,
                 "title" => "Changed"
               })
    end
  end

  test "every name a subflow gives resolves in the composition" do
    assert subflows(concept(concept: String.replace(@subflow, "on: :state", "on: :colour"))) ==
             [{:unknown_field, ["thing", "colour"]}]

    assert subflows(concept(concept: String.replace(@subflow, "[:judge]", "[:jury]"))) ==
             [{:unknown_role, ["jury"]}]

    assert subflows(concept(concept: String.replace(@subflow, "system:t", "system:u"))) ==
             [{:run_as, ["system:u"]}]

    # Without an acl no role is known.
    assert {:unknown_role, ["judge"]} in subflows(concept(concept: @subflow), nil)
  end

  test "a select names fields, roles and states the subflow has" do
    assert selects(select(", choices: [:state], roles: [jury: :kept_by]")) ==
             [{:role_unawaited, ["thing", "jury"]}]

    assert selects(
             select(", choices: [:state], imports: [[when: [state: [:done]], state: :gone]]")
           ) ==
             [{:import_state, ["thing", "gone"]}]

    # A choice no state waits for is refused; a subflow with no choice of people (its
    # branches read what it is given) is selected without one.
    assert selects(select(", choices: [:title]")) == [{:choice_unawaited, ["thing", "title"]}]
    assert selects(select(", admission: []")) == []

    # nil among a field's values allows no value (the field empty); any other value must
    # be the field's. An import row may also say whether the fact is completed.
    assert selects(
             select(
               ", admission: [state: [:done, nil]], imports: [[completed: true, state: :closed], [when: [state: [nil]], state: :open]]"
             )
           ) == []

    assert selects(select(", admission: [state: [:gone, nil]]")) ==
             [{:unknown_value, ["thing", "state"]}]

    assert selects(select(", imports: [[completed: :yes, state: :closed]]")) ==
             [{:import_completed, [":yes"]}]
  end

  test "a select's role may come through a fact made with the subject, and from nowhere else" do
    # Each thing is made with its slip (a component); whoever holds the slip is its judge.
    slip = """
    entity :slip, label: "Slip", plural: "slips", id_type: :manual do
      field :of, :string
    end
    relation :slip, label: "slip", from: [:thing], to: [:slip], max_outgoing: 1
    relation :held_by, label: "held by", from: [:slip], to: [:keeper], max_outgoing: 1
    relation :seen_by, label: "seen by", from: [:keeper], to: [:keeper]
    """

    part = ~s(\nextend_relation :slip, component: [key: "SL-{key}", values: [of: "{key}"]])

    with_role = fn role, part ->
      concept(
        concept:
          @subflow <>
            slip <> part <> "\nselect :thing, choices: [:state], roles: [judge: #{role}]"
      )
    end

    assert selects(with_role.(":held_by", part)) == []

    assert selects(with_role.(":seen_by", part)) ==
             [{:role_not_from_subject, ["judge", "seen_by"]}]

    # Without the component, the slip is a fact of its own: its holder is no role on a thing.
    assert selects(with_role.(":held_by", "")) ==
             [{:role_not_from_subject, ["judge", "held_by"]}]
  end

  test "a select's reopening policy is an explicit restart or a new generation" do
    for policy <- [:explicit, :new_generation] do
      assert selects(select(", reopen: #{inspect(policy)}")) == []
    end

    assert selects(select(", reopen: :always")) == [{:reopen_policy, [":always"]}]
  end

  test "a migration leads to a current digest and maps states it knows" do
    a = String.duplicate("a", 64)

    migrated = fn to ->
      c =
        concept(
          concept:
            @subflow <>
              "\nmigrate :thing, from: #{inspect(a)}, to: #{inspect(to)}, reason: \"r\", states: :same"
        )

      current = RunIdentity.current(c.flows, [], [:prod])

      migrations =
        for %{kind: :migrate, value: {s, o}} = i <- c.items,
            do: %{subflow: s, opts: o, file: i.file, line: i.line}

      keys(RunIdentity.problems(current, migrations))
    end

    assert migrated.(String.duplicate("b", 64)) == [{:not_current, ["thing"]}]
    assert {:digests, ["thing"]} in migrated.("short")
  end

  test "a composition refuses at the file and line that wrote the mistake" do
    source = """
    defmodule RelaDSL.ChecksTest.Refused.Thing do
      use RelaDSL
      entity :thing, label: "Thing", plural: "things", id_type: :manual do
        field :title, :string
        create ask: [:colour]
      end
    end
    defmodule RelaDSL.ChecksTest.Refused.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [RelaDSL.ChecksTest.Refused.Thing]
    end
    defmodule RelaDSL.ChecksTest.Refused.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"
      modules [RelaDSL.ChecksTest.Refused.Mod]
      defcomposition :c do
        subflows([])
      end
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(source, "model.exs") end
    # The entity that wrote the rule.
    assert {error.file, error.line} == {"model.exs", 3}
  end
end
