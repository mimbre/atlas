defmodule AtlasFlow.WorkSource.UpgradeTest do
  # IS-Atlas-26: a supervised Runtime upgrade, moved on one poll at a time and ordered in
  # the poll answer: drain, wait until no slot is busy, update, verify after the restart.
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

  defp upgrade(key, values \\ %{}) do
    FakeFacts.put(Upgrade.kind(), %{
      "key" => key,
      "values" => Map.merge(%{"build" => "b2", "step" => "requested"}, values),
      "links" => %{Upgrade.relation() => ["mini"]},
      "version" => 1
    })
  end

  defp values(key \\ "RU-01"), do: FakeFacts.get(Upgrade.kind(), key)["values"]

  # A poll of the Runtime on `build` in `incarnation`, reporting `report` for RU-01.
  defp poll(opts \\ []) do
    input = %{
      L.poll_input("mini", [], Keyword.get(opts, :offer, %{"deep_coding" => 1}))
      | build: Keyword.get(opts, :build, "b1"),
        incarnation: Keyword.get(opts, :incarnation, "inc-1")
    }

    input =
      case Keyword.get(opts, :report) do
        nil ->
          input

        report ->
          Map.put(input, :upgrade, Map.merge(%{id: "RU-01", busy: [], update: :none}, report))
      end

    {:polled, polled} = WorkSource.poll(@mini, input)
    polled[:upgrade]
  end

  test "drain, wait while a slot is busy, update, verify the restart, done" do
    upgrade("RU-01")

    assert %{id: "RU-01", build: "b2", action: :drain} = poll()
    assert %{"step" => "draining", "from_build" => "b1", "from_incarnation" => "inc-1"} = values()

    # A turn still runs: the upgrade waits, naming the slot.
    assert %{action: :drain} = poll(report: %{mode: :draining, busy: ["dev1"]})
    assert %{"step" => "waiting", "busy" => "dev1"} = values()
    assert %{action: :drain} = poll(report: %{mode: :draining, busy: ["dev1"]})
    assert values()["step"] == "waiting"

    # The turn ended: update.
    assert %{action: :update} = poll(report: %{mode: :draining, busy: []})
    assert values()["step"] == "updating"
    assert values()["busy"] in [nil, ""]
    assert %{action: :update} = poll(report: %{mode: :draining, update: :running})

    # Back from its restart, on the release, still draining: resume.
    assert %{action: :resume} =
             poll(
               build: "b2",
               incarnation: "inc-2",
               report: %{mode: :draining, update: :installed}
             )

    assert %{"step" => "verifying", "incarnation" => "inc-2"} = values()

    assert %{action: :resume} =
             poll(build: "b2", incarnation: "inc-2", report: %{mode: :draining})

    # Open, offering its slots: it accepts work again.
    assert nil == poll(build: "b2", incarnation: "inc-2", report: %{mode: :open})
    assert values()["step"] == "done"
    assert nil == poll(build: "b2", incarnation: "inc-2")
  end

  test "open but offering nothing is not yet verified" do
    upgrade("RU-01", %{
      "step" => "verifying",
      "from_incarnation" => "inc-1",
      "incarnation" => "inc-2"
    })

    assert %{action: :resume} =
             poll(build: "b2", incarnation: "inc-2", offer: %{}, report: %{mode: :open})

    assert values()["step"] == "verifying"
  end

  test "a refused update ends it failed, with the step and the Runtime's reason" do
    upgrade("RU-01", %{"step" => "updating", "from_incarnation" => "inc-1"})

    assert nil ==
             poll(
               report: %{
                 mode: :draining,
                 update: :refused,
                 step: :update,
                 reason: "slot busy: dev2"
               }
             )

    assert %{"step" => "failed", "failed_step" => "update", "reason" => "slot busy: dev2"} =
             values()
  end

  test "back on another build ends it failed at restart" do
    upgrade("RU-01", %{"step" => "updating", "from_incarnation" => "inc-1"})

    assert nil == poll(build: "b1", incarnation: "inc-2", report: %{mode: :draining})
    assert %{"step" => "failed", "failed_step" => "restart", "reason" => reason} = values()
    assert reason =~ "came back on build b1, not b2"
  end

  test "a second upgrade of the same Runtime is refused while one runs" do
    upgrade("RU-01")
    upgrade("RU-02", %{"build" => "b3"})

    assert %{id: "RU-01", action: :drain} = poll()

    assert %{"step" => "failed", "failed_step" => "start", "reason" => reason} = values("RU-02")
    assert reason =~ "RU-01 is in progress"
    assert values("RU-01")["step"] == "draining"
  end

  test "no upgrade, or only ended ones: the poll is answered as before" do
    assert nil == poll()
    upgrade("RU-01", %{"step" => "done"})
    assert nil == poll()
  end
end
