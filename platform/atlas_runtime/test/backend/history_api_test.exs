defmodule AtlasRuntime.Backend.HistoryApiTest do
  @moduledoc """
  The one router on the history contract (BK2′; design §8, §13.1 Q1, Q2): one test per
  resource × outcome through the test facade (`AtlasRuntime.Test.HistoryFacade` on
  `AtlasRuntime.Test.FakeHistory`), the routing next to work's turn output, the query
  decode, and the facade's refusals.
  """
  # The fakes' answers are global.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntime.Test.{FakeHistory, FakeWork, WorkRest}
  alias AtlasRuntime.Test.HistoryFacade, as: F

  @socket {"local:test", WorkRest.__rights__(:socket)}

  setup do
    FakeWork.reset_all()
    FakeHistory.reset_all()
    FakeWork.owner(self())

    on_exit(fn ->
      FakeWork.reset_all()
      FakeHistory.reset_all()
    end)
  end

  defp request(path, client \\ @socket),
    do: conn("GET", path) |> assign(:client, client) |> WorkRest.call(WorkRest.init([]))

  defp ok(conn) do
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]
    JSON.decode!(conn.resp_body)
  end

  defp problem(conn, status, type) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/problem+json"]

    assert %{"type" => ^type, "status" => ^status, "title" => _} =
             body = JSON.decode!(conn.resp_body)

    body
  end

  defp called(capability) do
    assert_received {:fake_history, ^capability, client, input}
    {client, input}
  end

  defp turn_json(id \\ "turn-0000000000000001"), do: F.Turn.dump(FakeHistory.a_turn(id))

  describe "resource × outcome → status" do
    test "GET /v1/turns: turns → 200, the page itself" do
      assert ok(request("/v1/turns")) == %{
               "turns" => [turn_json()],
               "cursor" => "h:1",
               "more" => false
             }

      assert {@socket, %F.ListTurnsInput{slot: nil, since: nil, cursor: nil, limit: nil}} =
               called(:list_turns)
    end

    test "GET /v1/turns/{turn_id}: found → 200, the turn" do
      assert ok(request("/v1/turns/turn-0000000000000002")) == %{
               "turn" => turn_json("turn-0000000000000002")
             }

      assert {@socket, %F.GetTurnInput{turn_id: "turn-0000000000000002"}} = called(:get_turn)
    end

    test "GET /v1/turns/{turn_id}: not_found → 404 not-found" do
      FakeHistory.answer(:get_turn, fn _client, _input -> %F.Outcome.NotFound{} end)
      body = problem(request("/v1/turns/turn-0000000000000009"), 404, "not-found")
      assert Map.keys(body) |> Enum.sort() == ["status", "title", "type"]
    end
  end

  describe "routing next to the work contract" do
    test "GET /v1/turns/{id}/output reaches work's turn_output; GET /v1/turns/{id} reaches history" do
      request("/v1/turns/turn-0000000000000003/output")
      assert_received {:fake_work, :turn_output, _client, %{turn_id: "turn-0000000000000003"}}
      refute_received {:fake_history, _, _, _}

      request("/v1/turns/turn-0000000000000003")
      assert {_, %F.GetTurnInput{turn_id: "turn-0000000000000003"}} = called(:get_turn)
      refute_received {:fake_work, _, _, _}
    end

    test "a turn id is one encoded path segment" do
      ok(request("/v1/turns/a%2Fb"))
      assert {_, %F.GetTurnInput{turn_id: "a/b"}} = called(:get_turn)
    end
  end

  describe "get_turn declared on another path (BK2 1c)" do
    defp shadow(name, path) do
      Code.compile_string("""
      defmodule #{name} do
        use AtlasRuntimeBackend.Generator.Schema

        version "0.1.0"
        boundary AtlasRuntimeBoundary.History
        expose [:list_turns, :get_turn]
        rights :socket, [:read, :read_all]

        target :rest, carries: :entities do
          resource :get, "/v1/turns",
            capability: :list_turns,
            query: [slot: :slot, since: :since, cursor: :cursor, limit: :limit]

          resource :get, "#{path}", capability: :get_turn
          status :turns, 200
          status :found, 200
          status :not_found, 404, type: "not-found"
          error :invalid, 400, type: "invalid"
          error :not_permitted, 403, type: "not-permitted"
          error :no_route, 404, type: "no-route"
          error :unauthenticated, 401, type: "unauthenticated"
          error :origin_refused, 403, type: "origin-refused"
        end
      end

      defmodule #{name}.Rest do
        use AtlasRuntimeBackend.Generator.Targets.Rest,
          contracts: [
            work:
              {AtlasRuntimeBackend.Work,
               facade: AtlasRuntime.Test.WorkFacade, stream: AtlasRuntime.Backend.Events},
            history: {#{name}, facade: AtlasRuntime.Test.HistoryFacade}
          ]
      end
      """)
    end

    test "on work's output path it overlaps work's turn_output" do
      error =
        assert_raise CompileError, fn ->
          shadow("AtlasRuntime.Backend.HistoryApiTest.OnOutput", "/v1/turns/:turn_id/output")
        end

      assert Exception.message(error) =~
               "overlapping paths: GET /v1/turns/:turn_id/output (work) and " <>
                 "GET /v1/turns/:turn_id/output (history)"
    end

    # The plan's mutation (BK2′ 2): the extra parameter is refused before any overlap check,
    # because a path parameter must be an input field.
    test "as /v1/turns/{turn_id}/{rest} it is refused: rest is no input field" do
      error =
        assert_raise CompileError, fn ->
          shadow("AtlasRuntime.Backend.HistoryApiTest.OnRest", "/v1/turns/:turn_id/:rest")
        end

      assert Exception.message(error) =~ "path parameter :rest is no field of :get_turn_input"
    end
  end

  describe "query decode" do
    test "slot, since, cursor and limit reach list_turns typed" do
      ok(request("/v1/turns?slot=dev1&since=2026-11-16T09%3A00%3A00Z&cursor=h%3A2&limit=100"))

      assert {_,
              %F.ListTurnsInput{
                slot: "dev1",
                since: ~U[2026-11-16 09:00:00Z],
                cursor: "h:2",
                limit: 100
              }} =
               called(:list_turns)
    end

    test "an input that does not decode is 400 invalid, and history is not called" do
      for query <- ["since=yesterday", "limit=many", "page=2", "slot=a&slot=b"] do
        problem(request("/v1/turns?" <> query), 400, "invalid")
        refute_received {:fake_history, _, _, _}
      end
    end
  end

  describe "limit: range 1..100 (§13.1 Q1)" do
    test "limit=0 and limit=101 are 400 invalid, and history is not called" do
      for limit <- ["0", "101"] do
        body = problem(request("/v1/turns?limit=" <> limit), 400, "invalid")
        assert body["detail"] =~ "limit must be in 1..100, got #{limit}"
        refute_received {:fake_history, _, _, _}
      end
    end

    test "the bounds themselves reach list_turns as given, nothing clamped" do
      for limit <- [1, 100] do
        ok(request("/v1/turns?limit=#{limit}"))
        assert {_, %F.ListTurnsInput{limit: ^limit}} = called(:list_turns)
      end
    end
  end

  describe "rights (Q2, Q4)" do
    test "the socket client reads all history" do
      assert {_, rights} = @socket
      assert :read in rights and :read_all in rights
    end

    test "a client without read gets 403 not-permitted, and history is not called" do
      client = {"local:test", [:submit]}
      problem(request("/v1/turns", client), 403, "not-permitted")
      problem(request("/v1/turns/turn-0000000000000001", client), 403, "not-permitted")
      refute_received {:fake_history, _, _, _}
    end
  end
end
