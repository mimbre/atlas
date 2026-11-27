defmodule AtlasControl.MachinesPageTest do
  # The Machines tab (contract 0.43.0): with one machine, its page; with more, a list. The
  # shop's benches are the machines (`AtlasControl.Shop.Benched`), its shifts the attempts
  # that ran on them, its orders the work and its refits the upgrades.
  use ExUnit.Case, async: true

  alias AtlasControl.MachinesPage

  @now ~U[2026-11-27 12:00:00Z]
  @m AtlasControl.Model.catalog(AtlasControl.Shop.Benched)

  defp bench(key, name, values \\ %{}),
    do: %{"key" => key, "values" => Map.merge(%{"name" => name}, values), "links" => %{}}

  defp shift(key, order, values),
    do: %{
      "key" => key,
      "values" => values,
      "links" => %{"shift_of" => [order], "shift_on" => ["mini"]}
    }

  defp refit(key, build, step, since),
    do: %{
      "key" => key,
      "values" => %{"build" => build, "step" => step},
      "links" => %{"refit_of" => ["mini"]},
      "origins" => %{"refit_of" => %{"since" => since}}
    }

  # Facts as the page reads them: `benches`, and per bench `refits` and `shifts`; orders
  # O-n on widget W-n, titled "Widget n".
  defp reader(opts) do
    benches = Keyword.get(opts, :benches, [bench("mini", "Mac mini")])
    refits = Keyword.get(opts, :refits, [])
    shifts = Keyword.get(opts, :shifts, [])

    fn
      "bench", %{"plain" => true} ->
        %{"facts" => benches}

      "bench", %{"key" => key} ->
        %{"fact" => Enum.find(benches, &(&1["key"] == key))}

      "refit", %{"linked" => %{"refit_of" => _}} ->
        %{"facts" => refits}

      "shift", %{"linked" => %{"shift_on" => _}} ->
        %{"facts" => shifts}

      "order", %{"key" => "O-" <> n = key} ->
        %{
          "fact" => %{
            "key" => key,
            "values" => %{"phase" => "fitting"},
            "links" => %{"order_of" => ["W-#{n}"]}
          }
        }

      "widget", %{"key" => "W-" <> n = key} ->
        %{"fact" => %{"key" => key, "values" => %{"title" => "Widget #{n}"}}}

      _, _ ->
        %{"error" => "unknown"}
    end
  end

  # Flow's health answer: the bench polled `ago` seconds before now, on `build`.
  defp flow(opts \\ []) do
    polled = DateTime.add(@now, -Keyword.get(opts, :ago, 12), :second)

    %{
      "runtimes" => [
        %{
          "runtime" => "mini",
          "polled_at" => DateTime.to_iso8601(polled),
          "build" => Keyword.get(opts, :build, "develop-aaaaaaaaaaaa"),
          "incarnation" => "inc-7",
          "incarnation_since" => "2026-11-27T09:00:00Z",
          "poll_max" => 25
        }
      ],
      "queue" => Keyword.get(opts, :queue, [])
    }
  end

  defp render(route, opts \\ []) do
    MachinesPage.render(
      route,
      @m,
      reader(opts),
      Keyword.get_lazy(opts, :flow, fn -> flow(opts) end),
      @now,
      Keyword.get(opts, :newest, "develop-bbbbbbbbbbbb")
    )
  end

  defp tab(opts \\ []), do: render({:machine_page, :machines, %{}}, opts)
  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))
  defp props(page, id), do: block(page, id)["props"]
  defp pairs(page, id), do: Map.new(props(page, id)["fields"], &{&1["label"], &1["value"]})

  test "with one machine the tab is its page: header, state, health, the lists, the main action, actions and details" do
    page =
      tab(
        benches: [
          bench("mini", "Mac mini", %{
            "setup" => ~s({"version": 3, "slots": ["dev1", "dev2"]}),
            "setup_version" => 3
          })
        ],
        shifts: [
          shift("SH-1", "O-1", %{
            "slot" => "dev1",
            "host" => "mac-mini.local",
            "began" => "2026-11-27T11:48:00Z"
          })
        ]
      )

    assert Enum.map(page.blocks, &{&1["id"], &1["type"]}) == [
             {"header", "header"},
             {"state", "text"},
             {"health", "item"},
             {"slots", "list"},
             {"queue", "list"},
             {"finished", "list"},
             {"upgrades", "list"},
             {"answers", "answers"},
             {"actions", "actions"},
             {"details", "item"}
           ]

    assert page.title == "Mac mini"

    assert %{"eyebrow" => "MACHINE", "key" => "mini", "title" => "Mac mini", "icon" => "gears"} =
             props(page, "header")

    assert props(page, "state")["text"] == "Open · build develop-aaaaaaaaaaaa"

    assert pairs(page, "health") == %{
             "Last seen" => "12 s ago, 27 Nov 11:59:48 UTC",
             "Polls" => "each poll waits up to 25 s for work",
             "Running since" => "27 Nov 09:00:00 UTC",
             "Newest build" => "develop-bbbbbbbbbbbb, newer than its develop-aaaaaaaaaaaa"
           }

    # One card per slot: what it works on, its stage and how long; or free.
    assert [busy, free] = props(page, "slots")["rows"]

    assert %{
             "id" => "dev1",
             "label" => "W-1 · Widget 1",
             "detail" => "Fitting · for 12 min",
             "to" => "/k/widget/W-1",
             "since" => "2026-11-27T11:48:00Z"
           } = busy

    assert %{"id" => "dev2", "label" => "Free"} = free

    assert [%{"label" => "Edit configuration", "to" => "/k/bench/mini/edit"}] =
             props(page, "actions")["actions"]

    assert pairs(page, "details") == %{
             "Incarnation" => "inc-7",
             "Machine name" => "mac-mini.local",
             "Installed version" => "develop-aaaaaaaaaaaa",
             "Policy version" => "3"
           }

    assert [%{"kind" => "part", "props" => %{"role" => "details"}}] = page.markup
  end

  test "recently finished: the last ten with their subject, outcome and duration; none without a subject" do
    shifts =
      for n <- 1..12 do
        shift("SH-#{n}", "O-#{n}", %{
          "slot" => "dev1",
          "began" => "2026-11-27T#{String.pad_leading("#{n - 1}", 2, "0")}:00:00Z",
          "finished" => "2026-11-27T#{String.pad_leading("#{n - 1}", 2, "0")}:04:10Z",
          "result" => "completed"
        })
      end

    # An attempt whose task leads nowhere is left out, not shown by its id alone.
    orphan =
      %{
        "key" => "SH-99",
        "values" => %{"finished" => "2026-11-27T11:59:00Z", "result" => "completed"},
        "links" => %{"shift_on" => ["mini"]}
      }

    rows = props(tab(shifts: [orphan | shifts]), "finished")["rows"]

    assert Enum.map(rows, & &1["id"]) == for(n <- 12..3//-1, do: "W-#{n}")
    assert hd(rows)["label"] == "W-12 · Widget 12"
    assert hd(rows)["detail"] == "completed · 4 min 10 s"
    assert hd(rows)["to"] == "/k/widget/W-12"
  end

  test "the queue lists what waits for a Runtime, oldest first, with what it is about" do
    queue = [
      %{
        "task" => "O-3",
        "title" => "Fit widget 3",
        "profile" => "deep_coding",
        "subject_kind" => "widget",
        "subject_key" => "W-3",
        "since" => "2026-11-27T10:00:00Z"
      }
    ]

    assert [row] = props(tab(queue: queue), "queue")["rows"]

    assert %{
             "label" => "W-3 · Fit widget 3",
             "detail" => "needs deep coding",
             "to" => "/k/widget/W-3",
             "since" => "2026-11-27T10:00:00Z"
           } = row

    assert props(tab(), "queue")["rows"] == []
  end

  test "upgrades show newest first with their step; one under way makes the machine draining or upgrading" do
    refits = [
      refit("RF-01", "develop-000000000000", "done", "2026-11-20T10:00:00Z"),
      refit("RF-02", "develop-bbbbbbbbbbbb", "waiting", "2026-11-27T11:00:00Z")
    ]

    page = tab(refits: refits)
    assert Enum.map(props(page, "upgrades")["rows"], & &1["id"]) == ["RF-02", "RF-01"]

    assert props(page, "state")["text"] ==
             "Draining for upgrade RF-02 · build develop-aaaaaaaaaaaa"

    assert hd(props(page, "upgrades")["rows"])["detail"] =~ "waiting until no slot is busy"

    updating = [refit("RF-02", "develop-bbbbbbbbbbbb", "updating", "2026-11-27T11:00:00Z")]
    assert props(tab(refits: updating), "state")["text"] =~ "Upgrading (RF-02)"
  end

  describe "the main action, Upgrade to the newest build" do
    defp offered?(page), do: block(page, "answers") != nil

    test "is offered when a newer build exists, as the page's main answer opening its confirm" do
      assert [answer] = props(tab(), "answers")["answers"]

      assert %{
               "label" => "Upgrade to the newest build",
               "weight" => "main",
               "to" => "/machines/mini/upgrade",
               "detail" => "develop-aaaaaaaaaaaa → develop-bbbbbbbbbbbb"
             } = answer
    end

    test "is not offered when the machine runs the newest build" do
      page = tab(build: "develop-bbbbbbbbbbbb")
      refute offered?(page)
      assert pairs(page, "health")["Newest build"] == "develop-bbbbbbbbbbbb, which it runs"
    end

    test "is not offered while an upgrade is under way" do
      refits = [refit("RF-01", "develop-bbbbbbbbbbbb", "requested", "2026-11-27T11:00:00Z")]
      refute offered?(tab(refits: refits))

      # An ended one does not hold it back.
      refits = [refit("RF-01", "develop-cccccccccccc", "failed", "2026-11-27T11:00:00Z")]
      assert offered?(tab(refits: refits))
    end

    test "is not offered when the newest build or the machine's build is not known" do
      refute offered?(tab(newest: nil))
      refute offered?(tab(flow: %{"runtimes" => [], "queue" => []}))
      refute offered?(tab(flow: nil))
    end

    test "its confirm names both builds; the upgrade it makes is the newest build under the machine" do
      page = render({:machine_page, :machine_upgrade, %{machine: "mini"}})

      assert %{
               "title" => "Upgrade Mac mini to the newest build?",
               "confirm_to" => %{
                 "endpoint" => "upgrade_machine",
                 "params" => %{"machine" => "mini"}
               },
               "cancel_to" => "/machines/mini"
             } = props(page, "confirm")

      assert props(page, "confirm")["text"] =~ "runs develop-aaaaaaaaaaaa"

      assert MachinesPage.upgrade(@m, "mini", reader([]), flow(), "develop-bbbbbbbbbbbb") ==
               {:ok, "refit", %{"build" => "develop-bbbbbbbbbbbb"}, %{"refit_of" => ["mini"]}}

      assert {:refuse, why} =
               MachinesPage.upgrade(@m, "mini", reader([]), flow(), "develop-aaaaaaaaaaaa")

      assert why =~ "runs the newest build"

      # Without an offer the confirm only says why.
      page = render({:machine_page, :machine_upgrade, %{machine: "mini"}}, newest: nil)
      refute Map.has_key?(props(page, "confirm"), "confirm_to")
    end
  end

  test "a machine not seen within the limit says so in the error tone, and what to do" do
    page = tab(ago: 14 * 60)

    assert props(page, "state")["text"] =~ "Not seen"

    assert %{"role" => "error", "label" => "Not seen", "text" => text} =
             props(page, "health-error")

    assert text =~ "has not polled for 14 min (limit 10 min)"
    assert text =~ "atlas-runtime service status"

    assert Enum.any?(page.markup, &(&1["kind"] == "highlight" and &1["start"] == "health"))
    refute block(tab(), "health-error")
  end

  test "with more than one machine the tab is a simple list, each opening its page" do
    page = tab(benches: [bench("mini", "Mac mini"), bench("studio", "Mac Studio")])

    assert [%{"id" => "machines", "type" => "list"}] = page.blocks

    assert [
             %{"id" => "mini", "label" => "Mac mini", "to" => "/machines/mini"},
             %{"id" => "studio", "label" => "Mac Studio", "to" => "/machines/studio"}
           ] = props(page, "machines")["rows"]

    assert hd(props(page, "machines")["rows"])["detail"] == "Open · build develop-aaaaaaaaaaaa"

    machine =
      render({:machine_page, :machine, %{machine: "studio"}},
        benches: [bench("mini", "Mac mini"), bench("studio", "Mac Studio")]
      )

    assert props(machine, "header")["key"] == "studio"
    assert machine.back == "/machines"
  end
end
