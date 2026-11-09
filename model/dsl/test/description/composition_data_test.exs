defmodule RelaDSL.Description.CompositionDataTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Atlas

  # A neutral model: cups stand on a tray. A cup's run reports how it ended to its tray
  # (a link, current by revision), and the tray counts its cups (a count). It is compiled
  # from text with one change at a time; each bad reference fails the compile.
  @link "link :cup, to: {:tray, :on_tray}, field: :outcome, states: [full: :full, spilt: :spilt], stale: :drop, current: {:revision, :revision}"
  @count "count :cup, to: {:tray, :on_tray}, all: :cups, open: :open_cups"

  defp model(link, count) do
    p = "RelaDSL.CompositionDataTest.M#{System.unique_integer([:positive])}"

    """
    defmodule #{p}.Tray do
      use RelaDSL
      entity :tray, label: "Tray", plural: "trays", id_type: :manual do
        field :revision, :string
        field :outcome, :string
        field :cups, :integer
        field :open_cups, :integer
      end
      subflow :tray, subject: :tray do
        owner default: {:tray, :desk}
        start :create
        initial :waiting
        state :waiting do
          await :outcome, full: :done, spilt: :done
          branch to: :done, by: :atlas, when: "entity.open_cups == 0 and entity.cups > 0"
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
      end
    end
    """
  end

  defp compile!(link \\ @link, count \\ @count) do
    modules = Code.compile_string(model(link, count), "model.exs")
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
