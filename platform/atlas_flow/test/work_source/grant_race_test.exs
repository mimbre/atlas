defmodule AtlasFlow.WorkSource.GrantRaceTest do
  # Plan m3 A2 acceptance 2: the grant is race-safe (§3.2). A hand-over that lands between
  # the lease write and the check after it loses the lease before it is offered; one that
  # lands after the reply is caught by the next sweep. A lease write that lands between
  # Dispatch's read and its own write fences Dispatch's off. Races are staged with a
  # FakeFacts hook between two named steps; asserted on poll answers and fact values.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Dispatch, FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L

  @mini {"mini", "ada"}

  setup do
    dir = Path.join(System.tmp_dir!(), "race-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    Map.merge(ctx, L.supervised_task("B-1", "ada"))
  end

  defp poll(holdings \\ []), do: WorkSource.poll(@mini, L.poll_input("mini", holdings))

  test "a hand-over between the lease write and the check after it: never offered, the fact shows lost",
       ctx do
    Dispatch.resync()

    FakeFacts.hook(
      "task",
      ctx.task,
      "flow/dispatch",
      :after,
      L.supervisor_set(nil),
      {L.config()["kind"], ctx.run}
    )

    assert {:polled, %{leases: []}} = poll()
    assert %{"lease_state" => "lost", "lease_end_cause" => "supervision"} = L.values(ctx.task)
    assert is_binary(L.values(ctx.task)["lease_id"])
  end

  test "a hand-over after the reply: the next sweep loses the offered lease", ctx do
    Dispatch.resync()
    assert {:polled, %{leases: [%{lease_id: lease}]}} = poll()

    L.supervise(ctx.run, nil)
    Dispatch.sweep()
    assert %{"lease_state" => "lost", "lease_end_cause" => "supervision"} = L.values(ctx.task)
    assert {:polled, %{lease_lost: [^lease], leases: []}} = poll([lease])
  end

  test "another lease written between Dispatch's read and its write fences the grant off", ctx do
    Dispatch.resync()

    FakeFacts.hook("task", ctx.task, "flow/dispatch", :before, fn fact ->
      fact
      |> put_in(["values", "lease_id"], "TK-B-1-1~1~elsewhereelsewhereelsew")
      |> put_in(["values", "lease_state"], "offered")
    end)

    assert {:polled, %{leases: []}} = poll()
    assert L.values(ctx.task)["lease_id"] == "TK-B-1-1~1~elsewhereelsewhereelsew"
  end

  test "an unrelated field written meanwhile does not stop the grant (only the fence's fields count)",
       ctx do
    Dispatch.resync()

    FakeFacts.hook("task", ctx.task, "flow/dispatch", :before, fn fact ->
      put_in(fact, ["values", "state"], "waiting again")
    end)

    assert {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    assert L.values(ctx.task)["lease_id"] == lease
  end
end
