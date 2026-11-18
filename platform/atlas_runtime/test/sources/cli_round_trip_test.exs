defmodule AtlasRuntime.Sources.CliRoundTripTest do
  @moduledoc """
  M2 A7, Main's CLI acceptance (`plan-input/main-a7-cli.md`): the coordinators' tooling keeps
  the `atlas-runtime` commands after direct submit is gone. The real CLI (the Go binary the
  suite builds, `ATLAS_RUNTIME_EXECUTABLE`) talks to `backend.sock` of a throwaway home, as
  the socket's owner; behind it the Service, the executor and the built-in local work
  source with its puller (`AtlasRuntime.WorkHarness`), and the fake native harness on
  `PATH`, never a real model.

  The round trip: `start` → the local source leases the work to the executor (the same
  work id, A6 Q1) → its turn → `output --follow` → a page with `ended`. Then `status` (by
  work and by key), `continue`, `stop` and `release` on the same home.

  Every CLI call runs as a port with a deadline; one still running then is killed by its OS
  pid, so nothing outlives the test.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Backend.Listener
  alias AtlasRuntime.Model.LocalSource.QueuedWork
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Sources.Local
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  # Every CLI call ends within this (`output --follow` included), or it is killed.
  @deadline 20_000

  setup do
    bench = start!()
    start_supervised!({Listener, home: bench.dir, router: AtlasRuntime.Backend.Rest})
    %{bench: bench}
  end

  # The CLI's exit status and its stdout, one decoded JSON value per line.
  defp cli(bench, args) do
    exe = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        args: args,
        env: [{~c"ATLAS_RUNTIME_HOME", String.to_charlist(bench.dir)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + @deadline
    collect(port, os_pid, deadline, "")
  end

  defp collect(port, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, acc <> data)

      {^port, {:exit_status, status}} ->
        {status, for(line <- String.split(acc, "\n", trim: true), do: JSON.decode!(line))}
    after
      remaining ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        flunk("atlas-runtime #{inspect(args_of(port))} did not end within #{@deadline} ms")
    end
  end

  defp args_of(port), do: Port.info(port, :name)

  defp folder(bench, name) do
    path = Path.join(bench.workspace, name)
    File.mkdir_p!(path)
    path
  end

  defp start_args(bench, name, assignment, extra \\ []) do
    ["start", "--profile", "light_work", "--cost-class", "standard", "--cwd", folder(bench, name)] ++
      extra ++ [assignment]
  end

  defp status(bench, id) do
    {0, [work]} = cli(bench, ["status", "--work", id])
    work
  end

  defp await_status(bench, id, check),
    do: await(fn -> (w = status(bench, id)) && check.(w) && w end)

  test "start → lease from the local source → turn → output --follow → ended; status by work and key",
       %{bench: bench} do
    assert {0, [%{"work_id" => id, "client_key" => "rt-1"} = started]} =
             cli(bench, start_args(bench, "round", "complete round trip", ["--key", "rt-1"]))

    assert started["client"] =~ ~r/\Alocal:/

    # The work is the local source's, and reaches the executor as its lease, under one id.
    assert {:ok, %QueuedWork{client_key: "rt-1"}} = Local.get(id)
    await(fn -> match?(%M.WorkRecord{}, Store.read_work(bench.dir, id)) end)

    assert %M.WorkRecord{client: "source:local", client_key: lease} =
             Store.read_work(bench.dir, id)

    refute lease == "rt-1"

    done = await_status(bench, id, &(&1["state"] == "completed"))
    [%{"turn_id" => turn, "slot" => slot}] = done["attempts"]

    await(fn ->
      match?({:ok, %QueuedWork{state: :ended, result: %{kind: :completed}}}, Local.get(id))
    end)

    # output --follow reads every page and returns at the one that says ended.
    assert {0, pages} = cli(bench, ["output", "--turn", turn, "--follow"])
    assert pages != []
    assert %{"ended" => true, "more" => false} = List.last(pages)
    refute Enum.any?(Enum.drop(pages, -1), & &1["ended"])
    assert Enum.any?(pages, &(&1["events"] != []))

    # status by key is the local source's key, the same work.
    assert {0, [%{"work_id" => ^id}]} = cli(bench, ["status", "--key", "rt-1"])
    assert {0, [%{"works" => works}]} = cli(bench, ["status"])
    assert Enum.count(works, &(&1["work_id"] == id)) == 1

    # continue: a new work that continues that turn's conversation, on its slot.
    assert {0, [%{"work_id" => next}]} =
             cli(
               bench,
               ["continue", "--resume-from", turn] ++
                 tl(start_args(bench, "round", "complete continued"))
             )

    refute next == id
    continued = await_status(bench, next, &(&1["state"] == "completed"))
    assert [%{"slot" => ^slot, "provenance" => %{"continues" => ^turn}}] = continued["attempts"]
    assert [%{"resumed" => false}, %{"resumed" => true}] = launches(bench)
  end

  test "stop cancels a running local work; release answers for its slot", %{bench: bench} do
    assert {0, [%{"work_id" => id}]} = cli(bench, start_args(bench, "stop", "hang until stopped"))
    running = await_status(bench, id, &(&1["state"] == "running"))
    [%{"slot" => slot}] = running["attempts"]
    # The fake harness has launched the turn.
    await(fn -> length(launches(bench)) == 1 end)

    assert {0, [%{"work_id" => ^id, "attempts" => [stopping]}]} =
             cli(bench, ["stop", "--work", id])

    assert stopping["cancel_stage"] in ["requested", "signalled", "forced"]

    assert [%{"state" => "cancelled", "quiescent" => true}] =
             await_status(bench, id, &(&1["state"] == "cancelled"))["attempts"]

    # Its end reaches the local source through the puller's report.
    await(fn ->
      match?({:ok, %QueuedWork{state: :ended, result: %{kind: :cancelled}}}, Local.get(id))
    end)

    # The slot's process is gone, so release answers released; it starts nothing.
    assert {0, [released]} = cli(bench, ["release", "--slot", slot])
    assert is_map(released)
    refute Map.has_key?(released, "type")
    assert {0, [%{"works" => [%{"work_id" => ^id}]}]} = cli(bench, ["status"])
    assert length(launches(bench)) == 1
  end
end
