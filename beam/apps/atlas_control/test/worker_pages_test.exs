defmodule AtlasControl.WorkerPagesTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{Console, WorkerPages}

  # The worker page of run `page-turn` (`AtlasControl.Packing`: a run is a turn, a trace its
  # execution). `facts` changes what Facts says: `:values` the run's own, `:execution` its
  # trace's, `:others` the worker's other runs, `:links` the run's links.
  defp fixture(history, opts \\ %{}, facts \\ []) do
    params = %{machine: "page-machine", worker: "page-worker", turn: "page-turn", attempt: "1"}
    target = WorkerPages.target(params)
    execution = Map.merge(target["worker"], Map.take(target, ~w(turn attempt)))

    execution =
      execution
      |> Map.merge(%{"key" => "execution", "harness" => "codex"})
      |> Map.merge(facts[:execution] || %{})

    values =
      Map.merge(
        %{"host" => "page-machine", "try" => "1", "status" => "over"},
        facts[:values] || %{}
      )

    run = %{
      "key" => "page-turn",
      "values" => values,
      "links" => Map.merge(%{"worker" => ["page-worker"]}, facts[:links] || %{})
    }

    # Runs are turns and traces the executions (`AtlasControl.Packing`); a reader may read.
    description =
      AtlasControl.Model.catalog(AtlasControl.Packing, %{
        "workers" => %{"read" => %{"actors" => ["viewer"]}}
      })

    read = fn
      "reader", %{"key" => "viewer"} ->
        %{"fact" => %{"key" => "viewer"}}

      "trace", %{"turn" => "page-turn", "attempt" => "1"} ->
        %{"fact" => execution}

      "run", %{"key" => "page-turn"} ->
        %{"fact" => run}

      "run", %{"linked" => %{"worker" => "page-worker"}, "plain" => true} ->
        %{"facts" => [run | facts[:others] || []]}

      "card", %{"key" => key} ->
        %{"fact" => %{"key" => key, "values" => %{"title" => "fixture item title"}}}

      "memo_note", %{"execution" => "execution", "after_position" => 0, "limit" => 50} ->
        history
    end

    page =
      WorkerPages.render(
        {:worker_page, :worker, params},
        description,
        %{key: "viewer", kind: "reader"},
        read,
        opts
      )

    {page, target}
  end

  @none %{"facts" => [], "after_position" => 0, "more" => false}

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))
  defp values(block), do: Enum.map(block["props"]["fields"], & &1["value"])

  # Another run of the same worker.
  defp other(key, values),
    do: %{
      "key" => key,
      "values" => Map.merge(%{"host" => "page-machine", "try" => "2"}, values),
      "links" => %{"worker" => ["page-worker"]}
    }

  defp project(page, target) do
    Console.project(
      %{
        "path" => WorkerPages.path(target),
        "back" => page.back,
        "blocks" => page.blocks,
        "markup" => page.markup
      },
      1,
      page.console_actions
    )
  end

  # The Workers page over these runs (`AtlasControl.Packing`: a run is a turn, going is
  # running, over is ended, `until` its lease and `done_at` when it ended). Each run is
  # `{key, status, at}`: `at` is the lease of a going run and the end of an over one.
  defp workers_page(runs) do
    description =
      AtlasControl.Model.catalog(AtlasControl.Packing, %{
        "workers" => %{"read" => %{"actors" => ["viewer"]}}
      })

    turns =
      for {key, status, at} <- runs do
        values = %{"host" => "m-#{key}", "try" => "1", "status" => status}

        values =
          if status == "going",
            do: Map.put(values, "until", at),
            else: Map.merge(values, %{"done_at" => at, "reason" => "finished"})

        %{"key" => key, "values" => values, "links" => %{"worker" => ["w-#{key}"]}}
      end

    by_key = Map.new(turns, &{&1["key"], &1})

    read = fn
      "reader", %{"key" => "viewer"} ->
        %{"fact" => %{"key" => "viewer"}}

      "run", %{"plain" => true} = query when map_size(query) == 1 ->
        %{"facts" => turns}

      "run", %{"key" => key} ->
        %{"fact" => by_key[key]}

      "trace", %{"turn" => key, "attempt" => "1"} ->
        %{
          "fact" => %{
            "key" => "trace-#{key}",
            "environment" => AtlasBus.environment(),
            "machine" => "m-#{key}",
            "worker" => "w-#{key}",
            "turn" => key,
            "attempt" => "1"
          }
        }
    end

    page =
      WorkerPages.render(
        {:worker_page, :workers, %{}},
        description,
        %{key: "viewer", kind: "reader"},
        read,
        %{}
      )

    lists = for block <- page.blocks, do: {block["id"], block["type"], block["props"]}
    {page, lists}
  end

  defp row_keys({_id, _type, props}), do: Enum.map(props["rows"], & &1["id"])

  defp opens(key),
    do:
      WorkerPages.path(%{
        "worker" => %{"machine" => "m-#{key}", "worker" => "w-#{key}"},
        "turn" => key,
        "attempt" => "1"
      })

  test "the Workers page lists running turns first, newest activity first, then finished ones newest end first" do
    {_page, lists} =
      workers_page([
        {"R-1", "over", "2026-11-10T10:00:00Z"},
        {"R-2", "going", "2026-11-13T09:00:00Z"},
        {"R-3", "going", "2026-11-13T11:00:00Z"},
        {"R-4", "over", "2026-11-12T10:00:00Z"},
        {"R-5", "going", "2026-11-13T10:00:00Z"},
        {"R-6", "over", "2026-11-11T10:00:00Z"}
      ])

    assert Enum.map(lists, fn {id, type, _} -> {id, type} end) == [
             {"workers-running", "list"},
             {"workers-finished", "list"}
           ]

    [running, finished] = lists
    assert row_keys(running) == ["R-3", "R-5", "R-2"]
    assert row_keys(finished) == ["R-4", "R-6", "R-1"]

    # Each row opens its own turn's worker page, from either list.
    for {_, _, props} <- lists, row <- props["rows"] do
      assert row["to"] == opens(row["id"])

      assert {:worker_page, :worker, %{turn: turn, attempt: "1"}} =
               AtlasControl.Pages.route(row["to"])

      assert turn == row["id"]
    end
  end

  test "the Workers page keeps only the twenty most recently finished turns" do
    runs =
      for n <- 1..25 do
        {"R-#{String.pad_leading("#{n}", 2, "0")}", "over",
         DateTime.to_iso8601(DateTime.add(~U[2026-11-01 00:00:00Z], n, :hour))}
      end

    {_page, [running, finished]} = workers_page(Enum.shuffle(runs))
    assert row_keys(running) == []

    assert row_keys(finished) ==
             for(n <- 25..6//-1, do: "R-#{String.pad_leading("#{n}", 2, "0")}")
  end

  test "an empty Running list keeps its place and its empty state" do
    {page, [{"workers-running", "list", running}, {"workers-finished", "list", finished}]} =
      workers_page([{"R-1", "over", "2026-11-10T10:00:00Z"}])

    assert running["rows"] == []
    assert is_binary(running["empty"]) and running["empty"] != ""
    assert row_keys({nil, nil, finished}) == ["R-1"]

    # Rows of the second list stay selectable and openable in the Console.
    assert {:ok, projected} =
             Console.project(
               %{
                 "path" => "/workers",
                 "back" => page.back,
                 "blocks" => page.blocks,
                 "markup" => page.markup
               },
               1
             )

    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)

    assert {:ok, bindings} =
             AtlasBFFContract.Console.Projection.bindings(projection, %{
               path: "/workers",
               context: "browse",
               generation: 0,
               on: "workers-finished",
               row: "R-1"
             })

    assert bindings["Enter"]["props"]["operation"]["name"] == "open_selected"
  end

  test "worker and conversation panes retain stable boundaries and unavailable output is explicit" do
    {page, target} = fixture(@none)

    assert Enum.map(page.blocks, & &1["id"]) ==
             [
               "worker",
               "worker-output",
               "worker-output-details",
               "guidance-history",
               "worker-record"
             ]

    # The conversation leads with what the worker said; the rest is one folded section.
    assert Enum.map(page.markup, &{&1["kind"], &1["start"], &1["end"]}) == [
             {"part", "worker", "worker"},
             {"part", "worker-output", "worker-record"},
             {"section", "worker-output-details", "worker-record"}
           ]

    assert Enum.map(page.markup, & &1["props"]["role"]) == ["main", "related", nil]
    assert List.last(page.markup)["props"]["collapsible"] == true
    refute Enum.any?(page.console_actions, &(&1.operation["name"] == "worker_output_subscribe"))
    refute Enum.any?(page.console_actions, &(&1.operation["name"] == "worker_history"))
    assert {:ok, projected} = project(page, target)

    assert Enum.any?(
             projected["blocks"],
             &(get_in(&1, ["props", "operation", "name"]) == "part_next")
           )

    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)

    assert {:ok, bindings} =
             AtlasBFFContract.Console.Projection.bindings(projection, %{
               path: WorkerPages.path(target),
               context: "browse",
               generation: 0,
               on: "guidance-history",
               row: nil
             })

    refute Map.has_key?(bindings, "Down")
    refute Map.has_key?(bindings, "Up")
    refute Map.has_key?(bindings, "e")
  end

  test "durable history exposes selectable rows without granting unsupported worker capabilities" do
    interactions =
      for {key, body} <- [{"first", "/stop is literal\nα"}, {"second", "next guidance"}] do
        %{
          "key" => key,
          "environment" => AtlasBus.environment(),
          "worker" => "page-worker",
          "turn" => "page-turn",
          "attempt" => "1",
          "execution" => "execution",
          "actor" => "viewer",
          "body" => body,
          "projection" => %{"proven" => "recorded", "uncertain" => true, "closures" => []},
          "receipt_count" => 0
        }
      end

    {page, target} =
      fixture(%{"facts" => interactions, "after_position" => 2, "more" => false})

    assert {:ok, projected} = project(page, target)
    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)

    current = %{
      path: WorkerPages.path(target),
      context: "browse",
      generation: 0,
      on: "guidance-history",
      row: "first"
    }

    assert {:ok, bindings} = AtlasBFFContract.Console.Projection.bindings(projection, current)
    assert bindings["Down"]["props"]["operation"]["name"] == "list_next"
    assert bindings["Up"]["props"]["operation"]["name"] == "list_previous"

    assert Enum.find(page.blocks, &(&1["id"] == "guidance-history"))["props"]["rows"] ==
             Enum.map(interactions, fn interaction ->
               %{
                 "id" => interaction["key"],
                 "label" => interaction["body"],
                 "detail" => "viewer · recorded (uncertain)",
                 "to" => WorkerPages.path(target)
               }
             end)

    assert {:ok, event} = AtlasBFFContract.Console.Projection.capture(projection, "e", current)
    assert {:ok, action} = AtlasBFFContract.Console.Projection.resolve(projection, event, current)

    assert action["props"]["operation"] == %{
             "name" => "worker_receipts",
             "execution" => target,
             "interaction_source" => "selected_history"
           }

    assert {:error, :stale_or_unavailable_action} =
             AtlasBFFContract.Console.Projection.resolve(projection, event, %{
               current
               | row: "second"
             })

    details = Enum.find(page.blocks, &(&1["id"] == "guidance-details"))

    for interaction <- interactions do
      assert Enum.any?(details["props"]["fields"], &(&1["value"] == interaction["body"]))
    end

    assert hd(page.blocks)["props"]["actions"] == []
    refute Enum.any?(page.console_actions, &(&1.operation["name"] == "worker_output_subscribe"))
  end

  test "history continuation fixes the exact execution and correlated durable cursor" do
    {page, target} = fixture(%{"facts" => [], "after_position" => 50, "more" => true})
    history = Enum.find(page.console_actions, &(&1.operation["name"] == "worker_history"))
    assert history.operation["execution"] == target
    assert {:ok, cursor} = Base.url_decode64(history.operation["cursor"], padding: false)
    assert JSON.decode!(cursor) == [AtlasBus.environment(), "viewer", "execution", nil, 50]
    receipts = Enum.find(page.console_actions, &(&1.operation["name"] == "worker_receipts"))

    assert receipts.operation == %{
             "name" => "worker_receipts",
             "execution" => target,
             "interaction_source" => "selected_history"
           }

    assert receipts.on == "guidance-history"
    assert receipts.row == nil
    assert {:ok, projected} = project(page, target)
    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)
    assert Enum.any?(projection.actions, &(&1["props"]["operation"] == history.operation))
    assert Enum.any?(projection.actions, &(&1["props"]["operation"] == receipts.operation))
  end

  test "failed history read declares no history or receipt operation" do
    {page, _target} = fixture(%{"error" => "unavailable"})
    assert block(page, "guidance-history")["type"] == "item"
    assert [_reason] = values(block(page, "guidance-history"))

    refute Enum.any?(
             page.console_actions,
             &(&1.operation["name"] in ["worker_history", "worker_receipts"])
           )
  end

  test "authoritative output capability is independent of guidance and fixes the execution" do
    capability = fn execution ->
      send(self(), {:output_target, execution})
      %{"available" => true, "replay" => true}
    end

    {page, target} =
      fixture(
        %{"facts" => [], "after_position" => 0, "more" => false},
        %{output_capability: capability}
      )

    assert_received {:output_target, ^target}
    assert hd(page.blocks)["props"]["actions"] == []
    output = Enum.find(page.console_actions, &(&1.operation["name"] == "worker_output_subscribe"))
    assert output.operation == %{"name" => "worker_output_subscribe", "execution" => target}
    assert output.on == "worker-output"
    assert block(page, "worker-output")["type"] == "item"
    assert {:ok, _projected} = project(page, target)

    {page, _} =
      fixture(
        %{"facts" => [], "after_position" => 0, "more" => false},
        %{
          output_capability: fn ^target ->
            %{"available" => false, "replay" => false, "reason" => "output_unavailable"}
          end
        }
      )

    refute Enum.any?(page.console_actions, &(&1.operation["name"] == "worker_output_subscribe"))

    # Why output cannot be read is a detail of the stream, not the conversation.
    assert "output_unavailable" in values(block(page, "worker-output-details"))
    refute "output_unavailable" in values(block(page, "worker-output"))
  end

  # A standalone turn: no item, an execution that knows neither its harness version nor
  # a configured model, the title and model Runtime reported on the turn.
  @finished [
    values: %{
      "reason" => "finished",
      "done_at" => "2026-11-13T12:40:00Z",
      "until" => "",
      "about" => "fixture title",
      "engine" => "fixture-model"
    },
    execution: %{
      "harness_version" => "unknown",
      "configured_model" => "unknown",
      "recorded_at" => "2026-11-13T11:30:00Z"
    }
  ]

  test "a finished standalone turn leads with what it was and says nothing it does not know" do
    {page, _target} = fixture(@none, %{}, @finished)
    worker = block(page, "worker")
    shown = values(worker)

    assert worker["props"]["title"] == "fixture title"

    for known <- ["fixture-model", "codex", "page-machine", "page-worker", "page-turn"],
        do: assert(known in shown)

    assert AtlasBus.environment() in shown

    # Nothing on the page is a placeholder for what nobody knows.
    for block <- page.blocks, field <- block["props"]["fields"] || [] do
      refute String.downcase(field["value"]) =~ "unknown"
      refute String.trim(field["value"]) == ""
    end

    # No item: neither the item nor its title is a field, and no action opens one.
    refute Enum.any?(page.blocks, &match?(%{"props" => %{"actions" => [_ | _]}}, &1))

    # Its start, end and duration are there because they are known, and not otherwise.
    {unknown_times, _} =
      fixture(@none, %{},
        values: Map.drop(@finished[:values], ["done_at"]),
        execution: Map.drop(@finished[:execution], ["recorded_at"])
      )

    assert length(shown) == length(values(block(unknown_times, "worker"))) + 3

    # Without a reported title or model, the worker names the page and the model is left out.
    {plain, _} =
      fixture(@none, %{},
        values: Map.drop(@finished[:values], ["about", "engine"]),
        execution: @finished[:execution]
      )

    refute block(plain, "worker")["props"]["title"] == "fixture title"
    assert length(values(block(plain, "worker"))) == length(shown) - 1
  end

  test "the state is in plain words, and the model is the turn's before the execution's" do
    m =
      AtlasControl.Model.catalog(AtlasControl.Packing, %{
        "workers" => %{"read" => %{"actors" => ["viewer"]}}
      })

    about = fn values, execution ->
      run = %{
        "key" => "page-turn",
        "values" => Map.merge(%{"host" => "page-machine", "try" => "1"}, values),
        "links" => %{"worker" => ["page-worker"]}
      }

      trace =
        Map.merge(
          %{
            "key" => "execution",
            "environment" => AtlasBus.environment(),
            "machine" => "page-machine",
            "worker" => "page-worker",
            "turn" => "page-turn",
            "attempt" => "1",
            "harness" => "codex"
          },
          execution
        )

      read = fn
        "reader", _ -> %{"fact" => %{"key" => "viewer"}}
        "trace", _ -> %{"fact" => trace}
        "run", %{"key" => _} -> %{"fact" => run}
        "run", %{"linked" => _} -> %{"facts" => [run]}
      end

      target =
        WorkerPages.target(%{
          machine: "page-machine",
          worker: "page-worker",
          turn: "page-turn",
          attempt: "1"
        })

      {:ok, _view, about} =
        AtlasControl.Workers.about(m, %{key: "viewer", kind: "reader"}, target, read)

      about
    end

    assert about.(%{"status" => "going"}, %{})["status"] == "running"
    assert about.(%{"status" => "over", "reason" => "finished"}, %{})["status"] == "finished"
    assert about.(%{"status" => "over", "reason" => "failed: x"}, %{})["status"] == "failed"
    assert about.(%{"status" => "over", "reason" => "killed"}, %{})["status"] == "stopped"
    assert about.(%{"status" => "over", "reason" => "silent"}, %{})["status"] == "ended"
    # A state the page has no word for is shown as it is.
    assert about.(%{"status" => "fixture-state"}, %{})["status"] == "fixture-state"

    configured = %{"configured_model" => "asked", "reported_model" => "reported"}
    assert about.(%{"status" => "over", "engine" => "turn"}, configured)["model"] == "turn"
    assert about.(%{"status" => "over"}, configured)["model"] == "reported"
    assert about.(%{"status" => "over"}, %{"configured_model" => "asked"})["model"] == "asked"
    assert about.(%{"status" => "over"}, %{"configured_model" => "unknown"})["model"] == nil
  end

  test "a running turn says what it is doing and how long it has run, not when it ended" do
    running = [
      values: %{
        "status" => "going",
        "last" => "fixture activity",
        "until" => "2099-01-01T00:00:00Z",
        "about" => "fixture title"
      },
      execution: %{"recorded_at" => "2026-11-13T11:30:00Z"}
    ]

    {page, _} = fixture(@none, %{}, running)
    shown = values(block(page, "worker"))
    assert "fixture activity" in shown

    {ended, _} =
      fixture(@none, %{},
        values: %{
          "status" => "over",
          "reason" => "finished",
          "last" => "fixture activity",
          "about" => "fixture title"
        },
        execution: %{"recorded_at" => "2026-11-13T11:30:00Z"}
      )

    # Ended: no activity, and no end time is known here; running: the activity and the
    # duration so far (to when Control confirmed it), and never an end.
    refute "fixture activity" in values(block(ended, "worker"))
    assert length(shown) == length(values(block(ended, "worker"))) + 2
  end

  test "a line names a newer turn of the same worker exactly when there is one" do
    finished = [values: %{"reason" => "finished", "done_at" => "2026-11-13T12:00:00Z"}]

    newer = fn others, facts ->
      {page, _} = fixture(@none, %{}, Keyword.put(facts, :others, others))
      block(page, "worker-newer")
    end

    assert newer.([], finished) == nil
    # An older turn that ended before this one is not newer.
    assert newer.(
             [other("R-old", %{"status" => "over", "done_at" => "2026-11-13T11:00:00Z"})],
             finished
           ) == nil

    # A running one is; so is one that ended later. Each opens that turn's worker page.
    for later <- [
          other("R-next", %{"status" => "going", "until" => "2099-01-01T00:00:00Z"}),
          other("R-next", %{
            "status" => "over",
            "reason" => "finished",
            "done_at" => "2026-11-13T13:00:00Z"
          })
        ] do
      assert %{"type" => "list", "props" => %{"rows" => [row]}} = newer.([later], finished)
      assert row["label"] == "R-next"

      assert {:worker_page, :worker, %{turn: "R-next", attempt: "2", worker: "page-worker"}} =
               AtlasControl.Pages.route(row["to"])
    end

    # A running turn has no newer one, even beside another running turn.
    running = [values: %{"status" => "going", "until" => "2099-01-01T00:00:00Z"}]

    assert newer.(
             [other("R-next", %{"status" => "going", "until" => "2099-01-01T00:00:00Z"})],
             running
           ) == nil

    {page, _} =
      fixture(
        @none,
        %{},
        Keyword.put(finished, :others, [other("R-next", %{"status" => "going"})])
      )

    # The line sits in the Worker part, which then ends with it.
    assert hd(page.markup)["end"] == "worker-newer"
  end

  test "the details fold behind one key that projects with the page's actions" do
    {page, target} = fixture(@none, %{}, @finished)
    section = Enum.find(page.markup, &(&1["kind"] == "section"))
    ids = Enum.map(page.blocks, & &1["id"])

    inside =
      Enum.slice(
        ids,
        Enum.find_index(ids, &(&1 == section["start"]))..Enum.find_index(
          ids,
          &(&1 == section["end"])
        )
      )

    # Guidance, the execution record and the output's own state are details.
    assert Enum.all?(
             ["worker-output-details", "guidance-history", "worker-record"],
             &(&1 in inside)
           )

    refute "worker-output" in inside
    refute "worker" in inside

    toggle = Enum.find(page.console_actions, &(&1.operation["name"] == "sections_toggle"))
    assert [_key] = toggle.keys
    assert {:ok, projected} = project(page, target)
    assert {:ok, projection} = AtlasBFFContract.Console.compile(projected)
    assert Enum.any?(projection.actions, &(&1["props"]["operation"] == toggle.operation))

    # What the worker part says is not said again in the conversation or the details.
    worker_values = MapSet.new(values(block(page, "worker")))

    for id <- ["worker-output", "worker-output-details"],
        value <- values(block(page, id)),
        do: refute(MapSet.member?(worker_values, value))
  end

  describe "guidance to a running worker" do
    # A clerk's running turn on a card (`AtlasControl.Packing`); the reader may submit.
    # Whether the card is still the worker's open work, Facts' presentation of it says.
    defp submit(presentation) do
      m =
        AtlasControl.Model.catalog(AtlasControl.Packing, %{
          "workers" => %{"submit" => %{"actors" => ["viewer"]}}
        })

      target = %{
        "environment" => AtlasBus.environment(),
        "machine" => "page-machine",
        "worker" => "page-worker",
        "turn" => "page-turn",
        "attempt" => "1"
      }

      execution =
        Map.merge(target, %{
          "key" => "execution",
          "capability_version" => "1",
          "queued_input" => true,
          "durable_accept_query" => true,
          "consumption_evidence" => true
        })

      lease = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

      turn = %{
        "key" => "page-turn",
        "values" => %{
          "host" => "page-machine",
          "try" => "1",
          "status" => "going",
          "until" => lease
        },
        "links" => %{"worker" => ["page-worker"], "work" => ["C-1"]}
      }

      card = %{
        "key" => "C-1",
        "values" => %{"step" => "packing"},
        "links" => %{"holder" => ["page-worker"]},
        "presentation" => presentation
      }

      read = fn
        "reader", %{"key" => "viewer"} -> %{"fact" => %{"key" => "viewer"}}
        "trace", %{"turn" => "page-turn", "attempt" => "1"} -> %{"fact" => execution}
        "memo_note", %{"client_key" => _} -> %{"fact" => nil}
        "run", %{"key" => "page-turn"} -> %{"fact" => turn}
        "run", %{"linked" => _} -> %{"facts" => [turn]}
        "card", %{"key" => "C-1", "presentation" => true} -> %{"fact" => card}
      end

      write = fn _kind, content ->
        {:stored,
         %{
           "fact" =>
             Map.merge(content["values"], %{
               "actor" => content["by"],
               "environment" => AtlasBus.environment()
             })
         }}
      end

      request = %{
        "execution" => target,
        "guidance" => %{"client_key" => "k-1", "body" => "Look again", "cause" => "test"}
      }

      AtlasControl.Workers.handle(
        "worker_submit",
        request,
        m,
        %{key: "viewer", kind: "reader"},
        read,
        write
      )
    end

    @open %{"owner" => ["page-worker"], "actionable" => true, "handover" => nil}

    test "is taken while the work is the worker's and open" do
      assert {:ok, %{"interaction" => _}} = submit(@open)
    end

    test "is refused once its run ended, or a handover waits, or the work is another's" do
      for shown <- [
            %{@open | "actionable" => false},
            %{@open | "handover" => %{"from" => ["page-worker"], "position" => 2}},
            %{@open | "owner" => ["someone-else"]}
          ] do
        assert {:error, "stale_execution"} = submit(shown)
      end
    end
  end
end
