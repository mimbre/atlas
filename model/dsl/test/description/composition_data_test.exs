defmodule RelaDSL.Description.CompositionDataTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Atlas
  alias RelaDSL.Description.Subflows
  alias RelaDSL.Schema.Composition

  # A neutral model: cups stand on a tray. A cup's run reports how it ended to its tray
  # (a link, current by revision), and the tray counts its cups (a count). It is compiled
  # from text with one change at a time; each bad reference fails the compile.
  @link "link :cup, to: {:tray, :on_tray}, field: :outcome, states: [full: :full, spilt: :spilt], stale: :drop, current: {:revision, :revision}"
  @count "count :cup, to: {:tray, :on_tray}, all: :cups, open: :open_cups"

  @tally "tally to: {:tray, :about_tray}, all: :notes"

  defp model(link, count, tally) do
    p = "RelaDSL.CompositionDataTest.M#{System.unique_integer([:positive])}"

    """
    defmodule #{p}.Tray do
      use RelaDSL
      entity :tray, label: "Tray", plural: "trays", id_type: :manual do
        field :revision, :string
        field :outcome, :string
        field :cups, :integer
        field :open_cups, :integer
        field :notes, :integer
      end
      subflow :tray, subject: :tray do
        owner default: {:tray, :desk}
        start :create
        initial :waiting
        state :waiting do
          await :outcome, full: :done, spilt: :done
          branch to: :done, by: :atlas, when: "entity.open_cups == 0 and entity.cups > 0"
          branch to: :done, by: :atlas, when: "entity.notes > 2"
        end
        final :done
      end
    end
    defmodule #{p}.Cup do
      use RelaDSL
      entity :cup, label: "Cup", plural: "cups", id_type: :manual do
        field :revision, :string
        field :level, :string
      end
      relation :on_tray, label: "on tray", from: [:cup], to: [:tray], max_outgoing: 1
      entity :note, label: "Note", plural: "notes", id_type: :manual do
        field :text, :string
      end
      relation :about_tray, label: "about tray", from: [:cup, :note], to: [:tray]
      subflow :cup, subject: :cup do
        owner default: {:tray, :desk}
        start :create
        initial :filling
        state :filling do
          wait_for [:filler], on: :level, reset: false, full: :full, spilt: :spilt
        end
        final :full
        final :spilt
      end
    end
    defmodule #{p}.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Tray, #{p}.Cup]
    end
    defmodule #{p}.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"
      modules [#{p}.Mod]
      acl comment: "Roles."
      role "filler", read: ["*"], update: [:cup]
      defcomposition :c do
        subflows([#{p}.Tray, #{p}.Cup])
        #{link}
        #{count}
        #{tally}
      end
    end
    """
  end

  defp compile!(link \\ @link, count \\ @count, tally \\ @tally) do
    modules = Code.compile_string(model(link, count, tally), "model.exs")
    {comp, _} = Enum.find(modules, fn {m, _} -> String.ends_with?(inspect(m), ".Comp") end)
    comp
  end

  defp refused(link, count, message) do
    error = assert_raise CompileError, fn -> compile!(link, count) end
    assert Exception.message(error) =~ message
  end

  test "the model compiles its links and counts as versioned data" do
    comp = compile!()

    assert comp.composition() == %{
             "version" => 1,
             "links" => [
               %{
                 "child" => "cup",
                 "child_subject" => "cup",
                 "parent_subject" => "tray",
                 "relation" => "on_tray",
                 "field" => "outcome",
                 "states" => %{"full" => "full", "spilt" => "spilt"},
                 "stale" => "drop",
                 "current" => %{"child" => "revision", "parent" => "revision"}
               }
             ],
             "counts" => [
               %{
                 "child" => "cup",
                 "child_subject" => "cup",
                 "parent_subject" => "tray",
                 "relation" => "on_tray",
                 "all" => "cups",
                 "open" => "open_cups"
               }
             ],
             "tallies" => [
               %{
                 "parent_subject" => "tray",
                 "relation" => "about_tray",
                 "all" => "notes",
                 "readers" => ["tray"]
               }
             ]
           }

    # flows.json holds the same, beside the subflows: no subflow's digest changes.
    flows = comp.__flows__()
    gates = comp.__rela__(:gates)
    with = JSON.decode!(Atlas.flows_json(flows, gates, "h", comp.__composition__()))
    without = JSON.decode!(Atlas.flows_json(flows, gates, "h"))
    assert with["composition"] == Map.update!(comp.composition(), "links", &drop_nil/1)
    refute Map.has_key?(without, "composition")
    assert with["flows"] == without["flows"]

    for module <- comp.subflows(:prod),
        do: assert(module.digest() == RelaDSL.DefinitionDigest.of(with["flows"][module.name()]))
  end

  test "a tally counts what relates to a parent its subflow reads, by a relation that ends there" do
    comp = compile!()
    flows = comp.__flows__()
    t = %{subject: :tray, relation: :about_tray, all: :notes}

    problems = fn tally ->
      for {_line, p} <- Composition.problems(%{comp.__composition__() | tallies: [tally]}, flows),
          do: p
    end

    assert problems.(t) == []

    assert [{:many_writers, :tray, :cups, writers}] = problems.(%{t | all: :cups})
    assert Enum.sort(writers) == [{:count, :cup}, {:tally, :about_tray}]

    assert {:unread, {:tally, :about_tray}, :revision, :tray} in problems.(%{t | all: :revision})

    assert {:unknown_options, {:tally, :about_tray}, [:open]} in problems.(
             Map.put(t, :unknown, [:open])
           )

    assert {:missing_option, {:tally, :about_tray}, :all} in problems.(%{t | all: nil})

    # Against the description: its relation ends at the parent, and the field is the parent's.
    schema = comp.rela_schema()
    assert Subflows.tally_problems(t, schema) == []

    assert Subflows.tally_problems(%{t | relation: :on_shelf}, schema) == [
             {:not_to_parent, :on_shelf, "tray"}
           ]

    assert Subflows.tally_problems(%{t | all: :mugs}, schema) == [
             {:no_field, :about_tray, "tray", :mugs}
           ]

    # The compile refuses each, at the tally's line.
    error =
      assert_raise CompileError, fn ->
        compile!(@link, @count, "tally to: {:tray, :on_tray}, all: :notes, open: :x")
      end

    assert error.file == "model.exs"
  end

  test "a link without current: is written as keep, its current as nil" do
    link = String.replace(@link, ", stale: :drop, current: {:revision, :revision}", "")
    [l] = compile!(link, @count).composition()["links"]
    assert {l["stale"], l["current"]} == {"keep", nil}
  end

  describe "a bad reference fails the compile" do
    test "a link field the parent does not have" do
      refused(
        String.replace(@link, "field: :outcome", "field: :result"),
        @count,
        ~r/writes result full to tray|tray.result/
      )
    end

    test "a count field the parent does not have" do
      refused(@link, String.replace(@count, "all: :cups", "all: :mugs"), ~r/mugs/)
    end

    test "a current field the child or the parent does not have" do
      refused(
        String.replace(@link, "{:revision, :revision}", "{:round, :revision}"),
        @count,
        "cup.round, which cup does not have"
      )

      refused(
        String.replace(@link, "{:revision, :revision}", "{:revision, :round}"),
        @count,
        "tray.round, which tray does not have"
      )
    end

    test "an option a link or count does not know, or one of the wrong shape" do
      refused(@link <> ", latest: true", @count, "link cup: knows no latest")
      refused(@link, @count <> ", closed: :done", "count cup: knows no closed")
      refused(String.replace(@link, "stale: :drop", "stale: :newest"), @count, "stale: is :drop")

      refused(
        String.replace(@link, "{:revision, :revision}", ":revision"),
        @count,
        "current: is {child field, parent field}"
      )
    end
  end

  defp drop_nil(links), do: Enum.map(links, &Map.reject(&1, fn {_, v} -> v == nil end))
end
