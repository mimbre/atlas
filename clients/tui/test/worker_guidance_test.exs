defmodule AtlasTui.WorkerGuidanceTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.WorkerGuidance, as: Guidance

  @execution %{
    "worker" => %{"environment" => "test", "machine" => "machine-1", "worker" => "worker-1"},
    "turn" => "turn-1",
    "attempt" => "attempt-1"
  }
  @values %{
    "client_key" => "session-key-1",
    "body" => "  /workers\n$(printf literal); \"quoted\"\tλ  ",
    "cause" => "  reason\nunfinished:  "
  }

  defp fresh, do: Guidance.new(@execution, @values)
  defp submitting, do: Guidance.submit(fresh(), %{})

  defp interaction(changes \\ %{}) do
    %{
      "key" => "interaction-1",
      "environment" => "test",
      "actor" => "viewer-1",
      "client_key" => @values["client_key"],
      "body" => @values["body"],
      "body_digest" => "opaque-state-digest",
      "worker" => "worker-1",
      "turn" => "turn-1",
      "attempt" => "attempt-1",
      "mode" => "queued_guidance",
      "execution" => "state-execution-1",
      "cause" => @values["cause"],
      "recorded_at" => "2026-11-06T10:00:00Z",
      "recorded_position" => 1,
      "projection" => %{"proven" => "recorded", "uncertain" => false, "closures" => []},
      "receipt_count" => 0
    }
    |> Map.merge(changes)
  end

  defp result(request, values) do
    {:ok, name, _request} = Wire.decode_request(request)
    Wire.reply(name, :result, Map.put(values, "id", request["id"]))
  end

  defp error(request, code, retryable \\ false) do
    {:ok, name, _request} = Wire.decode_request(request)

    Wire.reply(name, :error, %{
      "id" => request["id"],
      "error" => %{"code" => code, "message" => "Control: " <> code, "retryable" => retryable}
    })
  end

  test "partial drafts survive edits and reconnect literally without inventing a key" do
    partial = %{"body" => @values["body"], "cause" => ""}
    state = Guidance.new(@execution, partial)
    assert state.values == partial
    assert state.attempted == nil
    assert state.status == :draft
    assert Guidance.reconnect(state) == {state, []}
    refute Map.has_key?(state.values, "client_key")

    state = Guidance.update(state, %{"cause" => @values["cause"], "client_key" => "partial-key"})
    state = Guidance.update(state, %{"body" => @values["body"] <> "\n"})
    assert state.values["cause"] == @values["cause"]
    assert state.values["body"] == @values["body"] <> "\n"
    assert state.values["client_key"] == "partial-key"
    assert Guidance.reconnect(state) == {state, []}
    assert state.pending == %{}
    assert state.execution == @execution
  end

  test "submit emits the generated exact-target protocol and fixes the literal payload" do
    {state, [request]} = submitting()
    assert {:ok, :worker_submit, ^request} = Wire.decode_request(request)
    assert request["execution"] == @execution
    assert request["guidance"] == @values
    assert state.execution == @execution
    assert state.attempted == @values
    assert state.values == @values
    assert state.status == :submitting
    assert state.pending == %{request["id"] => :worker_submit}
    assert state.interaction == nil
    assert state.error == nil

    {edited, [query]} = Guidance.submit(state, %{"body" => "not another submit"})
    assert edited.values["body"] == "not another submit"
    assert edited.attempted == @values
    assert edited.pending == %{query["id"] => :worker_query}
    assert edited.status == :querying
    assert query["op"] == "worker_query"
    assert query["execution"] == @execution
    assert query["client_key"] == @values["client_key"]
    assert Guidance.submit(edited, %{}) == {edited, []}
  end

  test "explicit submit recovers a lost successful reply while the connection stays open" do
    {state, [submit]} = submitting()
    {state, [query]} = Guidance.submit(state, %{})
    assert {:ok, :worker_query, ^query} = Wire.decode_request(query)
    assert query["execution"] == @execution
    assert query["client_key"] == @values["client_key"]
    refute query["id"] == submit["id"]
    assert state.status == :querying
    assert state.pending == %{query["id"] => :worker_query}
    assert state.attempted == @values
    assert Guidance.submit(state, %{}) == {state, []}

    assert Guidance.receive(state, result(submit, %{"interaction" => interaction()})) ==
             {state, []}

    reply = result(query, %{"found" => true, "interaction" => interaction()})
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :accepted
    assert state.interaction == interaction()
    assert state.pending == %{}
    assert Guidance.submit(state, %{}) == {state, []}
  end

  test "a live-connection negative query still requires another explicit submit to retry" do
    {state, [submit]} = submitting()
    {state, [query]} = Guidance.submit(state, %{})
    assert query["op"] == "worker_query"
    assert Guidance.submit(state, %{}) == {state, []}

    {state, []} = Guidance.receive(state, result(query, %{"found" => false}))
    assert state.status == :retryable
    assert state.pending == %{}
    assert state.interaction == nil
    assert state.attempted == @values

    {state, [retry]} = Guidance.submit(state, %{})
    assert retry["op"] == "worker_submit"
    assert retry["execution"] == @execution
    assert retry["guidance"] == submit["guidance"]
    refute retry["id"] in [submit["id"], query["id"]]
    assert state.status == :submitting
  end

  test "partial invalid submission remains a draft with no attempted delivery" do
    state = Guidance.new(@execution, %{"body" => @values["body"]})
    {state, []} = Guidance.submit(state, %{})
    assert state.status == :error
    assert state.error["code"] == "invalid_request"
    assert state.attempted == nil
    assert state.pending == %{}
    assert state.values == %{"body" => @values["body"]}
    assert Guidance.reconnect(state) == {state, []}

    {state, [request]} = Guidance.submit(state, Map.take(@values, ["client_key", "cause"]))
    assert request["guidance"] == @values
    assert state.status == :submitting
  end

  test "only a correlated matching interaction proves acceptance, never consumption" do
    {state, [request]} = submitting()
    accepted = interaction()
    {state, []} = Guidance.receive(state, result(request, %{"interaction" => accepted}))
    assert state.status == :accepted
    assert state.interaction == accepted
    assert state.interaction["projection"]["proven"] == "recorded"
    assert state.interaction["receipt_count"] == 0
    assert state.attempted == @values
    assert state.values == @values
    assert state.pending == %{}
    assert Guidance.reconnect(state) == {state, []}
    assert Guidance.submit(state, %{}) == {state, []}
    assert Guidance.receive(state, error(request, "stale_target")) == {state, []}
  end

  test "a lost successful reply is recovered by exact-key query without resubmission" do
    {state, [submit]} = submitting()
    state = Guidance.update(state, %{"body" => "retained but not attempted draft"})
    {state, [query]} = Guidance.reconnect(state)
    assert {:ok, :worker_query, ^query} = Wire.decode_request(query)
    assert query["execution"] == @execution
    assert query["client_key"] == @values["client_key"]
    refute query["id"] == submit["id"]
    assert state.pending == %{query["id"] => :worker_query}
    assert state.status == :querying
    assert state.attempted == @values
    assert Guidance.submit(state, %{}) == {state, []}

    delayed = result(submit, %{"interaction" => interaction()})
    assert Guidance.receive(state, delayed) == {state, []}

    reply = result(query, %{"found" => true, "interaction" => interaction()})
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :accepted
    assert state.interaction == interaction()
    assert state.values["body"] == "retained but not attempted draft"
    assert state.attempted == @values
    assert state.execution == @execution
    assert state.pending == %{}
  end

  test "a negative query allows only an explicit identical retry with a fresh request id" do
    {state, [submit]} = submitting()
    {state, [query]} = Guidance.reconnect(state)
    negative = result(query, %{"found" => false})
    {state, []} = Guidance.receive(state, negative)
    assert state.status == :retryable
    assert state.interaction == nil
    assert state.attempted == @values
    assert state.pending == %{}

    for field <- ["body", "cause", "client_key"] do
      {refused, []} = Guidance.submit(state, %{field => "different"})
      assert refused.error["code"] == "immutable_payload"
      assert refused.attempted == @values
      assert refused.values[field] == "different"
      assert refused.pending == %{}
      assert refused.interaction == nil
      assert refused.execution == @execution
    end

    {state, [retry]} = Guidance.submit(state, @values)
    assert retry["execution"] == @execution
    assert retry["guidance"] == submit["guidance"]
    refute retry["id"] in [submit["id"], query["id"]]
    assert state.attempted == @values
    assert state.status == :submitting
    assert Guidance.receive(state, negative) == {state, []}

    assert Guidance.receive(state, result(submit, %{"interaction" => interaction()})) ==
             {state, []}

    {state, []} = Guidance.receive(state, result(retry, %{"interaction" => interaction()}))
    assert state.status == :accepted
  end

  test "reconnecting after a negative query queries again instead of retrying automatically" do
    {state, [_submit]} = submitting()
    {state, [query]} = Guidance.reconnect(state)
    {state, []} = Guidance.receive(state, result(query, %{"found" => false}))
    {state, [next_query]} = Guidance.reconnect(state)
    assert next_query["op"] == "worker_query"
    assert next_query["execution"] == @execution
    assert next_query["client_key"] == @values["client_key"]
    assert state.status == :querying
    assert state.attempted == @values
    assert Guidance.submit(state, %{}) == {state, []}
  end

  test "repeated reconnects invalidate delayed query results and errors" do
    {state, [_submit]} = submitting()
    {state, [old_query]} = Guidance.reconnect(state)
    {state, [query]} = Guidance.reconnect(state)
    refute old_query["id"] == query["id"]
    assert state.pending == %{query["id"] => :worker_query}
    assert Guidance.receive(state, result(old_query, %{"found" => false})) == {state, []}

    assert Guidance.receive(
             state,
             result(old_query, %{"found" => true, "interaction" => interaction()})
           ) == {state, []}

    assert Guidance.receive(state, error(old_query, "state_unavailable", true)) == {state, []}
    {state, []} = Guidance.receive(state, result(query, %{"found" => false}))
    assert state.status == :retryable
  end

  test "unrelated, malformed and cross-viewer replies cannot satisfy a pending submit" do
    {state, [request]} = submitting()
    {other, [other_request]} = submitting()
    refute other_request["id"] == request["id"]
    assert other.pending != state.pending

    unknown = result(other_request, %{"interaction" => interaction()})

    wrong_operation =
      Wire.reply(:worker_query, :result, %{"id" => request["id"], "found" => false})

    valid = result(request, %{"interaction" => interaction()})

    for reply <- [unknown, wrong_operation, nil, "not a reply", %{}] do
      assert Guidance.receive(state, reply) == {state, []}
    end

    malformed = [
      Map.put(valid, "version", "999.0.0"),
      Map.put(valid, "channel", "runtime"),
      Map.delete(valid, "interaction"),
      Map.put(valid, "extra", true),
      put_in(valid, ["interaction", "receipt_count"], "not an integer")
    ]

    for reply <- malformed do
      {rejected, []} = Guidance.receive(state, reply)
      assert rejected.status == :unknown
      assert rejected.attempted == state.attempted
      assert rejected.pending == %{}
      assert rejected.interaction == nil
    end
  end

  test "foreign targets and conflicting payloads are refused for submit and query results" do
    changes = [
      %{"environment" => "prod"},
      %{"worker" => "worker-2"},
      %{"turn" => "successor-turn"},
      %{"attempt" => "successor-attempt"},
      %{"client_key" => "another-key"},
      %{"body" => "different body"},
      %{"cause" => "different cause"},
      %{"mode" => "another-mode"}
    ]

    for change <- changes, operation <- [:worker_submit, :worker_query] do
      {state, [request]} = submitting()

      {state, [request]} =
        if operation == :worker_query, do: Guidance.reconnect(state), else: {state, [request]}

      fields = %{"interaction" => interaction(change)}
      fields = if operation == :worker_query, do: Map.put(fields, "found", true), else: fields
      {state, []} = Guidance.receive(state, result(request, fields))
      assert state.status == :unknown
      assert state.error["code"] == "invalid_reply"
      assert state.interaction == nil
      assert state.pending == %{}
      assert state.attempted == @values
      assert state.execution == @execution

      {state, [query]} = Guidance.submit(state, %{})
      assert state.status == :querying
      assert query["op"] == "worker_query"
      assert query["execution"] == @execution
      assert query["client_key"] == @values["client_key"]
    end
  end

  test "incomplete or contradictory query results do not prove acceptance or permit retry" do
    {state, [_submit]} = submitting()
    {state, [query]} = Guidance.reconnect(state)

    for fields <- [
          %{"found" => true},
          %{"found" => false, "interaction" => interaction()}
        ] do
      {refused, []} = Guidance.receive(state, result(query, fields))
      assert refused.status == :unknown
      assert refused.error["code"] == "invalid_reply"
      assert refused.interaction == nil
      assert refused.attempted == @values
      {recovering, [next_query]} = Guidance.submit(refused, %{})
      assert recovering.status == :querying
      assert recovering.interaction == nil
      assert next_query["op"] == "worker_query"
      assert next_query["execution"] == @execution
      assert next_query["client_key"] == @values["client_key"]
    end
  end

  test "unknown outcomes and retryable query errors preserve uncertainty and the attempted key" do
    {state, [request]} = submitting()
    reply = error(request, "outcome_unknown")
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :unknown
    assert state.error == reply["error"]
    assert state.pending == %{}
    assert state.interaction == nil

    {state, [query]} = Guidance.submit(state, %{})
    assert query["op"] == "worker_query"
    reply = error(query, "state_unavailable", true)
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :unknown
    assert state.error == reply["error"]
    assert state.error["retryable"]
    assert state.attempted == @values

    {_state, [next_query]} = Guidance.submit(state, %{})
    assert next_query["op"] == "worker_query"
    assert next_query["execution"] == @execution
    assert next_query["client_key"] == @values["client_key"]
  end

  test "typed stale-target rejection is surfaced and never retargets a successor" do
    {state, [request]} = submitting()
    reply = error(request, "stale_target")
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :error
    assert state.error == reply["error"]
    assert state.execution == @execution
    assert state.attempted == @values
    assert state.values == @values
    assert state.interaction == nil
    assert state.pending == %{}

    {state, [query]} = Guidance.submit(state, %{})
    assert query["op"] == "worker_query"
    assert query["execution"] == @execution
    assert query["client_key"] == @values["client_key"]
    reply = error(query, "target_mismatch")
    {state, []} = Guidance.receive(state, reply)
    assert state.status == :unknown
    assert state.error == reply["error"]
    assert state.execution == @execution
    assert state.interaction == nil
    {state, [next_query]} = Guidance.submit(state, %{})
    assert state.status == :querying
    assert next_query["op"] == "worker_query"
    assert next_query["execution"] == @execution
    assert next_query["client_key"] == @values["client_key"]
  end

  test "pre-admission invalid guidance remains editable without losing its key" do
    values = Map.put(@values, "body", "")
    {state, [request]} = Guidance.submit(Guidance.new(@execution, values), values)
    {state, []} = Guidance.receive(state, error(request, "invalid_guidance"))
    assert state.attempted == nil
    assert state.values == values
    corrected = Map.put(values, "body", "/stop is literal\n界")
    {state, [request]} = Guidance.submit(state, corrected)
    assert request["op"] == "worker_submit"
    assert request["guidance"] == corrected
    assert request["execution"] == @execution
    assert state.attempted == corrected
  end

  test "malformed correlated query response permits another exact query without resubmission" do
    {state, [_submit]} = submitting()
    {state, [query]} = Guidance.reconnect(state)
    malformed = result(query, %{"found" => false}) |> Map.put("found", "invalid")
    {state, []} = Guidance.receive(state, malformed)
    {state, [next]} = Guidance.submit(state, %{})
    assert next["op"] == "worker_query"
    assert next["client_key"] == @values["client_key"]
    assert next["execution"] == @execution
    assert state.attempted == @values
  end
end
