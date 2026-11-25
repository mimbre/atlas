defmodule AtlasFlow.WorkSource.UpgradeTest do
  # IS-Atlas-26: a Runtime's upgrade on its runtime_upgrade fact, served in every poll
  # answer until it ends, and where the Runtime is with it written back, step by step.
  # Through AtlasFlow.WorkSource on FakeFacts, as the configuration tests are.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Upgrade

  @mini {"mini", "ada"}

  setup do
    dir = Path.join(System.tmp_dir!(), "upgrade-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    L.start(dir)
  end

  defp upgrade(key \\ "RU-01", values) do
    FakeFacts.put(Upgrade.kind(), %{
      "key" => key,
      "values" => Map.merge(%{"build" => "b2", "state" => "open"}, values),
      "links" => %{Upgrade.relation() => ["mini"]},
      "version" => 1
    })
  end

  defp values(key \\ "RU-01"), do: FakeFacts.get(Upgrade.kind(), key)["values"]

  defp poll(changes \\ %{}) do
    input = Map.merge(%{L.poll_input("mini") | build: "b1"}, changes)
    {:polled, polled} = WorkSource.poll(@mini, input)
    polled
  end

  defp report(step, fields \\ %{}),
    do: %{upgrade: Map.merge(%{id: "RU-01", step: step, busy: [], mode: :draining}, fields)}

  test "served until done: drain, wait for the busy slot, update, verify after the restart" do
    upgrade(%{})

    # First served: where it starts from is recorded.
    assert poll().upgrade == %{id: "RU-01", build: "b2"}

    assert %{"step" => "draining", "from_build" => "b1", "from_incarnation" => "inc-1"} =
             values()

    # Waiting until the turn on dev1 ends: Control shows the busy slot.
    assert poll(report(:draining, %{busy: ["dev1"]})).upgrade.build == "b2"
    assert %{"step" => "draining", "busy" => "dev1"} = values()

    assert poll(report(:updating)).upgrade.id == "RU-01"
    assert values()["step"] == "updating"
    assert values()["busy"] in [nil, ""]

    # The restarted Runtime, on the new build, before it offers work: not done yet.
    restarted =
      Map.merge(report(:restarted, %{mode: :open}), %{build: "b2", incarnation: "inc-2"})

    assert poll(Map.put(restarted, :offer, %{})).upgrade.id == "RU-01"
    assert values()["step"] == "verifying"

    # It accepts work again: done, and no longer served.
    refute Map.has_key?(poll(restarted), :upgrade)
    assert %{"step" => "done", "state" => "ended", "incarnation" => "inc-2"} = values()
    refute Map.has_key?(poll(%{build: "b2", incarnation: "inc-2"}), :upgrade)
  end

  test "a failure the Runtime reports ends it with the step and reason" do
    upgrade(%{"step" => "updating", "from_build" => "b1", "from_incarnation" => "inc-1"})

    failed = report(:failed, %{failed_step: :update, reason: "fetch: HTTP 404", mode: :open})
    refute Map.has_key?(poll(failed), :upgrade)

    assert %{
             "step" => "failed",
             "state" => "ended",
             "failed_step" => "update",
             "reason" => "fetch: HTTP 404"
           } = values()
  end

  test "a Runtime that came back on another build fails at verify" do
    upgrade(%{"step" => "updating", "from_build" => "b1", "from_incarnation" => "inc-1"})

    restarted =
      Map.merge(report(:restarted, %{mode: :open}), %{build: "b1", incarnation: "inc-2"})

    refute Map.has_key?(poll(restarted), :upgrade)

    assert %{"step" => "failed", "failed_step" => "verify", "reason" => reason} = values()
    assert reason =~ "came back on build b1, not b2"
  end

  test "a Runtime already on the build is done at once" do
    upgrade(%{"build" => "b1"})
    refute Map.has_key?(poll(), :upgrade)
    assert %{"step" => "done", "reason" => "the Runtime already runs this build"} = values()
  end

  test "an ended upgrade, another Runtime's or a report for another id changes nothing" do
    upgrade("RU-01", %{"step" => "done", "state" => "ended"})
    refute Map.has_key?(poll(), :upgrade)
    assert values()["step"] == "done"

    upgrade("RU-02", %{"step" => "draining", "from_incarnation" => "inc-1"})
    assert poll(report(:updating)).upgrade.id == "RU-02"
    assert values("RU-02")["step"] == "draining"

    {:polled, polled} = WorkSource.poll({"other", "ada"}, L.poll_input("other"))
    refute Map.has_key?(polled, :upgrade)
  end

  test "no upgrade: the poll is answered as before" do
    polled = poll()
    refute Map.has_key?(polled, :upgrade)
    assert Map.has_key?(polled, :timing)
  end
end
