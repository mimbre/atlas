defmodule AtlasControl.WorkerPagesTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{Console, WorkerPages}

  defp fixture(history, opts \\ %{}) do
    params = %{machine: "page-machine", worker: "page-worker", turn: "page-turn", attempt: "1"}
    target = WorkerPages.target(params)
    execution = Map.merge(target["worker"], Map.take(target, ~w(turn attempt)))
    execution = Map.merge(execution, %{"key" => "execution", "harness" => "codex"})

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
        %{
          "fact" => %{
            "key" => "page-turn",
            "values" => %{"host" => "page-machine", "try" => "1", "status" => "over"},
            "links" => %{"worker" => ["page-worker"]}
          }
        }

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
    {page, target} = fixture(%{"facts" => [], "after_position" => 0, "more" => false})
    assert Enum.map(page.blocks, & &1["id"]) == ["worker", "guidance-history", "worker-output"]

    assert Enum.map(page.markup, &{&1["start"], &1["end"], &1["props"]["role"]}) == [
             {"worker", "worker", "main"},
             {"guidance-history", "worker-output", "related"}
           ]

    assert List.last(page.blocks)["props"]["title"] == "Output unavailable"
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
    assert Enum.at(page.blocks, 1)["props"]["title"] == "History unavailable"

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
    assert List.last(page.blocks)["props"]["title"] == "Worker output"
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

    assert List.last(page.blocks)["props"]["fields"] == [
             %{"label" => "Reason", "value" => "output_unavailable"}
           ]
  end
end
