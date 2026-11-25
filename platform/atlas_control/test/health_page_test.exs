defmodule AtlasControl.HealthPageTest do
  # IS-Atlas-117: the core's health page. Each row is marked late once it passes its limit
  # (Flow 2 min, a Runtime 10 min); the syncs say rela does not report them yet; Facts'
  # queue is counted on the Bus. Through a session, the page asks Flow once and Facts
  # nothing.
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasControl.{FakeStore, HealthPage}

  @now ~U[2026-11-23 10:10:00Z]

  defp flow(flow, runtimes \\ []),
    do: %{"flow" => flow, "runtimes" => runtimes, "at" => DateTime.to_iso8601(@now)}

  defp finished(due, at), do: %{"last_due" => due, "last_finished" => at, "next_due" => nil}

  defp row(report, group, label) do
    Enum.find(HealthPage.rows(report, @now)[group], &(&1.label == label))
  end

  describe "Flow's lag" do
    test "a round finished on time is not late; its lag is its due to its end" do
      r =
        row(
          %{flow: flow(finished("2026-11-23T10:09:00Z", "2026-11-23T10:09:04Z"))},
          :core,
          "Flow"
        )

      refute r.late
      assert r.text =~ "4 s behind (limit 2 min)"
    end

    test "a round still stepping counts from its due until now, late past 2 min" do
      r = row(%{flow: flow(%{"due" => "2026-11-23T10:08:30Z"})}, :core, "Flow")
      refute r.late
      assert r.text =~ "1 min 30 s behind"

      # Flow 9 minutes late, as on 2026-11-23.
      r = row(%{flow: flow(%{"due" => "2026-11-23T10:01:00Z"})}, :core, "Flow")
      assert r.late
      assert r.text =~ "9 min behind"
    end

    test "a round due whose timer the Engine has not taken counts too" do
      r = row(%{flow: flow(%{"next_due" => "2026-11-23T10:07:00Z"})}, :core, "Flow")
      assert r.late
      assert r.text =~ "3 min behind"
      refute row(%{flow: flow(%{"next_due" => "2026-11-23T10:11:00Z"})}, :core, "Flow").late
    end

    test "a Flow that does not answer is late, and so are the Runtimes it would report" do
      assert row(%{flow: nil}, :core, "Flow").late

      assert [%{late: true, text: "Flow did not answer"}] =
               HealthPage.rows(%{flow: nil}, @now).runtimes
    end
  end

  test "each Runtime's last poll is late past 10 min" do
    report = %{
      flow:
        flow(finished("2026-11-23T10:09:00Z", "2026-11-23T10:09:01Z"), [
          %{"runtime" => "laptop", "polled_at" => "2026-11-23T09:59:00Z"},
          %{"runtime" => "mini", "polled_at" => "2026-11-23T10:09:40Z"}
        ])
    }

    assert %{late: true, text: "polled 11 min ago" <> _} = row(report, :runtimes, "laptop")
    assert %{late: false, text: "polled 20 s ago" <> _} = row(report, :runtimes, "mini")
  end

  test "the syncs say rela does not report them, and Facts' queue is a count" do
    rows = HealthPage.rows(%{flow: flow(%{}), facts_waiting: 7}, @now)
    assert [%{label: "rela syncs", late: false, text: "not reported by rela" <> _}] = rows.syncs
    assert %{text: "7 waiting"} = Enum.find(rows.core, &(&1.label == "Facts' queue"))
  end

  test "the page counts the late rows and marks their group in the error tone" do
    page =
      HealthPage.render(
        %{flow: flow(%{"due" => "2026-11-23T10:01:00Z"}), facts_waiting: 0},
        @now
      )

    assert page.title == "Health"
    assert page.back == "/workers"
    summary = Enum.find(page.blocks, &(&1["id"] == "summary"))["props"]

    assert [%{"label" => "Checks", "value" => "4"}, %{"label" => "Late", "value" => "1"}] =
             summary["fields"]

    assert [%{"to" => "/workers", "page" => true}] = summary["actions"]

    core = Enum.find(page.blocks, &(&1["id"] == "health-core"))["props"]
    assert %{"label" => "Flow", "value" => "late · 9 min behind" <> _} = hd(core["fields"])

    assert [%{"kind" => "highlight", "start" => "health-core", "props" => %{"tone" => "error"}}] =
             page.markup
  end

  describe "the decider's alerts" do
    defp healthy,
      do: %{
        flow:
          flow(finished("2026-11-23T10:09:00Z", "2026-11-23T10:09:04Z"), [
            %{"runtime" => "mini", "polled_at" => "2026-11-23T10:09:40Z"}
          ]),
        facts_waiting: 0
      }

    test "a healthy core raises none, and says when its first row would pass its limit" do
      assert HealthPage.alerts(healthy(), @now) == []
      # mini polled 10:09:40; late past 10 min, so at 10:19:41.
      assert HealthPage.until(healthy(), @now) == "2026-11-23T10:19:41Z"
      assert HealthPage.alert_view([]) == %{blocks: [], markup: []}
    end

    test "Flow past its limit is one alert, naming it and since when" do
      report = put_in(healthy().flow["flow"], %{"due" => "2026-11-23T10:01:00Z"})

      assert [%{key: "flow", what: "Flow", since: ~U[2026-11-23 10:01:00Z], text: text}] =
               HealthPage.alerts(report, @now)

      assert text =~ "Flow behind since 23 Nov 10:01:00 UTC: 9 min behind (limit 2 min)"
      # Open: read again at once, so it goes once Flow recovers.
      assert HealthPage.until(report, @now) == "2026-11-23T10:10:00Z"
    end

    test "a Runtime past its limit is one alert per Runtime, since its last poll" do
      report = %{
        healthy()
        | flow:
            flow(finished("2026-11-23T10:09:00Z", "2026-11-23T10:09:01Z"), [
              %{"runtime" => "laptop", "polled_at" => "2026-11-23T09:59:00Z"},
              %{"runtime" => "mini", "polled_at" => "2026-11-23T10:09:40Z"}
            ])
      }

      assert [
               %{key: "runtime:laptop", what: "Runtime laptop", since: ~U[2026-11-23 09:59:00Z]} =
                 a
             ] =
               HealthPage.alerts(report, @now)

      assert a.text =~ "Runtime laptop behind since 23 Nov 09:59:00 UTC: polled 11 min ago"

      # The same stall reads the same a minute later: one alert, not one per check.
      later = DateTime.add(@now, 60, :second)

      assert [%{key: "runtime:laptop", since: ~U[2026-11-23 09:59:00Z]}] =
               HealthPage.alerts(report, later)
    end

    test "a Flow that does not answer is one alert, not one for its Runtimes too" do
      assert [
               %{
                 key: "flow",
                 what: "Flow",
                 since: nil,
                 text: "Flow fell behind: Flow did not answer"
               }
             ] =
               HealthPage.alerts(%{flow: nil, facts_waiting: 0}, @now)
    end

    test "the syncs raise none until rela reports their runs" do
      assert Enum.all?(HealthPage.alerts(healthy(), @now), &(&1.key != "syncs"))
    end

    test "the alerts are an item with the Health action, in the error tone" do
      view =
        HealthPage.alert_view(HealthPage.alerts(%{flow: nil, facts_waiting: 0}, @now))

      assert [%{"id" => "alerts", "props" => props}] = view.blocks
      assert props["title"] == "Alerts"

      assert [%{"label" => "Flow", "value" => "Flow fell behind: Flow did not answer"}] =
               props["fields"]

      assert [%{"to" => "/health", "key" => "h", "page" => true}] = props["actions"]
      assert [%{"kind" => "highlight", "props" => %{"tone" => "error"}}] = view.markup
    end
  end

  describe "through a session" do
    setup do
      Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
      start_supervised!(FakeStore)
      start_supervised!(AtlasControl.FakeFlow)

      start_supervised!(
        {AtlasControl.Gateway,
         port: 0,
         name: :health_gateway,
         model: AtlasControl.Shop,
         settings: %{"workers" => %{"read" => %{"actors" => ["ada"]}}}}
      )

      on_exit(fn ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
            do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
      end)

      # Its own Flow health endpoint: in the umbrella, Flow's own holds `flow/health`.
      endpoint = "flow/health-#{System.unique_integer([:positive])}"
      Application.put_env(:atlas_control, :health_endpoint, endpoint)
      on_exit(fn -> Application.delete_env(:atlas_control, :health_endpoint) end)

      %{port: AtlasControl.Gateway.port(:health_gateway), endpoint: endpoint}
    end

    # Flow's health endpoint, answering `_health` with `answer`.
    defp flow_health(endpoint, answer) do
      test = self()

      pid =
        spawn_link(fn ->
          :ok = AtlasBus.attach(endpoint)
          send(test, :attached)
          serve(answer)
        end)

      assert_receive :attached
      pid
    end

    defp serve(answer) do
      receive do
        {:atlas_bus, %Envelope{class: "request", kind: "_health"} = request, _} ->
          AtlasBus.send(Envelope.reply(request, "answer"), answer)
          serve(answer)

        {:answer, from, answer} ->
          send(from, :answering)
          serve(answer)
      end
    end

    defp open(port, as, path, before \\ fn -> :ok end) do
      {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
      on_exit(fn -> :gen_tcp.close(s) end)

      send_line(s, %{
        "op" => "hello",
        "env" => "test",
        "client" => "agent",
        "as" => as,
        "spec" => AtlasControl.Blocks.version()
      })

      _first = page(s)
      before.()
      send_line(s, %{"op" => "open", "to" => path})
      page(s)
    end

    defp send_line(s, message), do: :ok = :gen_tcp.send(s, [JSON.encode!(message), "\n"])

    defp page(s) do
      {:ok, line} = :gen_tcp.recv(s, 0, 3_000)
      message = JSON.decode!(line)
      if message["op"] == "page", do: message, else: page(s)
    end

    test "a reader of the Workers page reads the core's health from Flow while Facts is silent",
         c do
      polled = DateTime.utc_now() |> DateTime.add(-20, :second) |> DateTime.to_iso8601()
      flow_health(c.endpoint, flow(%{}, [%{"runtime" => "mini", "polled_at" => polled}]))
      parent = self()

      page =
        open(c.port, "ada", "/health", fn ->
          FakeStore.silent(true)
          send(parent, {:reads, length(FakeStore.reads())})
        end)

      assert_receive {:reads, reads}
      assert page["path"] == "/health"
      assert page["title"] == "Health"

      runtimes = Enum.find(page["blocks"], &(&1["id"] == "health-runtimes"))["props"]["fields"]
      assert [%{"label" => "mini", "value" => "polled " <> _}] = runtimes
      assert length(FakeStore.reads()) == reads
    end

    test "without Flow's answer the page still comes, its Flow late", c do
      Application.put_env(:atlas_control, :health_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:atlas_control, :health_timeout_ms) end)

      page = open(c.port, "ada", "/health")
      core = Enum.find(page["blocks"], &(&1["id"] == "health-core"))["props"]["fields"]

      assert %{"value" => "late · Flow did not answer"} =
               Enum.find(core, &(&1["label"] == "Flow"))
    end

    test "one the settings do not name as a reader is refused", c do
      page = open(c.port, "bea", "/health")
      assert page["title"] == "Worker unavailable"
    end

    defp alerts(page), do: Enum.find(page["blocks"], &(&1["id"] == "alerts"))

    defp ago(seconds),
      do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

    defp healthy_now(runtimes),
      do: %{
        "flow" => %{"last_due" => ago(5), "last_finished" => ago(4), "next_due" => nil},
        "runtimes" => runtimes,
        "at" => ago(0)
      }

    test "the decider's start page carries one alert per stall, gone once it recovers", c do
      Application.put_env(:atlas, :actors, %{"decider" => "ada"})
      on_exit(fn -> Application.delete_env(:atlas, :actors) end)

      stalled = healthy_now([%{"runtime" => "laptop", "polled_at" => ago(11 * 60)}])
      server = flow_health(c.endpoint, stalled)

      page = open(c.port, "ada", "/")

      assert %{"props" => %{"title" => "Alerts", "fields" => [field], "actions" => [health]}} =
               alerts(page)

      assert field["label"] == "Runtime laptop"
      assert field["value"] =~ "Runtime laptop behind since "
      assert health["to"] == "/health"

      # The Runtime polls again: the alert is gone, nothing to close by hand.
      send(
        server,
        {:answer, self(), healthy_now([%{"runtime" => "laptop", "polled_at" => ago(1)}])}
      )

      assert_receive :answering
      assert alerts(open(c.port, "ada", "/")) == nil
    end

    test "a healthy core raises no alert, and another than the decider sees none", c do
      Application.put_env(:atlas, :actors, %{"decider" => "ada"})
      on_exit(fn -> Application.delete_env(:atlas, :actors) end)

      server =
        flow_health(c.endpoint, healthy_now([%{"runtime" => "mini", "polled_at" => ago(1)}]))

      assert alerts(open(c.port, "ada", "/")) == nil

      send(
        server,
        {:answer, self(), healthy_now([%{"runtime" => "mini", "polled_at" => ago(20 * 60)}])}
      )

      assert_receive :answering
      assert alerts(open(c.port, "bea", "/")) == nil
      assert alerts(open(c.port, "ada", "/")) != nil
    end
  end
end
