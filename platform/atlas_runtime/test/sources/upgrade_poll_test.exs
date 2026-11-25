defmodule AtlasRuntime.Sources.UpgradePollTest do
  @moduledoc """
  IS-Atlas-26 over the puller: an upgrade the source serves drains the Runtime, waits
  while a slot is busy (each poll naming it), runs the update command once no slot is
  busy, and after the restart (a new incarnation on the served build) opens the Runtime
  again and reports it restarted. A failed update is reported with its step and the
  Runtime opened again. The update command here is a fake that records its arguments.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.{Upgrade, Work}
  alias AtlasRuntime.Boundary.Work, as: W
  alias AtlasRuntime.Sources.Puller
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source

  @moduletag capture_log: true

  @name "flow-test"
  @order %{id: "RU-01", build: "b2"}

  @source %{
    "name" => @name,
    "kind" => "remote",
    "url" => "https://flow-test.example/",
    "credential_file" => "sources/flow-test/token",
    "priority" => 1,
    "max_slots" => 2,
    "max_store_bytes" => 2_147_483_648
  }

  # The built-in local source too, so a hand-started work can keep a slot busy.
  @local %{
    "name" => "local",
    "kind" => "builtin",
    "priority" => 2,
    "max_slots" => 2,
    "max_store_bytes" => 2_147_483_648
  }

  setup do
    bench = start!(%{"sources" => [@source, @local]})

    start_supervised!(%{
      id: :local_source,
      type: :supervisor,
      start:
        {AtlasRuntime.Sources.Supervisor, :start_link,
         [bench.dir, [puller: [tick: 50, min_poll_ms: 20, retry_ms: 20]]]}
    })

    source = Source.start(name: @name)
    Source.use(source)
    target = FakeSourceTarget.new(source)

    puller =
      start_supervised!(
        {Puller, name: @name, target: target, tick: :manual, polling: :manual},
        id: make_ref()
      )

    # The update command: records its arguments, and answers as update --detach does.
    calls = Path.join(bench.dir, "update-calls")
    update = Path.join(bench.dir, "bin/fake-update")

    File.write!(update, """
    #!/bin/sh
    echo "$@" >> '#{calls}'
    echo '{"update":"started","pid":1}'
    """)

    File.chmod!(update, 0o755)
    previous = System.get_env("ATLAS_RUNTIME_BUILD")
    Application.put_env(:atlas_runtime, :update_command, update)

    on_exit(fn ->
      Application.delete_env(:atlas_runtime, :update_command)

      if previous,
        do: System.put_env("ATLAS_RUNTIME_BUILD", previous),
        else: System.delete_env("ATLAS_RUNTIME_BUILD")
    end)

    serving = Agent.start_link(fn -> @order end) |> elem(1)

    FakeSourceTarget.hook(target, :poll, fn call, _input ->
      {:polled, polled} = call.()

      case Agent.get(serving, & &1) do
        nil -> {:polled, polled}
        order -> {:polled, Map.put(polled, :upgrade, order)}
      end
    end)

    %{bench: bench, target: target, puller: puller, calls: calls, serving: serving}
  end

  defp last_poll(target), do: target |> FakeSourceTarget.calls(:poll) |> List.last()

  defp kept(dir) do
    case File.read(Path.join(dir, "upgrade.json")) do
      {:ok, data} -> JSON.decode!(data)
      _ -> nil
    end
  end

  # Polls until the step is reached: an answer that comes while the last step's task still
  # runs takes no step of its own (the next poll's does).
  defp poll(ctx, step) do
    await(
      fn ->
        assert :polled = Puller.poll_now(ctx.puller)
        match?(%{"step" => ^step}, kept(ctx.bench.dir))
      end,
      "upgrade step #{step}"
    )
  end

  defp calls(ctx), do: if(File.exists?(ctx.calls), do: File.read!(ctx.calls), else: "")

  test "drain, wait for the busy slot, update, restart, open again", ctx do
    work = submit!(ctx.bench, "hang on s2", %{slot: "s2"}, client("c1", [:choose_slot]))
    await_launch(ctx.bench, work)

    poll(ctx, "draining")
    assert Work.runtime().mode == :draining

    # Each poll says what it waits for; the update does not run while s2 is busy.
    assert :polled = Puller.poll_now(ctx.puller)

    assert last_poll(ctx.target).upgrade ==
             %{id: "RU-01", step: :draining, busy: ["s2"], mode: :draining}

    assert calls(ctx) == ""

    # The turn ends: the update command runs, once.
    W.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await(fn -> Enum.all?(Work.runtime().slots, fn {_, busy} -> not busy end) end, "idle slots")
    poll(ctx, "updating")
    assert calls(ctx) == "update --build b2 --detach\n"
    incarnation = Work.runtime().incarnation
    assert kept(ctx.bench.dir)["incarnation"] == incarnation

    assert :polled = Puller.poll_now(ctx.puller)
    assert %{step: :updating, busy: []} = last_poll(ctx.target).upgrade

    # The update restarted the Runtime on the released build: a new incarnation.
    stop_work()
    System.put_env("ATLAS_RUNTIME_BUILD", "b2")
    start_work!(ctx.bench)
    assert Work.runtime().runtime_build == "b2"
    refute Work.runtime().incarnation == incarnation

    poll(ctx, "restarted")
    assert Work.runtime().mode == :open
    assert :polled = Puller.poll_now(ctx.puller)

    assert %{step: :restarted, mode: :open, build: "b2"} =
             Map.put(last_poll(ctx.target).upgrade, :build, last_poll(ctx.target).build)

    # Whether it offers work again is the source's check (the local source's puller here
    # may hold the free slots in its own open poll at this moment).
    assert calls(ctx) == "update --build b2 --detach\n"

    # The source verified it and serves it no more: the record goes.
    Agent.update(ctx.serving, fn _ -> nil end)
    assert :polled = Puller.poll_now(ctx.puller)
    await(fn -> kept(ctx.bench.dir) == nil end, "upgrade.json removed")
    assert :polled = Puller.poll_now(ctx.puller)
    refute Map.has_key?(last_poll(ctx.target), :upgrade)
  end

  test "a failed update is reported with its step, and the Runtime opened again", ctx do
    poll(ctx, "updating")
    assert Work.runtime().mode == :draining

    File.write!(
      Path.join(ctx.bench.dir, "update.json"),
      JSON.encode!(%{
        "state" => "failed",
        "step" => "fetch",
        "error" => "fetch: #{ctx.bench.dir}/releases: HTTP 404"
      })
    )

    poll(ctx, "failed")
    assert Work.runtime().mode == :open
    assert :polled = Puller.poll_now(ctx.puller)

    assert %{step: :failed, failed_step: :update, mode: :open, reason: reason} =
             last_poll(ctx.target).upgrade

    assert reason == "fetch: <runtime home>/releases: HTTP 404"
  end

  test "a Runtime that came back on another build fails at restart", ctx do
    poll(ctx, "updating")
    stop_work()
    start_work!(ctx.bench)

    poll(ctx, "failed")
    assert %{"failed_step" => "restart", "reason" => reason} = kept(ctx.bench.dir)
    assert reason =~ "came back on build"
    assert Work.runtime().mode == :open
  end

  test "not served while draining: no step, so a resume by hand holds", ctx do
    work = submit!(ctx.bench, "hang on s2", %{slot: "s2"}, client("c1", [:choose_slot]))
    await_launch(ctx.bench, work)
    poll(ctx, "draining")

    # Ended at the source: it serves it no more, and the slot is free again.
    Agent.update(ctx.serving, fn _ -> nil end)
    W.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await(fn -> Enum.all?(Work.runtime().slots, fn {_, busy} -> not busy end) end, "idle slots")
    Work.set_mode(:open, "local:test")

    for _ <- 1..3, do: assert(:polled = Puller.poll_now(ctx.puller))
    assert Work.runtime().mode == :open
    assert kept(ctx.bench.dir)["step"] == "draining"
    assert calls(ctx) == ""
  end

  test "another source's answers neither report nor move it", ctx do
    poll(ctx, "updating")
    assert Upgrade.report(ctx.bench.dir, "local") == nil
    assert :ok = Upgrade.served(ctx.bench.dir, "local", nil)
    assert kept(ctx.bench.dir)["step"] == "updating"
  end
end
