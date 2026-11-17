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

    for _ <- 1..5 do
      {micros, %F.Outcome.Found{work: %{state: :starting}}} =
        :timer.tc(fn -> F.get_work(client(), %{work_id: work.work_id}) end)

      assert micros < 200_000
      {micros, %F.Outcome.Capacity{}} = :timer.tc(fn -> F.capacity(client()) end)
      assert micros < 200_000
      Process.sleep(100)
    end

    assert launches(bench) == []
    pid = await(fn -> private_attempt(bench.dir, work.work_id, 1).prepare_pid end)
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

    assert %F.Outcome.Accepted{} =
             F.submit(client(), base_request(code, "complete ro", "read-only"))
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
    pid = await(fn -> private_attempt(bench.dir, work.work_id, 1).prepare_pid end)
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
    Process.sleep(200)
    assert work!(work.work_id).state == :cancelling
    CodeStandIn.release(code)
    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.result.reason == :cancel
    assert attempt.quiescent
    Process.sleep(300)
    assert launches(bench) == []
  end

  test "a max_duration deadline while preparing ends failed: time_limit, and no turn is asked",
       %{bench: bench, code: code} do
    write_policy!(bench.dir, %{
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only", "workspace-write"],
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
    Process.sleep(300)
    assert launches(bench) == []
  end

  test "a restart while preparing: interrupted, retryable, not quiescent while the helper lives; a fresh retry waits for it",
       %{bench: bench, code: code} do
    CodeStandIn.hold(code)
    work = submit_base!(code, "complete after a restart")
    pid = await(fn -> private_attempt(bench.dir, work.work_id, 1).prepare_pid end)
    await(fn -> CodeStandIn.held?(code) end)
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
    Process.sleep(500)
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

  test "retry resume: true continues in the same folder, without preparing it", %{
    bench: bench,
    code: code
  } do
    work = submit_base!(code, "complete then resume")
    [%{turn_id: turn_id}] = await_state(work.work_id, :completed).attempts
    await(fn -> turn(bench, turn_id)["session_id"] end)
    folder = expected_folder(bench.dir, work.work_id)
    # What the agent wrote (P7b's fake gains a write goal).
    File.write!(Path.join(folder, "a.txt"), "agent\n")

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})
    done = await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert [first, %{provenance: %{continues: ^turn_id}} = second] = done.attempts
    assert second.resume_point.conversation_id == first.resume_point.conversation_id
    assert [_, %{"resumed" => true, "cwd" => ^folder}] = launches(bench)
    assert File.read!(Path.join(folder, "a.txt")) == "agent\n"
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
