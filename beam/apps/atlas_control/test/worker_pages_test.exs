defmodule AtlasControl.WorkerPagesTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{Console, WorkerPages}

  defp fixture(history, opts \\ %{}) do
    params = %{machine: "page-machine", worker: "page-worker", turn: "page-turn", attempt: "1"}
    target = WorkerPages.target(params)
    execution = Map.merge(target["worker"], Map.take(target, ~w(turn attempt)))
    execution = Map.merge(execution, %{"key" => "execution", "harness" => "codex"})

    names = %{
      "kind" => "turns",
      "machine" => "machine",
      "attempt" => "attempt",
      "by" => "by",
      "on" => "on",
      "state" => "state",
      "running" => "running",
      "lease" => "lease",
      "outcome" => "outcome"
    }

    description = %{
      "runtime" => %{"turn" => names},
      "guidance" => %{
        "control" => %{"read" => %{"actors" => ["viewer"]}},
        "execution" => %{"kind" => "executions"},
        "interaction" => %{"kind" => "interactions"}
      }
    }

    read = fn
      "readers", %{"key" => "viewer"} ->
        %{"fact" => %{"key" => "viewer"}}

      "executions", %{"turn" => "page-turn", "attempt" => "1"} ->
        %{"fact" => execution}

      "turns", %{"key" => "page-turn"} ->
        %{
          "fact" => %{
            "key" => "page-turn",
            "values" => %{"machine" => "page-machine", "attempt" => "1", "state" => "done"},
            "links" => %{"by" => ["page-worker"]}
          }
        }

      "interactions", %{"execution" => "execution", "after_position" => 0, "limit" => 50} ->
        history
    end

    page =
      WorkerPages.render(
        {:worker_page, :worker, params},
        description,
        %{key: "viewer", kind: "readers"},
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
