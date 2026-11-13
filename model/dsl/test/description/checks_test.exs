defmodule RelaDSL.Description.ChecksTest do
  use ExUnit.Case, async: true

  # A small model, compiled from text with one change at a time: the composition refuses
  # each mistake at compile time, at the file and line that wrote it.
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

  defp refused(parts, message) do
    error = assert_raise CompileError, fn -> compiles(parts) end
    assert Exception.message(error) =~ message
    error
  end

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
  @acl ~s(acl comment: "Roles."\n  role "t-flow", read: ["*"], update: [:thing]\n  role "judge", read: ["*"], update: [:thing]\n  assign "system:t", "t-flow")

  test "the small model compiles, with a subflow and its roles" do
    assert [_ | _] = compiles([])
    assert [_ | _] = compiles(concept: @subflow, composition: @acl, flows: true)
  end

  test "a name a rule gives must resolve to a field, relation or value" do
    refused([entity: "create ask: [:colour]"], ~s(thing: unknown field "colour"))

    refused(
      [entity: "requires when: [state: [:gone]], fields: [:title], error: \"x\""],
      "unknown value"
    )

    # A relation's review reads the kinds it leads to.
    refused(
      [relation: ", review: [field: :state, value: :gone, label: \"x\"]"],
      ~s(keeper: unknown field "state")
    )

    refused(
      [entity: "late after: :due, while: :expected, label: \"late\""],
      ~s(unknown field "due")
    )
  end

  test "each leaf has one author, and each rule is given once" do
    error =
      refused(
        [entity: "primary :title", composition: "extend_entity :thing, primary: :title"],
        "entities.thing.primary is given twice"
      )

    assert error.file == "model.exs"
    refused([entity: "top false\n top true"], "top is given more than once")
  end

  test "a key no construct holds is refused where it is written" do
    refused([composition: "extend_entity :thing, colour: :red"], "knows no colour")
    refused([entity: "field :size, :integer, wide: true"], "knows no wide")
    refused([schema: ", worlds: []"], "worlds is a key of Rela's schema that Atlas does not use")

    refused(
      [schema: ", default_world: :x"],
      "default_world is a key of Rela's schema that Atlas does not use"
    )
  end

  test "a kind or relation is defined once, and a relation leads between kinds of the composition" do
    refused(
      [concept: "relation :kept_by, label: \"again\", from: [:thing], to: [:keeper]"],
      "relations.kept_by is defined twice"
    )

    refused(
      [concept: "relation :lost, label: \"lost\", from: [:thing], to: [:ghost]"],
      "ghost, which is not a kind"
    )
  end

  test "a legacy flow is sound: a done state, an owner and a way out, every state reaches done" do
    flow = fn states ->
      "legacy_flow :f, kinds: [:thing], on: nil, field: :expected, states: #{states}"
    end

    refused(
      [composition: flow.("[[name: :a, owner: [kind: :keeper, key: \"k\"], next: [:a]]]")],
      "has no done state"
    )

    refused(
      [
        composition:
          flow.(
            "[[name: :d, when: [completed: true], done: true], [name: :a, owner: [kind: :keeper, key: \"k\"], next: [:a]]]"
          )
      ],
      "a never reaches done"
    )

    refused(
      [
        composition:
          flow.("[[name: :d, when: [completed: true], done: true], [name: :a, next: [:d]]]")
      ],
      "its owner names no kind"
    )
  end

  test "every name a subflow gives resolves in the composition" do
    refused(
      [
        concept: String.replace(@subflow, "on: :state", "on: :colour"),
        composition: @acl,
        flows: true
      ],
      "names thing.colour"
    )

    refused(
      [concept: String.replace(@subflow, "[:judge]", "[:jury]"), composition: @acl, flows: true],
      "names the role jury"
    )

    refused(
      [concept: String.replace(@subflow, "system:t", "system:u"), composition: @acl, flows: true],
      "run_as system:u is not assigned"
    )

    refused([concept: @subflow, flows: true, composition: ""], "role judge")
  end

  test "a select names fields, roles and states the subflow has" do
    select = fn opts -> @subflow <> "\nselect :thing, choices: [:state]#{opts}" end

    refused(
      [concept: select.(", roles: [jury: :kept_by]"), composition: @acl, flows: true],
      "waits for no jury"
    )

    refused(
      [
        concept: select.(", imports: [[when: [state: [:done]], state: :gone]]"),
        composition: @acl,
        flows: true
      ],
      "imports state gone"
    )

    refused(
      [concept: select.(", legacy: :old"), composition: @acl, flows: true],
      "no legacy flow"
    )

    # A choice no state waits for is refused; a subflow with no choice of people (its
    # branches read what it is given) is selected without one.
    refused(
      [
        concept: @subflow <> "\nselect :thing, choices: [:title]",
        composition: @acl,
        flows: true
      ],
      "waits for people to choose title"
    )

    assert [_ | _] =
             compiles(
               concept: @subflow <> "\nselect :thing, admission: []",
               composition: @acl,
               flows: true
             )

    # nil among a field's values allows no value (the field empty); any other value must
    # be the field's. An import row may also say whether the fact is completed.
    assert [_ | _] =
             compiles(
               concept:
                 @subflow <>
                   "\nselect :thing, admission: [state: [:done, nil]], imports: [[completed: true, state: :closed], [when: [state: [nil]], state: :open]]",
               composition: @acl,
               flows: true
             )

    refused(
      [
        concept: @subflow <> "\nselect :thing, admission: [state: [:gone, nil]]",
        composition: @acl,
        flows: true
      ],
      "has no value among"
    )

    refused(
      [
        concept: @subflow <> "\nselect :thing, imports: [[completed: :yes, state: :closed]]",
        composition: @acl,
        flows: true
      ],
      "completed is true or false"
    )
  end

  test "a select's reopening policy is an explicit restart or a new generation" do
    for policy <- [:explicit, :new_generation] do
      assert [_ | _] =
               compiles(
                 concept: @subflow <> "\nselect :thing, reopen: #{inspect(policy)}",
                 composition: @acl,
                 flows: true
               )
    end

    refused(
      [concept: @subflow <> "\nselect :thing, reopen: :always", composition: @acl, flows: true],
      "reopen: :always is neither :explicit nor :new_generation"
    )
  end

  test "a migration leads to a current digest and maps states it knows" do
    digest = fn -> String.duplicate("a", 64) end

    migrate = fn opts ->
      @subflow <> "\nmigrate :thing, from: #{inspect(digest.())}, reason: \"r\"#{opts}"
    end

    refused(
      [
        concept: migrate.(", to: #{inspect(String.duplicate("b", 64))}, states: :same"),
        composition: @acl,
        flows: true
      ],
      "is no current digest of thing"
    )

    refused(
      [concept: migrate.(", to: \"short\", states: :same"), composition: @acl, flows: true],
      "full SHA-256 digests"
    )
  end
end
