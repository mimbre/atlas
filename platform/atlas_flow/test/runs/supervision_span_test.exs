defmodule AtlasFlow.Runs.SupervisionSpanTest do
  @moduledoc """
  S2 of M3 (work acquisition decision 2026-11-17 §5.6, S2): Flow clears a run's supervisor
  in the same write as the run leaves its supervised span, and a new generation or an
  imported run starts without one. On the neutral watch model (`AtlasFlow.TestModel.Watch`:
  `open` in no span, `packing` and `loading` in span `pack`, `checking` in the adjacent
  span `check`, final `done`) with `FakeFacts`, asserted on the stored run, the run fact's
  link and the write log, never on wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @model AtlasFlow.TestModel.Watch
  @relation "watched_by"

  setup do
    Application.put_env(:atlas_bus, :store, "span-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})

    loaded = AtlasFlow.Model.load(@model, :prod)
    assert loaded.refusal == nil
    %{config: loaded.config, flows: loaded.flows}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp bin(step),
    do: FakeFacts.put("bin", %{"key" => "B-1", "values" => %{"phase" => "first", "step" => step}})

  defp key(generation \\ 1), do: Run.key("watch", "bin", "B-1", generation)

  defp reconcile(c), do: Store.reconcile(c.config, c.flows, @now)

  defp run(c, generation \\ 1) do
    {:ok, run} = Store.decode(c.config, FakeFacts.get("cursor", key(generation)))
    run
  end

  defp link(generation \\ 1), do: FakeFacts.get("cursor", key(generation))["links"][@relation]

  defp writes(generation \\ 1), do: Enum.filter(FakeFacts.sent(), &(&1["key"] == key(generation)))

  defp pickup(c, n, actor) do
    r = run(c)

    FakeFacts.put_input(%{
      "key" => "S-#{n}",
      "run" => r["key"],
      "entry" => r["entry"],
      "generation" => r["generation"],
      "status" => "applied",
      "actor" => actor,
      "operation" => "pickup",
      "roles" => [],
      "changed_fields" => %{},
      "links" => %{},
      "position" => n,
      "prepared_at" => "2026-11-17T08:59:00Z"
    })

    assert {:ok, _} = reconcile(c)
  end

  # A run in `step`'s state (`check`: by way of `packing`), picked up there by ada.
  defp supervised(c, step) do
    bin(if step == "check", do: "pack", else: step)
    assert {:ok, [_]} = reconcile(c)
    if step == "check", do: assert(move(c, "check")["state"] == "checking")
    pickup(c, 10, "ada")
    r = run(c)
    assert r["supervised_by"] == "ada" and link() == ["ada"]
    r
  end

  # The run moved to `step`'s state by a change of its subject.
  defp move(c, step) do
    bin(step)
    assert {:ok, _} = reconcile(c)
    run(c)
  end

  defp spans(c), do: c.config["supervision"]["spans"]["watch"]

  # -- the transition table, on the stored run -------------------------------------------

  test "a move within one span keeps the supervisor", c do
    before = supervised(c, "pack")
    assert before["state"] == "packing"

    r = move(c, "load")
    assert r["state"] == "loading" and r["entry"] > before["entry"]
    assert r["supervised_by"] == "ada" and link() == ["ada"]
  end

  test "a move from span A to the adjacent span B clears the supervisor; B needs a new pickup",
       c do
    assert supervised(c, "pack")["state"] == "packing"

    r = move(c, "check")
    assert r["state"] == "checking"
    refute Map.has_key?(r, "supervised_by")
    assert link() == []

    pickup(c, 20, "bea")
    assert run(c)["supervised_by"] == "bea" and link() == ["bea"]
    assert run(c)["state"] == "checking"
  end

  test "a move out of every span clears the supervisor", c do
    # Only `packing` and `checking` lie in a span here, so `loading` lies in none.
    c =
      put_in(c, [:config, "supervision", "spans", "watch"], [
        %{"name" => "pack", "states" => ["packing"]},
        %{"name" => "check", "states" => ["checking"]}
      ])

    assert supervised(c, "pack")["state"] == "packing"

    r = move(c, "load")
    assert r["state"] == "loading"
    refute Map.has_key?(r, "supervised_by")
    assert link() == []
  end

  test "a move into a span from outside sets no supervisor", c do
    bin("wait")
    assert {:ok, [_]} = reconcile(c)
    assert run(c)["state"] == "open"

    r = move(c, "pack")
    assert r["state"] == "packing"
    refute Map.has_key?(r, "supervised_by")
    assert link() in [nil, []]
  end

  test "a final state lies in no span: the supervisor is cleared when the run completes", c do
    supervised(c, "check")

    r = move(c, "done")
    assert {r["state"], r["status"]} == {"done", "completed"}
    refute Map.has_key?(r, "supervised_by")
    assert link() == []
  end

  test "the state change and the clear are one write; none holds the new state with the old supervisor",
       c do
    supervised(c, "pack")
    move(c, "check")

    leaving = Enum.filter(writes(), &(&1["values"]["state"] == "checking"))
    assert [first | _] = leaving

    assert first["links"] == %{@relation => []}
    assert first["was"][@relation] == ["ada"]
    assert first["was"]["state"] == "packing"

    # No write sets the new state and keeps (or sets) the old supervisor.
    for w <- leaving, do: refute(w["links"][@relation] == ["ada"])
    assert Enum.count(writes(), &Map.has_key?(&1["links"] || %{}, @relation)) == 2
  end

  test "a run of a subflow that declares no span never gets a supervisor", c do
    c = put_in(c, [:config, "supervision", "spans", "watch"], [])
    bin("pack")
    assert {:ok, [_]} = reconcile(c)
    pickup(c, 10, "ada")

    r = run(c)
    assert %{"supervision" => "outside_span", "refused" => true} = r["last_input"]
    refute Map.has_key?(r, "supervised_by")
    assert link() in [nil, []]

    # And one that holds a supervisor anyway loses it on its next move.
    stale = Map.put(r, "supervised_by", "ada")

    refute Map.has_key?(
             Run.leave_span(r, Map.put(stale, "state", "loading"), []),
             "supervised_by"
           )

    refute Map.has_key?(Run.leave_span(r, stale, []), "supervised_by")
  end

  # -- new generations and imports -------------------------------------------------------

  test "a new generation (restart) starts without a supervisor", c do
    c = put_in(c, [:config, "selection", "watch", "restart_by"], ["clerk"])
    supervised(c, "check")
    completed = move(c, "done")
    assert completed["status"] == "completed"

    # A run stored before S2 can still hold the supervisor of the span it completed in.
    fact = FakeFacts.get("cursor", key())
    FakeFacts.put("cursor", put_in(fact, ["links", @relation], ["ada"]))
    assert run(c)["supervised_by"] == "ada"

    FakeFacts.put_input(%{
      "key" => "R-1",
      "run" => key(),
      "entry" => completed["entry"],
      "generation" => 1,
      "status" => "applied",
      "actor" => "ada",
      "roles" => ["restart"],
      "changed_fields" => %{},
      "links" => %{},
      "position" => 30,
      "prepared_at" => "2026-11-17T08:59:00Z"
    })

    assert {:ok, _} = reconcile(c)
    second = run(c, 2)
    assert second["generation"] == 2 and second["status"] == "active"
    refute Map.has_key?(second, "supervised_by")
    assert link(2) in [nil, []]
    assert [create | _] = writes(2)
    assert create["op"] == "create"
    refute Map.has_key?(create["links"] || %{}, @relation)
  end

  test "restart/4 starts the next generation without its predecessor's supervisor", c do
    flow = c.flows["watch"]
    subject = %{"key" => "B-1", "values" => %{"step" => "check"}}

    completed =
      Run.new("watch", flow, subject, [], @now)
      |> Map.merge(%{"status" => "completed", "state" => "done", "supervised_by" => "ada"})

    assert {:ok, next} = Run.restart(completed, flow, subject, @now)
    assert next["generation"] == 2
    refute Map.has_key?(next, "supervised_by")
  end

  test "an imported run starts without a supervisor", c do
    flow = c.flows["watch"]
    subject = %{"key" => "B-1", "values" => %{"step" => "pack"}}

    for state <- ["packing", "done"] do
      imported = Run.new("watch", flow, subject, [%{"when" => %{}, "state" => state}], @now)
      assert imported["state"] == state and imported["last_input"]["import"] == true
      refute Map.has_key?(imported, "supervised_by")
    end

    # Stored: the import's create carries no supervisor link.
    c =
      put_in(c, [:config, "selection", "watch", "imports"], [
        %{"when" => %{}, "state" => "packing"}
      ])

    bin("pack")
    assert {:ok, [_]} = reconcile(c)
    assert run(c)["state"] == "packing"
    refute Map.has_key?(run(c), "supervised_by")
    assert [create | _] = writes()
    refute Map.has_key?(create["links"] || %{}, @relation)
  end

  # -- the rule itself -------------------------------------------------------------------

  test "leave_span/3 over the transition table", c do
    at = fn state -> %{"key" => "R", "state" => state, "supervised_by" => "ada"} end

    kept? = fn from, to ->
      Map.has_key?(Run.leave_span(at.(from), at.(to), spans(c)), "supervised_by")
    end

    # in → in within one span; the same state (a pickup, a re-entry in place)
    assert kept?.("packing", "loading")
    assert kept?.("loading", "packing")
    assert kept?.("packing", "packing")
    assert kept?.("checking", "checking")
    # span A → adjacent span B; in → out; in → final; out → in
    refute kept?.("packing", "checking")
    refute kept?.("loading", "checking")
    refute kept?.("loading", "open")
    refute kept?.("checking", "done")
    refute kept?.("open", "packing")

    # Another run (a new generation) is not a transition of this one.
    other = Map.put(at.("open"), "key", "R2")
    assert Run.leave_span(at.("checking"), other, spans(c)) == other
  end

  test "leaving a span and coming back to it (rework) needs a new pickup", c do
    flow = c.flows["watch"]
    subject = %{"key" => "B-1", "values" => %{"step" => "load"}}
    {:ok, loading} = Run.step(Run.new("watch", flow, subject, [], @now), flow, subject, @now)
    loading = loading |> put_in(["pending", "writes"], []) |> Map.put("supervised_by", "ada")
    assert loading["state"] == "loading"

    # The task is abandoned: back to `open`, outside every span.
    {:ok, back} =
      Run.task_result(loading, flow, subject, @now, "abandoned", %{"key" => "TK-B-1-1"}, [])

    assert back["state"] == "open"
    back = Run.leave_span(loading, back, spans(c))
    refute Map.has_key?(back, "supervised_by")

    # Into the span again: still nobody supervises until someone picks it up.
    {:ok, again} = Run.step(put_in(back, ["pending", "writes"], []), flow, subject, @now)
    assert again["state"] == "loading"
    refute Map.has_key?(Run.leave_span(back, again, spans(c)), "supervised_by")
  end
end
