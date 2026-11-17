defmodule AtlasRuntime.Sources.SelfFencingTest do
  @moduledoc """
  M2 A2, sleep-safe self-fencing (decision §5.3 item 2, F2; W4's `LeaseClock` in the puller):
  a lease not renewed for `lease_ttl` gets the cancel stages at the next check, and its late
  `ended` is never uploaded. The lease's age is the larger of the monotonic and the
  wall-clock time since the send time of its last successful poll, read from an injected
  clock: a sleep (wall clock on, monotonic still) fences, and so does a backward wall jump;
  a reply that comes late renews only from when its poll was sent. The fence check never
  waits on I/O (Main's round 2): a hung import or report of another lease does not delay it,
  nor does a local work source that does not answer (the cancel goes to the executor), and a
  fenced lease's own task is killed. A restarted puller keeps each lease's last real renewal
  (P3); one the core does not know is fenced conservatively. A lease is accepted before
  its import, which runs under the lease's renewal and is fenced like running work; its
  held attempt holds its slot only while that import runs (Main's #330 F5).
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{Puller, Rights}
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)
  # The source's lease_ttl (900 s), as the puller takes it from `timing`.
  @ttl 900_000

  setup ctx do
    bench =
      start!(%{
        "sources" => [
          %{
            "name" => @name,
            "kind" => "remote",
            "url" => "https://flow-test.example/",
            "credential_file" => "sources/flow-test/token",
            "priority" => 1,
            "max_slots" => 2,
            "max_store_bytes" => 2_147_483_648
          }
        ]
      })

    source = Source.start(name: @name)
    Source.use(source)

    Source.add_base_work(source, %{
      work_key: "task-1",
      title: "task-1",
      instructions: "hang",
      profile: "light_work",
      cost_class: :standard,
      input: %{
        permissions: :"workspace-write"
      }
    })

    {:ok, clock} = Agent.start_link(fn -> {0, 0} end)
    target = FakeSourceTarget.new(source)

    opts =
      [
        name: @name,
        target: target,
        clock: fn -> Agent.get(clock, & &1) end,
        tick: :manual,
        polling: :manual
      ] ++ Map.get(ctx, :puller_opts, [])

    puller = start_supervised!({Puller, opts})

    # Leased at {0, 0}, recorded, running, and reported started.
    assert :polled = Puller.poll_now(puller)
    assert %B.Outcome.Works{works: [%{work_id: work_id}]} = B.list_work(@client, %{})
    await_state(work_id, :running, @client)
    assert :ok = Puller.check_now(puller)
    [lease_id] = Map.keys(Puller.leases(puller))

    %{
      bench: bench,
      source: source,
      clock: clock,
      target: target,
      opts: opts,
      puller: puller,
      work_id: work_id,
      lease_id: lease_id
    }
  end

  # The executor's own record (never through the work facade, whose implementation is the
  # local source's process).
  defp attempts(client \\ @client, work_id) do
    assert %B.Outcome.Found{work: %{attempts: attempts}} =
             AtlasRuntime.Work.get_work(client, %B.GetWorkInput{work_id: work_id})

    attempts
  end

  defp move(clock, mono, sys), do: Agent.update(clock, fn {m, s} -> {m + mono, s + sys} end)

  defp phase(ctx), do: Puller.leases(ctx.puller)[ctx.lease_id].phase

  defp cancel_requested?(ctx) do
    assert [attempt] = attempts(ctx.work_id)
    attempt.timestamps.cancel_requested_at != nil
  end

  # Bounded: a puller that waits on a hung call fails the test instead of hanging it.
  defp check!(ctx), do: GenServer.call(ctx.puller, :check_now, 5_000)

  # The puller stopped and started again with the same options (its clock included).
  defp restart!(ctx) do
    :ok = stop_supervised({Puller, @name})
    %{ctx | puller: start_supervised!({Puller, ctx.opts})}
  end

  defp reports(ctx), do: Agent.get(ctx.source, & &1.leases[ctx.lease_id].reports)

  test "sleep/wake: wall clock on by lease_ttl, monotonic still, polls failing: the next check fences, and the late end is not uploaded",
       ctx do
    FakeSourceTarget.hook(ctx.target, :poll, fn _call, _input -> {:error, :unreachable} end)
    # The machine sleeps: CLOCK_UPTIME_RAW stands still, the wall clock does not.
    move(ctx.clock, 0, @ttl)
    assert :error = Puller.poll_now(ctx.puller)
    refute cancel_requested?(ctx)

    assert :ok = Puller.check_now(ctx.puller)
    assert cancel_requested?(ctx)
    assert phase(ctx) == :fenced

    work =
      await_work(ctx.work_id, &(&1.state == :cancelled and hd(&1.attempts).quiescent), @client)

    assert hd(work.attempts).cancel_reason == :cancel

    # The source can be reached again: nothing more of the fenced lease is sent.
    FakeSourceTarget.hook(ctx.target, :poll, nil)
    assert :polled = Puller.poll_now(ctx.puller)
    assert :ok = Puller.check_now(ctx.puller)
    assert [%S.Accepted{}, %S.Started{}] = reports(ctx)
    assert %{holdings: []} = List.last(FakeSourceTarget.calls(ctx.target, :poll))
  end

  test "a backward wall jump does not keep a lease alive: the monotonic time fences", ctx do
    move(ctx.clock, @ttl, -3_600_000)
    assert :ok = Puller.check_now(ctx.puller)
    assert phase(ctx) == :fenced
    assert cancel_requested?(ctx)
  end

  test "a lease renewed by a poll is fenced exactly lease_ttl after that poll was sent", ctx do
    move(ctx.clock, 100_000, 100_000)
    assert :polled = Puller.poll_now(ctx.puller)

    move(ctx.clock, @ttl - 1, @ttl - 1)
    assert :ok = Puller.check_now(ctx.puller)
    assert phase(ctx) == :started
    refute cancel_requested?(ctx)

    move(ctx.clock, 1, 1)
    assert :ok = Puller.check_now(ctx.puller)
    assert phase(ctx) == :fenced
  end

  test "renewal by send time: a reply that comes late renews only from when its poll was sent",
       ctx do
    move(ctx.clock, 100_000, 100_000)

    # The answer takes lease_ttl to arrive.
    FakeSourceTarget.hook(ctx.target, :poll, fn call, _input ->
      answer = call.()
      move(ctx.clock, @ttl, @ttl)
      answer
    end)

    assert :polled = Puller.poll_now(ctx.puller)
    assert Puller.leases(ctx.puller)[ctx.lease_id].stamp == {100_000, 100_000}

    assert :ok = Puller.check_now(ctx.puller)
    assert phase(ctx) == :fenced
  end

  # Review dev1 finding 1: the fence's cancel goes to the executor, not through the work
  # facade, whose implementation is the local source's process. A local source that never
  # answers (a stand-in registered under its name) does not delay a remote lease's fence.
  test "a local source that does not answer: the remote lease is fenced at once, and the puller stays up",
       ctx do
    stand_in = spawn(fn -> receive do: (:stop -> :ok) end)
    true = Process.register(stand_in, AtlasRuntime.Sources.Local)
    on_exit(fn -> send(stand_in, :stop) end)

    move(ctx.clock, @ttl, @ttl)
    assert :ok = check!(ctx)
    assert phase(ctx) == :fenced
    assert cancel_requested?(ctx)
    assert Process.alive?(ctx.puller)
    assert Process.info(stand_in, :message_queue_len) == {:message_queue_len, 0}
  end

  # P3: a restart is no renewal. The core keeps each lease's last real renewal for the
  # source, and the restarted puller fences from it.
  describe "P3: a restarted puller" do
    test "keeps the last real renewal: fenced lease_ttl after it, with no poll since", ctx do
      move(ctx.clock, @ttl - 1, @ttl - 1)
      ctx = restart!(ctx)

      assert :ok = check!(ctx)
      refute phase(ctx) == :fenced
      refute cancel_requested?(ctx)
      assert Puller.leases(ctx.puller)[ctx.lease_id].stamp == {0, 0}

      move(ctx.clock, 1, 1)
      assert :ok = check!(ctx)
      assert phase(ctx) == :fenced
      assert cancel_requested?(ctx)
      assert FakeSourceTarget.calls(ctx.target, :poll) |> length() == 1
    end

    # The core knows no renewal of the lease (as after its own restart): it is unrenewed,
    # renewed only by a poll, and fenced when a poll fails first or none renews it within
    # the accept deadline of the start.
    test "a lease whose renewal the core does not know: a failing poll fences it", ctx do
      :ok = stop_supervised({Puller, @name})
      assert :ok = AtlasRuntime.Work.renewed(@name, nil, %{})
      ctx = %{ctx | puller: start_supervised!({Puller, ctx.opts})}
      assert Puller.leases(ctx.puller)[ctx.lease_id].stamp == :unrenewed

      assert :ok = check!(ctx)
      refute phase(ctx) == :fenced

      FakeSourceTarget.hook(ctx.target, :poll, fn _call, _input -> {:error, :unreachable} end)
      assert :error = Puller.poll_now(ctx.puller)
      assert phase(ctx) == :fenced
      assert cancel_requested?(ctx)
    end

    test "a lease whose renewal the core does not know: renewed by a poll, else fenced after the accept deadline",
         ctx do
      # Twice: first a poll renews it; then, after another such restart, none does.
      for renewed? <- [true, false] do
        :ok = stop_supervised({Puller, @name})
        assert :ok = AtlasRuntime.Work.renewed(@name, nil, %{})
        ctx = %{ctx | puller: start_supervised!({Puller, ctx.opts})}

        if renewed? do
          move(ctx.clock, 1_000, 1_000)
          assert :polled = Puller.poll_now(ctx.puller)
          assert Puller.leases(ctx.puller)[ctx.lease_id].stamp != :unrenewed
          move(ctx.clock, 30_000, 30_000)
          assert :ok = check!(ctx)
          refute phase(ctx) == :fenced
        else
          move(ctx.clock, 29_999, 29_999)
          assert :ok = check!(ctx)
          refute phase(ctx) == :fenced
          move(ctx.clock, 1, 1)
          assert :ok = check!(ctx)
          assert phase(ctx) == :fenced
          assert cancel_requested?(ctx)
        end
      end
    end
  end

  # Main's round 2 (2): the fence check never waits on I/O. A second lease's import, or its
  # report, hangs at the source (an injected hook that never answers); the running lease is
  # still fenced at the check that finds it lease_ttl old, on the injected clock.
  describe "round 2: the fence check never waits on I/O" do
    setup ctx do
      Source.add_base_work(
        ctx.source,
        %{
          work_key: "task-2",
          title: "task-2",
          instructions: "hang",
          profile: "light_work",
          cost_class: :standard,
          input: %{permissions: :"workspace-write"}
        },
        %{"slow.txt" => "slow\n"}
      )

      :ok
    end

    # A hook that tells the test it was called, from the task that called it, and never
    # answers.
    defp hang(tag) do
      test = self()

      fn _real, input ->
        send(test, {tag, self(), input})
        receive do: (:never -> {:error, :unreachable})
      end
    end

    # Main's #330 F5 (a), (b): accept first. The slow import's lease is accepted and that
    # accept recorded before anything is imported; it holds its own slot while its import
    # runs, is renewed by the polls like running work, and once fenced its import is killed
    # and its attempt never starts.
    test "a slow import keeps its lease through renewals; fenced, its import is killed and it never starts",
         ctx do
      FakeSourceTarget.hook(ctx.target, :get_blob, hang(:importing))
      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:importing, importer, {slow, _sha}}, 5_000

      # Accepted and recorded at the source before the import; the import runs in a task.
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)
      assert Puller.leases(ctx.puller)[slow].phase == :importing
      assert [%{lease_id: ^slow, kind: :import}] = Puller.jobs(ctx.puller)
      slow_work = Puller.leases(ctx.puller)[slow].work_id

      assert [%{work_id: ^slow_work, held: true, importing: true}] =
               Enum.filter(AtlasRuntime.Work.holdings(@name), &(&1.lease_id == slow))

      # Its held attempt holds its own slot (of max_slots 2, the running lease the other).
      assert AtlasRuntime.Work.offer(@name) == %{}
      assert :ok = AtlasRuntime.Work.offer_done(@name, 0)

      # Renewed by a poll like running work: past the first lease_ttl it is not fenced.
      move(ctx.clock, @ttl - 1, @ttl - 1)
      assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      assert %{holdings: held} = List.last(FakeSourceTarget.calls(ctx.target, :poll))
      assert slow in Enum.map(held, & &1.lease_id)
      move(ctx.clock, 2, 2)
      assert :ok = check!(ctx)
      assert Puller.leases(ctx.puller)[slow].phase == :importing
      assert Process.alive?(importer)

      # No renewal for lease_ttl (the import's own deadline is further off): fenced, the
      # import killed, and the attempt never starts.
      move(ctx.clock, @ttl, @ttl)
      assert :ok = check!(ctx)
      assert Puller.leases(ctx.puller)[slow].phase == :fenced
      refute Process.alive?(importer)
      assert Puller.jobs(ctx.puller) == []
      assert :polled = Task.await(poll, 5_000)

      assert [%{state: :cancelled, result: %{never_started: true}} = attempt] =
               attempts(slow_work)

      assert is_nil(attempt.timestamps.running_at)
      # An import answer that came now would not start it either.
      late = %{baseline_id: "sha256:" <> String.duplicate("a", 64), change_set: nil}
      assert :not_pending = AtlasRuntime.Work.lease_imported(slow_work, {:ok, late})
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)
    end

    test "a slow import past its own deadline: the accepted attempt ends failed, never started; its slot is free",
         ctx do
      FakeSourceTarget.hook(ctx.target, :get_blob, hang(:importing))
      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:importing, importer, {slow, _sha}}, 5_000
      slow_work = Puller.leases(ctx.puller)[slow].work_id

      # Renewed, so only the import's deadline (below the grace: lease_ttl + 2 min) ends it.
      for _ <- 1..2 do
        move(ctx.clock, 60_000, 60_000)
        assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      end

      move(ctx.clock, @ttl, @ttl)
      assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      assert :ok = check!(ctx)
      refute Process.alive?(importer)
      assert :polled = Task.await(poll, 5_000)

      assert [%{state: :failed, result: %{never_started: true}}] = attempts(slow_work)

      assert [%S.Accepted{}, %S.Ended{result: %{kind: :failed, never_started: true}}] =
               Agent.get(ctx.source, & &1.leases[slow].reports)

      # F5 (a): nothing is held for the source once that import is over.
      assert AtlasRuntime.Work.offer(@name) == %{"light_work" => 1}
      assert :ok = AtlasRuntime.Work.offer_done(@name, 0)
    end

    test "a slow report: the running lease is fenced on time; the hung report is dropped with its lease",
         ctx do
      FakeSourceTarget.hook(ctx.target, :report, hang(:reporting))
      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:reporting, reporter, %{lease_id: slow, report: %{state: :accepted}}}, 5_000

      # The report runs in a task of its own; the puller answers meanwhile.
      assert [%{lease_id: ^slow, kind: :report}] = Puller.jobs(ctx.puller)
      assert Puller.leases(ctx.puller)[slow].phase == :accepting

      # lease_ttl after the poll was sent: fenced at this check, the report still hanging.
      move(ctx.clock, @ttl, @ttl)
      assert Process.alive?(reporter)
      assert :ok = check!(ctx)
      assert phase(ctx) == :fenced
      assert cancel_requested?(ctx)

      # The hung report's lease is not renewed either: fenced, its task killed, its attempt
      # never released.
      assert Puller.leases(ctx.puller)[slow].phase in [:fenced, :lost]
      refute Process.alive?(reporter)
      assert Puller.jobs(ctx.puller) == []
      assert :polled = Task.await(poll, 5_000)

      slow_work = Puller.leases(ctx.puller)[slow].work_id

      assert %B.Outcome.Found{work: %{attempts: [attempt]}} =
               B.get_work(@client, %{work_id: slow_work})

      assert is_nil(attempt.timestamps.running_at)
    end

    # Review dev1 finding 3 (V2): the fence kills the fenced lease's own task. Its `started`
    # report hangs, and the report deadline is far off, so only the fence can end it.
    @tag puller_opts: [report_timeout_ms: 10 * @ttl]
    test "a fenced lease's own hung report is killed by the fence; the source gets nothing more of it",
         ctx do
      test = self()
      first = ctx.lease_id

      FakeSourceTarget.hook(ctx.target, :report, fn real, input ->
        case input do
          %{lease_id: id, report: %{state: :started}} when id != first ->
            send(test, {:reporting, self(), input})
            receive do: (:never -> {:error, :unreachable})

          _ ->
            real.()
        end
      end)

      assert :polled = Puller.poll_now(ctx.puller)
      [slow] = Map.keys(Puller.leases(ctx.puller)) -- [first]
      await_state(Puller.leases(ctx.puller)[slow].work_id, :running, @client)

      check = Task.async(fn -> Puller.check_now(ctx.puller) end)
      assert_receive {:reporting, reporter, %{lease_id: ^slow}}, 5_000
      assert [%{lease_id: ^slow, kind: :report}] = Puller.jobs(ctx.puller)

      move(ctx.clock, @ttl, @ttl)
      assert :ok = check!(ctx)
      assert Puller.leases(ctx.puller)[slow].phase == :fenced
      refute Process.alive?(reporter)
      assert Puller.jobs(ctx.puller) == []
      assert :ok = Task.await(check, 5_000)
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)
    end

    # Review dev1 finding 4 (V8): a lease being imported keeps its slot on the start path
    # too. A direct submit (Deviation 2: no local source runs here) is admitted, but does
    # not start in that slot; the lease runs once imported.
    test "a direct submit while a lease imports does not start in its slot; the lease runs once imported",
         ctx do
      test = self()

      FakeSourceTarget.hook(ctx.target, :get_blob, fn real, input ->
        send(test, {:importing, self(), input})
        receive do: (:go -> real.())
      end)

      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:importing, importer, {slow, _sha}}, 5_000

      assert %B.Outcome.Accepted{work: %{work_id: direct}} =
               B.submit(client(), request(ctx.bench, "hang direct"))

      assert [%{state: :buffered, slot: nil}] = attempts(client(), direct)

      FakeSourceTarget.hook(ctx.target, :get_blob, nil)
      send(importer, :go)
      assert :polled = Task.await(poll, 5_000)

      leased = Puller.leases(ctx.puller)[slow].work_id
      await_state(leased, :running, @client)
      assert [%{state: :buffered, slot: nil}] = attempts(client(), direct)
    end
  end

  # Main's #330 round 3, dev2's findings 2 and 3, on the injected clock. A second lease
  # (task-2) has an input to import; its import is held by a hook.
  describe "round 3: an accepted lease's import and its age" do
    setup ctx do
      Source.add_base_work(
        ctx.source,
        %{
          work_key: "task-2",
          title: "task-2",
          instructions: "hang",
          profile: "light_work",
          cost_class: :standard,
          input: %{permissions: :"workspace-write"}
        },
        %{"slow.txt" => "slow\n"}
      )

      :ok
    end

    # The import's get_blob tells the test it was called and waits for `:go` (or never).
    defp held_import(ctx) do
      test = self()

      FakeSourceTarget.hook(ctx.target, :get_blob, fn real, input ->
        send(test, {:importing, self(), input})
        receive do: (:go -> real.())
      end)
    end

    # The leases each poll answer carried, sent to the test.
    defp tell_leases(ctx) do
      test = self()

      FakeSourceTarget.hook(ctx.target, :poll, fn call, _input ->
        {:polled, polled} = answer = call.()
        send(test, {:leased, polled.leases})
        answer
      end)
    end

    # Finding 2: the puller restarts 40 s into the import (past the 30 s accept deadline).
    # The lease is restored as accepted and importing: renewed, fenced as usual, never
    # given up for its accept deadline; delivered again, it is imported and runs once.
    test "a restart 40 s into an import keeps the lease accepted and importing; it runs once delivered again",
         ctx do
      tell_leases(ctx)
      held_import(ctx)
      poll = Task.async(fn -> catch_exit(Puller.poll_now(ctx.puller)) end)
      assert_receive {:importing, _importer, {slow, _sha}}, 5_000
      assert_received {:leased, leases}
      redelivered = Enum.find(leases, &(&1.lease_id == slow))
      slow_work = Puller.leases(ctx.puller)[slow].work_id
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)

      # 40 s on, a poll renews it; then the puller restarts.
      move(ctx.clock, 40_000, 40_000)
      assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      ctx = restart!(ctx)
      Task.await(poll, 5_000)

      assert %{phase: :importing, stamp: {40_000, 40_000}} = Puller.leases(ctx.puller)[slow]
      assert :ok = check!(ctx)
      assert Puller.leases(ctx.puller)[slow].phase == :importing

      # Still renewed by the polls and kept, 40 s more.
      move(ctx.clock, 40_000, 40_000)
      assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      assert %{holdings: held} = List.last(FakeSourceTarget.calls(ctx.target, :poll))
      assert slow in Enum.map(held, & &1.lease_id)
      assert :ok = check!(ctx)
      assert Puller.leases(ctx.puller)[slow].phase == :importing

      assert [%{work_id: ^slow_work, held: true, importing: true, ran: false}] =
               Enum.filter(AtlasRuntime.Work.holdings(@name), &(&1.lease_id == slow))

      assert [%{state: :buffered} = attempt] = attempts(slow_work)
      assert is_nil(attempt.timestamps.cancel_requested_at)

      # The source delivers it again: imported now, released, and it runs as one attempt.
      FakeSourceTarget.hook(ctx.target, :get_blob, nil)

      FakeSourceTarget.hook(ctx.target, :poll, fn call, _input ->
        {:polled, polled} = call.()
        {:polled, %{polled | leases: [redelivered | polled.leases]}}
      end)

      assert :polled = GenServer.call(ctx.puller, :poll_now, 5_000)
      assert Puller.leases(ctx.puller)[slow].phase in [:released, :started]
      await_state(slow_work, :running, @client)
      assert [_one] = attempts(slow_work)
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)
    end

    # Finding 3: the import answers after lease_ttl and the grace (a sleep: no check or poll
    # ran meanwhile). The lease is fenced at that answer; its work never starts.
    test "an import that answers after lease_ttl and the grace never starts its work", ctx do
      held_import(ctx)
      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:importing, importer, {slow, _sha}}, 5_000
      slow_work = Puller.leases(ctx.puller)[slow].work_id

      move(ctx.clock, @ttl + 120_000 + 1, @ttl + 120_000 + 1)
      FakeSourceTarget.hook(ctx.target, :get_blob, nil)
      send(importer, :go)
      assert :polled = Task.await(poll, 5_000)

      assert Puller.leases(ctx.puller)[slow].phase == :fenced

      assert [%{state: :cancelled, result: %{never_started: true}} = attempt] =
               attempts(slow_work)

      assert is_nil(attempt.timestamps.running_at)
      assert [%S.Accepted{}] = Agent.get(ctx.source, & &1.leases[slow].reports)
    end

    # The same rule where the accept's answer is what releases: recorded after lease_ttl
    # (its report took that long), the lease is fenced, and nothing is imported or started.
    test "an accept recorded after lease_ttl is fenced: nothing is imported, its work never starts",
         ctx do
      FakeSourceTarget.hook(ctx.target, :report, fn real, input ->
        answer = real.()
        if input.report.state == :accepted, do: move(ctx.clock, @ttl, @ttl)
        answer
      end)

      assert :polled = Puller.poll_now(ctx.puller)
      [slow] = Map.keys(Puller.leases(ctx.puller)) -- [ctx.lease_id]
      slow_work = Puller.leases(ctx.puller)[slow].work_id

      assert Puller.leases(ctx.puller)[slow].phase == :fenced
      assert for({^slow, _sha} <- FakeSourceTarget.calls(ctx.target, :get_blob), do: 1) == []
      assert Puller.jobs(ctx.puller) == []

      assert [%{state: :cancelled, result: %{never_started: true}} = attempt] =
               attempts(slow_work)

      assert is_nil(attempt.timestamps.running_at)
    end
  end
end
