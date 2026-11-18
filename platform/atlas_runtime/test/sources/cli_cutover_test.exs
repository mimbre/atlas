defmodule AtlasRuntime.Sources.CliCutoverTest do
  @moduledoc """
  M2 A6, the CLI cut-over (M2 plan A6; Main's A6 Q1–Q3): every work command of the CLI, as
  `backend.sock` serves it (`AtlasRuntime.Backend.Rest`, the socket owner's client), goes
  to the built-in local work source; the executor gets the work only through that source's
  puller, under the same work id (Q1). A policy without `sources` has `local` (Q2). The
  output page says when the turn's output has ended (Q3), which `output --follow` stops on.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import Plug.Conn
  import Plug.Test

  alias AtlasRuntime.Backend.Rest
  alias AtlasRuntime.Model.LocalSource.QueuedWork
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Sources.{Local, Puller}
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  # The socket owner, as the listener assigns it.
  @owner {"local:owner", Rest.__rights__(:socket)}

  defp sources!(bench) do
    start_supervised!(%{
      id: :sources,
      type: :supervisor,
      start:
        {AtlasRuntime.Sources.Supervisor, :start_link,
         [bench.dir, [puller: [tick: 50, min_poll_ms: 20, retry_ms: 20]]]}
    })
  end

  defp rest(method, path, body \\ nil, headers \\ []) do
    conn =
      conn(method, path, if(body, do: JSON.encode!(body), else: ""))
      |> assign(:client, @owner)

    conn = %{conn | req_headers: conn.req_headers ++ headers}
    conn = Rest.call(conn, Rest.init([]))
    {conn.status, JSON.decode!(conn.resp_body)}
  end

  defp start(bench, instructions, key) do
    rest("POST", "/v1/work", request(bench, instructions), [
      {"content-type", "application/json"},
      {"idempotency-key", key}
    ])
  end

  defp status(id), do: elem(rest("GET", "/v1/work/#{id}"), 1)

  defp await_status(id, check) do
    await(fn -> check.(status(id)) end)
    status(id)
  end

  describe "a policy without sources (Q2: local alone)" do
    setup do
      bench = start!(%{}, local: false)
      sources!(bench)
      %{bench: bench}
    end

    test "start, status by id and by key, and output to its end: one work id throughout", %{
      bench: bench
    } do
      assert {201, %{"work_id" => id, "client" => "local:owner", "client_key" => "k-1"}} =
               start(bench, "complete", "k-1")

      # Added to the local source; the executor's record, once leased, has the same id (Q1)
      # and is the local source's client's.
      assert {:ok, %QueuedWork{client: "local:owner", client_key: "k-1"}} = Local.get(id)
      await(fn -> match?(%M.WorkRecord{}, Store.read_work(bench.dir, id)) end)

      assert %M.WorkRecord{client: "source:local", idempotency_key: ^id} =
               Store.read_work(bench.dir, id)

      done = await_status(id, &(&1["state"] == "completed"))
      assert %{"client" => "local:owner", "client_key" => "k-1", "attempts" => [attempt]} = done

      # The same key and request again is the same work (I3, at the local source).
      assert {200, %{"work_id" => ^id}} = start(bench, "complete", "k-1")
      assert {200, %{"work_id" => ^id, "client_key" => "k-1"}} = rest("GET", "/v1/work?key=k-1")

      # Q3: once the turn has ended, the page that reaches the end of its output says so.
      turn = attempt["turn_id"]
      await(fn -> match?({200, %{"ended" => true}}, rest("GET", "/v1/turns/#{turn}/output")) end)
      assert {200, %{"ended" => true, "more" => false}} = rest("GET", "/v1/turns/#{turn}/output")

      # The list shows it once, as the adder's.
      assert {200, %{"works" => works}} = rest("GET", "/v1/work")
      assert [%{"client" => "local:owner"}] = Enum.filter(works, &(&1["work_id"] == id))
    end

    test "output of a running turn is not ended; kill gets the cancel stages", %{bench: bench} do
      assert {201, %{"work_id" => id}} = start(bench, "hang", "k-hang")
      running = await_status(id, &(&1["state"] == "running"))
      turn = hd(running["attempts"])["turn_id"]

      assert {200, %{"ended" => false}} = rest("GET", "/v1/turns/#{turn}/output")

      # The cancel's outcome is the work (§8.2), its current attempt showing the cancel stage.
      assert {status, %{"work_id" => ^id, "client" => "local:owner"}} =
               rest("POST", "/v1/work/#{id}/cancel", %{"mode" => "force"}, [
                 {"content-type", "application/json"}
               ])

      assert status in [200, 202]
      assert await_status(id, &(&1["state"] == "cancelled"))
    end

    test "retry of a local work: the next attempt, under the same work id", %{bench: bench} do
      assert {201, %{"work_id" => id}} = start(bench, "complete", "k-retry")
      await_status(id, &(&1["state"] == "completed" and hd(&1["attempts"])["quiescent"]))

      assert {201, %{"work_id" => ^id, "client" => "local:owner"}} =
               rest("POST", "/v1/work/#{id}/attempts", %{}, [{"content-type", "application/json"}])

      done = await_status(id, &(length(&1["attempts"]) == 2 and &1["state"] == "completed"))
      assert done["client_key"] == "k-retry"
    end
  end

  describe "a local entry that is offered nothing (max_slots 0)" do
    setup do
      bench =
        start!(
          %{
            "sources" => [
              %{
                "name" => "local",
                "kind" => "builtin",
                "priority" => 1,
                "max_slots" => 0,
                "max_store_bytes" => 2_147_483_648
              }
            ]
          },
          local: false
        )

      sources!(bench)
      %{bench: bench}
    end

    # The A6 rule itself: the CLI's start creates nothing in the executor. Its work waits at
    # the local source, which is offered no slot here.
    test "start reaches the executor only through the local source", %{bench: bench} do
      assert {201, %{"work_id" => id, "state" => "buffered"}} = start(bench, "complete", "k-q")
      # The event: two polls of the local puller answered, so the second was sent after the
      # add (the first may have been open already). The work is still queued at the source.
      for _ <- 1..2, do: assert(:polled = Puller.poll_now(Local.puller_name()))
      assert Work.offer("local") == %{}
      assert :ok = Work.offer_done("local", 0)
      assert {:ok, %QueuedWork{state: :queued}} = Local.get(id)
      assert Path.wildcard(Path.join(bench.dir, "work/work-*.json")) == []
      assert Work.holdings("local") == []
      assert %{"state" => "buffered", "client" => "local:owner"} = status(id)
    end

    test "stop of a queued work ends it cancelled at the source; nothing reaches the executor",
         %{bench: bench} do
      assert {201, %{"work_id" => id}} = start(bench, "complete", "k-stop")

      assert {200, %{"work_id" => ^id, "state" => "cancelled"}} =
               rest("POST", "/v1/work/#{id}/cancel", %{"mode" => "graceful"}, [
                 {"content-type", "application/json"}
               ])

      assert {:ok, %QueuedWork{state: :ended, result: %{kind: :cancelled}}} = Local.get(id)
      assert Path.wildcard(Path.join(bench.dir, "work/work-*.json")) == []
      assert %{"state" => "cancelled"} = status(id)
    end
  end

  # M2 A7, the cut-over: no direct submit, so a policy whose `sources` name no `local` (an
  # explicit `[]` here) has no way in for the CLI's work. Nothing reaches the executor.
  describe "sources: [] (no local source)" do
    setup do
      bench = start!(%{"sources" => []}, local: false)
      assert AtlasRuntime.Sources.Supervisor.start_link(bench.dir) == :ignore
      %{bench: bench}
    end

    test "start is at_capacity(not_accepting) and creates nothing; a key and a retry find nothing",
         %{bench: bench} do
      refute Local.running?()
      assert {503, %{"reason" => "not_accepting"}} = start(bench, "complete", "k-none")
      assert {404, _} = rest("GET", "/v1/work?key=k-none")

      # No local work exists, so a retry has none to name (dev3's R2): not_found, not 503.
      assert {404, %{"type" => "not-found"}} =
               rest("POST", "/v1/work/work-0123456789abcdef/attempts", %{}, [
                 {"content-type", "application/json"}
               ])

      # Answered by the core after both calls above: no lease reached it, nothing is recorded.
      assert Work.holdings("local") == []
      assert Path.wildcard(Path.join(bench.dir, "work/work-*.json")) == []
      assert {200, %{"works" => []}} = rest("GET", "/v1/work")
      assert launches(bench) == []
    end
  end
end
