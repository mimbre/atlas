defmodule AtlasRuntime.Boundary.VisibilityTest do
  # Design §13 case 10: two in-BEAM clients call the facade directly ({id, rights} given;
  # only the socket adapter derives local:<user>). Each sees neither the other's work nor
  # its notifications; read_all sees both; capacity is global.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  test "without read_all a client sees only its own work, output and notifications" do
    bench = start!()
    alice = client("alice")
    bob = client("bob")
    admin = {"admin", [:read, :read_all]}

    parent = self()

    bob_inbox =
      spawn_link(fn ->
        F.subscribe(bob, %{})
        send(parent, :subscribed)

        receive_all = fn receive_all, seen ->
          receive do
            {:atlas_runtime_work, notification} ->
              receive_all.(receive_all, [notification | seen])

            {:report, to} ->
              send(to, {:bob_saw, Enum.reverse(seen)})
          end
        end

        receive_all.(receive_all, [])
      end)

    assert_receive :subscribed
    assert F.subscribe(admin, %{}) == %F.Outcome.Subscribed{}

    gate = Path.join(bench.dir, "hold")
    File.write!(gate, "")
    mine = submit!(bench, "wait hold", %{client_key: "same"}, alice)
    [%{turn_id: turn}] = await_launch(bench, mine, 1, alice).attempts

    # Bob: no work, no output, no key, and not in a heartbeat's running list.
    assert %F.Outcome.NotFound{} = F.get_work(bob, %{work_id: mine.work_id})
    assert %F.Outcome.NotFound{} = F.find_work(bob, %{client_key: "same"})
    assert %F.Outcome.Works{works: []} = F.list_work(bob, %{})
    assert %F.Outcome.NotFound{} = F.turn_output(bob, %{turn_id: turn})
    assert %F.Outcome.NotFound{} = F.cancel(bob, %{work_id: mine.work_id, mode: "force"})
    assert %F.Outcome.NotFound{} = F.retry(bob, %{work_id: mine.work_id})
    # Heartbeats while it runs, to every subscriber: Bob's must not list it, the admin's must.
    heartbeats(3)
    File.rm!(gate)
    await_state(mine.work_id, :completed, alice)

    # Alice and read_all see it, and its output.
    assert %F.Outcome.Found{} = F.get_work(alice, %{work_id: mine.work_id})
    assert %F.Outcome.Works{works: [%{work_id: id}]} = F.list_work(admin, %{})
    assert id == mine.work_id
    assert %F.Outcome.Page{} = F.turn_output(alice, %{turn_id: turn})
    assert %F.Outcome.Page{} = F.turn_output(admin, %{turn_id: turn})

    # Capacity is global.
    assert F.capacity(bob) == F.capacity(alice)

    send(bob_inbox, {:report, self()})
    assert_receive {:bob_saw, seen}
    refute Enum.any?(seen, &match?(%F.WorkChanged{}, &1))
    heartbeats = for %F.Heartbeat{} = h <- seen, do: h
    assert heartbeats != []
    assert Enum.all?(heartbeats, &(&1.running == []))

    admin_saw = notifications()
    assert Enum.any?(admin_saw, &match?(%F.WorkChanged{work_id: ^id, state: :completed}, &1))
    assert Enum.any?(admin_saw, &match?(%F.Heartbeat{running: [%{work_id: ^id}]}, &1))

    # Bob's own key is his own work.
    theirs = submit!(bench, "complete for bob", %{client_key: "same"}, bob)
    refute theirs.work_id == mine.work_id
  end

  # §3.2 Ownership: retry and cancel act only on the caller's own work. Another client's
  # work is not_found to a caller that cannot see it, and refused: not_permitted to one with
  # read_all, which grants reading, never acting.
  test "retry and cancel act only on the caller's own work; read_all reads, never acts" do
    bench = start!()
    alice = client("alice")
    bob = client("bob")
    carol = client("carol", [:read_all])

    gate = Path.join(bench.dir, "hold")
    File.write!(gate, "")
    mine = submit!(bench, "wait hold", %{}, alice)
    await_launch(bench, mine, 1, alice)

    assert %F.Outcome.NotFound{} = F.cancel(bob, %{work_id: mine.work_id, mode: "force"})
    assert %F.Outcome.NotFound{} = F.retry(bob, %{work_id: mine.work_id})

    assert %F.Outcome.Found{} = F.get_work(carol, %{work_id: mine.work_id})

    for mode <- ["graceful", "force"] do
      assert %F.Outcome.Refused{reason: :not_permitted, detail: detail} =
               F.cancel(carol, %{work_id: mine.work_id, mode: mode})

      assert detail =~ "another client"
    end

    assert %F.Outcome.Refused{reason: :not_permitted} = F.retry(carol, %{work_id: mine.work_id})

    assert %F.Outcome.Refused{reason: :not_permitted} =
             F.retry(carol, %{work_id: mine.work_id, resume: true})

    # Nothing changed: the one attempt still runs.
    assert %F.Outcome.Found{work: work} = F.get_work(alice, %{work_id: mine.work_id})
    assert [%{state: :running, cancel_stage: nil}] = work.attempts

    # The owner acts on it.
    assert %F.Outcome.Cancelling{} = F.cancel(alice, %{work_id: mine.work_id, mode: "force"})
    await_state(mine.work_id, :cancelled, alice)
    File.rm!(gate)
  end

  test "a client cannot continue a turn of a work it may not read" do
    bench = start!()
    alice = client("alice")
    mine = submit!(bench, "complete for alice", %{}, alice)
    [%{turn_id: turn}] = await_state(mine.work_id, :completed, alice).attempts
    assert turn(bench, turn)["session_id"]

    assert %F.Outcome.Refused{reason: :resume_unavailable} =
             F.submit(client("bob"), request(bench, "complete for bob", %{resume_from: turn}))

    assert %F.Outcome.Accepted{} =
             F.submit(alice, request(bench, "complete again", %{resume_from: turn}))
  end
end
