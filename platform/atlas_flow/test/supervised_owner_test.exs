defmodule AtlasFlow.SupervisedOwnerTest do
  # A state owned by the configured `decider` inside a supervised span goes to the run's
  # human supervisor (its `supervised_by`); with no supervisor, outside every span of its
  # own subflow, or a supervisor of another kind, it goes to the configured decider. Other
  # owners never move to the supervisor, and the supervisor costs no read of its own: it
  # is the link the run's fact holds, as the run Flow read carries it. The span model is
  # this file's own: a neutral one on the depot.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Engine, FakeFacts}
  alias AtlasFlow.Runs.Run

  defmodule Written do
    @moduledoc "A sort whose checks are the decider's and whose packing is a fixed clerk's."
    use RelaDSL.Schema

    subflow :sort, label: "Sort", subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by, default: {:clerk, config: :decider})
      start(:create)
      initial(:check)

      state :check, label: "Check it" do
        branch(to: :recheck, when: "entity.result == 'again'")
        branch(to: :pack, when: "entity.result == 'pack'")
        present(expected: "Check it")
      end

      state :recheck, label: "Check it again" do
        branch(to: :done, when: "entity.result == 'ok'")
        present(expected: "Check it again")
      end

      state :pack, label: "Pack it" do
        owner(relation: :owned_by, default: {:clerk, :ada})
        branch(to: :done, when: "entity.result == 'ok'")
        present(expected: "Pack it")
      end

      final(:done, label: "Done")
    end
  end

  defmodule Sort do
    @moduledoc false
    use AtlasFlow.Sorts, from: AtlasFlow.SupervisedOwnerTest.Written
  end

  defmodule Span do
    @moduledoc "The span model's parts: its selection, and a span holding `check` and `pack` (`recheck` lies outside it)."

    def selection,
      do: %{
        "sort" => %{
          "subject" => "box",
          "projection" => %{"field" => "todo", "owner_relation" => "owned_by"},
          "admission" => %{},
          "imports" => [],
          "migrations" => []
        }
      }

    def supervision(subflow \\ "sort"),
      do: %{
        "version" => 1,
        "relation" => "tended_by",
        "spans" => %{
          subflow => [
            %{"name" => "tend", "label" => "Tend", "states" => ["check", "pack"], "with" => []}
          ]
        }
      }

    # The run's supervisor relation, to `kind`.
    def relations(kind),
      do:
        Map.put(AtlasFlow.Depot.relations(), "tended_by", %{
          "from" => ["cursor"],
          "to" => [kind],
          "max_outgoing" => 1
        })
  end

  defmodule Spanned do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.SupervisedOwnerTest.Sort],
      actors: [decider: "clerk"],
      selection: AtlasFlow.SupervisedOwnerTest.Span.selection(),
      relations: AtlasFlow.SupervisedOwnerTest.Span.relations("clerk"),
      supervision: AtlasFlow.SupervisedOwnerTest.Span.supervision()
  end

  # The same span, but its supervisor is of another kind than the decider.
  defmodule OtherKind do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.SupervisedOwnerTest.Sort],
      actors: [decider: "clerk"],
      selection: AtlasFlow.SupervisedOwnerTest.Span.selection(),
      relations: AtlasFlow.SupervisedOwnerTest.Span.relations("crate"),
      supervision: AtlasFlow.SupervisedOwnerTest.Span.supervision()
  end

  # The same span, but declared for another subflow than the run's own.
  defmodule Elsewhere do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.SupervisedOwnerTest.Sort],
      actors: [decider: "clerk"],
      selection: AtlasFlow.SupervisedOwnerTest.Span.selection(),
      relations: AtlasFlow.SupervisedOwnerTest.Span.relations("clerk"),
      supervision: AtlasFlow.SupervisedOwnerTest.Span.supervision("elsewhere")
  end

  # The same subflow, with no supervision at all.
  defmodule Unsupervised do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.SupervisedOwnerTest.Sort],
      actors: [decider: "clerk"],
      selection: AtlasFlow.SupervisedOwnerTest.Span.selection(),
      relations: AtlasFlow.SupervisedOwnerTest.Span.relations("clerk")
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    for key <- ["ada", "dee", "sam"], do: FakeFacts.put("clerk", %{"key" => key})
    FakeFacts.put("crate", %{"key" => "sam"})
    box = "B-#{System.unique_integer([:positive])}"
    FakeFacts.put("box", %{"key" => box, "values" => %{}})
    %{box: box}
  end

  defp start(model) do
    {:ok, engine} =
      start_supervised({Engine, every: 3_600_000, model: model, actors: %{"decider" => "dee"}})

    engine
  end

  defp owner(box), do: FakeFacts.get("box", box)["links"]["owned_by"]
  defp state(box), do: FakeFacts.get("box", box)["values"]["todo"]

  # The run's writer sets (or clears) its supervisor on the run's fact: a link of the
  # supervision relation.
  defp supervise(box, supervisor) do
    key = Run.key("sort", "box", box, 1)
    run = FakeFacts.get("cursor", key)
    assert run != nil
    links = Map.put(run["links"] || %{}, "tended_by", List.wrap(supervisor))
    FakeFacts.put("cursor", Map.put(run, "links", links))
  end

  defp result(box, value) do
    fact = FakeFacts.get("box", box)
    FakeFacts.put("box", put_in(fact, ["values", "result"], value))
  end

  test "inside the span, a supervised run's decider state goes to the supervisor", %{box: box} do
    engine = start(Spanned)
    Engine.round(engine)
    assert owner(box) == ["dee"]

    supervise(box, "sam")
    Engine.round(engine)
    assert owner(box) == ["sam"]
    assert state(box) == "Check it"
  end

  test "a cleared supervisor gives the state back to the decider", %{box: box} do
    engine = start(Spanned)
    Engine.round(engine)
    supervise(box, "sam")
    Engine.round(engine)
    assert owner(box) == ["sam"]

    supervise(box, nil)
    Engine.round(engine)
    assert owner(box) == ["dee"]
  end

  test "a decider state outside the span goes to the decider, supervised or not", %{box: box} do
    engine = start(Spanned)
    Engine.round(engine)
    supervise(box, "sam")
    Engine.round(engine)
    assert owner(box) == ["sam"]

    result(box, "again")
    Engine.round(engine)
    assert state(box) == "Check it again"
    assert owner(box) == ["dee"]
  end

  test "inside the span, an owner that is not the decider stays its own", %{box: box} do
    engine = start(Spanned)
    Engine.round(engine)
    supervise(box, "sam")
    result(box, "pack")
    Engine.round(engine)
    assert state(box) == "Pack it"
    assert owner(box) == ["ada"]
  end

  test "a supervisor of another kind than the decider is not the owner", %{box: box} do
    engine = start(OtherKind)
    Engine.round(engine)
    supervise(box, "sam")
    Engine.round(engine)
    assert owner(box) == ["dee"]
  end

  test "a span of another subflow does not move the run's decider state", %{box: box} do
    engine = start(Elsewhere)
    Engine.round(engine)
    supervise(box, "sam")
    Engine.round(engine)
    assert state(box) == "Check it"
    assert owner(box) == ["dee"]
  end

  # Flow's reads in one round of an engine on `model`, after it has settled on the facts.
  defp reads_in_a_round(model) do
    engine = start(model)
    Engine.round(engine)
    Engine.round(engine)
    {before, _plain} = FakeFacts.reads()
    Engine.round(engine)
    {after_round, _plain} = FakeFacts.reads()
    stop_supervised!(Engine)
    after_round - before
  end

  test "a supervised span's decider state reads nothing more for its supervisor", %{box: box} do
    engine = start(Spanned)
    Engine.round(engine)
    supervise(box, "sam")
    Engine.round(engine)
    assert owner(box) == ["sam"]
    stop_supervised!(Engine)

    in_span = reads_in_a_round(Unsupervised)
    assert reads_in_a_round(Spanned) == in_span
    assert reads_in_a_round(Elsewhere) == in_span

    result(box, "pack")
    fixed_owner = reads_in_a_round(Unsupervised)
    assert state(box) == "Pack it"
    assert reads_in_a_round(Spanned) == fixed_owner
  end

  describe "AtlasFlow.Model.owner/3" do
    @decider %{"kind" => "clerk", "config" => "decider"}
    @actors %{"decider" => %{"key" => "dee"}}
    @spans [%{"states" => ["check"]}]
    @sam %{"kind" => "clerk", "key" => "sam"}

    test "the decider is the supervisor only in a span, with a supervisor of its kind" do
      run = %{"state" => "check", "spans" => @spans, "supervised_by" => @sam}
      assert AtlasFlow.Model.owner(@decider, @actors, run) == @sam

      for other <- [
            %{run | "supervised_by" => nil},
            %{run | "state" => "recheck"},
            %{run | "spans" => []},
            %{run | "supervised_by" => %{@sam | "kind" => "crate"}},
            %{run | "supervised_by" => %{@sam | "key" => ""}},
            nil
          ] do
        assert AtlasFlow.Model.owner(@decider, @actors, other) == %{
                 "kind" => "clerk",
                 "key" => "dee"
               }
      end
    end

    test "another configured role, or a fixed owner, never goes to the supervisor" do
      run = %{"state" => "check", "spans" => @spans, "supervised_by" => @sam}
      checker = %{"kind" => "clerk", "config" => "checker"}
      actors = Map.put(@actors, "checker", %{"key" => "cho"})
      assert AtlasFlow.Model.owner(checker, actors, run) == %{"kind" => "clerk", "key" => "cho"}
      ada = %{"kind" => "clerk", "key" => "ada"}
      assert AtlasFlow.Model.owner(ada, actors, run) == ada
    end
  end
end
