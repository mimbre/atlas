defmodule AtlasTui.WorkerConversationTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Blocks, Console, Model, Protocol, View, WorkerConversation}
  alias AtlasTui.ConsoleProjectionFixture, as: Fixture
  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire

  @params %{machine: "box", worker: "W-1", turn: "R-1", attempt: "attempt-1"}
  @execution %{
    "worker" => %{"environment" => "test", "machine" => "box", "worker" => "W-1"},
    "turn" => "R-1",
    "attempt" => "attempt-1"
  }

  defp form_page(key \\ "original-key", params \\ @params) do
    %{
      "op" => "page",
      "path" => Blocks.path(:worker_guidance, params),
      "reason" => "open",
      "title" => "Guidance",
      "back" => Blocks.path(:worker, params),
      "blocks" => [
        %{
          "id" => "guidance-form",
          "type" => "form",
          "props" => %{
            "title" => "Queue literal guidance",
            "submit_label" => "Queue for this exact turn",
            "submit_to" => %{
              "endpoint" => "queue_worker_guidance",
              "params" => Map.new(params, fn {k, v} -> {Atom.to_string(k), v} end)
            },
            "cancel_to" => Blocks.path(:worker, params),
            "inputs" => [
              %{
                "name" => "client_key",
                "label" => "Key",
                "kind" => "readonly",
                "value" => key,
                "required" => true
              },
              %{
                "name" => "body",
                "label" => "Literal guidance",
                "kind" => "multiline",
                "value" => "",
                "required" => true
              },
              %{
                "name" => "cause",
                "label" => "Why",
                "kind" => "text",
                "value" => "Operator request",
                "required" => true
              }
            ]
          }
        }
      ]
    }
  end

  defp initial do
    Fixture.model(%{
      "op" => "page",
      "path" => "/workers",
      "title" => "Workers",
      "blocks" => [%{"id" => "workers", "type" => "list", "props" => %{"rows" => []}}]
    })
  end

  defp editor do
    {model, _effects} = Fixture.receive(initial(), form_page())
    model
  end

  defp request(effects, op),
    do:
      Enum.find_value(effects, fn
        {:send, %{"op" => ^op} = request} -> request
        _ -> nil
      end)

  defp reply(request, fields) do
    {:ok, operation, _} = Wire.decode_request(request)
    Wire.reply(operation, :result, Map.put(fields, "id", request["id"]))
  end

  defp reconnect(model, page) do
    model = Console.disconnected(model)

    {model, []} =
      Console.receive(model, %{
        "op" => "welcome",
        "surface" => "console",
        "env" => "test",
        "spec" => Protocol.version()
      })

    {model, _} = Console.receive(model, %{"op" => "page"})

    {model, _} =
      Console.receive(model, %{
        "op" => "boot",
        "title" => "Atlas",
        "env" => "test",
        "spec" => Protocol.version(),
        "revision" => "restored",
        "initial_to" => "/workers",
        "active_tab" => "workers",
        "tabs" => [%{"id" => "workers", "label" => "Workers", "to" => "/workers"}]
      })

    Fixture.receive(model, page)
  end

  defp interaction(submit) do
    Map.merge(submit["guidance"], %{
      "key" => "interaction-1",
      "environment" => "test",
      "actor" => "H-1",
      "body_digest" => "opaque",
      "worker" => "W-1",
      "turn" => "R-1",
      "attempt" => "attempt-1",
      "mode" => "queued_guidance",
      "execution" => "execution-1",
      "recorded_at" => "2026-11-06T10:00:00Z",
      "recorded_position" => 1,
      "projection" => %{"proven" => "recorded", "uncertain" => false, "closures" => []},
      "receipt_count" => 0
    })
  end

  test "partial literal drafts and original submission key survive handshake and resize" do
    text = "/stop is literal\n  界é unfinished"
    {model, []} = Model.key(editor(), {:char, text})
    assert model.values["body"] == text
    {restored, effects} = reconnect(model, form_page("new-server-default"))
    assert restored.values == model.values
    assert restored.values["client_key"] == "original-key"
    refute request(effects, "worker_submit")
    refute request(effects, "worker_query")

    Enum.reduce([38, 140, 38], restored, fn width, current ->
      {_rows, resized} = View.frame(current, width, 40, 5)
      assert resized.values == model.values
      assert resized.conversation.guidance.values == model.values
      resized
    end)
  end

  test "lost acceptance is queried on reconnect and never resubmitted or retargeted" do
    {model, []} = Model.key(editor(), {:char, "literal guidance"})
    {model, effects} = Model.key(model, :ctrl_s)
    submit = request(effects, "worker_submit")
    assert submit["execution"] == @execution
    {model, []} = Model.key(model, {:char, "must not mutate in-flight payload"})
    assert model.values == submit["guidance"]
    {model, effects} = reconnect(model, form_page("replacement-default"))
    query = request(effects, "worker_query")
    assert query["execution"] == submit["execution"]
    assert query["client_key"] == submit["guidance"]["client_key"]
    refute request(effects, "worker_submit")

    {model, effects} =
      Console.receive(
        model,
        reply(query, %{"found" => true, "interaction" => interaction(submit)})
      )

    assert model.conversation.guidance.status == :accepted
    assert request(effects, "open")["to"] == Blocks.path(:worker, @params)
    refute request(effects, "worker_submit")
  end

  test "live lost reply uses declared submit to query before an identical explicit retry" do
    {model, []} = Model.key(editor(), {:char, "one payload"})
    {model, effects} = Model.key(model, :ctrl_s)
    original = request(effects, "worker_submit")
    {model, effects} = Model.key(model, :ctrl_s)
    query = request(effects, "worker_query")
    refute request(effects, "worker_submit")
    {model, effects} = Console.receive(model, reply(query, %{"found" => false}))
    refute request(effects, "worker_submit")
    {_, effects} = Model.key(model, :ctrl_s)
    retry = request(effects, "worker_submit")
    assert retry["execution"] == original["execution"]
    assert retry["guidance"] == original["guidance"]
  end

  test "unexpected successor page cannot replace the displayed exact-turn draft" do
    {model, []} = Model.key(editor(), {:char, "old-turn draft"})
    {model, _} = Console.navigate(model, model.path)
    successor = %{@params | turn: "R-2", attempt: "attempt-2"}
    {model, effects} = Fixture.receive(model, form_page("successor-key", successor))
    assert model.path == Blocks.path(:worker_guidance, @params)
    assert model.values["body"] == "old-turn draft"
    assert model.conversation.execution == @execution
    assert model.notice.text =~ "target changed"
    refute request(effects, "worker_submit")
  end

  test "unavailable exact turn retains readable draft without manufacturing a send form" do
    {model, []} = Model.key(editor(), {:char, "retained 界é draft"})

    page = %{
      form_page()
      | "blocks" => [
          %{
            "id" => "unavailable",
            "type" => "item",
            "props" => %{
              "title" => "Worker unavailable",
              "fields" => [%{"label" => "Reason", "value" => "stale_target"}]
            }
          }
        ]
    }

    {model, effects} = reconnect(model, page)
    assert Model.form(model) == nil
    assert View.plain(View.render(model, 100, 50, 5)) =~ "retained 界é draft"
    assert View.plain(View.render(model, 100, 50, 5)) =~ "stale_target"
    refute request(effects, "worker_submit")
    {_, effects} = Model.operation(model, "submit_form")
    refute request(effects, "worker_submit")
  end

  defp history_model do
    path = Blocks.path(:worker, @params)

    page =
      Fixture.project(%{
        "op" => "page",
        "path" => path,
        "title" => "Worker",
        "blocks" => [
          %{
            "id" => "guidance-history",
            "type" => "item",
            "props" => %{"title" => "Durable guidance", "fields" => []}
          },
          %{
            "id" => "guidance-details",
            "type" => "item",
            "props" => %{
              "title" => "Fallback details",
              "fields" => [%{"label" => "Body", "value" => "superseded fallback body"}]
            }
          }
        ]
      })

    operations = [
      {"history-next", "h",
       %{"name" => "worker_history", "execution" => @execution, "cursor" => "declared-first"}},
      {"history-receipts", "e",
       %{
         "name" => "worker_receipts",
         "execution" => @execution,
         "interaction_source" => "selected_history"
       }}
    ]

    actions =
      Enum.map(operations, fn {id, key, op} ->
        %{
          "id" => id,
          "type" => "console_action",
          "props" => %{
            "label" => id,
            "keys" => [key],
            "operation" => op,
            "available" => true,
            "scope" => %{
              "page" => path,
              "context" => "browse",
              "on" => "guidance-history",
              "revision" => page["actions_revision"]
            }
          }
        }
      end)

    page =
      page
      |> Map.update!("blocks", &(&1 ++ actions))
      |> Map.update!(
        "markup",
        &(&1 ++
            [
              %{
                "kind" => "legend",
                "start" => "history-next",
                "end" => "history-receipts",
                "props" => %{"title" => "History", "context" => "browse"}
              }
            ])
      )

    {model, effects} = Console.receive(initial(), page)
    {model, request(effects, "worker_history")}
  end

  defp history_record(key, position) do
    interaction(%{
      "guidance" => %{"client_key" => key, "body" => "Literal " <> key, "cause" => "operator"}
    })
    |> Map.merge(%{"key" => key, "recorded_position" => position})
  end

  test "declared history action follows correlated frontier and receipts bind later loaded selection" do
    {model, first} = history_model()
    assert model.console.action_error == nil
    assert AtlasTui.Interactions.capture(model, {:char, "e"}) == nil
    assert View.plain(View.render(model, 120, 80, 5)) =~ "superseded fallback body"

    {model, []} =
      Console.receive(
        model,
        reply(first, %{
          "interactions" => [history_record("I-1", 1)],
          "cursor" => "accepted-one",
          "more" => true
        })
      )

    rendered = View.plain(View.render(model, 120, 80, 5))
    assert rendered =~ "Literal I-1"
    refute rendered =~ "superseded fallback body"

    {model, effects} = Model.key(model, {:char, "h"})
    second = request(effects, "worker_history")
    assert second["cursor"] == "accepted-one"
    assert AtlasTui.Interactions.capture(model, {:char, "h"}) == nil

    {model, []} =
      Console.receive(
        model,
        reply(second, %{
          "interactions" => [history_record("I-2", 2)],
          "cursor" => "accepted-two",
          "more" => false
        })
      )

    assert AtlasTui.Interactions.capture(model, {:char, "h"}) == nil
    model = %{model | selected: 1}
    {_, effects} = Model.key(model, {:char, "e"})
    assert request(effects, "worker_receipts")["interaction"] == "I-2"
    assert request(effects, "worker_receipts")["execution"] == @execution
    # Loaded rows do not authorize movement disabled by the original Server declaration.
    assert AtlasTui.Interactions.capture(model, :down) == nil

    {refreshed, _reads} =
      Fixture.receive(model, %{
        "op" => "page",
        "path" => model.path,
        "reason" => "refresh",
        "title" => "Worker",
        "blocks" => [
          %{
            "id" => "guidance-history",
            "type" => "list",
            "props" => %{
              "rows" => [%{"id" => "I-1", "label" => "Literal I-1", "to" => model.path}]
            }
          }
        ]
      })

    assert Enum.at(Model.rows(refreshed), refreshed.selected).id == "I-2"
  end

  test "late history replies cannot replace a different displayed page" do
    {model, pending} = history_model()
    {model, _} = Console.navigate(model, "/workers")

    {model, _} =
      Fixture.receive(model, %{
        "op" => "page",
        "path" => "/workers",
        "title" => "Workers",
        "blocks" => [%{"id" => "workers", "type" => "list", "props" => %{"rows" => []}}]
      })

    {updated, []} =
      Console.receive(
        model,
        reply(pending, %{
          "interactions" => [history_record("I-1", 1)],
          "cursor" => "accepted-one",
          "more" => false
        })
      )

    assert updated.path == "/workers"
    assert updated.blocks == model.blocks
    assert updated.ids == ["workers"]
  end

  defp output_model do
    {model, _} =
      Fixture.receive(initial(), %{
        "op" => "page",
        "path" => Blocks.path(:worker, @params),
        "title" => "Worker",
        "blocks" => [
          %{
            "id" => "worker-output",
            "type" => "item",
            "props" => %{"title" => "Output", "fields" => []}
          }
        ]
      })

    model
  end

  defp output_send([{:worker_output_send, request} | _]), do: request

  defp output_reply(request, fields) do
    {:ok, operation, _} = Wire.decode_request(request)
    Wire.reply(operation, :result, Map.put(fields, "id", request["id"]))
  end

  defp retry_delay(effects),
    do:
      Enum.find_value(effects, fn
        {:worker_output_retry, delay} -> delay
        _ -> nil
      end)

  defp unavailable_view(state \\ "running", reason \\ "output_unavailable"),
    do:
      Map.merge(output_view(), %{
        "state" => state,
        "output" => %{"available" => false, "replay" => false, "reason" => reason}
      })

  # Connects as App does after its retry timer, while Control still reports
  # the exact execution's output unavailable at inspect time.
  defp unavailable_inspect(model, view \\ unavailable_view()) do
    {model, effects} = WorkerConversation.output_connected(model)
    inspect = output_send(effects)
    assert inspect["op"] == "worker_inspect"
    WorkerConversation.output_receive(model, output_reply(inspect, %{"view" => view}))
  end

  defp output_view do
    %{
      "execution" => @execution,
      "state" => "running",
      "confirmed_at" => "2026-11-09T12:00:00Z",
      "guidance" => %{"available" => false, "reason" => "guidance unsupported"},
      "output" => %{"available" => true, "replay" => true},
      "descriptor" => %{
        "harness" => "test-harness",
        "harness_version" => "1",
        "configured_model" => "configured",
        "capability_version" => "1",
        "queued_input" => false,
        "durable_accept_query" => false,
        "consumption_evidence" => false
      }
    }
  end

  defp output_stream(watermark, ended),
    do: %{
      "execution" => @execution,
      "epoch" => "epoch-a",
      "first_sequence" => 1,
      "watermark" => watermark,
      "ended" => ended
    }

  defp output_event(sequence),
    do: %{"sequence" => sequence, "kind" => "text", "text" => "line #{sequence}"}

  # Connects as App does after a (re)started output connection reports ready,
  # then subscribes from the retained cursor and drains one batch.
  defp output_drain(model, cursor, events, watermark, ended) do
    {model, effects} = WorkerConversation.output_connected(model)
    inspect = output_send(effects)
    assert inspect["op"] == "worker_inspect"

    {model, effects} =
      WorkerConversation.output_receive(model, output_reply(inspect, %{"view" => output_view()}))

    subscribe = output_send(effects)
    assert subscribe["cursor"] == cursor

    {model, _poll} =
      WorkerConversation.output_receive(
        model,
        output_reply(subscribe, %{
          "subscription" => "subscription-#{watermark}",
          "view" => output_view(),
          "stream" => output_stream(watermark, ended),
          "cursor" => cursor || "opaque-before-replay"
        })
      )

    {model, effects} = WorkerConversation.output_next(model)
    next = output_send(effects)

    WorkerConversation.output_receive(
      model,
      output_reply(next, %{
        "subscription" => next["subscription"],
        "events" => Enum.map(events, &output_event/1),
        "cursor" => "cursor-#{watermark}",
        "stream" => output_stream(watermark, ended),
        "more" => false
      })
    )
  end

  defp output_unavailable(model, retryable) do
    {model, effects} = WorkerConversation.output_next(model)
    next = output_send(effects)

    WorkerConversation.output_receive(
      model,
      Wire.reply(:worker_output_next, :error,
        id: next["id"],
        error: %{code: "output_unavailable", message: "producer link lost", retryable: retryable},
        view: output_view(),
        reset: %{reason: "output_unavailable"}
      )
    )
  end

  test "retryable output_unavailable recovers the output pane without the explicit output key" do
    model = output_model()
    assert WorkerConversation.output_target(model) == @execution
    {model, _} = output_drain(model, nil, [1], 1, false)
    assert model.conversation.output.status == :ready

    {model, effects} = output_unavailable(model, true)
    assert model.conversation.output.status == :unavailable
    # App keeps the exact target and schedules its bounded reconnect; no busy restart.
    assert WorkerConversation.output_target(model) == @execution
    assert retry_delay(effects) == 2_000
    refute :worker_output_restart in effects

    {model, _} = output_drain(model, "cursor-1", [1, 2, 3], 3, true)
    output = model.conversation.output
    assert output.status == :ended
    assert output.replay_watermark == 3
    assert Enum.map(output.events, & &1.event["text"]) == ["line 1", "line 2", "line 3"]
    assert WorkerConversation.output_target(model) == nil
  end

  test "non-retryable output_unavailable stays manual" do
    model = output_model()
    {model, _} = output_drain(model, nil, [1], 1, false)
    {model, effects} = output_unavailable(model, false)
    assert model.conversation.output.status == :unavailable
    assert effects == []
    assert WorkerConversation.output_target(model) == nil
  end

  test "consecutive unavailable inspects keep retrying with bounded backoff until output returns" do
    model = output_model()
    {model, _} = output_drain(model, nil, [1], 1, false)
    {model, effects} = output_unavailable(model, true)
    assert retry_delay(effects) == 2_000

    model =
      Enum.reduce([4_000, 8_000, 16_000, 16_000], model, fn delay, model ->
        {model, effects} = unavailable_inspect(model)
        assert model.conversation.output.status == :unavailable
        assert WorkerConversation.output_target(model) == @execution
        assert retry_delay(effects) == delay
        model
      end)

    {model, _} = output_drain(model, "cursor-1", [1, 2, 3], 3, true)
    output = model.conversation.output
    assert output.status == :ended
    assert Enum.map(output.events, & &1.event["text"]) == ["line 1", "line 2", "line 3"]
    assert WorkerConversation.output_target(model) == nil
  end

  test "an unavailable inspect right after a Console reconnect retries and backoff resets on success" do
    model = output_model()
    assert WorkerConversation.output_target(model) == @execution
    {model, effects} = unavailable_inspect(model)
    assert model.conversation.output.status == :unavailable
    assert WorkerConversation.output_target(model) == @execution
    assert retry_delay(effects) == 2_000
    {model, effects} = unavailable_inspect(model)
    assert retry_delay(effects) == 4_000

    {model, _} = output_drain(model, nil, [1], 1, false)
    assert model.conversation.output.status == :ready
    assert model.conversation.output.events |> length() == 1
    {_model, effects} = output_unavailable(model, true)
    assert retry_delay(effects) == 2_000
  end

  test "terminal, unsupported and ended unavailability stop automatic output retries" do
    for view <- [
          unavailable_view("running", "output_expired"),
          Map.delete(output_view(), "output")
        ] do
      {model, effects} = unavailable_inspect(output_model(), view)
      assert retry_delay(effects) == nil
      assert WorkerConversation.output_target(model) == nil
    end

    # Once the stream has been observed ended, an inspect for a no-longer-running
    # worker is final; while the worker still runs, unavailability stays transient.
    {ended, _} = output_drain(output_model(), nil, [1], 1, true)
    assert ended.conversation.output.status == :ended
    operation = %{"name" => "worker_output_subscribe", "execution" => @execution}
    {ended, [:worker_output_restart]} = WorkerConversation.action(ended, operation)

    {model, effects} = unavailable_inspect(ended, unavailable_view("finished"))
    assert retry_delay(effects) == nil
    assert WorkerConversation.output_target(model) == nil

    {model, effects} = unavailable_inspect(ended, unavailable_view("running"))
    assert retry_delay(effects) == 2_000
    assert WorkerConversation.output_target(model) == @execution
  end
end
