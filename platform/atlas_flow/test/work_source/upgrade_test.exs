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

  # The Engine passes over the hints of Flow's own writes: Delivery (whose Engine here is
  # the test process) has the upgrade's run reconciled on each step it records, and only then.
  test "each recorded step has the upgrade's run reconciled" do
    upgrade("RU-01")

    assert %{action: :drain} = poll()
    assert_received {:"$gen_cast", {:reconcile, "runtime_upgrade", "RU-01"}}

    assert %{action: :drain} = poll()
    refute_received {:"$gen_cast", {:reconcile, _, _}}

    assert %{action: :update} = poll(report: %{mode: :draining, busy: []})
    assert_received {:"$gen_cast", {:reconcile, "runtime_upgrade", "RU-01"}}
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

  test "a refused update resumes the old Runtime before ending failed" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    report = %{mode: :draining, update: :refused, step: :update, reason: "slot busy: dev2"}
    assert %{action: :resume} = poll(report: report)

    assert %{"step" => "updating", "failed_step" => "update", "reason" => "slot busy: dev2"} =
             values()

    assert %{action: :resume} = poll(report: report)
    assert nil == poll(report: %{mode: :open, update: :refused})

    assert %{"step" => "failed", "failed_step" => "update", "reason" => "slot busy: dev2"} =
             values()
  end

  test "a wrong restart stays pending until the old build returns and opens" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    assert nil == poll(build: "b3", incarnation: "inc-2", report: %{mode: :draining})
    assert %{"step" => "updating", "failed_step" => "restart", "reason" => reason} = values()
    assert reason =~ "came back on build b3, not b2"
    assert nil == poll(build: "b1", incarnation: "inc-1", report: %{mode: :draining})

    assert %{action: :resume} =
             poll(build: "b1", incarnation: "inc-3", report: %{mode: :draining})

    assert nil == poll(build: "b1", incarnation: "inc-3", report: %{mode: :open})
    assert values()["step"] == "failed"
  end

  test "failure intent must be stored before resume and is retried" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    report = %{mode: :draining, update: :failed, step: :update, reason: "download"}
    :ok = GenServer.call(FakeFacts, {:refuse_write, Upgrade.kind(), "RU-01"})
    assert %{action: :drain} = poll(report: report)
    refute values()["failed_step"]
    :ok = GenServer.call(FakeFacts, {:allow_write, Upgrade.kind(), "RU-01"})
    assert %{action: :resume} = poll(report: report)
    assert values()["failed_step"] == "update"
  end

  test "a lost failure write acknowledgement cannot resume before durable intent" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    FakeFacts.lose_ack(Upgrade.kind())
    report = %{mode: :draining, update: :failed, step: :update, reason: "download"}
    assert %{action: :drain} = poll(report: report)
    assert values()["failed_step"] == "update"
    assert %{action: :resume} = poll(report: report)
  end

  test "unreadable Facts keeps an old draining Runtime's failure report alive" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    query = %{"linked" => %{Upgrade.relation() => "mini"}, "plain" => true}
    :ok = GenServer.call(FakeFacts, {:block_read, Upgrade.kind(), query})
    report = %{mode: :draining, update: :failed, step: :update, reason: "download"}
    assert %{id: "RU-01", build: "b1", action: :drain} = poll(report: report)
    refute values()["failed_step"]
    assert nil == poll(report: %{mode: :open, update: :failed})
    assert nil == poll(report: %{mode: :draining, update: :running})
    assert nil == poll(build: "", report: report)
    :ok = GenServer.call(FakeFacts, {:allow_read, Upgrade.kind(), query})
    assert %{action: :resume} = poll(report: report)
    assert values()["failed_step"] == "update"
  end

  test "an updating run with no report cannot blindly reissue the update" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    assert nil == poll()
    assert values()["step"] == "updating"
  end

  test "a lost terminal acknowledgement cannot leave a recovered Runtime drained" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1",
      "failed_step" => "update",
      "reason" => "download"
    })

    FakeFacts.lose_ack(Upgrade.kind())
    assert %{action: :resume} = poll(report: %{mode: :open, update: :failed})
    assert values()["step"] == "failed"
    assert nil == poll(report: %{mode: :open})
  end

  test "an already open old Runtime records failure before ending" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1"
    })

    assert %{action: :resume} = poll(report: %{mode: :open, update: :failed, step: :update})
    assert %{"step" => "updating", "failed_step" => "update"} = values()
    assert nil == poll(report: %{mode: :open, update: :failed})
    assert values()["step"] == "failed"
  end

  test "missing or unknown failure step never authorizes recovery" do
    for {key, report} <- [
          {"RU-01", %{mode: :draining, update: :failed}},
          {"RU-02", %{mode: :draining, update: :failed, step: :unexpected}}
        ] do
      upgrade(key, %{
        "step" => "updating",
        "from_build" => "b1",
        "from_incarnation" => "inc-1"
      })

      assert nil == poll(report: Map.put(report, :id, key))
      assert %{"step" => "updating", "failed_step" => "unknown"} = values(key)
      assert nil == poll(report: %{id: key, mode: :draining})
      upgrade(key, %{"step" => "failed"})
    end
  end

  test "a failure reported during verification waits for the old build" do
    upgrade("RU-01", %{
      "step" => "verifying",
      "from_build" => "b1",
      "from_incarnation" => "inc-1",
      "incarnation" => "inc-2"
    })

    assert nil ==
             poll(
               build: "b2",
               incarnation: "inc-2",
               report: %{mode: :draining, update: :failed, step: :restart, reason: "restart"}
             )

    assert %{"step" => "verifying", "failed_step" => "restart"} = values()
    assert %{action: :resume} = poll(incarnation: "inc-3", report: %{mode: :draining})
    assert nil == poll(incarnation: "inc-3", report: %{mode: :open})
    assert values()["step"] == "failed"
  end

  test "recovery never resumes without matching build, incarnation and report" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1",
      "failed_step" => "update",
      "reason" => "download"
    })

    assert nil == poll(build: "b3", report: %{mode: :draining})
    assert nil == poll(incarnation: "", report: %{mode: :draining})
    assert nil == poll(report: %{id: "RU-02", mode: :stopping})
    assert %{action: :drain} = poll()
    assert nil == poll(report: %{mode: :stopping})
    assert %{action: :resume} = poll(report: %{mode: :draining})
  end

  test "a persisted recovery marker never reruns the update" do
    upgrade("RU-01", %{
      "step" => "updating",
      "from_build" => "b1",
      "from_incarnation" => "inc-1",
      "failed_step" => "update",
      "reason" => "download"
    })

    # A restarted puller may have lost the order; re-establish its mode report first.
    assert %{action: :drain} = poll()
    assert %{action: :resume} = poll(report: %{mode: :draining, update: :none})
    assert %{action: :resume} = poll(report: %{mode: :draining, update: :none})
    assert nil == poll(report: %{mode: :open, update: :none})
    assert %{"step" => "failed", "reason" => "download"} = values()
  end

  test "a verified target is not resumed after its identity changes" do
    upgrade("RU-01", %{
      "step" => "verifying",
      "from_build" => "b1",
      "from_incarnation" => "inc-1",
      "incarnation" => "inc-2"
    })

    assert nil == poll(build: "b1", incarnation: "inc-3", report: %{mode: :draining})
    assert nil == poll(build: "b2", incarnation: "inc-3", report: %{mode: :draining})
    assert values()["step"] == "verifying"
  end

  test "old records without source identity are not blindly resumed" do
    upgrade("RU-01", %{"step" => "updating", "from_incarnation" => "inc-1"})
    assert nil == poll(report: %{mode: :draining, update: :failed, step: :update})
    assert values()["failed_step"] == "update"
    assert nil == poll(report: %{mode: :draining})
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
