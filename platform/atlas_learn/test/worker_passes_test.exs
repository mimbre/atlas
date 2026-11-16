defmodule AtlasLearn.Observations.WorkerPassesTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.Fixtures
  alias AtlasLearn.Observations.WorkerPasses

  # Stands in for Runtime's history route on backend.sock: GET /v1/turns pages the recorded
  # turns, `per_page` at a time, with the offset as the opaque cursor; every request is sent
  # to `test`.
  defmodule HistoryRoute do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts), do: if(opts[:refuse], do: refuse(conn), else: route(conn, opts))

    defp refuse(conn) do
      conn
      |> put_resp_content_type("application/problem+json")
      |> send_resp(403, JSON.encode!(%{"type" => "not-permitted", "title" => "Forbidden"}))
    end

    defp route(%{method: "GET", request_path: "/v1/turns"} = conn, opts) do
      conn = fetch_query_params(conn)
      send(opts[:test], {:history, conn.query_params})
      turns = opts[:turns]
      from = String.to_integer(conn.query_params["cursor"] || "0")
      page = Enum.slice(turns, from, opts[:per_page])
      next = from + length(page)
      more = next < length(turns)
      body = JSON.encode!(%{"turns" => page, "cursor" => Integer.to_string(next), "more" => more})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    defp route(conn, _opts) do
      conn
      |> put_resp_content_type("application/problem+json")
      |> send_resp(404, JSON.encode!(%{"type" => "no-route", "title" => "Not Found"}))
    end
  end

  defp runtime_home(plug_opts) do
    home = Fixtures.scratch("rt")
    File.mkdir_p!(home)

    start_supervised!(
      {Bandit,
       plug: {HistoryRoute, Keyword.put(plug_opts, :test, self())},
       ip: {:local, Path.join(home, "backend.sock")},
       port: 0,
       startup_log: false}
    )

    home
  end

  test "turns that started or ended in the window are records; the others are context" do
    observation = WorkerPasses.observe(Fixtures.window(), read: Fixtures.runtime_read())

    assert observation.status == :read
    ids = Enum.map(observation.records, & &1.id)
    assert "turn-00000000000000a2" in ids
    assert "turn-00000000000000a7" in ids
    assert length(ids) == 6

    assert Enum.map(observation.context, & &1.id) |> Enum.sort() ==
             ["turn-00000000000000a1", "turn-00000000000000a8"]
  end

  test "worker, backend and model are translated from slot, harness and the models; the dropped fields are noted" do
    observation = WorkerPasses.observe(Fixtures.window(), read: Fixtures.runtime_read())
    by_id = Map.new(observation.records, &{&1.id, &1})

    # No reported model: the configured one.
    assert %{worker: "gamma", backend: "codex", model: "gpt-5"} = by_id["turn-00000000000000a6"]
    # The reported model wins over the configured one.
    assert %{worker: "beta", backend: "claude", model: "opus"} = by_id["turn-00000000000000a4"]

    for record <- observation.records ++ observation.context,
        do: assert(%{source: nil, result: nil, error: nil, recorded_state: nil} = record)

    assert Enum.any?(observation.notes, &(&1 =~ "the turn a turn continued, its result or error"))
  end

  test "pages through the history from a week before the window until a page says no more" do
    test = self()
    [first, second | rest] = Fixtures.runtime_turns()["turns"] |> Enum.chunk_every(3)
    pages = %{nil => {first, "p2"}, "p2" => {second, "p3"}, "p3" => {List.flatten(rest), nil}}

    read = fn query ->
      send(test, {:query, query})
      {turns, next} = pages[query["cursor"]]
      {:ok, %{"turns" => turns, "cursor" => next || "end", "more" => next != nil}}
    end

    observation = WorkerPasses.observe(Fixtures.window(), read: read)
    assert length(observation.records) + length(observation.context) == 8

    since = "2026-11-03T06:00:00Z"
    assert_received {:query, %{"since" => ^since, "limit" => 100} = query}
    refute Map.has_key?(query, "cursor")
    assert_received {:query, %{"since" => ^since, "cursor" => "p2"}}
    assert_received {:query, %{"cursor" => "p3"}}
    refute_received {:query, _}

    stuck = fn _ -> {:ok, %{"turns" => [], "cursor" => "same", "more" => true}} end

    assert {:unavailable, "Runtime's history page has more turns but no new cursor"} =
             WorkerPasses.observe(Fixtures.window(), read: stuck).status
  end

  test "an unreachable or refusing Runtime is reported, not raised" do
    window = Fixtures.window()

    assert {:unavailable, "cannot reach " <> _} =
             WorkerPasses.observe(window, runtime_home: Fixtures.scratch("no-runtime")).status

    refusing = fn _ -> {:refused, "not-permitted (HTTP 403)"} end

    assert {:unavailable, "Runtime refused the read: not-permitted (HTTP 403)"} =
             WorkerPasses.observe(window, read: refusing).status

    assert {:unavailable, "Runtime's reply is not a page of turns"} =
             WorkerPasses.observe(window, read: fn _ -> {:ok, %{"turns" => []}} end).status

    assert WorkerPasses.observe(window, []).status == :not_asked
  end

  test "reads list_turns over backend.sock with :httpc, page by page" do
    home = runtime_home(turns: Fixtures.runtime_turns()["turns"], per_page: 3)
    observation = WorkerPasses.observe(Fixtures.window(), runtime_home: home)

    assert observation.status == :read
    assert observation.source == "Runtime history at #{Path.join(home, "backend.sock")}"
    assert length(observation.records) == 6
    assert length(observation.context) == 2

    assert_received {:history, %{"since" => "2026-11-03T06:00:00Z", "limit" => "100"} = first}
    refute Map.has_key?(first, "cursor")
    assert_received {:history, %{"cursor" => "3"}}
    assert_received {:history, %{"cursor" => "6"}}
    refute_received {:history, _}
  end

  test "records from the Runtime equal the recorded turns field for field, but for the RQ1 drops" do
    home = runtime_home(turns: Fixtures.runtime_turns()["turns"], per_page: 100)
    observation = WorkerPasses.observe(Fixtures.window(), runtime_home: home)
    by_id = Map.new(observation.records, &{&1.id, &1})
    dropped = %{source: nil, result: nil, error: nil, recorded_state: nil}

    assert by_id["turn-00000000000000a6"] ==
             Map.merge(dropped, %{
               id: "turn-00000000000000a6",
               worker: "gamma",
               state: "failed",
               backend: "codex",
               model: "gpt-5",
               started_at: "2026-11-10T18:00:00Z",
               ended_at: "2026-11-10T18:01:00Z"
             })

    assert by_id["turn-00000000000000a5"] ==
             Map.merge(dropped, %{
               id: "turn-00000000000000a5",
               worker: "beta",
               state: "unknown",
               backend: "claude",
               model: "opus",
               started_at: "2026-11-10T16:00:00Z",
               ended_at: nil
             })

    assert by_id["turn-00000000000000a4"] ==
             Map.merge(dropped, %{
               id: "turn-00000000000000a4",
               worker: "beta",
               state: "finished",
               backend: "claude",
               model: "opus",
               started_at: "2026-11-10T14:00:00Z",
               ended_at: "2026-11-10T14:50:00Z"
             })

    assert Enum.sort(Map.keys(by_id)) ==
             Enum.map(~w(a2 a3 a4 a5 a6 a7), &"turn-00000000000000#{&1}")
  end

  test "a refusal from the backend keeps its problem type" do
    home = runtime_home(turns: [], per_page: 1, refuse: true)

    assert {:unavailable, "Runtime refused the read: not-permitted (HTTP 403)"} =
             WorkerPasses.observe(Fixtures.window(), runtime_home: home).status
  end
end
