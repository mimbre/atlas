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
        if refits == :unavailable, do: %{"error" => "unavailable"}, else: %{"facts" => refits}

      "shift", %{"linked" => %{"shift_on" => _}} ->
        if shifts == :unavailable, do: %{"error" => "unavailable"}, else: %{"facts" => shifts}

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
  defp flow(opts) do
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

  defp render(route, opts) do
    MachinesPage.render(
      route,
      @m,
      reader(opts),
      Keyword.get_lazy(opts, :flow, fn -> flow(opts) end),
      @now,
      Keyword.get(opts, :newest),
      Keyword.get(opts, :verify, fn _, _ -> false end)
    )
  end

  defp tab(opts \\ []), do: render({:machine_page, :machines, %{}}, opts)
  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))
  defp props(page, id), do: block(page, id)["props"]
  defp pairs(page, id), do: Map.new(props(page, id)["fields"], &{&1["label"], &1["value"]})

  test "with one machine the tab shows its health, lists, actions and details" do
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
             {"actions", "actions"},
             {"identity", "item"},
             {"versions", "item"}
           ]

    assert page.title == "Mac mini"

    assert %{"eyebrow" => "MACHINE", "key" => "mini", "title" => "Mac mini", "icon" => "gears"} =
             props(page, "header")

    assert props(page, "state")["text"] == "Seen · build develop-aaaaaaaaaaaa"

    assert pairs(page, "health") == %{
             "Last seen" => "12 s ago, 27 Nov 11:59:48 UTC",
             "Polls" => "each poll waits up to 25 s for work",
             "Observed since" => "27 Nov 09:00:00 UTC",
             "Core build" => "unknown: the core does not know its own build"
           }

    assert [%{"label" => "Overall health", "key" => "h", "to" => "/health"}] =
             props(page, "health")["actions"]

    # Desired slots are not evidence of free capacity.
    assert [busy, unknown] = props(page, "slots")["rows"]

    assert %{
             "id" => "dev1",
             "label" => "W-1 · Widget 1",
             "detail" => "Fitting · for 12 min",
             "to" => "/k/widget/W-1",
             "since" => "2026-11-27T11:48:00Z"
           } = busy

    assert %{"id" => "dev2", "label" => "Status unknown", "detail" => "Desired configuration"} =
             unknown

    assert [%{"label" => "Edit configuration", "to" => "/k/bench/mini/edit"}] =
             props(page, "actions")["actions"]

    assert pairs(page, "identity") == %{
             "Incarnation" => "inc-7",
             "Machine name" => "mac-mini.local"
           }

    assert pairs(page, "versions") == %{
             "Installed version" => "develop-aaaaaaaaaaaa",
             "Policy version" => "3"
           }

    assert [
             %{
               "kind" => "part",
               "start" => "identity",
               "end" => "versions",
               "props" => %{"title" => "Details", "role" => "details"}
             }
           ] = page.markup
  end

  test "missing machine details remain unknown without empty detail cards" do
    page = tab(flow: %{"runtimes" => [], "queue" => []}, shifts: :unavailable)
    assert block(page, "identity") == nil
    assert block(page, "versions") == nil
    assert props(page, "slots")["empty"] == "Slot activity is unknown: Facts did not answer."
    assert props(page, "health")["fields"] != []
  end

  test "refused or pending configuration never makes desired slots free" do
    for applied <- [2, nil, 3] do
      page =
        tab(
          benches: [
            bench("mini", "Mac mini", %{
              "setup" => ~s({"version": 3, "slots": ["new"]}),
              "setup_version" => applied,
              "refused_version" => 3
            })
          ],
          shifts: [
            shift("SH-1", "O-1", %{
              "slot" => "old",
              "began" => "2026-11-27T11:48:00Z"
            })
          ]
        )

      assert [
               %{"id" => "new", "label" => "Status unknown", "detail" => "Desired configuration"},
               %{"id" => "old", "label" => "W-1 · Widget 1"}
             ] = props(page, "slots")["rows"]
    end

    assert props(tab(), "slots")["empty"] == "Slot configuration and availability are unknown."
  end

  test "unavailable attempts make slot activity and recent work unknown, not empty" do
    page =
      tab(
        benches: [bench("mini", "Mac mini", %{"setup" => ~s({"slots": ["dev1"]})})],
        shifts: :unavailable
      )

    assert props(page, "slots")["rows"] == []
    assert props(page, "slots")["empty"] == "Slot activity is unknown: Facts did not answer."
    assert props(page, "finished")["rows"] == []

    assert props(page, "finished")["empty"] ==
             "Recently finished work is unknown: Facts did not answer."

    known = tab(shifts: [])
    assert props(known, "finished")["empty"] == "Nothing has finished here yet."
  end

  test "an attempt marked lost by boot repair is not shown as busy without an end time" do
    page =
      tab(
        benches: [bench("mini", "Mac mini", %{"setup" => ~s({"slots": ["dev1"]})})],
        shifts: [
          shift("SH-1", "O-1", %{
            "slot" => "dev1",
            "began" => "2026-11-27T11:48:00Z",
            "state" => "lost",
            "result" => "restart"
          })
        ]
      )

    assert [%{"id" => "dev1", "label" => "Status unknown"}] = props(page, "slots")["rows"]
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

  test "lost attempts without an end time follow dated results deterministically and have no duration" do
    dated =
      for n <- 1..9 do
        shift("SH-#{n}", "O-#{n}", %{
          "began" => "2026-11-27T09:00:00Z",
          "finished" => "2026-11-27T10:00:00Z",
          "result" => "completed"
        })
      end

    lost =
      for n <- 10..12 do
        shift("SH-#{n}", "O-#{n}", %{
          "began" => "2026-11-27T11:00:00Z",
          "state" => "lost",
          "result" => "restart"
        })
      end

    rows = props(tab(shifts: lost ++ dated), "finished")["rows"]
    reversed = props(tab(shifts: Enum.reverse(lost ++ dated)), "finished")["rows"]

    assert Enum.map(rows, & &1["id"]) ==
             Enum.map(reversed, & &1["id"])

    assert Enum.map(rows, & &1["id"]) ==
             for(n <- 9..1//-1, do: "W-#{n}") ++ ["W-12"]

    assert List.last(rows)["detail"] == "lost · restart"
    assert List.last(rows)["tone"] == "attention"
    assert List.last(rows)["since"] == nil

    assert [row] = props(tab(shifts: [hd(lost)]), "finished")["rows"]
    assert row["detail"] == "lost · restart"
    assert row["since"] == nil
  end

  test "a lost attempt with an end time shows its cause and real duration" do
    lost =
      shift("SH-1", "O-1", %{
        "began" => "2026-11-27T11:00:00Z",
        "finished" => "2026-11-27T11:04:10Z",
        "state" => "lost",
        "result" => "expired"
      })

    assert [row] = props(tab(shifts: [lost]), "finished")["rows"]
    assert row["detail"] == "lost · expired · 4 min 10 s"
    assert row["since"] == "2026-11-27T11:04:10Z"
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
    assert props(tab(), "queue")["empty"] == "No work is waiting."

    for unavailable <- [nil, %{}, %{"queue" => nil}] do
      queue = props(tab(flow: unavailable), "queue")
      assert queue["rows"] == []
      assert queue["empty"] == "Queue status is unknown."
    end
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

  test "unavailable upgrades are unknown and cannot be offered or confirmed" do
    opts = [
      refits: :unavailable,
      newest: "develop-bbbbbbbbbbbb",
      verify: fn _, _ -> true end
    ]

    page = tab(opts)
    assert props(page, "state")["text"] == "Unknown · build develop-aaaaaaaaaaaa"
    assert props(page, "upgrades")["rows"] == []
    assert props(page, "upgrades")["empty"] == "Upgrade status is unknown."
    refute block(page, "answers")

    confirm =
      props(render({:machine_page, :machine_upgrade, %{machine: "mini"}}, opts), "confirm")

    refute Map.has_key?(confirm, "confirm_to")
    assert confirm["text"] == "Upgrade status is unknown: Facts did not answer."

    list = tab(opts ++ [benches: [bench("mini", "Mac mini"), bench("studio", "Mac Studio")]])
    assert hd(props(list, "machines")["rows"])["detail"] == "Unknown · build develop-aaaaaaaaaaaa"
  end

  test "upgrade is offered only with published newer proof and no upgrade underway" do
    opts = [newest: "develop-bbbbbbbbbbbb", verify: fn _, _ -> true end]
    assert block(tab(opts), "answers")
    page = render({:machine_page, :machine_upgrade, %{machine: "mini"}}, opts)
    assert props(page, "confirm")["confirm_to"]

    for rejected <- [
          [newest: nil],
          [newest: "develop-bbbbbbbbbbbb", verify: fn _, _ -> false end],
          [newest: "develop-bbbbbbbbbbbb", verify: fn _, _ -> :unknown end],
          opts ++ [flow: nil],
          opts ++
            [refits: [refit("RF-1", "develop-bbbbbbbbbbbb", "waiting", "2026-11-27T11:00:00Z")]]
        ] do
      refute block(tab(rejected), "answers")

      refute Map.has_key?(
               props(
                 render({:machine_page, :machine_upgrade, %{machine: "mini"}}, rejected),
                 "confirm"
               ),
               "confirm_to"
             )
    end
  end

  test "submit reads fresh upgrade state and proof, and fails closed" do
    newest = "develop-bbbbbbbbbbbb"

    assert {:ok, "refit", %{"build" => ^newest}, %{"refit_of" => ["mini"]}} =
             MachinesPage.upgrade(@m, "mini", reader([]), flow([]), newest, fn _, _ -> true end)

    assert {:refuse, _} =
             MachinesPage.upgrade(@m, "mini", reader([]), flow([]), newest, fn _, _ -> false end)

    read = fn
      "refit", _ -> %{"error" => "unavailable"}
      kind, query -> reader([]).(kind, query)
    end

    assert {:refuse, _} =
             MachinesPage.upgrade(@m, "mini", read, flow([]), newest, fn _, _ -> true end)
  end

  test "missing Flow is unknown, not open" do
    assert props(tab(flow: nil), "state")["text"] == "Unknown"
  end

  test "after health tracking restarts, a missing observation makes no core-start claim" do
    assert props(tab(), "state")["text"] =~ "Seen"
    page = tab(flow: %{"runtimes" => [], "queue" => []}, newest: "develop-bbbbbbbbbbbb")
    assert props(page, "state")["text"] == "Not seen"
    assert pairs(page, "health")["Last seen"] == "not seen by current health tracking"
    assert props(page, "health-error")["text"] =~ "has not been seen by current health tracking"
    refute Map.has_key?(pairs(page, "health"), "Observed since")

    confirm =
      render({:machine_page, :machine_upgrade, %{machine: "mini"}},
        flow: %{"runtimes" => [], "queue" => []},
        newest: "develop-bbbbbbbbbbbb"
      )

    assert props(confirm, "confirm")["text"] =~ "current health tracking has not seen it"
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

    assert hd(props(page, "machines")["rows"])["detail"] == "Seen · build develop-aaaaaaaaaaaa"

    machine =
      render({:machine_page, :machine, %{machine: "studio"}},
        benches: [bench("mini", "Mac mini"), bench("studio", "Mac Studio")]
      )

    assert props(machine, "header")["key"] == "studio"
    assert machine.back == "/machines"
  end
end
