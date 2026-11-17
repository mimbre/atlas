defmodule AtlasFlow.Runs.SupervisionInputsTest do
  @moduledoc """
  S1 of M3 (work acquisition decision 2026-11-17 §5.6, R3 and S1): Flow, the run's only
  writer, checks pickup and hand-over inputs and writes the run's supervisor itself.
  On the neutral watch model (`AtlasFlow.TestModel.Watch`) with `FakeFacts`: one test
  per check, asserted on run fields, the run fact's link, input status and refusal tags,
  never on wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Depot, FakeFacts, Sorts, Talk, TestModel}
  alias AtlasFlow.Runs.{Inputs, Run, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @model AtlasFlow.TestModel.Watch
  @relation "watched_by"

  setup do
    Application.put_env(:atlas_bus, :store, "supervision-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    for clerk <- ~w(ada bea cid), do: FakeFacts.put("clerk", %{"key" => clerk})
    FakeFacts.put("robot", %{"key" => "rob"})

    loaded = AtlasFlow.Model.load(@model, :prod)
    assert loaded.refusal == nil
    %{config: loaded.config, flows: loaded.flows}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp bin(step),
    do: FakeFacts.put("bin", %{"key" => "B-1", "values" => %{"phase" => "first", "step" => step}})

  defp key, do: Run.key("watch", "bin", "B-1", 1)

  defp reconcile(c), do: Store.reconcile(c.config, c.flows, @now)

  defp run(c) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", key()))
    run
  end

  defp link(), do: FakeFacts.get("cursor", key())["links"][@relation]

  # A run in `state`: packing (span pack), loading (span pack, a task), checking or open.
  defp started(c, step \\ "pack") do
    bin(step)
    assert {:ok, [_]} = reconcile(c)
    run(c)
  end

  defp slip(c, n, operation, actor, extra \\ %{}) do
    r = run(c)

    input =
      Map.merge(
        %{
          "key" => "S-#{n}",
          "run" => r["key"],
          "entry" => r["entry"],
          "generation" => r["generation"],
          "status" => "applied",
          "actor" => actor,
          "operation" => operation,
          "roles" => [],
          "changed_fields" => %{},
          "links" => %{},
          "position" => n,
          "prepared_at" => "2026-11-17T08:59:00Z"
        },
        extra
      )

    FakeFacts.put_input(input)
    input
  end

  defp status(input_key) do
    %{"inputs" => inputs} = Talk.read("slip", %{"run" => key()})
    Enum.find(inputs, &(&1["key"] == input_key))["status"]
  end

  # The run writes that set the supervisor link, oldest first.
  defp link_writes,
    do:
      Enum.filter(
        FakeFacts.sent(),
        &(&1["key"] == key() and Map.has_key?(&1["links"] || %{}, @relation))
      )

  defp unchanged_but_cursor(before, now),
    do:
      Map.drop(before, ~w(input_cursor last_input)) == Map.drop(now, ~w(input_cursor last_input))

  # A refusal: tagged, consumed, and nothing but the cursor and the last input changed.
  defp assert_refused(c, before, input, tag) do
    assert {:ok, _} = reconcile(c)
    after_ = run(c)
    assert %{"supervision" => ^tag, "refused" => true, "input" => k} = after_["last_input"]
    assert k == input["key"]
    assert after_["input_cursor"] == input["position"]
    assert unchanged_but_cursor(before, after_)
    assert status(input["key"]) == "consumed"
  end

  # -- pickup ----------------------------------------------------------------------------

  test "a checked pickup sets the supervisor in one stored run write and consumes the input", c do
    before = started(c)
    assert before["state"] == "packing" and before["supervised_by"] == nil
    input = slip(c, 10, "pickup", "ada")

    assert {:ok, [r]} = reconcile(c)
    assert r["supervised_by"] == "ada"
    assert run(c)["supervised_by"] == "ada"
    assert link() == ["ada"]

    # One write: the link, the cursor and the last input together.
    assert [write] = link_writes()
    assert write["links"] == %{@relation => ["ada"]}
    assert write["values"]["input_cursor"] == 10

    assert %{"input" => "S-10", "supervision" => "pick_up"} =
             JSON.decode!(write["values"]["last_input"])

    assert status(input["key"]) == "consumed"
    assert r["state"] == "packing"
  end

  test "a pickup again by the supervisor changes nothing and is still consumed", c do
    started(c)
    slip(c, 10, "pickup", "ada")
    assert {:ok, _} = reconcile(c)
    again = slip(c, 11, "pickup", "ada")

    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "ada"
    assert %{"supervision" => "pick_up", "input" => "S-11"} = run(c)["last_input"]
    assert length(link_writes()) == 1
    assert status(again["key"]) == "consumed"
  end

  test "a pickup while someone else supervises is refused (supervised)", c do
    started(c)
    slip(c, 10, "pickup", "ada")
    assert {:ok, _} = reconcile(c)
    before = run(c)

    assert_refused(c, before, slip(c, 11, "pickup", "bea"), "supervised")
    assert run(c)["supervised_by"] == "ada" and link() == ["ada"]
  end

  test "an actor that is no holder's fact (another kind, or none) is refused (actor)", c do
    before = started(c)
    assert_refused(c, before, slip(c, 10, "pickup", "rob"), "actor")

    before = run(c)
    assert_refused(c, before, slip(c, 11, "pickup", "nobody"), "actor")
    assert link_writes() == []
  end

  test "a state outside every span is refused (outside_span)", c do
    before = started(c, "wait")
    assert before["state"] == "open"
    assert_refused(c, before, slip(c, 10, "pickup", "ada"), "outside_span")
  end

  test "an input of an entry the run has left is refused (moved_on)", c do
    before = started(c)
    input = slip(c, 10, "pickup", "ada", %{"entry" => before["entry"] - 1})
    assert_refused(c, before, input, "moved_on")
  end

  test "an input that is not applied, of another run, or at the cursor is not taken", c do
    before = started(c)
    slip(c, 10, "pickup", "ada", %{"status" => "consumed"})
    slip(c, 11, "pickup", "ada", %{"run" => "other"})
    slip(c, before["input_cursor"], "pickup", "ada", %{"key" => "S-at"})

    assert {:ok, _} = reconcile(c)
    assert run(c) == before
  end

  # -- hand-over -------------------------------------------------------------------------

  defp supervised(c) do
    started(c)
    slip(c, 10, "pickup", "ada")
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "ada"
    run(c)
  end

  test "a checked hand-over clears the supervisor and keeps the holder for its To-Do, in one write",
       c do
    supervised(c)
    input = slip(c, 11, "hand_over", "ada", %{"hand_to" => "bea"})

    assert {:ok, _} = reconcile(c)
    r = run(c)
    refute Map.has_key?(r, "supervised_by")
    assert link() == []
    assert r["pending"]["hand_over"] == %{"to" => "bea", "input" => "S-11"}
    assert %{"supervision" => "hand_over", "input" => "S-11"} = r["last_input"]

    assert [_, write] = link_writes()
    assert write["links"] == %{@relation => []}
    assert write["was"][@relation] == ["ada"]
    assert JSON.decode!(write["values"]["pending"])["hand_over"]["to"] == "bea"
    assert status(input["key"]) == "consumed"

    # Nobody supervises until the holder picks it up themselves.
    slip(c, 12, "pickup", "bea")
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "bea"
  end

  test "the held hand-over survives the run entering its next state, for its To-Do", c do
    supervised(c)
    slip(c, 11, "hand_over", "ada", %{"hand_to" => "bea"})
    assert {:ok, _} = reconcile(c)
    left = run(c)

    slip(c, 12, "choice", "cid", %{"roles" => ["clerk"], "changed_fields" => %{"choice" => "yes"}})

    assert {:ok, _} = reconcile(c)
    r = run(c)
    assert r["state"] == "checking" and r["entry"] == left["entry"] + 1
    assert r["input_cursor"] == 12 and status("S-12") == "consumed"
    assert r["pending"]["hand_over"] == %{"to" => "bea", "input" => "S-11"}
  end

  test "a hand-over needs exactly one target that is a holder (target, target_kind)", c do
    supervised(c)

    for {n, hand_to, tag} <- [
          {11, nil, "target"},
          {12, "", "target"},
          {13, ["bea", "cid"], "target"},
          {14, "rob", "target_kind"},
          {15, "nobody", "target_kind"}
        ] do
      before = run(c)
      assert_refused(c, before, slip(c, n, "hand_over", "ada", %{"hand_to" => hand_to}), tag)
      assert run(c)["supervised_by"] == "ada"
    end
  end

  test "a hand-over to the supervisor themselves is refused (self)", c do
    before = supervised(c)
    assert_refused(c, before, slip(c, 11, "hand_over", "ada", %{"hand_to" => "ada"}), "self")
    assert link() == ["ada"]
  end

  test "only the run's current supervisor may hand over (not_supervisor)", c do
    before = supervised(c)

    assert_refused(
      c,
      before,
      slip(c, 11, "hand_over", "bea", %{"hand_to" => "cid"}),
      "not_supervisor"
    )

    assert run(c)["supervised_by"] == "ada"
  end

  test "a hand-over of a run nobody supervises is refused (not_supervisor)", c do
    before = started(c)

    assert_refused(
      c,
      before,
      slip(c, 10, "hand_over", "ada", %{"hand_to" => "bea"}),
      "not_supervisor"
    )

    refute Map.has_key?(run(c), "supervised_by")
  end

  # -- order, mechanisms, replays and restarts -------------------------------------------

  test "a supervision input in a state that runs a task is taken anyway", c do
    before = started(c, "load")
    assert before["state"] == "loading"
    assert {:task, _} = c.flows["watch"].mechanism("loading")
    slip(c, 10, "pickup", "ada")

    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "ada" and run(c)["state"] == "loading"
    assert status("S-10") == "consumed"
  end

  test "in a state that runs a task, a supervision input passes an earlier input of its entry",
       c do
    before = started(c, "load")
    assert before["state"] == "loading"
    assert {:task, _} = c.flows["watch"].mechanism("loading")

    slip(c, 10, "choice", "bea", %{"roles" => ["clerk"], "changed_fields" => %{"choice" => "yes"}})

    slip(c, 11, "pickup", "ada")

    assert {:ok, _} = reconcile(c)
    r = run(c)
    assert r["supervised_by"] == "ada" and link() == ["ada"]
    assert r["state"] == "loading" and r["entry"] == before["entry"]
    assert r["input_cursor"] == 11
    assert status("S-11") == "consumed"
  end

  test "the run machine takes a supervision input before a mechanism's early return", c do
    flow = c.flows["watch"]
    subject = %{"key" => "B-1", "values" => %{"step" => "load"}}
    {:ok, r} = Run.step(Run.new("watch", flow, subject, [], @now), flow, subject, @now)
    r = put_in(r, ["pending", "writes"], [])
    assert r["state"] == "loading"

    input = %{
      "key" => "S-1",
      "run" => r["key"],
      "entry" => r["entry"],
      "status" => "applied",
      "position" => 1
    }

    check = fn ^input -> {:pick_up, "ada"} end

    assert {:ok, ^r} = Run.step(r, flow, %{"key" => "B-1", "values" => %{}}, @now, [input])

    assert {:ok, %{"supervised_by" => "ada", "input_cursor" => 1}} =
             Run.step(r, flow, %{"key" => "B-1", "values" => %{}}, @now, [input],
               supervision: check
             )

    # Its entry writes still pending: taken too.
    waiting = put_in(r, ["pending", "writes"], [%{"id" => "w"}])

    assert {:ok, %{"supervised_by" => "ada"}} =
             Run.step(waiting, flow, %{"key" => "B-1", "values" => %{}}, @now, [input],
               supervision: check
             )
  end

  test "a pickup ahead of a choice: both are taken, in position order", c do
    started(c)
    slip(c, 10, "pickup", "ada")

    slip(c, 11, nil, "bea", %{
      "roles" => ["clerk"],
      "changed_fields" => %{"choice" => "yes"}
    })

    assert {:ok, _} = reconcile(c)
    r = run(c)
    assert r["supervised_by"] == "ada"
    assert r["state"] == "checking" and r["input_cursor"] == 11
    assert status("S-10") == "consumed" and status("S-11") == "consumed"
  end

  test "a pickup queued behind a choice: the choice first, then the pickup, made for the entry it left (moved_on)",
       c do
    started(c)

    slip(c, 10, "choice", "bea", %{
      "roles" => ["clerk"],
      "changed_fields" => %{"choice" => "yes"}
    })

    slip(c, 11, "pickup", "ada")

    assert {:ok, _} = reconcile(c)
    r = run(c)
    assert r["state"] == "checking" and r["input_cursor"] == 11
    assert %{"supervision" => "moved_on", "input" => "S-11"} = r["last_input"]
    refute Map.has_key?(r, "supervised_by")
    assert status("S-10") == "consumed" and status("S-11") == "consumed"
  end

  test "a replayed input (the same position) changes nothing", c do
    started(c)
    input = slip(c, 10, "pickup", "ada")
    assert {:ok, _} = reconcile(c)
    before = run(c)
    sent = length(FakeFacts.sent())

    FakeFacts.put_input(input)
    assert {:ok, _} = reconcile(c)
    assert run(c) == before
    assert length(FakeFacts.sent()) == sent
  end

  test "restarted between storing the run and consuming the input: consumed next time, set once",
       c do
    started(c)
    slip(c, 10, "pickup", "ada")
    # Flow stops right after the run write is stored, before it consumes the input.
    :ok = GenServer.call(FakeFacts, {:busy_after_write, "cursor", key()})

    assert {:error, _} = reconcile(c)
    assert FakeFacts.get("cursor", key())["links"][@relation] == ["ada"]
    assert status("S-10") == "applied"

    :ok = GenServer.call(FakeFacts, {:free, "cursor", key()})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "ada"
    assert status("S-10") == "consumed"
    assert length(link_writes()) == 1
  end

  test "a holder Facts cannot read now decides nothing: the input waits", c do
    before = started(c)
    slip(c, 10, "pickup", "ada")
    :ok = GenServer.call(FakeFacts, {:busy, "clerk", "ada"})

    assert {:error, _} = reconcile(c)
    assert run(c) == before
    assert status("S-10") == "applied"

    :ok = GenServer.call(FakeFacts, {:free, "clerk", "ada"})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "ada"
  end

  test "Flow writes the supervisor on its run only, never on another fact", c do
    supervised(c)
    slip(c, 11, "hand_over", "ada", %{"hand_to" => "bea"})
    assert {:ok, _} = reconcile(c)

    for write <- FakeFacts.sent(),
        Map.has_key?(write["links"] || %{}, @relation),
        do: assert(write["key"] == key())

    assert length(link_writes()) == 2
  end

  # -- today's path, unchanged -----------------------------------------------------------

  test "a choice still moves a supervised run as it always did", c do
    started(c)
    slip(c, 10, nil, "bea", %{"roles" => ["clerk"], "changed_fields" => %{"choice" => "yes"}})

    assert {:ok, _} = reconcile(c)
    assert %{"state" => "checking", "input_cursor" => 10} = r = run(c)
    refute Map.has_key?(r["last_input"], "supervision")
  end

  test "a model that declares no supervision passes such an input over, as any input no branch takes" do
    config = TestModel.config()
    assert config["supervision"] == nil
    flow = Sorts.Chosen
    r = Run.new("sort", flow, %{"key" => "B-1", "values" => %{"phase" => "first"}}, [], @now)
    r = put_in(r, ["pending", "writes"], [])

    input = %{
      "key" => "I-1",
      "run" => r["key"],
      "entry" => r["entry"],
      "status" => "applied",
      "operation" => "pickup",
      "actor" => "ada",
      "roles" => [],
      "changed_fields" => %{},
      "position" => 3,
      "prepared_at" => "2026-11-17T08:59:00Z"
    }

    assert {:ok, ignored} = Run.step(r, flow, %{"key" => "B-1", "values" => %{}}, @now, [input])
    assert ignored["last_input"] == %{"version" => 1, "input" => "I-1", "ignored" => true}
    refute Map.has_key?(ignored, "supervised_by")
    assert Depot.supervision() == nil
  end

  # -- the check itself ------------------------------------------------------------------

  test "each check has its own tag, in order", c do
    s = %{
      "inputs" => c.config["supervision"]["inputs"],
      "spans" => c.config["supervision"]["spans"]["watch"]
    }

    holder? = &(&1 in ~w(ada bea))

    run = %{
      "key" => "R",
      "generation" => 1,
      "entry" => 2,
      "input_cursor" => 0,
      "state" => "packing"
    }

    i =
      &Map.merge(
        %{"run" => "R", "entry" => 2, "status" => "applied", "position" => 1, "actor" => "ada"},
        &1
      )

    assert Inputs.supervision(i.(%{"operation" => "pickup"}), run, s, holder?) ==
             {:pick_up, "ada"}

    assert Inputs.supervision(i.(%{"operation" => "choice"}), run, s, holder?) == nil
    assert Inputs.supervision(i.(%{}), run, s, holder?) == nil
    assert Inputs.supervision(i.(%{"operation" => "pickup"}), run, nil, holder?) == nil

    assert Inputs.supervision(i.(%{"operation" => "pickup", "generation" => 2}), run, s, holder?) ==
             nil

    assert Inputs.supervision(i.(%{"operation" => "pickup", "position" => 0}), run, s, holder?) ==
             nil

    assert Inputs.supervision(
             i.(%{"operation" => "pickup", "status" => "prepared"}),
             run,
             s,
             holder?
           ) == nil

    assert Inputs.supervision(i.(%{"operation" => "pickup", "entry" => 1}), run, s, holder?) ==
             {:refused, "moved_on"}

    assert Inputs.supervision(i.(%{"operation" => "pickup", "actor" => "rob"}), run, s, holder?) ==
             {:refused, "actor"}

    assert Inputs.supervision(
             i.(%{"operation" => "pickup"}),
             %{run | "state" => "open"},
             s,
             holder?
           ) ==
             {:refused, "outside_span"}

    held = Map.put(run, "supervised_by", "bea")

    assert Inputs.supervision(i.(%{"operation" => "pickup"}), held, s, holder?) ==
             {:refused, "supervised"}

    hand = &i.(%{"operation" => "hand_over", "hand_to" => &1})
    mine = Map.put(run, "supervised_by", "ada")
    assert Inputs.supervision(hand.("bea"), mine, s, holder?) == {:hand_over, "ada", "bea"}
    assert Inputs.supervision(hand.("bea"), held, s, holder?) == {:refused, "not_supervisor"}
    assert Inputs.supervision(hand.("bea"), run, s, holder?) == {:refused, "not_supervisor"}
    assert Inputs.supervision(hand.(nil), mine, s, holder?) == {:refused, "target"}
    assert Inputs.supervision(hand.("rob"), mine, s, holder?) == {:refused, "target_kind"}
    assert Inputs.supervision(hand.("ada"), mine, s, holder?) == {:refused, "self"}

    unavailable = fn _ -> :unavailable end
    assert Inputs.supervision(i.(%{"operation" => "pickup"}), run, s, unavailable) == :unavailable
  end
end
