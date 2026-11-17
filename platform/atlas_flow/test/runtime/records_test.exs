defmodule AtlasFlow.Runtime.RecordsTest do
  # Plan m3 §3.5 (A2): from the reports on a lease, one task_attempt per lease with its
  # provenance, never overwritten: created by refused or started (or by ended, after
  # accepted alone), gaining the result and provenance at ended, kept once terminal, and
  # never written by another lease. Asserted on the attempt facts and the writes sent.
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runtime.Records
  alias AtlasFlow.WorkSource.Translate

  @task "TK-B-7-1"
  @lease "TK-B-7-1~1~AAAAAAAAAAAAAAAAAAAAAA"
  @later "TK-B-7-1~2~BBBBBBBBBBBBBBBBBBBBBB"

  setup do
    Application.put_env(:atlas_bus, :store, "records-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow/delivery")
    :ok
  end

  defp attempt(n \\ 1), do: FakeFacts.get("task_attempt", Records.attempt_key(@task, n))
  defp writes, do: Enum.filter(FakeFacts.sent(), &String.starts_with?(&1["key"], "TA-"))
  defp ended(opts \\ []), do: Translate.normal(L.ended(nil, opts))

  test "the key of a lease's attempt names its task and attempt" do
    assert Records.attempt_key(@task, 3) == "TA-TK-B-7-1-3"
  end

  test "accepted makes no record" do
    assert {:ok, :none} = Records.record(@task, 1, @lease, %{"state" => "accepted"}, "mini")
    assert writes() == []
  end

  test "started creates the record, linked to its task and the machinery it ran on" do
    assert {:ok, :created} = Records.record(@task, 1, @lease, %{"state" => "started"}, "mini")

    assert %{"values" => %{"state" => "running", "lease_id" => @lease}, "links" => links} =
             attempt()

    assert links == %{"attempt_of" => [@task], "ran_on" => ["mini"]}
  end

  test "without a machinery fact there is no ran_on link" do
    assert {:ok, :created} = Records.record(@task, 1, @lease, %{"state" => "refused"}, nil)
    assert attempt()["links"] == %{"attempt_of" => [@task]}
    assert attempt()["values"]["state"] == "refused"
  end

  test "ended fills in the result and its last turn's provenance" do
    {:ok, :created} = Records.record(@task, 1, @lease, %{"state" => "started"}, "mini")
    assert {:ok, :changed} = Records.record(@task, 1, @lease, ended(), "mini")

    assert %{
             "state" => "completed",
             "result_kind" => "completed",
             "turn_id" => "turn-1",
             "provider" => "vendor",
             "harness" => "harness",
             "configured_model" => "model-a",
             "reported_model" => "model-a",
             "machine" => "machine-1",
             "slot" => "slot-1",
             "started_at" => "2026-11-17T12:00:10Z"
           } = attempt()["values"]
  end

  test "accepted then ended creates it at ended" do
    assert {:ok, :created} = Records.record(@task, 1, @lease, ended(kind: :failed), nil)
    assert attempt()["values"]["state"] == "failed"
  end

  test "a terminal record is never written again; a replay writes nothing" do
    {:ok, :created} = Records.record(@task, 1, @lease, ended(), nil)
    sent = length(writes())
    assert {:ok, :kept} = Records.record(@task, 1, @lease, ended(kind: :failed), nil)
    assert {:ok, :kept} = Records.record(@task, 1, @lease, %{"state" => "started"}, nil)
    assert length(writes()) == sent
    assert attempt()["values"]["state"] == "completed"
  end

  test "a running record only gains: a recorded provenance field is never replaced" do
    FakeFacts.put("task_attempt", %{
      "key" => Records.attempt_key(@task, 1),
      "version" => 0,
      "values" => %{"state" => "running", "lease_id" => @lease, "provider" => "earlier"}
    })

    assert {:ok, :changed} = Records.record(@task, 1, @lease, ended(), nil)
    assert %{"provider" => "earlier", "state" => "completed"} = attempt()["values"]
  end

  test "another lease's record is kept; each lease has its own" do
    {:ok, :created} = Records.record(@task, 1, @lease, %{"state" => "started"}, nil)
    assert {:ok, :kept} = Records.record(@task, 1, @later, ended(), nil)
    assert attempt()["values"]["state"] == "running"

    assert {:ok, :created} = Records.record(@task, 2, @later, ended(), nil)
    assert attempt(2)["values"]["lease_id"] == @later
  end

  test "a lost answer, then the same report again: one record, written once" do
    FakeFacts.lose_ack("task_attempt")
    assert {:error, _} = Records.record(@task, 1, @lease, %{"state" => "started"}, nil)
    assert {:ok, :unchanged} = Records.record(@task, 1, @lease, %{"state" => "started"}, nil)
    assert length(writes()) == 1
    assert attempt()["values"]["state"] == "running"
  end
end
