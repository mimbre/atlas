defmodule AtlasRuntime.Sources.SelfFencingTest do
  @moduledoc """
  M2 A2, sleep-safe self-fencing (decision §5.3 item 2, F2; W4's `LeaseClock` in the puller):
  a lease not renewed for `lease_ttl` gets the cancel stages at the next check, and its late
  `ended` is never uploaded. The lease's age is the larger of the monotonic and the
  wall-clock time since the send time of its last successful poll, read from an injected
  clock: a sleep (wall clock on, monotonic still) fences, and so does a backward wall jump;
  a reply that comes late renews only from when its poll was sent. The fence check never
  waits on I/O (Main's round 2): a hung import or report of another lease does not delay it.
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

  setup do
    _bench =
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

    puller =
      start_supervised!(
        {Puller,
         name: @name,
         target: target,
         clock: fn -> Agent.get(clock, & &1) end,
         tick: :manual,
         polling: :manual}
      )

    # Leased at {0, 0}, recorded, running, and reported started.
    assert :polled = Puller.poll_now(puller)
    assert %B.Outcome.Works{works: [%{work_id: work_id}]} = B.list_work(@client, %{})
    await_state(work_id, :running, @client)
    assert :ok = Puller.check_now(puller)
    [lease_id] = Map.keys(Puller.leases(puller))

    %{
      source: source,
      clock: clock,
      target: target,
      puller: puller,
      work_id: work_id,
      lease_id: lease_id
    }
  end

  defp move(clock, mono, sys), do: Agent.update(clock, fn {m, s} -> {m + mono, s + sys} end)

  defp phase(ctx), do: Puller.leases(ctx.puller)[ctx.lease_id].phase

  defp cancel_requested?(ctx) do
    assert %B.Outcome.Found{work: %{attempts: [attempt]}} =
             B.get_work(@client, %{work_id: ctx.work_id})

    attempt.timestamps.cancel_requested_at != nil
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

    # Bounded: a puller that waits on a hung call fails the test instead of hanging it.
    defp check!(ctx), do: GenServer.call(ctx.puller, :check_now, 5_000)

    test "a slow import: the running lease is fenced on time; the import's deadline refuses its lease",
         ctx do
      FakeSourceTarget.hook(ctx.target, :get_blob, hang(:importing))
      poll = Task.async(fn -> Puller.poll_now(ctx.puller) end)
      assert_receive {:importing, importer, {slow, _sha}}, 5_000

      # The import runs in a task of its own; the puller answers meanwhile.
      assert [%{lease_id: ^slow, kind: :import}] = Puller.jobs(ctx.puller)

      # Its slot stays promised to this source after the poll is over: of max_slots 2, the
      # running lease holds one and the import the other, so nothing more is offered.
      assert AtlasRuntime.Work.offer(@name) == %{}
      assert :ok = AtlasRuntime.Work.offer_done(@name, 0)

      # lease_ttl after the poll was sent: fenced at this check, the import still hanging.
      move(ctx.clock, @ttl, @ttl)
      assert :ok = check!(ctx)
      assert phase(ctx) == :fenced
      assert cancel_requested?(ctx)
      assert Process.alive?(importer)

      # The import's deadline is below the grace (lease_ttl + 2 min): at lease_ttl + 2 min the
      # task is killed and the lease refused; no work is created for it.
      move(ctx.clock, 120_000, 120_000)
      assert :ok = check!(ctx)
      refute Process.alive?(importer)
      assert Puller.jobs(ctx.puller) == []
      assert :polled = Task.await(poll, 5_000)

      assert [%S.Refused{reason: :too_large}] =
               Agent.get(ctx.source, & &1.leases[slow].reports)

      assert %B.Outcome.Works{works: [%{work_id: work_id}]} = B.list_work(@client, %{})
      assert work_id == ctx.work_id
      refute Map.has_key?(Puller.leases(ctx.puller), slow)
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
  end
end
