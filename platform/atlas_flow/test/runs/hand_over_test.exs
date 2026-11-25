defmodule AtlasFlow.Runs.HandOverTest do
  @moduledoc """
  S3 of M3 (work acquisition decision 2026-11-17, decision 4): a checked hand-over gives
  the holder it is handed to a To-Do to pick the run up. On the neutral watch model
  (`AtlasFlow.TestModel.Watch`) with a part to assign through (`Desk` below: a memo, made
  with its badge, which is held by a clerk) and `FakeFacts`. Asserted on the write log,
  the facts written, the run's fields and ids, never on wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{FakeFacts, Talk}
  alias AtlasFlow.Runs.{HandOver, Run, Store}

  defmodule Desk do
    @moduledoc "The watch model, with a memo kind its hand-overs are given as, through a badge."
    @behaviour AtlasFlow.Model
    @watch AtlasFlow.TestModel.Watch

    @impl true
    def subflows(env), do: @watch.subflows(env)
    @impl true
    def runs, do: @watch.runs()
    @impl true
    def selection(name), do: @watch.selection(name)
    @impl true
    def composition, do: @watch.composition()
    @impl true
    def actors, do: @watch.actors()
    def turn, do: @watch.turn()
    def supervision, do: @watch.supervision()

    @impl true
    def relations,
      do:
        Map.merge(@watch.relations(), %{
          "card" => %{
            "from" => ["memo"],
            "to" => ["badge"],
            "max_outgoing" => 1,
            "component" => %{"key" => "B-{key}", "values" => %{"of" => "{key}"}}
          },
          "held_by" => %{"from" => ["badge"], "to" => ["clerk"], "max_outgoing" => 1}
        })
  end

  @now ~U[2026-11-17 09:00:00Z]
  @relation "watched_by"
  @hand_over [
    kind: "memo",
    id_prefix: "M-",
    digits: 2,
    assignment: "card",
    assigned_to: "held_by",
    values: [state: "open"],
    title: "Take {subject}",
    instructions: "{from} gave {subject} to you."
  ]

  setup do
    Application.put_env(:atlas_bus, :store, "hand-over-#{System.unique_integer([:positive])}")
    configured = Application.get_env(:atlas_flow, :hand_over)
    Application.put_env(:atlas_flow, :hand_over, @hand_over)

    on_exit(fn ->
      if configured,
        do: Application.put_env(:atlas_flow, :hand_over, configured),
        else: Application.delete_env(:atlas_flow, :hand_over)
    end)

    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    for clerk <- ~w(ada bea cid), do: FakeFacts.put("clerk", %{"key" => clerk})
    FakeFacts.put("robot", %{"key" => "rob"})

    loaded = AtlasFlow.Model.load(Desk, :prod)
    assert loaded.refusal == nil
    assert %{"kind" => "memo"} = loaded.config["hand_over"]
    %{config: loaded.config, flows: loaded.flows}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp key, do: Run.key("watch", "bin", "B-1", 1)
  defp reconcile(c), do: Store.reconcile(c.config, c.flows, @now)

  defp run(c) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", key()))
    run
  end

  defp slip(c, n, operation, actor, extra) do
    r = run(c)

    FakeFacts.put_input(
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
    )
  end

  defp status(input_key) do
    %{"inputs" => inputs} = Talk.read("slip", %{"run" => key()})
    Enum.find(inputs, &(&1["key"] == input_key))["status"]
  end

  # A bin's run in `packing` (span pack), supervised by `who`.
  defp supervised(c, who \\ "ada") do
    FakeFacts.put("bin", %{"key" => "B-1", "values" => %{"phase" => "first", "step" => "pack"}})
    assert {:ok, [_]} = reconcile(c)
    slip(c, 10, "pickup", who, %{})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == who
    run(c)
  end

  defp hand_over(c, n, from, to), do: slip(c, n, "hand_over", from, %{"hand_to" => to})

  # What Flow stored, oldest first: memo creates, the badge links and its run's writes.
  defp creates, do: Enum.filter(FakeFacts.sent(), &(&1["op"] == "create" and memo?(&1)))
  defp memo?(content), do: String.starts_with?(content["key"] || "", "M-")
  defp badge_writes, do: Enum.filter(FakeFacts.sent(), &String.starts_with?(&1["key"], "B-M-"))

  defp index(pred), do: Enum.find_index(FakeFacts.sent(), pred)

  # The first stored run write whose pending writes hold a write of `key`.
  defp holding(key) do
    &(&1["key"] == key() and
        Enum.any?(
          JSON.decode!(&1["values"]["pending"] || ~s({"writes":[]}))["writes"],
          fn w -> w["content"]["key"] == key end
        ))
  end

  # -- the To-Do -------------------------------------------------------------------------

  test "one checked hand-over gives the holder one To-Do, assigned through its part, after the run holding it is stored",
       c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")

    assert {:ok, _} = reconcile(c)

    # One To-Do: the configured kind's create, the handed-over subject's key in its texts.
    assert [create] = creates()
    assert %{"op" => "create", "key" => "M-01", "by" => "flow", "values" => values} = create
    assert values["state"] == "open"
    assert String.contains?(values["instructions"], "B-1")
    assert String.contains?(values["title"], "B-1")
    assert FakeFacts.get("memo", "M-01") != nil

    # Assigned through its part (the component the relation's template names) to the holder
    # it was handed to, never to the supervisor who handed it over. Flow writes both, in its
    # own name; each names the supervisor's hand-over input as its cause.
    assert [owner] = badge_writes()
    assert %{"op" => "change", "key" => "B-M-01", "by" => "flow"} = owner
    assert owner["links"] == %{"held_by" => ["bea"]}

    for write <- [create, owner] do
      assert write["by"] == "flow"
      assert String.contains?(write["cause"], "S-11")
      assert String.contains?(write["cause"], "ada")
    end

    assert Enum.all?(FakeFacts.stored_from_flow(), &(&1["by"] not in ~w(ada bea cid)))
    assert FakeFacts.get("badge", "B-M-01")["links"]["held_by"] == ["bea"]

    # Intent first: the run holding both writes was stored before either was sent; the
    # create before the link.
    stored = index(holding("M-01"))
    assert stored < index(&(&1 == create))
    assert index(&(&1 == create)) < index(&(&1 == owner))

    # Each under its stable id: the run, the input, "hand_over" and the To-Do's key.
    held = JSON.decode!(Enum.at(FakeFacts.sent(), stored)["values"]["pending"])["writes"]
    ids = Map.new(held, &{&1["content"]["key"], &1["id"]})
    assert ids["M-01"] == AtlasBus.Digest.of_term([key(), "S-11", "hand_over", "M-01"])

    assert ids["B-M-01"] ==
             AtlasBus.Digest.of_term([key(), "S-11", "hand_over", "M-01", "held_by"])

    # Built again from the same hand-over, the same writes.
    spec = c.config["hand_over"]
    again = HandOver.writes(spec, run(c), %{"to" => "bea", "input" => "S-11"}, "ada", 1)
    assert Enum.map(again, & &1["id"]) == Enum.map(held, & &1["id"])

    # Done: no writes left, the hand-over gone, nobody supervising, the input consumed.
    r = run(c)
    assert r["pending"]["writes"] == []
    refute Map.has_key?(r["pending"], "hand_over")
    refute Map.has_key?(r, "supervised_by")
    assert status("S-11") == "consumed"
  end

  test "an answer lost on the way is sent again under the same ids: one To-Do", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    # The To-Do's link is stored, and its answer lost: the reaction stops there.
    :ok = FakeFacts.lose_ack("badge")
    assert {:error, _} = reconcile(c)
    assert run(c)["pending"]["hand_over"]["to"] == "bea"

    assert {:ok, _} = reconcile(c)
    assert [%{"key" => "M-01"}] = creates()
    assert [_] = badge_writes()
    assert run(c)["pending"]["writes"] == []

    # The To-Do's own answer lost: Facts holds it as this create makes it, so it is the
    # one To-Do, not a taken number.
    slip(c, 12, "pickup", "bea", %{})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "bea"
    hand_over(c, 13, "bea", "cid")
    :ok = FakeFacts.lose_ack("memo")
    assert {:ok, _} = reconcile(c)
    assert Enum.map(creates(), & &1["key"]) == ~w(M-01 M-02)
    assert FakeFacts.get("badge", "B-M-02")["links"]["held_by"] == ["cid"]
  end

  test "Flow stopped between storing the run and sending its writes sends them once", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    :ok = GenServer.call(FakeFacts, {:busy_after_write, "cursor", key()})

    assert {:error, _} = reconcile(c)
    assert creates() == []
    held = FakeFacts.get("cursor", key())["values"]["pending"] |> JSON.decode!()
    assert Enum.map(held["writes"], & &1["content"]["key"]) == ~w(M-01 B-M-01)

    :ok = GenServer.call(FakeFacts, {:free, "cursor", key()})
    assert {:ok, _} = reconcile(c)
    assert {:ok, _} = reconcile(c)
    assert [%{"key" => "M-01"}] = creates()
    assert [_] = badge_writes()
  end

  test "a run write Facts refuses sends no To-Do; taken again, it is made once", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    :ok = GenServer.call(FakeFacts, {:refuse_write, "cursor", key()})

    assert {:error, _} = reconcile(c)
    assert creates() == [] and badge_writes() == []

    :ok = GenServer.call(FakeFacts, {:allow_write, "cursor", key()})
    assert {:ok, _} = reconcile(c)
    assert [%{"key" => "M-01"}] = creates()
    assert FakeFacts.get("memo", "M-02") == nil
  end

  test "a number another fact took meanwhile: the next one, stored before it is sent; one To-Do",
       c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    :ok = GenServer.call(FakeFacts, {:busy_after_write, "cursor", key()})
    assert {:error, _} = reconcile(c)

    # Someone made M-01 before Flow sent it.
    FakeFacts.put("memo", %{"key" => "M-01", "values" => %{"title" => "Theirs"}})
    :ok = GenServer.call(FakeFacts, {:free, "cursor", key()})

    assert {:ok, _} = reconcile(c)
    assert FakeFacts.get("memo", "M-01")["values"] == %{"title" => "Theirs"}
    assert [%{"key" => "M-02"} = create] = creates()
    assert FakeFacts.get("badge", "B-M-02")["links"]["held_by"] == ["bea"]
    assert FakeFacts.get("badge", "B-M-01") == nil
    assert index(holding("M-02")) < index(&(&1 == create))

    r = run(c)
    assert r["pending"]["writes"] == [] and not Map.has_key?(r["pending"], "hand_over")
  end

  test "a number held back after its To-Do was deleted: the next one under fresh ids; the run moves on",
       c do
    # The highest To-Do was deleted: the list ends at M-01, and M-02 is held back.
    FakeFacts.put("memo", %{"key" => "M-01", "values" => %{"title" => "Theirs"}})
    FakeFacts.put("memo", %{"key" => "M-02", "values" => %{"title" => "Gone"}})
    :ok = FakeFacts.reserve("memo", "M-02")

    supervised(c)
    hand_over(c, 11, "ada", "bea")
    assert {:ok, _} = reconcile(c)

    # One To-Do, numbered past the held-back key, assigned to the holder.
    assert [%{"key" => "M-03"} = create] = creates()
    assert FakeFacts.get("memo", "M-02") == nil
    assert FakeFacts.get("badge", "B-M-03")["links"]["held_by"] == ["bea"]
    assert FakeFacts.get("badge", "B-M-02") == nil
    assert index(holding("M-03")) < index(&(&1 == create))

    # Under the new number's ids, not the refused one's.
    held = JSON.decode!(Enum.at(FakeFacts.sent(), index(holding("M-03")))["values"]["pending"])
    ids = Map.new(held["writes"], &{&1["content"]["key"], &1["id"]})
    refused = AtlasBus.Digest.of_term([key(), "S-11", "hand_over", "M-02"])
    assert ids["M-03"] == AtlasBus.Digest.of_term([key(), "S-11", "hand_over", "M-03"])
    refute refused in Map.values(ids)

    # The refused id stays refused, even once the key is free: only a fresh id gets past.
    :ok = FakeFacts.release("memo", "M-02")

    [old, _] =
      HandOver.writes(
        c.config["hand_over"],
        run(c),
        %{"to" => "bea", "input" => "S-11"},
        "ada",
        2
      )

    assert old["id"] == refused
    assert {:refused, _, "reserved"} = Talk.put("memo", old["content"], refused, code: true)

    # The run moved on: nothing pending, the input consumed, the holder's pickup taken.
    r = run(c)
    assert r["pending"]["writes"] == [] and not Map.has_key?(r["pending"], "hand_over")
    assert status("S-11") == "consumed"
    slip(c, 12, "pickup", "bea", %{})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "bea"
    assert [_] = creates()
  end

  test "the hand-over's writes set no supervisor; the holder's own pickup does", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    assert {:ok, _} = reconcile(c)

    for write <- creates() ++ badge_writes(),
        do: refute(Map.has_key?(write["links"] || %{}, @relation))

    assert FakeFacts.get("cursor", key())["links"][@relation] == []
    refute Map.has_key?(run(c), "supervised_by")

    slip(c, 12, "pickup", "bea", %{})
    assert {:ok, _} = reconcile(c)
    assert run(c)["supervised_by"] == "bea"
    assert FakeFacts.get("cursor", key())["links"][@relation] == ["bea"]
  end

  test "two hand-overs in a row: two To-Dos, one per hand-over", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    assert {:ok, _} = reconcile(c)
    slip(c, 12, "pickup", "bea", %{})
    assert {:ok, _} = reconcile(c)
    hand_over(c, 13, "bea", "cid")
    assert {:ok, _} = reconcile(c)

    assert Enum.map(creates(), & &1["key"]) == ~w(M-01 M-02)
    assert FakeFacts.get("badge", "B-M-01")["links"]["held_by"] == ["bea"]
    assert FakeFacts.get("badge", "B-M-02")["links"]["held_by"] == ["cid"]
    assert Enum.map(badge_writes(), & &1["by"]) == ~w(flow flow)
    assert [first, second] = Enum.map(badge_writes(), & &1["cause"])
    assert String.contains?(first, "S-11") and String.contains?(second, "S-13")
  end

  test "Flow never closes a To-Do: it only creates them", c do
    supervised(c)
    hand_over(c, 11, "ada", "bea")
    assert {:ok, _} = reconcile(c)
    assert {:ok, _} = reconcile(c)

    assert [_] = for(w <- FakeFacts.sent(), memo?(w), do: w)
    assert [%{"op" => "create"}] = for(w <- FakeFacts.sent(), memo?(w), do: w)
  end

  test "a refused hand-over makes no To-Do", c do
    supervised(c)
    hand_over(c, 11, "bea", "cid")
    assert {:ok, _} = reconcile(c)
    assert %{"supervision" => "not_supervisor"} = run(c)["last_input"]
    assert creates() == [] and badge_writes() == []
  end

  test "the To-Dos Facts cannot list now decide nothing: the hand-over waits", c do
    before = supervised(c)
    hand_over(c, 11, "ada", "bea")
    list = %{"plain" => true}
    :ok = GenServer.call(FakeFacts, {:block_read, "memo", list})

    assert {:error, _} = reconcile(c)
    assert run(c) == before
    assert status("S-11") == "applied"

    :ok = GenServer.call(FakeFacts, {:allow_read, "memo", list})
    assert {:ok, _} = reconcile(c)
    assert [%{"key" => "M-01"}] = creates()
  end

  test "numbered after the To-Dos there are" do
    spec = HandOver.resolve(@hand_over, Desk.relations(), ["clerk"])
    assert HandOver.next_number(spec, []) == 1
    assert HandOver.next_number(spec, ~w(M-01 M-07 X-99 M-x)) == 8
    assert HandOver.key(spec, 3) == "M-03"
    assert HandOver.key(spec, 123) == "M-123"
  end

  test "no To-Do where the model has no part to assign it through, or none is configured" do
    watch = AtlasFlow.TestModel.Watch
    assert AtlasFlow.Model.load(watch, :prod).config["hand_over"] == nil

    relations = Desk.relations()
    assert HandOver.resolve(nil, relations, ["clerk"]) == nil
    assert HandOver.resolve(@hand_over, watch.relations(), ["clerk"]) == nil
    assert HandOver.resolve(@hand_over, relations, ["robot"]) == nil
    assert HandOver.resolve(Keyword.put(@hand_over, :kind, "bin"), relations, ["clerk"]) == nil
    assert HandOver.resolve(Keyword.delete(@hand_over, :title), relations, ["clerk"]) == nil
    assert %{"part" => %{"kind" => "badge"}} = HandOver.resolve(@hand_over, relations, ["clerk"])
  end
end
