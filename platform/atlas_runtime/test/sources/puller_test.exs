defmodule AtlasRuntime.Sources.PullerTest do
  @moduledoc """
  M2 A2, the puller (decision §5.2, §5.3 items 1 and 5; M2 plan A2): over M1's in-BEAM
  target on the in-test source, with the real executor. A lease is accepted, held until the
  source recorded it, then run, and reported started and ended; an accept that is late,
  lost or never recorded never starts; a lease taken over after a restart (and delivered
  again) runs once; the source's cancel runs the cancel stages; a full, paused or draining
  Runtime keeps polling with an empty offer; and the service starts a puller per source of
  the policy, `local` alone when it names none (Main's A6 Q2). The same over HTTPS with
  W3's transport and credential.

  Polls and checks are driven by the test (`polling: :manual`, `tick: :manual`), on an
  injected clock.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{Credential, HttpTarget, Puller, Rights}
  alias AtlasRuntime.Test.{FakeSourceTarget, WorkSourceRest}
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.TLSFixtures
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)

  defp sources(max_slots),
    do: %{
      "sources" => [
        %{
          "name" => @name,
          "kind" => "remote",
          "url" => "https://flow-test.example/",
          "credential_file" => "sources/flow-test/token",
          "priority" => 1,
          "max_slots" => max_slots,
          "max_store_bytes" => 2_147_483_648
        }
      ]
    }

  setup context do
    bench = start!(sources(Map.get(context, :max_slots, 2)))
    source = Source.start(name: @name)
    Source.use(source)
    {:ok, clock} = Agent.start_link(fn -> {0, 0} end)

    %{
      bench: bench,
      source: source,
      clock: clock,
      target: FakeSourceTarget.new(source)
    }
  end

  defp puller!(ctx, opts \\ []) do
    clock = ctx.clock
    {id, opts} = Keyword.pop_lazy(opts, :id, &make_ref/0)

    opts =
      Keyword.merge(
        [
          name: @name,
          target: ctx.target,
          clock: fn -> Agent.get(clock, & &1) end,
          tick: :manual,
          polling: :manual
        ],
        opts
      )
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    start_supervised!({Puller, opts}, id: id)
  end

  defp add(ctx, key, instructions, permissions \\ :"workspace-write") do
    Source.add_base_work(ctx.source, %{
      work_key: key,
      title: key,
      instructions: instructions,
      profile: "light_work",
      cost_class: :standard,
      input: %{
        permissions: permissions
      }
    })
  end

  defp states(source, key) do
    id = Source.current(source, key) || last_lease(source, key)
    for report <- Agent.get(source, & &1.leases[id].reports), do: report.__struct__
  end

  defp last_lease(source, key) do
    Agent.get(source, fn s ->
      case s.leases |> Map.values() |> Enum.filter(&(&1.work.work_key == key)) do
        [] -> nil
        leases -> leases |> Enum.max_by(& &1.offered_at) |> Map.get(:id)
      end
    end)
  end

  defp only_work(source_client \\ @client) do
    assert %B.Outcome.Works{works: [work]} = B.list_work(source_client, %{})
    work
  end

  defp phase(puller), do: puller |> Puller.leases() |> Map.values() |> Enum.map(& &1.phase)

  # Fails the report `state`, until cleared.
  defp fail_report(target, state) do
    FakeSourceTarget.hook(target, :report, fn call, input ->
      if input.report.state == state, do: {:error, :unreachable}, else: call.()
    end)
  end

  test "a lease is accepted, recorded, then run; started and ended (with its blobs) reach the source",
       ctx do
    add(ctx, "task-1", "write atlas/a.txt alpha")
    puller = puller!(ctx)

    assert :polled = Puller.poll_now(puller)
    assert [S.Accepted] = states(ctx.source, "task-1")

    work =
      await_work(
        only_work().work_id,
        &(&1.state == :completed and hd(&1.attempts).quiescent),
        @client
      )

    assert length(work.attempts) == 1

    assert :ok = Puller.check_now(puller)
    assert [S.Accepted, S.Started, S.Ended] = states(ctx.source, "task-1")
    assert Map.has_key?(Source.blobs(ctx.source), Source.sha256("alpha\n"))
    assert phase(puller) == [:done]
  end

  test "the attempt does not start before the source recorded its accept", ctx do
    add(ctx, "task-1", "hang")
    fail_report(ctx.target, :accepted)
    puller = puller!(ctx)

    assert :polled = Puller.poll_now(puller)
    assert [%{held: true, state: :buffered}] = Work.holdings(@name)
    Process.sleep(300)
    assert %{state: :buffered, attempts: [%{turn_id: nil}]} = only_work()

    FakeSourceTarget.hook(ctx.target, :report, nil)
    assert :ok = Puller.check_now(puller)
    assert [S.Accepted] = states(ctx.source, "task-1")
    await_launch(ctx.bench, only_work(), 1, @client)
  end

  test "an accept not recorded within the accept deadline is given up: never started", ctx do
    add(ctx, "task-1", "hang")
    fail_report(ctx.target, :accepted)
    puller = puller!(ctx)
    assert :polled = Puller.poll_now(puller)

    Agent.update(ctx.clock, fn {m, s} -> {m + 29_999, s + 29_999} end)
    assert :ok = Puller.check_now(puller)
    assert [%{held: true, state: :buffered}] = Work.holdings(@name)

    Agent.update(ctx.clock, fn {m, s} -> {m + 1, s + 1} end)
    assert :ok = Puller.check_now(puller)

    assert %{state: :cancelled, attempts: [%{result: %{never_started: true}}]} = only_work()
    assert phase(puller) == [:lost]
  end

  test "an accepted the source answers lease_lost (after its deadline) never starts", ctx do
    add(ctx, "task-1", "hang")

    FakeSourceTarget.hook(ctx.target, :report, fn call, input ->
      if input.report.state == :accepted, do: Source.advance(ctx.source, 31)
      call.()
    end)

    puller = puller!(ctx)
    assert :polled = Puller.poll_now(puller)

    assert %{state: :cancelled, attempts: [%{result: %{never_started: true}}]} = only_work()
    assert phase(puller) == [:lost]
  end

  test "a lease taken over after a restart, and delivered again, runs one attempt", ctx do
    add(ctx, "task-1", "hang")
    fail_report(ctx.target, :accepted)
    test = self()

    FakeSourceTarget.hook(ctx.target, :poll, fn call, _input ->
      {:polled, polled} = answer = call.()
      send(test, {:leased, polled.leases})
      answer
    end)

    puller = puller!(ctx, id: :first)
    assert :polled = Puller.poll_now(puller)
    assert_received {:leased, [%{lease_id: lease_id} = redelivered]}
    assert [%{lease_id: ^lease_id}] = Work.holdings(@name)

    # The Runtime restarts: the core and the puller; the attempt stays held.
    stop_supervised!(:first)
    stop_work()
    start_work!(ctx.bench)
    assert [%{lease_id: ^lease_id, held: true}] = Work.holdings(@name)

    # The source delivers the same lease again.
    FakeSourceTarget.hook(ctx.target, :poll, fn call, _input ->
      {:polled, polled} = call.()
      {:polled, %{polled | leases: [redelivered | polled.leases]}}
    end)

    FakeSourceTarget.hook(ctx.target, :report, nil)
    puller = puller!(ctx)
    assert :ok = Puller.check_now(puller)
    assert :polled = Puller.poll_now(puller)

    work = await_state(only_work().work_id, :running, @client)
    assert length(work.attempts) == 1
    assert [S.Accepted] = states(ctx.source, "task-1")
    assert length(Work.holdings(@name)) == 1
  end

  test "the source's cancel runs the cancel stages, and the cancelled end is reported", ctx do
    add(ctx, "task-1", "hang")
    puller = puller!(ctx)
    assert :polled = Puller.poll_now(puller)
    work_id = only_work().work_id
    await_state(work_id, :running, @client)
    assert :ok = Puller.check_now(puller)

    Source.cancel(ctx.source, "task-1")
    assert :polled = Puller.poll_now(puller)
    work = await_work(work_id, &(&1.state == :cancelled and hd(&1.attempts).quiescent), @client)

    assert %{cancel_reason: :cancel, timestamps: %{cancel_requested_at: %DateTime{}}} =
             hd(work.attempts)

    assert :ok = Puller.check_now(puller)

    assert [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :cancelled}}] =
             reports(ctx.source, "task-1")
  end

  @tag max_slots: 1
  test "when full, the poll goes on with an empty offer and renews what it holds", ctx do
    add(ctx, "task-1", "hang")
    puller = puller!(ctx)
    assert :polled = Puller.poll_now(puller)
    [%{lease_id: lease_id}] = Work.holdings(@name)
    await_launch(ctx.bench, only_work(), 1, @client)

    Source.advance(ctx.source, 600)
    Agent.update(ctx.clock, fn {m, s} -> {m + 600_000, s + 600_000} end)
    assert :polled = Puller.poll_now(puller)

    assert %{offer: offer, holdings: [%{lease_id: ^lease_id}]} =
             List.last(FakeSourceTarget.calls(ctx.target, :poll))

    assert offer == %{}
    assert Agent.get(ctx.source, & &1.leases[lease_id].expires_at) == 600 + 900
    assert %{^lease_id => %{stamp: {600_000, 600_000}}} = Puller.leases(puller)
  end

  @tag max_slots: 1
  test "a full Runtime's open poll is sent again with the new offer as soon as a slot frees",
       ctx do
    add(ctx, "task-1", "write atlas/a.txt one")
    add(ctx, "task-2", "write atlas/b.txt two")

    # A source that holds a poll with an empty offer open, as a long poll does (≤ poll_max).
    FakeSourceTarget.hook(ctx.target, :poll, fn call, input ->
      if input.offer == %{}, do: Process.sleep(60_000)
      call.()
    end)

    puller!(ctx, tick: 50, polling: :auto, min_poll_ms: 20)

    # task-1 runs and ends; its slot frees while the empty-offer poll is open.
    await(fn -> match?([_ | _], for(%S.Ended{} <- reports(ctx.source, "task-1"), do: 1)) end)
    await(fn -> Source.current(ctx.source, "task-2") != nil end)
    # task-1's offer, then the one sent when its slot freed: well before the open poll's end.
    offers = for %{offer: offer} <- FakeSourceTarget.calls(ctx.target, :poll), do: offer
    assert Enum.count(offers, &(&1 == %{"light_work" => 1})) >= 2
  end

  test "paused: an empty offer, renewals go on; draining: a held lease ends returned", ctx do
    add(ctx, "task-1", "hang")
    puller = puller!(ctx)
    assert :polled = Puller.poll_now(puller)
    await_state(only_work().work_id, :running, @client)

    Work.set_mode(:paused, "test")
    add(ctx, "task-2", "hang")
    Agent.update(ctx.clock, fn {m, s} -> {m + 1_000, s + 1_000} end)
    assert :polled = Puller.poll_now(puller)
    assert %{offer: offer, holdings: [_]} = List.last(FakeSourceTarget.calls(ctx.target, :poll))
    assert offer == %{}
    assert Enum.all?(Map.values(Puller.leases(puller)), &(&1.stamp == {1_000, 1_000}))

    # Open again: task-2 is leased, but its accept is not recorded yet when the drain begins.
    Work.set_mode(:open, "test")
    fail_report(ctx.target, :accepted)
    assert :polled = Puller.poll_now(puller)
    Work.set_mode(:draining, "test")

    FakeSourceTarget.hook(ctx.target, :report, nil)
    assert :ok = Puller.check_now(puller)

    assert [%S.Accepted{}, %S.Ended{result: %{kind: :returned, never_started: true}}] =
             reports(ctx.source, "task-2")
  after
    Work.set_mode(:open, "test")
  end

  test "the service starts pullers after the work core; without sources, local's only" do
    script = File.read!(Path.expand("../../host/service.exs", __DIR__))

    [work, sources, ready] =
      for text <- [
            "AtlasRuntime.Work.start_link(dir)",
            "AtlasRuntime.Sources.Supervisor.start_link(dir)",
            ~s(IO.puts("Runtime ready)
          ],
          do: script |> :binary.match(text) |> elem(0)

    assert work < sources and sources < ready

    dir = Path.join(System.tmp_dir!(), "a2-sup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # An explicit empty list names no source: nothing starts.
    write_policy!(dir, %{"sources" => []})
    assert AtlasRuntime.Sources.Supervisor.start_link(dir) == :ignore
    assert AtlasRuntime.Sources.Supervisor.sources(dir) == []

    # Main's A6 Q2: no `sources` is `local` alone (priority 1, every slot), and no remote
    # source: the local source and its puller start, nothing else.
    write_policy!(dir)

    assert [%{"name" => "local", "kind" => "builtin"}] =
             AtlasRuntime.Sources.Supervisor.sources(dir)

    assert {:ok, sup} = AtlasRuntime.Sources.Supervisor.start_link(dir)

    assert [AtlasRuntime.Sources.Local, {AtlasRuntime.Sources.Puller, "local"}] ==
             sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    Supervisor.stop(sup)

    write_policy!(dir, %{
      "sources" => [
        %{
          "name" => "local",
          "kind" => "builtin",
          "priority" => 1,
          "max_slots" => 1,
          "max_store_bytes" => 1
        }
      ]
    })

    # The count the service reports includes the builtin `local`.
    assert [%{"name" => "local"}] = AtlasRuntime.Sources.Supervisor.sources(dir)
    assert script =~ "length(AtlasRuntime.Sources.Supervisor.sources(dir))"

    # M2 A5: the builtin entry starts the local work source and its puller.
    assert {:ok, sup} = AtlasRuntime.Sources.Supervisor.start_link(dir)

    assert [AtlasRuntime.Sources.Local, {AtlasRuntime.Sources.Puller, "local"}] ==
             sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    Supervisor.stop(sup)
  end

  test "over HTTPS, with W3's transport and the source's credential: leased, run and reported",
       ctx do
    token = "a2." <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    File.mkdir_p!(Path.join([ctx.bench.dir, "sources", @name]))
    File.chmod!(Path.join(ctx.bench.dir, "sources"), 0o700)
    File.write!(Credential.path(ctx.bench.dir, @name), token <> "\n")
    File.chmod!(Credential.path(ctx.bench.dir, @name), 0o600)

    pki = TLSFixtures.pki("localhost")
    source = ctx.source

    handler = fn conn ->
      Source.use(source)

      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> ^token] ->
          conn
          |> Plug.Conn.assign(:client, {"mini", [:lease]})
          |> WorkSourceRest.call(WorkSourceRest.init([]))

        _ ->
          WorkSourceRest.__problem__(:unauthenticated, conn)
      end
    end

    server = start_supervised!(TLSFixtures.serve_spec(handler, pki))
    url = "https://localhost:#{TLSFixtures.port(server)}"
    ca = TLSFixtures.cacertfile(pki, ctx.bench.dir)

    add(ctx, "task-1", "complete", :"read-only")

    puller =
      puller!(ctx,
        target: nil,
        open: {HttpTarget, :open, [@name, url, ctx.bench.dir, [cacertfile: ca]]}
      )

    assert :polled = Puller.poll_now(puller)
    work_id = only_work().work_id
    await_work(work_id, &(&1.state == :completed and hd(&1.attempts).quiescent), @client)

    assert :ok = Puller.check_now(puller)

    assert [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}] =
             reports(source, "task-1")

    assert phase(puller) == [:done]
  end

  defp reports(source, key) do
    case Source.current(source, key) || last_lease(source, key) do
      nil -> []
      id -> Agent.get(source, & &1.leases[id].reports)
    end
  end
end
