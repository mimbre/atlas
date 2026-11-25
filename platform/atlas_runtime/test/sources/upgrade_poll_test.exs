defmodule AtlasRuntime.Sources.UpgradePollTest do
  @moduledoc """
  IS-Atlas-26 over the puller: an upgrade the source orders in a poll answer is carried
  out within that poll (drain, the update command once per upgrade, resume), and every
  later poll reports it (mode, busy slots, what the update command recorded) until an
  answer comes without one. After a restart, a new puller reports the upgrade
  `update.json` names from its first poll on. A poll carries no `upgrade` while there is
  none.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.{Upgrade, Work}
  alias AtlasRuntime.Sources.Puller
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source

  @moduletag capture_log: true

  @name "flow-test"

  @source %{
    "name" => @name,
    "kind" => "remote",
    "url" => "https://flow-test.example/",
    "credential_file" => "sources/flow-test/token",
    "priority" => 1,
    "max_slots" => 2,
    "max_store_bytes" => 2_147_483_648
  }

  setup do
    bench = start!(%{"sources" => [@source]})
    source = Source.start(name: @name)
    Source.use(source)
    target = FakeSourceTarget.new(source)
    test = self()

    # The update command: records itself running, as --detach does, and tells the test.
    spawn = fn executable, args, env ->
      {"ATLAS_RUNTIME_HOME", home} = List.keyfind(env, "ATLAS_RUNTIME_HOME", 0)
      id = Enum.at(args, Enum.find_index(args, &(&1 == "--upgrade")) + 1)

      File.write!(
        Upgrade.path(home),
        JSON.encode!(%{"upgrade" => id, "state" => "running", "step" => "update"})
      )

      send(test, {:update, executable, args})
      :ok
    end

    %{bench: bench, target: target, puller: puller(target, spawn), spawn: spawn}
  end

  defp puller(target, spawn, id \\ :puller) do
    start_supervised!(
      {Puller,
       name: @name, target: target, tick: :manual, polling: :manual, upgrade: [spawn: spawn]},
      id: id
    )
  end

  # Every next answer carries `order` (nil: none).
  defp order(target, order) do
    FakeSourceTarget.hook(target, :poll, fn call, _input ->
      {:polled, polled} = call.()
      {:polled, if(order, do: Map.put(polled, :upgrade, order), else: polled)}
    end)
  end

  defp last_poll(target), do: target |> FakeSourceTarget.calls(:poll) |> List.last()

  test "drain, update once, resume, and the report until the upgrade ends", ctx do
    assert :polled = Puller.poll_now(ctx.puller)
    refute Map.has_key?(last_poll(ctx.target), :upgrade)

    order(ctx.target, %{id: "RU-01", build: "b2", action: :drain})
    assert :polled = Puller.poll_now(ctx.puller)
    assert Work.runtime().mode == :draining

    assert :polled = Puller.poll_now(ctx.puller)

    assert %{id: "RU-01", mode: :draining, busy: [], update: :none} =
             last_poll(ctx.target).upgrade

    # The update command runs once for the upgrade, however often it is ordered.
    order(ctx.target, %{id: "RU-01", build: "b2", action: :update})
    assert :polled = Puller.poll_now(ctx.puller)

    assert_received {:update, _executable,
                     ["service", "update", "--build", "b2", "--upgrade", "RU-01", "--detach"]}

    assert :polled = Puller.poll_now(ctx.puller)
    refute_received {:update, _, _}
    assert %{update: :running, step: :update} = last_poll(ctx.target).upgrade

    # It refused: reported with its reason.
    File.write!(
      Upgrade.path(ctx.bench.dir),
      JSON.encode!(%{
        "upgrade" => "RU-01",
        "state" => "refused",
        "step" => "update",
        "reason" => "slot busy: dev1"
      })
    )

    assert :polled = Puller.poll_now(ctx.puller)
    assert %{update: :refused, reason: "slot busy: dev1"} = last_poll(ctx.target).upgrade

    order(ctx.target, %{id: "RU-01", build: "b2", action: :resume})
    assert :polled = Puller.poll_now(ctx.puller)
    assert Work.runtime().mode == :open

    # The source ended it: update.json goes, and so does the report.
    order(ctx.target, nil)
    assert :polled = Puller.poll_now(ctx.puller)
    refute File.exists?(Upgrade.path(ctx.bench.dir))
    assert :polled = Puller.poll_now(ctx.puller)
    refute Map.has_key?(last_poll(ctx.target), :upgrade)
  end

  test "after a restart the first poll reports the upgrade update.json names", ctx do
    stop_supervised!(:puller)

    File.write!(
      Upgrade.path(ctx.bench.dir),
      JSON.encode!(%{
        "upgrade" => "RU-07",
        "build" => "b2",
        "state" => "installed",
        "step" => "restart"
      })
    )

    puller = puller(ctx.target, ctx.spawn, :restarted)
    assert :polled = Puller.poll_now(puller)
    assert %{id: "RU-07", update: :installed, step: :restart} = last_poll(ctx.target).upgrade
  end
end
