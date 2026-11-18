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

  # -- `with:` runs (F2-O) ---------------------------------------------------------------
  #
  # A span names other subflows in its `with:`: their runs, on facts under the spanned
  # run's subject, take its supervisor too. Here the sort's span `tend` names `stack` (on
  # the box's crates, `in_box`) and not `heap` (on its tins, `on_box`). Both start in a
  # state the decider owns and move to one with a fixed owner.
  defmodule Under do
    @moduledoc "Two subflows under a box: `stack` on its crates, `heap` on its tins."
    use RelaDSL.Schema

    for {name, subject} <- [stack: :crate, heap: :tin] do
      subflow name, label: "Under", subject: subject do
        run_as("system:depot")
        owner(relation: :held_by, default: {:clerk, config: :decider})
        start(:create)
        initial(:weigh)

        state :weigh, label: "Weigh it" do
          branch(to: :seal, when: "entity.result == 'seal'")
          present(expected: "Weigh it")
        end

        state :seal, label: "Seal it" do
          owner(relation: :held_by, default: {:clerk, :ada})
          branch(to: :done, when: "entity.result == 'ok'")
          present(expected: "Seal it")
        end

        final(:done, label: "Done")
      end
    end
  end

  defmodule Stack do
    @moduledoc false
    use RelaDSL.Flow.Subflow,
      from: AtlasFlow.SupervisedOwnerTest.Under,
      subflow: :stack,
      behaviour: AtlasFlow.Subflow
  end

  defmodule Heap do
    @moduledoc false
    use RelaDSL.Flow.Subflow,
      from: AtlasFlow.SupervisedOwnerTest.Under,
      subflow: :heap,
      behaviour: AtlasFlow.Subflow
  end

  defmodule With do
    @moduledoc "The `with:` model's parts."

    defp selected(subject, owner_relation),
      do: %{
        "subject" => subject,
        "projection" => %{"field" => "todo", "owner_relation" => owner_relation},
        "admission" => %{},
        "imports" => [],
        "migrations" => []
      }

    def selection,
      do: %{
        "sort" => selected("box", "owned_by"),
        "stack" => selected("crate", "held_by"),
        "heap" => selected("tin", "held_by")
      }

    def supervision,
      do: %{
        "version" => 1,
        "relation" => "tended_by",
        "inputs" => %{
          "operation" => "operation",
          "operations" => ["pickup", "hand_over"],
          "hand_to" => "hand_to"
        },
        "spans" => %{
          "sort" => [
            %{
              "name" => "tend",
              "label" => "Tend",
              "states" => ["check", "pack"],
              "with" => ["stack"]
            }
          ]
        }
      }

    def relations,
      do:
        Map.merge(AtlasFlow.SupervisedOwnerTest.Span.relations("clerk"), %{
          "held_by" => %{"from" => ["crate", "tin"], "to" => ["clerk"], "max_outgoing" => 1},
          "on_box" => %{"from" => ["tin"], "to" => ["box"], "max_outgoing" => 1, "parent" => true}
        })

    def description,
      do: %{"entities" => Map.new(~w(box crate tin clerk cursor choice), &{&1, %{}})}
  end

  defmodule Withed do
    @moduledoc false
    use AtlasFlow.TestModel,
      subflows: [
        AtlasFlow.SupervisedOwnerTest.Sort,
        AtlasFlow.SupervisedOwnerTest.Stack,
        AtlasFlow.SupervisedOwnerTest.Heap
      ],
      actors: [decider: "clerk"],
      selection: AtlasFlow.SupervisedOwnerTest.With.selection(),
      relations: AtlasFlow.SupervisedOwnerTest.With.relations(),
      supervision: AtlasFlow.SupervisedOwnerTest.With.supervision()
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

  describe "a run of a subflow a span names in its `with:`" do
    alias AtlasFlow.{Supervision, Talk}
    alias AtlasFlow.Runs.Projection

    setup %{box: box} do
      # Its own Facts, describing the kinds the engine listens to.
      stop_supervised!(FakeFacts)
      start_supervised!({FakeFacts, description: With.description()})
      for key <- ["ada", "dee", "sam"], do: FakeFacts.put("clerk", %{"key" => key})
      FakeFacts.put("box", %{"key" => box, "values" => %{}})
      crate = "C-" <> box
      tin = "T-" <> box
      FakeFacts.put("crate", %{"key" => crate, "links" => %{"in_box" => [box]}})
      FakeFacts.put("tin", %{"key" => tin, "links" => %{"on_box" => [box]}})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
      %{crate: crate, tin: tin}
    end

    defp held(kind, key), do: FakeFacts.get(kind, key)["links"]["held_by"]
    defp todo(kind, key), do: FakeFacts.get(kind, key)["values"]["todo"]

    defp sort_run(box) do
      {:ok, run} =
        AtlasFlow.Runs.Store.decode(
          runner().config,
          FakeFacts.get("cursor", Run.key("sort", "box", box, 1))
        )

      run
    end

    # A pickup or hand-over of the box's sort run, sent as someone sends it (a submitted
    # input): Flow takes it from its hint. Answered once Flow settled past it.
    defp send_input(box, n, operation, actor, extra \\ %{}),
      do: settled(put_input(box, n, operation, actor, extra))

    # The input stored, without waiting for Flow: its position.
    defp put_input(box, n, operation, actor, extra \\ %{}) do
      run = sort_run(box)

      values =
        Map.merge(
          %{
            "run" => run["key"],
            "entry" => run["entry"],
            "generation" => run["generation"],
            "actor" => actor,
            "operation" => operation,
            "roles" => [],
            "changed_fields" => %{},
            "links" => %{}
          },
          extra
        )

      key = "I-#{n}-" <> box

      {:stored, position} =
        Talk.put("choice", %{"op" => "submit", "key" => key, "values" => values}, key)

      position
    end

    defp settled(position) do
      request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{"position" => position})
      id = request.id

      receive do
        {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, %{"settled" => settled}} ->
          assert settled >= position
      end
    end

    defp runner, do: AtlasFlow.Model.load(Withed, :prod, %{"decider" => "dee"})

    test "the `with:` child's decider state goes to the parent's supervisor; another child's to the decider",
         %{box: box, crate: crate, tin: tin} do
      engine = start(Withed)
      Engine.round(engine)
      assert {held("crate", crate), held("tin", tin)} == {["dee"], ["dee"]}

      supervise(box, "sam")
      Engine.round(engine)
      assert owner(box) == ["sam"]
      assert todo("crate", crate) == "Weigh it"
      assert held("crate", crate) == ["sam"]
      assert held("tin", tin) == ["dee"]

      # The parent leaves its span: the child's state is the decider's again.
      result(box, "again")
      Engine.round(engine)
      assert state(box) == "Check it again"
      assert held("crate", crate) == ["dee"]
    end

    test "with no supervisor, the `with:` child's decider state is the decider's",
         %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)
      Engine.round(engine)
      assert sort_run(box)["supervised_by"] == nil
      assert held("crate", crate) == ["dee"]
    end

    test "a pickup, a hand-over and another holder's pickup move the child's owner, each before any round",
         %{box: box, crate: crate, tin: tin} do
      engine = start(Withed)
      Engine.round(engine)
      assert held("crate", crate) == ["dee"]

      send_input(box, 1, "pickup", "sam")
      assert sort_run(box)["supervised_by"] == "sam"
      assert held("crate", crate) == ["sam"]

      send_input(box, 2, "hand_over", "sam", %{"hand_to" => "ada"})
      assert sort_run(box)["supervised_by"] == nil
      assert held("crate", crate) == ["dee"]

      send_input(box, 3, "pickup", "ada")
      assert sort_run(box)["supervised_by"] == "ada"
      assert held("crate", crate) == ["ada"]
      assert held("tin", tin) == ["dee"]
    end

    test "a child state with a fixed owner never moves to the supervisor",
         %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)
      supervise(box, "sam")
      fact = FakeFacts.get("crate", crate)
      FakeFacts.put("crate", put_in(fact, ["values", "result"], "seal"))
      Engine.round(engine)
      assert todo("crate", crate) == "Seal it"
      assert owner(box) == ["sam"]
      assert held("crate", crate) == ["ada"]
    end

    test "the child's owner and `AtlasFlow.Supervision.of/3` agree in every case",
         %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)

      agree = fn ->
        case Supervision.of(runner(), "crate", crate) do
          {:supervised, holder, _run} -> assert held("crate", crate) == [holder]
          :unsupervised -> assert held("crate", crate) == ["dee"]
        end
      end

      # Unsupervised, supervised in the span, cleared, and supervised outside the span.
      agree.()
      supervise(box, "sam")
      Engine.round(engine)
      assert {:supervised, "sam", _} = Supervision.of(runner(), "crate", crate)
      agree.()
      supervise(box, nil)
      Engine.round(engine)
      agree.()
      supervise(box, "sam")
      result(box, "again")
      Engine.round(engine)
      assert state(box) == "Check it again"
      agree.()
    end

    test "Facts not saying who supervises the child: an error, and nothing written",
         %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)
      supervise(box, "sam")
      Engine.round(engine)
      assert held("crate", crate) == ["sam"]
      stop_supervised!(Engine)

      :ok = GenServer.call(FakeFacts, {:busy, "cursor", Run.key("sort", "box", box, 1)})
      sent = length(FakeFacts.sent())
      assert Supervision.of(runner(), "crate", crate) == :unavailable
      assert Projection.project(runner(), "crate", crate) == {:error, :supervision_unavailable}
      assert length(FakeFacts.sent()) == sent
      assert held("crate", crate) == ["sam"]
    end

    # `Supervision.of/3` answers (its read is a transition read), but the projection's own
    # plain read of the spanned run's record fails: still an error, never the decider.
    test "the spanned run's record unreadable after Supervision answered: an error, nothing written",
         %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)
      supervise(box, "sam")
      Engine.round(engine)
      assert held("crate", crate) == ["sam"]
      stop_supervised!(Engine)

      key = Run.key("sort", "box", box, 1)
      :ok = GenServer.call(FakeFacts, {:block_read, "cursor", %{"key" => key, "plain" => true}})
      sent = length(FakeFacts.sent())
      assert {:supervised, "sam", ^key} = Supervision.of(runner(), "crate", crate)
      assert Projection.project(runner(), "crate", crate) == {:error, :supervision_unavailable}
      assert length(FakeFacts.sent()) == sent
      assert held("crate", crate) == ["sam"]
    end

    # The Router delivers in its call: once the Engine has handled the hint and the
    # `_settled` request (`:sys.get_state/1` is the barrier), an answer would be here.
    test "a failed downward lookup holds the hint for the round", %{box: box, crate: crate} do
      engine = start(Withed)
      Engine.round(engine)
      linked = %{"linked" => %{"in_box" => box}}
      :ok = GenServer.call(FakeFacts, {:block_read, "crate", linked})

      position = put_input(box, 1, "pickup", "sam")
      request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
      :ok = AtlasBus.send(request, %{"position" => position})
      id = request.id
      _ = :sys.get_state(engine)

      assert sort_run(box)["supervised_by"] == "sam"
      assert held("crate", crate) == ["dee"]
      refute_received {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, _}

      :ok = GenServer.call(FakeFacts, {:allow_read, "crate", linked})
      Engine.round(engine)
      assert_received {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, _}
      assert held("crate", crate) == ["sam"]
    end
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

    test "a precomputed in-span answer stands for the run's own spans" do
      run = %{"state" => "weigh", "in_span" => true, "supervised_by" => @sam}
      assert AtlasFlow.Model.owner(@decider, @actors, run) == @sam

      assert AtlasFlow.Model.owner(@decider, @actors, %{run | "in_span" => false}) ==
               %{"kind" => "clerk", "key" => "dee"}
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
