defmodule RelaDSL.Flow.SubflowTest do
  use ExUnit.Case, async: true

  alias RelaDSL.DefinitionDigest
  alias RelaDSL.Flow.Subflow

  defmodule Letter do
    use RelaDSL.Flow.Subflow,
      from: RelaDSL.Example,
      subflow: :letter,
      gates: RelaDSL.Example.Gates
  end

  defp definition,
    do:
      Subflow.definitions(RelaDSL.Example.__flows__(), RelaDSL.Example.Gates.__gates__(), :prod)[
        "letter"
      ]

  test "its digest is that of its data, so a run started under it keeps its identity" do
    assert Letter.digest() == DefinitionDigest.of(definition())
    assert Letter.states() == Enum.sort(Map.keys(definition()["states"]))
    assert {Letter.name(), Letter.subject(), Letter.initial()} == {"letter", "letter", "draft"}
  end

  test "where a run starts: on create, or when its predicate holds" do
    assert Letter.start?(:create, %{})
    assert Letter.start?(:predicate, %{"kind" => "reply"})
    refute Letter.start?(:predicate, %{"kind" => "note"})
    refute Letter.start?(:predicate, %{})
  end

  test "a change no role takes, a result, and a role's input each take their own branches" do
    # sent: the writer's branch on urgent, and the reply it awaits.
    assert Letter.next("sent", %{"urgent" => true}, :result) == {:to, "answered"}
    assert Letter.next("sent", %{"urgent" => true}, nil) == :stay

    # stuck: the editor's choice, and the admin's branch.
    choice = %{roles: ["editor"], changed: %{"choice" => "retry"}}
    assert Letter.next("stuck", %{"choice" => "retry"}, choice) == {:to, "draft"}
    assert Letter.next("stuck", %{"choice" => "retry"}, %{choice | roles: ["admin"]}) == :stay

    # A role's branch moves only on a field the input changed.
    assert Letter.next("stuck", %{"choice" => "retry"}, %{choice | changed: %{"other" => 1}}) ==
             :stay

    assert Letter.next("proofread", %{"gate_result" => "redo"}, :result) == {:to, "draft"}
    assert Letter.next("nowhere", %{}, nil) == :stay
  end

  test "what entering a state writes, its timers, mechanism and owner" do
    assert Letter.enter("post", %{}) == [
             {:set, %{"post_result" => "none"}},
             {:create,
              %{
                "type" => "receipt",
                "properties" => %{"title" => "Receipt"},
                "relate" => "receipt_of"
              }}
           ]

    assert Letter.enter("answered", %{}) == [{:set, %{"archived" => true}}]
    assert [%{"name" => "slow", "period" => "1d", "to" => "stuck"}] = Letter.timers("draft")
    assert {:gate, %{"gate" => "proofread", "version" => 2}} = Letter.mechanism("proofread")
    assert Letter.mechanism("sent") == nil
    assert Letter.final?("dropped") and not Letter.final?("sent")
    assert Letter.waiting_for("stuck") == ["editor"]
    assert Letter.owner("stuck")["default"] == %{"kind" => "team", "key" => "editors"}
    assert Letter.owner("draft") == Letter.owner()
  end

  test "what the owner sees is filled from the subject's values" do
    present = Letter.present("stuck", %{"reason" => "no stamp"})
    assert present["expected"] == "Decide on it: no stamp"
    assert present["why"] == "it could not go out"
    assert [%{"key" => "r"}, %{"key" => "d"}] = present["todo"]["answers"]
    assert Letter.present("stuck", %{})["expected"] == "Decide on it"
    assert Letter.present("proofread", %{}) == nil
  end

  test "a condition outside the grammar does not compile" do
    source = """
    defmodule RelaDSL.Flow.SubflowTest.Bad do
      use RelaDSL.Schema
      subflow :bad, subject: :box do
        owner default: {:clerk, :ada}
        start :create
        initial :waiting
        state :waiting do
          branch to: :done, when: "System.cmd('x') == 1"
        end
        final :done
      end
    end

    defmodule RelaDSL.Flow.SubflowTest.BadRun do
      use RelaDSL.Flow.Subflow, from: RelaDSL.Flow.SubflowTest.Bad, subflow: :bad
    end
    """

    assert_raise CompileError, ~r/no condition a runner evaluates/, fn ->
      Code.compile_string(source)
    end
  end
end
