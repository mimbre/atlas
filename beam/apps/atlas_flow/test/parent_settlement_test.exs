defmodule AtlasFlow.ParentSettlementTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk}
  alias AtlasFlow.Runs.Store

  defmodule Nested do
    @behaviour AtlasFlow.Model
    def subflows(env),
      do: Enum.reject(AtlasFlow.Yard.Nested.subflows(env), &(&1.name() == "tally"))

    defdelegate runs(), to: AtlasFlow.Yard.Nested
    defdelegate migrations(), to: AtlasFlow.Yard.Nested
    defdelegate composition(), to: AtlasFlow.Yard.Nested
    defdelegate actors(), to: AtlasFlow.Yard.Nested
    defdelegate turn(), to: AtlasFlow.Yard.Nested

    # Composition relations need not be presentation parents (review_of/test_of
    # in the production model are not). Only Store discovers these ancestors.
    def relations do
      Map.new(AtlasFlow.Yard.Nested.relations(), fn {name, relation} ->
        {name, Map.delete(relation, "parent")}
      end)
    end

    def selection(name) do
      AtlasFlow.Yard.Nested.selection(name)
      |> Map.put("projection", %{"field" => "todo", "state_field" => "projected"})
    end
  end

  setup do
    Application.put_env(:atlas_bus, :store, "parents-#{System.unique_integer([:positive])}")
    :ok = AtlasBus.attach("parent-tester")
    clock = start_supervised!({ManualClock, ~U[2026-11-14 00:00:00Z]})
    %{clock: clock}
  end

  defp description(kinds),
    do: %{"entities" => Map.new(kinds, &{&1, %{"plural" => &1 <> "s"}})}

  defp ask(position) do
    request = %{Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    request.id
  end

  defp answered(id, position) do
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}},
                   1_000

    assert settled >= position
  end

  for {kind, relation, role, verdict} <- [
        {"pr_review", "review_of", "reviewer", "changes_requested"},
        {"pr_test", "test_of", "tester", "failed"}
      ],
      failure <- [false, :parent, :ancestor] do
    test "production #{relation} projects Assignment before settlement; projection failure=#{failure}",
         c do
      start_supervised!(
        {FakeFacts,
         description:
           description(
             ~w(scene use_case issue pull_request pr_review pr_test decision assignment person agent flow_run flow_input)
           )}
      )

      FakeFacts.put("agent", %{"key" => "coordinator"})
      FakeFacts.put("person", %{"key" => "tester"})

      FakeFacts.put("issue", %{
        "key" => "IS-1",
        "values" => %{"title" => "Build it", "stage" => "specification"},
        "links" => %{"assignment" => ["AS-IS-1"]}
      })

      FakeFacts.put("assignment", %{"key" => "AS-IS-1"})

      FakeFacts.put("pull_request", %{
        "key" => "PR-1",
        "values" => %{
          "state" => "open",
          "revision" => "r1",
          "url" => "https://example.invalid/pr/1"
        },
        "links" => %{"assignment" => ["AS-PR-1"], "in_issue" => ["IS-1"]}
      })

      FakeFacts.put("assignment", %{"key" => "AS-PR-1"})

      FakeFacts.put(unquote(kind), %{
        "key" => "CH-1",
        "values" => %{"revision" => "r1"},
        "links" => %{unquote(relation) => ["PR-1"]}
      })

      engine =
        start_supervised!(
          {Engine,
           model: Model.AtlasEyra,
           environment: :test,
           actors: %{"decider" => "tester"},
           every: 3_600_000,
           clock: {ManualClock, c.clock}}
        )

      Engine.round(engine)
      assert FakeFacts.get("assignment", "AS-PR-1")["values"]["flow_state"] == "checking"
      config = :sys.get_state(engine).runner.config
      assert {:ok, child} = Store.latest(config, unquote(kind), unquote(kind), "CH-1")
      assert {:ok, issue_before} = Store.latest(config, "issue", "issue", "IS-1")
      # No hint: only the child completion's recursive reconciliation can repair this.
      issue_assignment = FakeFacts.get("assignment", "AS-IS-1")
      FakeFacts.put("assignment", put_in(issue_assignment, ["values", "expected"], "stale"))
      failed_assignment = if unquote(failure) == :ancestor, do: "AS-IS-1", else: "AS-PR-1"

      if unquote(failure),
        do: GenServer.call(FakeFacts, {:refuse_write, "assignment", failed_assignment})

      {:stored, p} =
        Talk.put(config["inputs"]["kind"], %{
          "op" => "submit",
          "key" => "choice-1",
          "values" => %{
            "run" => child["key"],
            "entry" => child["entry"],
            "roles" => [unquote(role)],
            "changed_fields" => %{"verdict" => unquote(verdict)}
          }
        })

      id = ask(p)
      state = :sys.get_state(engine)

      assert {:ok, %{"state" => "changes_requested"}} =
               Store.latest(config, "pull_request", "pull_request", "PR-1")

      assert {:ok, issue_after} = Store.latest(config, "issue", "issue", "IS-1")
      assert issue_after["entry"] == issue_before["entry"] + 1

      if unquote(failure) do
        assert Settled.value(state.settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}

        if unquote(failure) == :ancestor do
          assert FakeFacts.get("assignment", "AS-IS-1")["values"]["expected"] == "stale"
        else
          assert FakeFacts.get("assignment", "AS-PR-1")["values"]["flow_state"] == "checking"
        end

        Engine.round(engine)
        assert Settled.value(:sys.get_state(engine).settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        GenServer.call(FakeFacts, {:allow_write, "assignment", failed_assignment})
        Engine.round(engine)
      end

      answered(id, p)
      assignment = FakeFacts.get("assignment", "AS-PR-1")["values"]
      assert assignment["flow_state"] == "changes_requested"
      assert assignment["expected"] == "Make the changes asked for"
      assert FakeFacts.get("assignment", "AS-IS-1")["values"]["flow_state"] == "author"
      assert FakeFacts.get("assignment", "AS-IS-1")["values"]["expected"] == "Build it"
      writes = FakeFacts.sent()
      Engine.round(engine)
      assert FakeFacts.sent() == writes
    end
  end

  for failure <- [false, true] do
    test "all nested composition ancestors project before settlement; grandparent failure=#{failure}",
         c do
      start_supervised!(
        {FakeFacts, description: description(~w(basket tray cup hand cursor choice))}
      )

      FakeFacts.put("hand", %{"key" => "ada"})

      for {kind, key, links} <- [
            {"basket", "B-1", %{}},
            {"tray", "T-1", %{"in_basket" => ["B-1"]}},
            {"cup", "C-1", %{"on_tray" => ["T-1"]}}
          ] do
        FakeFacts.put(kind, %{
          "key" => key,
          "values" => %{"phase" => "first", "revision" => "r1"},
          "links" => links
        })
      end

      engine =
        start_supervised!(
          {Engine, model: Nested, every: 3_600_000, clock: {ManualClock, c.clock}}
        )

      Engine.round(engine)
      assert FakeFacts.get("basket", "B-1")["values"]["projected"] == "waiting"
      assert FakeFacts.get("tray", "T-1")["values"]["projected"] == "waiting"
      read = %{"key" => "B-1", "incoming" => false}
      if unquote(failure), do: GenServer.call(FakeFacts, {:block_read, "basket", read})

      {:stored, p} =
        Talk.put("cup", %{"op" => "change", "key" => "C-1", "values" => %{"level" => "full"}})

      id = ask(p)
      state = :sys.get_state(engine)

      assert {:ok, %{"state" => "packed"}} =
               Store.latest(state.runner.config, "pack", "basket", "B-1")

      assert {:ok, %{"state" => "filled"}} =
               Store.latest(state.runner.config, "fill", "tray", "T-1")

      if unquote(failure) do
        assert Settled.value(state.settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        Engine.round(engine)
        assert Settled.value(:sys.get_state(engine).settled) < p
        refute_received {:atlas_bus, %Envelope{id: ^id}, _}
        assert FakeFacts.get("basket", "B-1")["values"]["projected"] == "waiting"
        GenServer.call(FakeFacts, {:allow_read, "basket", read})
        Engine.round(engine)
      end

      answered(id, p)
      assert FakeFacts.get("tray", "T-1")["values"]["projected"] == nil
      assert FakeFacts.get("basket", "B-1")["values"]["projected"] == nil
      writes = FakeFacts.sent()
      Engine.round(engine)
      assert FakeFacts.sent() == writes
    end
  end
end
