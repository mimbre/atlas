defmodule AtlasBFFContract.WorkerActionsTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Console

  @execution %{
    "worker" => %{"environment" => "test", "machine" => "box", "worker" => "worker"},
    "turn" => "turn",
    "attempt" => "attempt"
  }

  test "worker read actions require a closed exact target and operation-specific parameters" do
    for name <- ~w(worker_history worker_output_subscribe) do
      operation = %{"name" => name, "execution" => @execution}
      assert Console.operation?(operation)
      assert Console.operation?(Map.put(operation, "cursor", "opaque-cursor"))

      for extra <- [
            %{"cursor" => 123},
            %{"cursor" => ""},
            %{"interaction_source" => "selected_history"},
            %{"interaction" => "arbitrary"},
            %{"to" => "/workers"}
          ] do
        refute Console.operation?(Map.merge(operation, extra))
      end

      for execution <- [
            Map.delete(@execution, "attempt"),
            Map.put(@execution, "attempt", " "),
            Map.put(@execution, "turn", 42),
            Map.put(@execution, "extra", "value"),
            Map.put(@execution, "worker", nil),
            put_in(@execution, ["worker", "environment"], ""),
            put_in(@execution, ["worker", "machine"], <<255>>),
            put_in(@execution, ["worker", "extra"], "value")
          ] do
        refute Console.operation?(%{operation | "execution" => execution})
      end
    end

    for name <- ~w(worker_output_next worker_output_unsubscribe worker_submit) do
      refute Console.operation?(%{"name" => name, "execution" => @execution})
    end
  end

  test "receipt actions accept only the declared selected-history binding" do
    operation = %{
      "name" => "worker_receipts",
      "execution" => @execution,
      "interaction_source" => "selected_history"
    }

    assert Console.operation?(operation)
    refute Console.operation?(Map.delete(operation, "interaction_source"))
    refute Console.operation?(%{operation | "interaction_source" => "worker-output"})
    refute Console.operation?(Map.put(operation, "interaction", "untrusted-key"))
    refute Console.operation?(Map.put(operation, "cursor", "history-cursor"))

    page = page(operation, "guidance-history")
    assert {:ok, projection} = Console.compile(page)
    current = %{path: page["path"], context: "browse", generation: 1}
    assert {:ok, event} = Console.capture(projection, "r", current)
    assert {:ok, action} = Console.resolve(projection, event, current)
    assert action["props"]["operation"] == operation

    for on <- [nil, "worker-output"] do
      assert {:error, :invalid_console_projection} = Console.compile(page(operation, on))
    end
  end

  test "new fields do not broaden existing local or navigation operations" do
    for operation <- [
          %{"name" => "refresh"},
          %{"name" => "open", "to" => "/workers"},
          %{"name" => "open_url", "url" => "https://example.com"},
          %{"name" => "agent_ask", "intent" => "Explain"}
        ] do
      assert Console.operation?(operation)
      refute Console.operation?(Map.put(operation, "execution", @execution))
      refute Console.operation?(Map.put(operation, "interaction_source", "selected_history"))
    end
  end

  defp page(operation, on) do
    %{
      "path" => "/workers/box/worker/turn/attempt",
      "actions_revision" => "revision",
      "blocks" => [
        %{"id" => "guidance-history", "type" => "text", "props" => %{"text" => "History"}},
        %{"id" => "worker-output", "type" => "text", "props" => %{"text" => "Output"}},
        %{
          "id" => "receipts",
          "type" => "console_action",
          "props" => %{
            "label" => "Receipts",
            "keys" => ["r"],
            "operation" => operation,
            "available" => true,
            "scope" => %{
              "page" => "/workers/box/worker/turn/attempt",
              "revision" => "revision",
              "context" => "browse",
              "on" => on
            }
          }
        }
      ],
      "markup" => [
        %{
          "kind" => "legend",
          "start" => "receipts",
          "end" => "receipts",
          "props" => %{"title" => "Conversation", "context" => "browse"}
        }
      ]
    }
  end
end
