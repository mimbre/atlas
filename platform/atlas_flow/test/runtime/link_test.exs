defmodule AtlasFlow.Runtime.LinkTest do
  @moduledoc """
  `AtlasFlow.Runtime.Link`'s own rules, against a stub `/v1/events` that answers each open as
  the test scripts it, and a fake `client:` for `list_work`/`get_work` that records what it is
  asked (review f11-review-dev4, required changes 1–3):

  - reconnect with exponential backoff, also when the stream opens and then fails, and the
    backoff starts again after a healthy stream;
  - `reset` reads `list_work(changed_since: last handled sequence)`;
  - a `work` event whose snapshot can't be read does not advance the sequence, so the next
    open replays it.

  The contract test (`http_contract_test.exs`) runs the Link against the real Runtime.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Runtime.{Config, Link}

  defmodule Script do
    @moduledoc false
    # Per kind (`:events`, `:list_work`, `:get_work`) a queue of answers; the last one repeats.
    use Agent

    def start_link(script), do: Agent.start_link(fn -> script end, name: __MODULE__)

    def next(kind) do
      Agent.get_and_update(__MODULE__, fn script ->
        case Map.fetch!(script, kind) do
          [last] -> {last, script}
          [answer | rest] -> {answer, Map.put(script, kind, rest)}
        end
      end)
    end
  end

  defmodule Events do
    @moduledoc false
    # `GET /v1/events`: tells the test about each open (time, `Last-Event-ID`), then answers
    # `{:status, n}`, or `{:sse, frames, :close | :hold}`.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{request_path: "/v1/events"} = conn, owner) do
      last = conn |> get_req_header("last-event-id") |> List.first()
      send(owner, {:open, System.monotonic_time(:millisecond), last})

      case Script.next(:events) do
        {:status, status} ->
          send_resp(conn, status, "")

        {:sse, frames, after_frames} ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          conn = Enum.reduce(frames, conn, fn f, c -> elem(chunk(c, f), 1) end)
          if after_frames == :hold, do: Process.sleep(1_500)
          conn
      end
    end

    def call(conn, _owner), do: send_resp(conn, 404, "")
  end

  defmodule FakeClient do
    @moduledoc false
    # The two reads the Link makes; each call is told to the test.
    def list_work(_machinery, since) do
      send(:persistent_term.get({__MODULE__, :owner}), {:list_work, since})
      Script.next(:list_work)
    end

    def get_work(_machinery, work_id) do
      send(:persistent_term.get({__MODULE__, :owner}), {:get_work, work_id})
      Script.next(:get_work)
    end
  end

  setup do
    :persistent_term.put({FakeClient, :owner}, self())
    on_exit(fn -> :persistent_term.erase({FakeClient, :owner}) end)

    pid =
      start_supervised!(
        {Bandit,
         plug: {Events, self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    %{
      m: %Config{
        name: "stub",
        url: "http://127.0.0.1:#{port}",
        token_env: "ATLAS_FLOW_LINK_TEST_NO_TOKEN"
      }
    }
  end

  defp script!(script), do: start_supervised!({Script, script})

  defp link!(m, backoff),
    do:
      start_supervised!(
        {Link, machinery: m, notify: self(), client: FakeClient, backoff: backoff, idle_ms: 5_000}
      )

  defp frame(event, data, id \\ nil) do
    id = if id, do: "id: #{id}\n", else: ""
    "#{id}event: #{event}\ndata: #{JSON.encode!(data)}\n\n"
  end

  # The times of the next `n` opens (and their `Last-Event-ID`s).
  defp opens(n), do: for(_ <- 1..n, do: assert_receive({:open, at, last}, 3_000) && {at, last})

  defp gaps(opens) do
    times = Enum.map(opens, &elem(&1, 0))
    Enum.zip_with(times, tl(times), &(&2 - &1))
  end

  @work %{"work_id" => "w-6", "revision" => 2, "state" => "running", "attempts" => []}

  describe "reconnect with backoff" do
    test "a refused open (502) backs off exponentially up to max", %{m: m} do
      script!(%{events: [{:status, 502}], list_work: [{:works, [], 1}], get_work: [:not_found]})
      link!(m, {100, 400})

      assert [g1, g2, g3, g4] = gaps(opens(5))
      assert g1 >= 90 and g2 >= 190 and g3 >= 390 and g4 >= 390, inspect([g1, g2, g3, g4])
      # Capped at max: not 800.
      assert g4 < 700, inspect([g1, g2, g3, g4])
    end

    test "a stream that opens and then fails its first list_work still backs off", %{m: m} do
      script!(%{
        events: [{:sse, [], :hold}],
        list_work: [{:unreachable, :down}],
        get_work: [:not_found]
      })

      link!(m, {100, 400})

      assert [g1, g2, g3, g4] = gaps(opens(5))
      assert g1 >= 90 and g2 >= 190 and g3 >= 390 and g4 >= 390, inspect([g1, g2, g3, g4])
      assert g4 < 700, inspect([g1, g2, g3, g4])
      # Every open read list_work again (no sequence yet): the reads are paced by the backoff too.
      for _ <- 1..5, do: assert_receive({:list_work, nil}, 1_000)
    end

    test "a stream whose work event stays unreadable still backs off", %{m: m} do
      script!(%{
        events: [{:sse, [frame("work", %{"work_id" => "w-6"}, 6)], :hold}],
        list_work: [{:works, [], 5}],
        get_work: [{:unreachable, :down}]
      })

      link!(m, {100, 400})

      assert [{_, nil} | again] = opens = opens(5)
      assert Enum.all?(again, &(elem(&1, 1) == "5"))
      [g1, g2, g3, g4] = gaps(opens)
      assert g1 >= 90 and g2 >= 190 and g3 >= 390 and g4 >= 390, inspect([g1, g2, g3, g4])
    end

    test "after a healthy stream (an event handled) the backoff starts again at first",
         %{m: m} do
      capacity = %{"slots" => %{"free" => 1}}

      script!(%{
        events: [
          {:status, 502},
          {:status, 502},
          {:status, 502},
          {:sse, [frame("heartbeat", %{"capacity" => capacity}, nil)], :close},
          {:sse, [], :hold}
        ],
        list_work: [{:works, [], 3}],
        get_work: [:not_found]
      })

      link!(m, {100, 1_600})

      assert [g1, g2, g3, g4] = gaps(opens(5))
      assert g1 >= 90 and g2 >= 190 and g3 >= 390, inspect([g1, g2, g3, g4])
      assert_received {:capacity, ^capacity}
      # Without the restart it would be 800.
      assert g4 >= 90 and g4 < 400, inspect([g1, g2, g3, g4])
    end
  end

  test "reset reads list_work(changed_since: the last handled sequence)", %{m: m} do
    script!(%{
      events: [
        {:sse,
         [
           frame("work", %{"work_id" => "w-6"}, 8),
           frame("reset", %{"current_sequence" => 20})
         ], :hold}
      ],
      list_work: [{:works, [], 7}, {:works, [@work], 15}],
      get_work: [{:found, @work}]
    })

    link = link!(m, {100, 400})

    assert_receive {:list_work, nil}, 3_000
    assert_receive {:get_work, "w-6"}, 3_000
    assert_receive {:list_work, since}, 3_000
    assert since == 8
    assert_receive {:work_changed, @work}
    assert_receive {:work_changed, @work}
    assert %{sequence: 20, resets: 1, reconciles: 2} = Link.info(link)
  end

  test "a work event whose snapshot can't be read does not advance the sequence; the next open replays it",
       %{m: m} do
    script!(%{
      events: [
        {:sse, [frame("work", %{"work_id" => "w-6"}, 6)], :hold},
        {:sse, [frame("work", %{"work_id" => "w-6"}, 6)], :close},
        {:sse, [], :hold}
      ],
      list_work: [{:works, [], 5}],
      get_work: [{:unreachable, :down}, {:found, @work}]
    })

    link = link!(m, {50, 200})

    assert [{_, nil}, {_, second}, {_, third}] = opens(3)
    # The read failed: the reconnect asks again from 5, and nothing was sent for w-6.
    assert second == "5"
    assert_received {:get_work, "w-6"}
    assert_received {:get_work, "w-6"}
    assert_received {:work_changed, @work}
    refute_received {:work_changed, _}
    # Read on the replay: from then on it counts as handled.
    assert third == "6"
    assert %{sequence: 6} = Link.info(link)
  end
end
