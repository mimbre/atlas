defmodule AtlasRuntime.Work.QuiescentStartTest do
  # Design §3.5: an attempt is quiescent when no process of it is left. So an attempt is
  # created not quiescent and stays so while buffered, running and cancelling; only its
  # terminal write (from the turn's group-gone result), the probe or a `release` sets it
  # (designer follow-up (a) to Q-A1). Every value below is the client's view.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  @claude %{
    "light_work" => %{
      "permissions" => ["read-only", "workspace-write", "materialized-folder"],
      "cost_classes" => ["low", "standard"],
      "options" => [%{"provider" => "anthropic", "harness" => "claude", "model" => "claude-test"}]
    }
  }

  setup do
    %{bench: start!()}
  end

  test "Claude: not quiescent while buffered, running and cancelling; quiescent once the group is gone",
       %{bench: bench} do
    lifecycle(bench, @claude, "claude")
  end

  test "Codex: not quiescent while buffered, running and cancelling; quiescent once the group is gone",
       %{bench: bench} do
    lifecycle(bench, nil, "codex")
  end

  test "a retry's new attempt is created not quiescent, and is quiescent once it ends",
       %{bench: bench} do
    work = submit!(bench, "complete then retried")
    await_state(work.work_id, :completed)

    assert %F.Outcome.Accepted{work: %{attempts: [%{quiescent: true}, next]}} =
             F.retry(client(), %{work_id: work.work_id})

    assert %{attempt: 2, state: :buffered, quiescent: false} = next

    assert [_, %{state: :completed, quiescent: true}] =
             await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts)).attempts
  end

  defp lifecycle(bench, profiles, backend) do
    policy =
      if profiles, do: %{"slots" => ["s1"], "profiles" => profiles}, else: %{"slots" => ["s1"]}

    write_policy!(bench.dir, policy)
    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000)

    # Created: the acceptance's own view.
    work = submit!(bench, "linger past the stop")
    assert [%{quiescent: false} = created] = work.attempts
    assert created.state in [:buffered, :starting, :running]

    # Running.
    [%{state: :running, quiescent: false, turn_id: turn_id}] = await_launch(bench, work).attempts
    launch = Enum.find(launches(bench), &(&1["goal"] == work.request.instructions))
    assert launch["backend"] == backend
    child = await_pid(Path.join(launch["cwd"], "linger.pid"))
    on_exit(fn -> System.cmd("/bin/kill", ["-9", "#{child}"], stderr_to_stdout: true) end)

    # Cancelling: the cancel's own answer, then while a member of the group still lives.
    assert %F.Outcome.Cancelling{stage: :signalled, work: %{attempts: [answered]}} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    assert %{state: :cancelling, quiescent: false} = answered
    await(fn -> leader_ended?(bench, work) end)
    assert alive?(child)

    assert [%{state: :cancelling, cancel_stage: :signalled, quiescent: false}] =
             work!(work.work_id).attempts

    # Terminal, with the group gone: the terminal write takes quiescent from that result.
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    [ended] = await_state(work.work_id, :cancelled).attempts
    assert ended.quiescent
    assert ended.result.native_outcome == :killed
    assert %{"state" => "killed"} = turn(bench, turn_id)
    refute alive?(child)
  end

  defp await_pid(file) do
    await(fn ->
      with {:ok, text} <- File.read(file),
           do: String.to_integer(String.trim(text)),
           else: (_ -> nil)
    end)
  end

  defp leader_ended?(bench, work) do
    case File.read(Path.join(bench.dir, "work-ends.jsonl")) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.any?(&(&1["goal"] == work.request.instructions))

      {:error, :enoent} ->
        false
    end
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", "#{pid}"], stderr_to_stdout: true))
end
