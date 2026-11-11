defmodule AtlasTui.WorkerHistoryTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.{Blocks, WorkerHistory}

  @execution %{
    "worker" => %{"environment" => "test", "machine" => "machine-a", "worker" => "worker-a"},
    "turn" => "turn-a",
    "attempt" => "attempt-a"
  }

  test "independent viewers correlate their own requests and do not share cursors" do
    {first, [request_a]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    {second, [request_b]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    refute request_a["id"] == request_b["id"]
    assert request_a["execution"] == @execution
    assert {^first, []} = WorkerHistory.load(first)

    response = history_reply(request_a, [interaction("one", 1)], "a-page", true)
    assert {^second, []} = WorkerHistory.receive(second, response)
    {first, []} = WorkerHistory.receive(first, response)
    assert first.loaded
    refute second.loaded
    assert first.cursor == "a-page"
    assert second.cursor == nil
    assert {^first, []} = WorkerHistory.receive(first, response)
    assert {^first, []} = WorkerHistory.load(first)
  end

  test "explicit pages deduplicate and sort recorded positions without eagerly draining" do
    {state, [first]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    a = interaction("a", 1)
    b = interaction("b", 2)
    c = interaction("c", 3)
    {state, []} = WorkerHistory.receive(state, history_reply(first, [b, a], "page-1", true))
    assert Enum.map(state.interactions, & &1["key"]) == ["a", "b"]
    assert map_size(state.pending) == 0
    assert text(state) =~ "More history pages available"

    {state, [next]} = WorkerHistory.next(state)
    assert next["cursor"] == "page-1"
    assert next["execution"] == @execution
    assert {^state, []} = WorkerHistory.next(state)
    {state, []} = WorkerHistory.receive(state, history_reply(next, [c, b], "page-2", false))
    assert Enum.map(state.interactions, & &1["key"]) == ["a", "b", "c"]
    assert {^state, []} = WorkerHistory.next(state)
    assert text(state) =~ "End of history at last fetch"
  end

  test "refresh supersedes interrupted reads, updates projections, and retains historical evidence" do
    {state, [first]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    a = interaction("a", 1)
    b = interaction("b", 2)
    {state, []} = WorkerHistory.receive(state, history_reply(first, [a], "page-1", true))
    {state, [next]} = WorkerHistory.next(state)
    {state, []} = WorkerHistory.receive(state, history_reply(next, [b], "page-2", true))
    {state, [interrupted]} = WorkerHistory.next(state)
    {state, [interrupted_receipts]} = WorkerHistory.receipts(state, "a")
    {state, [refresh]} = WorkerHistory.refresh(state)
    refute Map.has_key?(refresh, "cursor")
    assert state.stale == MapSet.new(["a", "b"])
    assert map_size(state.pending) == 1
    assert text(state) =~ "Stale: last known projection"

    assert {^state, []} =
             WorkerHistory.receive(state, history_reply(interrupted, [], "late", false))

    assert {^state, []} =
             WorkerHistory.receive(state, receipt_reply(interrupted_receipts, [], "late", false))

    updated = %{
      a
      | "projection" => %{
          "proven" => "admitted",
          "uncertain" => true,
          "closures" => ["attempt_ended"]
        },
        "receipt_count" => 2
    }

    {state, []} = WorkerHistory.receive(state, history_reply(refresh, [updated], "page-1", true))
    assert state.interactions == [updated, b]
    assert state.cursor == "page-2"
    assert state.stale == MapSet.new(["b"])
    assert text(state) =~ "attempt_ended"
    {state, [retry]} = WorkerHistory.receipts(state, "a")
    refute retry["id"] == interrupted_receipts["id"]
    assert map_size(state.pending) == 1
  end

  test "refresh probes an exhausted multi-page frontier once without phantom or eager continuation" do
    first_page = Enum.map(1..50, &interaction("i#{&1}", &1))
    second_page = Enum.map(51..52, &interaction("i#{&1}", &1))
    updated_first = put_in(hd(first_page), ["projection", "proven"], "admitted")
    refreshed_page = [updated_first | tl(first_page)]

    for {tail, more, cursor} <- [
          {[], false, "position-52"},
          {[interaction("i53", 53)], false, "position-53"},
          {Enum.map(53..102, &interaction("i#{&1}", &1)), true, "position-102"}
        ] do
      {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()

      {state, []} =
        WorkerHistory.receive(state, history_reply(request, first_page, "position-50", true))

      {state, [request]} = WorkerHistory.next(state)

      {state, []} =
        WorkerHistory.receive(state, history_reply(request, second_page, "position-52", false))

      refute state.more

      {state, [refresh]} = WorkerHistory.refresh(state)

      {state, [probe]} =
        WorkerHistory.receive(state, history_reply(refresh, refreshed_page, "position-50", true))

      assert probe["cursor"] == "position-52"
      assert probe["execution"] == @execution
      refute probe["id"] == refresh["id"]
      assert state.cursor == "position-52"
      refute state.more
      assert state.stale == MapSet.new(["i51", "i52"])
      assert hd(state.interactions) == updated_first
      assert text(state) =~ "Loading one history page"
      assert {^state, []} = WorkerHistory.next(state)

      reply = history_reply(probe, tail, cursor, more)
      assert {^state, []} = WorkerHistory.receive(state, %{reply | "id" => refresh["id"]})
      {superseded, [_new_refresh]} = WorkerHistory.refresh(state)
      assert {^superseded, []} = WorkerHistory.receive(superseded, reply)

      {state, []} = WorkerHistory.receive(state, reply)
      assert state.interactions == refreshed_page ++ second_page ++ tail
      assert state.cursor == cursor
      assert state.more == more
      assert state.pending == %{}
      assert state.stale == MapSet.new(["i51", "i52"])

      if more do
        assert text(state) =~ "More history pages available"
        {_, [next]} = WorkerHistory.next(state)
        assert next["cursor"] == cursor
      else
        assert text(state) =~ "End of history at last fetch"
        assert {^state, []} = WorkerHistory.next(state)
      end
    end
  end

  test "literal Unicode, actor, cause, positions and projections remain recorded facts in generic blocks" do
    body = "  λ雪 👩🏽‍💻\n\npartial <draft>\t\"quoted\"  \n"

    record = %{
      interaction("unicode", 17)
      | "body" => body,
        "actor" => "actor-Ж",
        "cause" => "cause-雪",
        "projection" => %{
          "proven" => "accepted",
          "uncertain" => true,
          "closures" => ["execution_expired", "unknown_結果"]
        }
    }

    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    {state, []} = WorkerHistory.receive(state, history_reply(request, [record], "end", false))
    assert hd(state.interactions)["body"] == body
    blocks = WorkerHistory.blocks(state)

    assert Enum.all?(blocks, fn {id, block} -> is_binary(id) and match?(%Blocks.Item{}, block) end)

    {_, block} = Enum.find(blocks, fn {id, _} -> id == "worker-history-interaction:unicode" end)
    assert block.title == "actor-Ж — recorded projection: accepted (uncertain)"
    assert hd(block.fields).label == "body"
    assert hd(block.fields).value == body
    fields = Map.new(block.fields, &{&1.label, &1.value})
    assert fields["body"] == body
    assert fields["actor"] == "actor-Ж"
    assert fields["cause"] == "cause-雪"
    assert fields["recorded_position"] == "17"
    assert fields["projection.proven"] == "accepted"
    assert fields["projection.uncertain"] == "true"
    assert JSON.decode!(fields["projection.closures"]) == record["projection"]["closures"]
    refute text(state) =~ "delivered"
    refute text(state) =~ "acknowledged"
    assert block.actions == nil
  end

  test "receipt pages are scoped to loaded interactions and independent of history cursors" do
    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    assert {^state, []} = WorkerHistory.receipts(state, "a")

    {state, []} =
      WorkerHistory.receive(
        state,
        history_reply(request, [interaction("a", 1)], "history-page", true)
      )

    assert {^state, []} = WorkerHistory.receipts(state, "foreign")
    {state, [request]} = WorkerHistory.receipts(state, "a")
    assert request["interaction"] == "a"
    refute Map.has_key?(request, "cursor")
    assert {^state, []} = WorkerHistory.receipts(state, "a")
    r1 = receipt("r1", "a", 2)
    r2 = %{receipt("r2", "a", 3) | "reason" => "Runtime evidence unavailable: 雪"}
    {state, []} = WorkerHistory.receive(state, receipt_reply(request, [r1], "receipt-page", true))
    assert state.cursor == "history-page"
    assert state.receipt_pages["a"].cursor == "receipt-page"
    {state, [request]} = WorkerHistory.receipts(state, "a")
    assert request["cursor"] == "receipt-page"

    {state, []} =
      WorkerHistory.receive(state, receipt_reply(request, [r2, r1], "receipt-end", false))

    assert state.receipt_pages["a"].receipts == [r1, r2]
    assert {^state, []} = WorkerHistory.receipts(state, "a")
    assert text(state) =~ "Runtime evidence unavailable: 雪"
    assert text(state) =~ "evidence-r2"
    assert text(state) =~ "admission-r2"
    assert text(state) =~ "consumption-r2"
    assert text(state) =~ "receipt-writer"
    assert text(state) =~ "receipt-cause"
    {_, [request]} = WorkerHistory.next(state)
    assert request["cursor"] == "history-page"
  end

  test "missing exact execution refuses reads and malformed or foreign records never enter history" do
    for execution <- [
          nil,
          %{},
          Map.delete(@execution, "attempt"),
          put_in(@execution, ["worker", "machine"], "")
        ] do
      state = WorkerHistory.new(execution)
      assert {^state, []} = WorkerHistory.load(state)
      assert text(state) =~ "Exact execution unavailable"
    end

    for field <- ~w(environment worker turn attempt) do
      {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
      foreign = Map.put(interaction("foreign", 1), field, "foreign")
      {state, []} = WorkerHistory.receive(state, history_reply(request, [foreign], "end", false))
      refute state.loaded
      assert state.interactions == []
      assert text(state) =~ "does not match the exact execution"
    end

    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    reply = history_reply(request, [interaction("a", 1)], "end", false)

    malformed =
      update_in(reply, ["interactions"], fn [record] -> [Map.delete(record, "execution")] end)

    {state, []} = WorkerHistory.receive(state, malformed)
    assert state.interactions == []
    assert text(state) =~ "Invalid response"
  end

  test "opaque execution identity is pinned and receipts cannot cross interaction or execution" do
    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()

    {state, []} =
      WorkerHistory.receive(state, history_reply(request, [interaction("a", 1)], "page-1", true))

    {history_pending, [history_request]} = WorkerHistory.next(state)
    foreign = %{interaction("b", 2) | "execution" => "other-execution"}

    {history_pending, []} =
      WorkerHistory.receive(
        history_pending,
        history_reply(history_request, [foreign], "end", false)
      )

    assert history_pending.interactions == state.interactions

    for foreign <- [
          Map.put(receipt("bad", "a", 2), "execution", "other-execution"),
          receipt("bad", "other-interaction", 2)
        ] do
      {pending, [request]} = WorkerHistory.receipts(state, "a")

      {rejected, []} =
        WorkerHistory.receive(pending, receipt_reply(request, [foreign], "end", false))

      assert rejected.receipt_pages["a"].receipts == []
      assert text(rejected) =~ "does not match the exact interaction"
    end
  end

  test "correlated errors preserve readable stale fallback while unrelated messages are ignored" do
    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    record = interaction("a", 1)
    {state, []} = WorkerHistory.receive(state, history_reply(request, [record], "page", true))
    {state, [request]} = WorkerHistory.next(state)

    error =
      Wire.reply(:worker_history, :error,
        id: request["id"],
        error: %{
          code: "state_unavailable",
          message: "Durable State disconnected",
          retryable: true
        }
      )

    assert {^state, []} = WorkerHistory.receive(state, %{error | "id" => "not-pending"})
    assert {^state, []} = WorkerHistory.receive(state, %{error | "op" => "worker_receipts_error"})
    {state, []} = WorkerHistory.receive(state, error)
    assert state.interactions == [record]
    assert state.cursor == "page"
    assert state.pending == %{}
    assert text(state) =~ "Durable State disconnected"
    assert text(state) =~ "Stale: last known projection"
    assert text(state) =~ record["body"]
    {state, [retry]} = WorkerHistory.next(state)
    assert retry["cursor"] == "page"
    refute retry["id"] == request["id"]
    {state, []} = WorkerHistory.receive(state, history_reply(retry, [], "end", false))
    refute Map.has_key?(state.errors, :history)
    assert state.interactions == [record]
  end

  test "empty history and failed receipt pages report only known availability" do
    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    assert text(state) =~ "Loading one history page"
    {empty, []} = WorkerHistory.receive(state, history_reply(request, [], "end", false))
    assert text(empty) =~ "No recorded interactions"
    assert {^empty, []} = WorkerHistory.next(empty)

    {state, []} =
      WorkerHistory.receive(state, history_reply(request, [interaction("a", 1)], "end", false))

    {state, [request]} = WorkerHistory.receipts(state, "a")

    {state, []} =
      WorkerHistory.receive(
        state,
        receipt_reply(request, [receipt("r", "a", 2)], "receipt-next", true)
      )

    {state, [request]} = WorkerHistory.receipts(state, "a")

    error =
      Wire.reply(:worker_receipts, :error,
        id: request["id"],
        error: %{
          code: "unavailable",
          message: "Receipts offline",
          retryable: true
        }
      )

    {state, []} = WorkerHistory.receive(state, error)
    assert length(state.receipt_pages["a"].receipts) == 1
    assert text(state) =~ "Stale: last known receipt evidence"
    assert text(state) =~ "Receipts offline"
    assert text(state) =~ "evidence-r"
  end

  test "immutable changes and nonadvancing cursors cannot overwrite loaded evidence" do
    {state, [request]} = WorkerHistory.new(@execution) |> WorkerHistory.load()
    record = interaction("a", 1)
    {state, []} = WorkerHistory.receive(state, history_reply(request, [record], "page", true))
    {pending, [request]} = WorkerHistory.next(state)
    changed = %{record | "body" => "rewritten"}

    {rejected, []} =
      WorkerHistory.receive(pending, history_reply(request, [changed], "end", false))

    assert rejected.interactions == [record]
    {rejected, []} = WorkerHistory.receive(pending, history_reply(request, [], "page", true))
    assert rejected.cursor == "page"
    assert Map.has_key?(rejected.errors, :history)
  end

  defp interaction(key, position) do
    %{
      "key" => key,
      "environment" => "test",
      "actor" => "actor-a",
      "client_key" => "client-#{key}",
      "body" => "Literal guidance #{key}",
      "body_digest" => "digest-#{key}",
      "worker" => "worker-a",
      "turn" => "turn-a",
      "attempt" => "attempt-a",
      "mode" => "queued_input",
      "execution" => "execution-a",
      "cause" => "cause-a",
      "recorded_at" => "2026-11-06T12:00:00Z",
      "recorded_position" => position,
      "projection" => %{"proven" => "accepted", "uncertain" => false, "closures" => []},
      "receipt_count" => 0
    }
  end

  defp receipt(key, interaction, position) do
    %{
      "key" => key,
      "environment" => "test",
      "interaction" => interaction,
      "worker" => "worker-a",
      "turn" => "turn-a",
      "attempt" => "attempt-a",
      "execution" => "execution-a",
      "stage" => "uncertain",
      "evidence_id" => "evidence-#{key}",
      "cause" => "receipt-cause",
      "writer" => "receipt-writer",
      "recorded_at" => "2026-11-06T12:01:00Z",
      "recorded_position" => position,
      "admission_id" => "admission-#{key}",
      "consumption_id" => "consumption-#{key}",
      "reason" => "Lost reply"
    }
  end

  defp history_reply(request, records, cursor, more),
    do:
      Wire.reply(:worker_history, :result,
        id: request["id"],
        interactions: records,
        cursor: cursor,
        more: more
      )

  defp receipt_reply(request, records, cursor, more),
    do:
      Wire.reply(:worker_receipts, :result,
        id: request["id"],
        receipts: records,
        cursor: cursor,
        more: more
      )

  defp text(state) do
    WorkerHistory.blocks(state)
    |> Enum.flat_map(fn {_id, block} -> Enum.map(block.fields, & &1.value) end)
    |> Enum.join("\n")
  end
end
