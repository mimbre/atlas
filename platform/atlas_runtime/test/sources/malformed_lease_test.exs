defmodule AtlasRuntime.Sources.MalformedLeaseTest do
  @moduledoc """
  The lease security fix (M2 assembly A, after A2): a lease that is not exactly the
  `work_source` contract's shape (an optional field missing, a field of a wrong type,
  undeclared fields, or no lease at all) is refused structurally.
  - It is not accepted: no work record, no holding.
  - The source is told `refused(invalid)`, the contract's own outcome, when the lease has an
    id to answer under.
  - The puller and the work core stay up, and the next well-formed lease runs.
  - Nothing the lease carries appears in the log.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import ExUnit.CaptureLog

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{Puller, Rights}
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)

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
    target = FakeSourceTarget.new(source)

    puller =
      start_supervised!({Puller, name: @name, target: target, tick: :manual, polling: :manual})

    sentinel = "SENTINEL-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    Source.add_base_work(source, %{
      work_key: "task-1",
      title: sentinel,
      instructions: sentinel,
      profile: "light_work",
      cost_class: :standard,
      input: %{
        permissions: :"read-only"
      }
    })

    %{source: source, target: target, puller: puller, sentinel: sentinel}
  end

  # The contract's structs as plain maps (DateTime stays a value), as a test bends them.
  defp plain(%DateTime{} = at), do: at
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(%{} = map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(v), do: v

  # The source's first lease reaches the puller as `bend` makes it.
  defp bend(target, bend) do
    FakeSourceTarget.hook(target, :poll, fn call, _input ->
      {:polled, polled} = call.()
      {:polled, %{polled | leases: Enum.map(polled.leases, &bend.(plain(&1)))}}
    end)
  end

  defp reports(source, lease_id), do: Agent.get(source, & &1.leases[lease_id].reports)

  # Refused structurally: nothing accepted, the source told, both processes up, and nothing
  # of the lease in the log.
  defp assert_refused(ctx, bend) do
    core = GenServer.whereis(Work.Server)
    bend(ctx.target, bend)

    log = capture_log(fn -> assert :polled = Puller.poll_now(ctx.puller) end)

    assert Work.holdings(@name) == []
    assert %B.Outcome.Works{works: []} = B.list_work(@client, %{})
    assert [%S.Refused{reason: :invalid}] = reports(ctx.source, "flow-test-lease-1")
    assert Process.alive?(ctx.puller)
    assert GenServer.whereis(Work.Server) == core
    assert log =~ "malformed lease"
    refute log =~ ctx.sentinel
    refute log =~ "flow-test-lease-1"
    log
  end

  # The next lease, well formed, is accepted and runs.
  defp assert_next_runs(ctx) do
    FakeSourceTarget.hook(ctx.target, :poll, nil)

    Source.add_base_work(ctx.source, %{
      work_key: "task-2",
      title: "next",
      instructions: "next",
      profile: "light_work",
      cost_class: :standard,
      input: %{
        permissions: :"read-only"
      }
    })

    assert :polled = Puller.poll_now(ctx.puller)
    assert [%{lease_id: "flow-test-lease-2", held: false}] = Work.holdings(@name)
  end

  test "a missing optional field (after_check) is refused invalid, not a crash", ctx do
    log = assert_refused(ctx, &update_in(&1.work, fn work -> Map.delete(work, :after_check) end))
    assert log =~ "missing_field at lease.work.after_check"
    assert_next_runs(ctx)
  end

  test "a field of a wrong type is refused invalid", ctx do
    # The enum as text, as a source that does not speak the contract would send it.
    log = assert_refused(ctx, &put_in(&1.work.input.permissions, "workspace-write"))
    assert log =~ "wrong_type at lease.work.input.permissions"
    assert_next_runs(ctx)
  end

  test "a field of a wrong shape (a text for the after-check's argv) is refused invalid", ctx do
    assert_refused(ctx, &put_in(&1.work.after_check, %{command: "rm -rf /", timeout: nil}))
    assert_next_runs(ctx)
  end

  test "undeclared fields are refused invalid, and their names and values are not logged", ctx do
    # The local source's own fields, which no remote lease may carry (C1).
    folder = "/etc/" <> ctx.sentinel

    log =
      assert_refused(ctx, fn lease ->
        lease
        |> put_in([:work, :folder], folder)
        |> Map.put(:slot, ctx.sentinel)
      end)

    assert log =~ "undeclared_field"
    refute log =~ "folder"
    refute log =~ "/etc/"
    assert_next_runs(ctx)
  end

  test "a lease with no usable id is dropped: no work, nothing reported, both processes up",
       ctx do
    core = GenServer.whereis(Work.Server)
    bend(ctx.target, fn _lease -> %{work: ctx.sentinel} end)

    log = capture_log(fn -> assert :polled = Puller.poll_now(ctx.puller) end)

    assert Work.holdings(@name) == []
    assert reports(ctx.source, "flow-test-lease-1") == []
    assert Process.alive?(ctx.puller) and GenServer.whereis(Work.Server) == core
    assert log =~ "without a usable lease_id"
    refute log =~ ctx.sentinel
  end

  test "the executor refuses anything that is not a lease as invalid, and stays up" do
    core = GenServer.whereis(Work.Server)

    for bad <- [nil, "lease", 42, [], %{}, %{lease_id: "x"}, %{lease_id: 1, work: %{}}] do
      assert Work.accept_lease(@name, bad) == {:refused, :invalid}
    end

    assert GenServer.whereis(Work.Server) == core
    assert %B.Outcome.Works{works: []} = B.list_work(@client, %{})
  end
end
