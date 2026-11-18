defmodule AtlasRuntime.Work.BaseWorkspaceTest do
  @moduledoc """
  S5a P7a (s5a-plan B6, B7, B25, B27, B29; design §3.3, §3.9 RQ7): a `base` work runs in the
  folder the Runtime chooses, `<home>/workers/work-<work_id>`, which the core materializes
  from the base at start through the real helper (`snapshot materialize`), from a loopback
  Code stand-in. The Work server never waits on the preparation.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn

  import AtlasRuntime.CodeStandIn,
    only: [
      base_request: 2,
      base_request: 3,
      base_request: 4,
      submit_base!: 2,
      submit_base!: 3,
      expected_folder: 2,
      private_attempt: 3,
      writable_bits: 1
    ]

  alias AtlasRuntime.Execution.Identity
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  setup context do
    test = self()
    options = Map.get(context, :work_options, [])

    options =
      Keyword.put_new(options, :after_write, fn record ->
        send(test, {:written, record, System.monotonic_time()})
      end)

    bench = start!(%{}, options)
    stand_in = CodeStandIn.start!(bench.dir)
    on_exit(fn -> CodeStandIn.stop(stand_in, bench.dir) end)
    %{bench: bench, code: stand_in}
  end

  defp record(bench, work_id), do: Store.read_work(bench.dir, work_id)

  def signal_probe(pid, _launched) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> :alive
      _ -> {:gone, "kill -0 found no process #{pid}"}
    end
  end

  # D44 gates naming a path on this machine (a folder workspace) on choose_path. A base
  # names none: the Runtime chooses its folder, so a client without choose_path submits one.
  test "a client without choose_path submits a base, which runs in the Runtime-chosen folder",
       %{bench: bench, code: code} do
    tcp = {"token:t", [:submit, :cancel, :read, :read_all]}

    assert %F.Outcome.Accepted{work: work} =
             F.submit(tcp, base_request(code, "complete without choose_path"))

    done = await_state(work.work_id, :completed, tcp)
    folder = expected_folder(bench.dir, work.work_id)
    [%{turn_id: turn_id} = attempt] = done.attempts
    assert attempt.result.kind == :completed
    assert turn(bench, turn_id)["cwd"] == folder
    assert %{folder: ^folder} = private_attempt(bench.dir, work.work_id, 1)
  end

  test "workspace-write: the base is materialized into <home>/workers/work-<work_id> before the turn, which runs there as materialized-folder",
       %{bench: bench, code: code} do
    work = submit_base!(code, "complete in a base folder")
    done = await_state(work.work_id, :completed)
    folder = expected_folder(bench.dir, work.work_id)

    # The starting commit names the folder, preparing, before the helper contacted Code.
    {starting, written_at} =
      Stream.repeatedly(fn ->
        receive do
          {:written, %{work_id: id} = record, at} when id == work.work_id -> {record, at}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.map(fn {record, at} -> {List.last(record.attempts), at} end)
      |> Enum.find(fn {attempt, _at} -> attempt.state == :starting end)

    assert %{folder: ^folder, preparing: true, prepare_pid: nil} = starting
    assert [%{at: first_contact} | _] = CodeStandIn.log(code)
    assert written_at < first_contact
    assert File.read!(Path.join([folder, "atlas", "README.md"])) == "base\n"
    assert CodeStandIn.archives(code) == ["atlas"]

    [%{turn_id: turn_id} = attempt] = done.attempts
    assert attempt.result.kind == :completed
    turn = turn(bench, turn_id)
    assert turn["cwd"] == folder
    assert turn["permissions"]["profile"] == "materialized-folder"
    assert turn["permissions"]["root"] == folder
    assert [%{"cwd" => ^folder}] = launches(bench)
    assert %{preparing: false, folder: ^folder} = private_attempt(bench.dir, work.work_id, 1)
    assert writable_bits(Path.join([folder, "atlas", "README.md"])) != 0

    # The stored request is the submitted one: no folder path in it, so a repeat is existing.
    assert %M.Base{base_id: base_id, permissions: :workspace_write} =
             record(bench, work.work_id).request.workspace

    assert base_id == code.id
    keyed = base_request(code, "keyed base", "workspace-write", %{client_key: "k1"})
    assert %F.Outcome.Accepted{work: keyed_work} = F.submit(client(), keyed)
    assert %F.Outcome.Existing{work: %{work_id: same}} = F.submit(client(), keyed)
    assert same == keyed_work.work_id

    assert %F.Outcome.Refused{reason: :conflict} =
             F.submit(client(), %{
               keyed
               | workspace: %{keyed.workspace | permissions: "read-only"}
             })

    # Not left preparing: its helper writes and seals under the home (CI run 44031687465).
    await_state(keyed_work.work_id, :completed)
  end

  test "read-only: the folder has no write bits and the turn runs with the read-only sandbox",
       %{bench: bench, code: code} do
    work = submit_base!(code, "complete read only", "read-only")
    [%{turn_id: turn_id}] = await_state(work.work_id, :completed).attempts
    folder = expected_folder(bench.dir, work.work_id)
    assert writable_bits(folder) == 0
    assert writable_bits(Path.join(folder, "atlas")) == 0
    assert writable_bits(Path.join([folder, "atlas", "README.md"])) == 0
    turn = turn(bench, turn_id)
    assert turn["cwd"] == folder
    assert turn["sandbox"] == "read-only"
    assert turn["permissions"] == nil
  end

  test "the Work server is not blocked while the helper waits on Code", %{
    bench: bench,
    code: code
  } do
    CodeStandIn.hold(code)
    work = submit_base!(code, "complete after a held archive")
    await(fn -> CodeStandIn.held?(code) end)

    # While the archive is held, the core answers and goes on beating: were it blocked on
    # the helper, neither a call nor a heartbeat would come before the release.
    for _ <- 1..5 do
      assert %F.Outcome.Found{work: %{state: :starting}} =
               F.get_work(client(), %{work_id: work.work_id})

      assert %F.Outcome.Capacity{} = F.capacity(client())
      heartbeats(1)
      assert CodeStandIn.held?(code)
    end

    assert launches(bench) == []

    pid =
      await(fn ->
        (attempt = private_attempt(bench.dir, work.work_id, 1)) && attempt.prepare_pid
      end)

    assert {_, 0} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)])
    CodeStandIn.release(code)
    await_state(work.work_id, :completed)
  end

  test "refusals at submit: a base_id that is no Code snapshot id, a permission the profile lacks, resume_from",
       %{bench: bench, code: code} do
    before = Path.wildcard(Path.join(bench.dir, "work/**"))

    for bad <- ["sha256:" <> String.duplicate("A", 64), "sha256:abc", "bas_123", code.id <> "0"] do
      request = base_request(code, "bad id")
      request = put_in(request.workspace.base_id, bad)

      assert %F.Outcome.Refused{reason: :invalid, detail: detail} = F.submit(client(), request)
      assert detail == "base_id must be a Code snapshot id until S5c"
    end

    assert %F.Outcome.Refused{reason: :invalid} =
             F.submit(
               client(),
               base_request(code, "resume into base", "read-only", %{
                 resume_from: "turn-0123456789abcdef"
               })
             )

    write_policy!(bench.dir, %{
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only"],
          "cost_classes" => ["standard"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
        }
      }
    })

    assert %F.Outcome.Refused{reason: :policy_forbids} =
             F.submit(client(), base_request(code, "no workspace-write"))

    assert Path.wildcard(Path.join(bench.dir, "work/**")) == before
    assert CodeStandIn.log(code) == []

    assert %F.Outcome.Accepted{work: accepted} =
             F.submit(client(), base_request(code, "complete ro", "read-only"))

    await_state(accepted.work_id, :completed)
  end

  test "Code answers 404 or is unreachable: failed: workspace, not retryable, no turn asked",
       %{bench: bench, code: code} do
    CodeStandIn.fail(code, 404)
    work = submit_base!(code, "complete never")
    [attempt] = await_state(work.work_id, :failed).attempts
    assert %{kind: :failed, reason: :workspace, retryable: false} = attempt.result
    refute File.exists?(expected_folder(bench.dir, work.work_id))

    CodeStandIn.unreachable!(bench.dir)
    other = submit_base!(code, "complete never either")
    [attempt] = await_state(other.work_id, :failed).attempts
    assert %{kind: :failed, reason: :workspace, retryable: false} = attempt.result
    assert attempt.quiescent
    assert launches(bench) == []
  end

  @tag work_options: [prepare_timeout_ms: 1_000]
  test "a preparation past prepare_timeout ends failed: workspace and its helper is killed",
       %{bench: bench, code: code} do
    CodeStandIn.hold(code)
    work = submit_base!(code, "complete never, held")

    pid =
      await(fn ->
        (attempt = private_attempt(bench.dir, work.work_id, 1)) && attempt.prepare_pid
      end)

    [attempt] = await_state(work.work_id, :failed).attempts
    assert %{kind: :failed, reason: :workspace, retryable: false} = attempt.result
    assert launches(bench) == []

    assert {_, status} =
             System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    assert status != 0
    CodeStandIn.release(code)
  end

  test "cancel while preparing: cancelled once the preparer ends, and no turn is asked",
       %{bench: bench, code: code} do
    CodeStandIn.hold(code)
    work = submit_base!(code, "complete never, cancelled")
    await(fn -> CodeStandIn.held?(code) end)

    assert %F.Outcome.Cancelling{stage: :requested} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    assert %F.Outcome.Cancelling{} = F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    heartbeats(2)
    assert work!(work.work_id).state == :cancelling
    CodeStandIn.release(code)
    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.result.reason == :cancel
    assert attempt.quiescent
    heartbeats(3)
    assert launches(bench) == []
  end

  test "a max_duration deadline while preparing ends failed: time_limit, and no turn is asked",
       %{bench: bench, code: code} do
    write_policy!(bench.dir, %{
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only", "materialized-folder"],
          "cost_classes" => ["standard"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
          "limits" => %{"max_duration" => 1}
        }
      }
    })

    CodeStandIn.hold(code)
    work = submit_base!(code, "complete never, too slow")
    await_work(work.work_id, &(&1.state == :cancelling))

    assert [%{cancel_reason: :time_limit, cancel_stage: :requested}] =
             work!(work.work_id).attempts

    CodeStandIn.release(code)
    [attempt] = await_state(work.work_id, :failed).attempts
    assert attempt.result.reason == :time_limit
    heartbeats(3)
    assert launches(bench) == []
  end

  test "a restart while preparing: interrupted, retryable, not quiescent while the helper lives; a fresh retry waits for it",
       %{bench: bench, code: code} do
    CodeStandIn.hold(code)
    work = submit_base!(code, "complete after a restart")

    pid =
      await(fn ->
        (attempt = private_attempt(bench.dir, work.work_id, 1)) && attempt.prepare_pid
      end)

    await(fn -> CodeStandIn.held?(code) end)
    # The committed pid alone is not enough: the core commits it, then acknowledges it, and a
    # preparer whose owner dies before the acknowledgement kills its helper (`Folders`,
    # review S3), so the helper this test needs alive would be gone (CI run 44140354565). Stop
    # the core only once the preparer is past the handshake, waiting on its helper.
    await(&preparer_awaits_helper?/0)
    stop_work()
    # The probe is the process check (`kill -0`): an agent sandbox may deny `ps`, which the
    # default listing (`Restart.processes/0`) needs.
    start_work!(bench, probe: &__MODULE__.signal_probe/2)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    assert attempt.result.retryable
    refute attempt.quiescent
    assert %{preparing: false, prepare_pid: ^pid} = private_attempt(bench.dir, work.work_id, 1)
    assert {_, 0} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)])

    # Not prepared again at boot, and a fresh retry stays buffered while the helper lives.
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    heartbeats(5)
    assert [%{state: :interrupted}, %{state: :buffered}] = work!(work.work_id).attempts
    assert CodeStandIn.archives(code) == ["atlas"]
    assert launches(bench) == []

    # The old helper finishes; the probe sees it gone, then the retry rebuilds the folder.
    CodeStandIn.release(code)
    done = await_state(work.work_id, :completed)
    assert [%{quiescent: true}, %{state: :completed}] = done.attempts
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]
    assert [%{"cwd" => cwd}] = launches(bench)
    assert cwd == expected_folder(bench.dir, work.work_id)
  end

  # The window the test above now avoids, held open on purpose: the core dies after it
  # committed `prepare_pid` and before it acknowledged it. The preparer then kills its helper,
  # and the attempt is still not quiescent at boot: the pid is recorded, so only the probe's
  # proof that the helper is gone settles it, never the boot itself.
  @tag work_options: [after_write: &__MODULE__.hold_after_pid_commit/1]
  test "a core that dies between committing prepare_pid and acknowledging it: the helper is killed, and the boot is not quiescent until the probe proves it gone",
       %{bench: bench, code: code} do
    test = self()
    :persistent_term.put({__MODULE__, :test}, test)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :test}) end)

    CodeStandIn.hold(code)
    work = submit_base!(code, "complete after a lost acknowledgement")
    assert_receive {:pid_committed, core, pid}, 10_000
    # The core is held inside that commit: the preparer still waits for the acknowledgement.
    refute preparer_awaits_helper?()
    assert {_, 0} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)])

    preparers = preparers()
    assert preparers != []
    stop_work()
    refute Process.alive?(core)
    # The preparer saw its owner go and killed the helper (its own `:DOWN`, not a timer); it
    # ends once it has the helper's exit status, so the helper is reaped by then. (The core
    # is stopped: the harness's `await/1`, which wakes on the core, cannot serve here.)
    for preparer <- preparers, do: AtlasTestAwait.down(preparer)
    assert signal_probe(pid, nil) != :alive

    start_work!(bench,
      probe: &__MODULE__.signal_probe/2,
      after_write: fn record -> send(test, {:written, record, System.monotonic_time()}) end
    )

    # The boot's own commit: interrupted, retryable, and not quiescent, the pid being recorded.
    boot = await_written(work.work_id, &(&1.state == :interrupted))
    assert boot.result.retryable
    refute boot.quiescent
    assert %{preparing: false, prepare_pid: ^pid} = private_attempt(bench.dir, work.work_id, 1)

    # Then the heartbeat probe, which proves the helper gone, settles it.
    settled = await_written(work.work_id, &(&1.state == :interrupted and &1.quiescent))
    assert settled.result.retryable
    assert [%{state: :interrupted, quiescent: true}] = work!(work.work_id).attempts
    assert launches(bench) == []
    CodeStandIn.release(code)
  end

  # The first core's after_write: the commit that records a prepare_pid is held (as a
  # descheduled core would be) before the core acknowledges it to the preparer.
  def hold_after_pid_commit(record) do
    case List.last(record.attempts) do
      %{state: :starting, preparing: true, prepare_pid: pid} when is_integer(pid) ->
        send(:persistent_term.get({__MODULE__, :test}), {:pid_committed, self(), pid})
        Process.sleep(:infinity)

      _ ->
        :ok
    end
  end

  # The next record of `work_id` the core wrote whose current attempt matches `fun`.
  defp await_written(work_id, fun) do
    receive do
      {:written, %{work_id: ^work_id} = record, _at} ->
        attempt = List.last(record.attempts)
        if fun.(attempt), do: attempt, else: await_written(work_id, fun)
    after
      10_000 -> flunk("no matching write of #{work_id}")
    end
  end

  # The preparers (`Folders` frames on the stack) alive now.
  defp preparers do
    for pid <- Process.list(),
        {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(stack, &match?({AtlasRuntime.Work.Folders, _, _, _}, &1)),
        do: pid
  end

  # A preparer (`Folders`) waiting on its helper's port: past the prepare_pid handshake.
  defp preparer_awaits_helper? do
    Enum.any?(Process.list(), fn pid ->
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stack} ->
          Enum.any?(stack, &match?({AtlasRuntime.Work.Folders, _, _, _}, &1)) and
            Enum.any?(stack, &match?({AtlasRuntime.Workspaces, :collect, _, _}, &1))

        nil ->
          false
      end
    end)
  end

  test "retry resume: true continues in the same folder, without preparing it", %{
    bench: bench,
    code: code
  } do
    work = submit_base!(code, "complete then resume")
    [%{turn_id: turn_id}] = await_state(work.work_id, :completed).attempts
    await(fn -> turn(bench, turn_id)["session_id"] end)
    folder = expected_folder(bench.dir, work.work_id)
    # What the agent wrote, inside the base's root: a change outside every root fails the
    # resumed attempt's freeze (P7b, B10).
    File.write!(Path.join(folder, "atlas/a.txt"), "agent\n")

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})
    done = await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert [first, %{provenance: %{continues: ^turn_id}} = second] = done.attempts
    assert second.resume_point.conversation_id == first.resume_point.conversation_id
    assert [_, %{"resumed" => true, "cwd" => ^folder}] = launches(bench)
    assert File.read!(Path.join(folder, "atlas/a.txt")) == "agent\n"
    assert CodeStandIn.archives(code) == ["atlas"]
    assert %{folder: ^folder, preparing: false} = private_attempt(bench.dir, work.work_id, 2)
  end

  test "a slot id may not start with work-" do
    refute Identity.valid_worker_id?("work-x")
    refute Identity.valid_worker_id?("work-work-0123456789abcdef")
    assert Identity.valid_worker_id?("slot1")
    assert Identity.valid_worker_id?("worker-1")
    assert Identity.valid_worker_id?("work")
  end
end
