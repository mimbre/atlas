defmodule AtlasRuntime.Backend.OperationsApiTest do
  @moduledoc """
  The one router on the operations contract (design §8, §13.1 Q4, Q11, Q12): one test per
  resource × outcome, through the test facade (`AtlasRuntime.Test.OperationsFacade` on
  `AtlasRuntime.Test.FakeOperations`), and the facade's refusals, answered alike for the
  work contract on the same router.
  """
  # The fakes' answers are global.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntime.Test.{FakeOperations, FakeWork, WorkRest}
  alias AtlasRuntime.Test.OperationsFacade, as: F

  @socket {"local:test", [:submit, :cancel, :read, :read_all, :choose_slot, :inspect, :operate]}

  setup do
    FakeWork.reset_all()
    FakeOperations.reset_all()
    FakeWork.owner(self())

    on_exit(fn ->
      FakeWork.reset_all()
      FakeOperations.reset_all()
    end)
  end

  defp request(method, path, body \\ nil, client \\ @socket) do
    body = if is_map(body), do: JSON.encode!(body), else: body || ""
    conn(method, path, body) |> assign(:client, client) |> WorkRest.call(WorkRest.init([]))
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)

  defp ok(conn, status) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/json"]
    json(conn)
  end

  defp problem(conn, status, type) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/problem+json"]
    assert %{"type" => ^type, "status" => ^status, "title" => _} = body = json(conn)
    body
  end

  defp called(capability) do
    assert_received {:fake_operations, ^capability, client, input}
    {client, input}
  end

  defp answer(capability, outcome),
    do: FakeOperations.answer(capability, fn _client, _input -> outcome end)

  defp info_json(fields \\ []), do: F.RuntimeInfo.dump(FakeOperations.a_runtime_info(fields))

  describe "Q12: resource × outcome → status" do
    test "GET /v1/runtime: runtime_info → 200, the runtime info itself" do
      assert ok(request("GET", "/v1/runtime"), 200) == info_json()

      assert %{"slots" => [%{"name" => "s1", "busy" => true}, %{"name" => "s2", "busy" => false}]} =
               info_json()

      assert {@socket, nil} = called(:runtime_info)
    end

    test "GET /v1/policy: policy → 200, the policy view" do
      body = ok(request("GET", "/v1/policy"), 200)
      assert body == F.Policy.dump(FakeOperations.a_policy())

      assert %{"version" => 4, "profiles" => [%{"options" => [%{"availability" => _}]}]} = body
      assert {@socket, nil} = called(:policy)
    end

    for {action, mode} <- [pause: :paused, resume: :open, drain: :draining] do
      test "POST /v1/control/#{action}: runtime_info → 200 + runtime info" do
        action = unquote(action)
        mode = unquote(mode)

        body = ok(request("POST", "/v1/control/#{action}"), 200)
        assert body == info_json(mode: mode)
        assert {@socket, nil} = called(action)
      end
    end

    test "POST /v1/control/stop {force}: stopping → 202 + runtime info" do
      body = ok(request("POST", "/v1/control/stop", %{"force" => true}), 202)
      assert body == info_json(mode: :stopping)
      assert {@socket, %F.StopInput{force: true}} = called(:stop)

      # No body: force is left out.
      assert request("POST", "/v1/control/stop").status == 202
      assert {_, %F.StopInput{force: nil}} = called(:stop)
    end

    test "POST /v1/slots/{slot}/release: released → 200" do
      assert ok(request("POST", "/v1/slots/s%201/release"), 200) == %{"slot" => "s 1"}
      assert {@socket, %F.ReleaseSlotInput{slot: "s 1"}} = called(:release_slot)
    end

    test "POST /v1/slots/{slot}/release: not_found → 404" do
      answer(:release_slot, %F.Outcome.NotFound{})
      body = problem(request("POST", "/v1/slots/s9/release"), 404, "not-found")
      assert Map.keys(body) |> Enum.sort() == ["status", "title", "type"]
    end

    test "POST /v1/slots/{slot}/release: refused(slot_busy) → 409 slot-busy" do
      answer(:release_slot, %F.Outcome.Refused{reason: :slot_busy, detail: "alive"})
      body = problem(request("POST", "/v1/slots/s1/release"), 409, "slot-busy")
      assert %{"reason" => "slot_busy", "detail" => "alive"} = body
    end

    test "POST /v1/slots/{slot}/release: refused(invalid) → 400 invalid" do
      answer(:release_slot, %F.Outcome.Refused{reason: :invalid, detail: "no such name"})
      body = problem(request("POST", "/v1/slots/s1/release"), 400, "invalid")
      assert %{"reason" => "invalid"} = body
    end

    test "POST /v1/harnesses/{harness}/clear-quota-mark: cleared → 200" do
      assert ok(request("POST", "/v1/harnesses/claude/clear-quota-mark"), 200) == %{}
      assert {@socket, %F.ClearQuotaMarkInput{harness: "claude"}} = called(:clear_quota_mark)
    end

    test "POST /v1/harnesses/{harness}/clear-quota-mark: not_found → 404" do
      answer(:clear_quota_mark, %F.Outcome.NotFound{})
      problem(request("POST", "/v1/harnesses/nobody/clear-quota-mark"), 404, "not-found")
    end

    test "the route table: every operations route, with its contract" do
      routes = for r <- WorkRest.__routes__(), r.contract == :operations, do: {r.method, r.path}

      assert routes == [
               get: "/v1/runtime",
               get: "/v1/policy",
               post: "/v1/control/pause",
               post: "/v1/control/resume",
               post: "/v1/control/drain",
               post: "/v1/control/stop",
               post: "/v1/slots/:slot/release",
               post: "/v1/harnesses/:harness/clear-quota-mark"
             ]

      # One router: the work routes are on it too.
      assert Enum.any?(
               WorkRest.__routes__(),
               &(&1.contract == :work and &1.path == "/v1/capacity")
             )
    end
  end

  describe "rights: a missing right is the facade's refusal, 403 not-permitted, for every contract" do
    test "(a) the socket's client operates" do
      assert WorkRest.__rights__(:socket) == elem(@socket, 1)
      assert request("POST", "/v1/control/pause").status == 200
      called(:pause)
    end

    test "(b) a listener without operate: 403 on every operate route, and nothing is called" do
      inspector = {"local:test", [:read, :inspect]}

      for {method, path, body} <- [
            {"POST", "/v1/control/pause", nil},
            {"POST", "/v1/control/resume", nil},
            {"POST", "/v1/control/drain", nil},
            {"POST", "/v1/control/stop", %{"force" => true}},
            {"POST", "/v1/slots/s1/release", nil},
            {"POST", "/v1/harnesses/claude/clear-quota-mark", nil}
          ] do
        body = problem(request(method, path, body, inspector), 403, "not-permitted")
        assert body["detail"] =~ "operate"
      end

      refute_received {:fake_operations, _, _, _}

      # inspect alone still reads.
      assert request("GET", "/v1/runtime", nil, inspector).status == 200
      assert request("GET", "/v1/policy", nil, inspector).status == 200
    end

    test "inspect is needed to read the Runtime" do
      operator = {"local:test", [:operate]}
      body = problem(request("GET", "/v1/runtime", nil, operator), 403, "not-permitted")
      assert body["detail"] =~ "inspect"
      problem(request("GET", "/v1/policy", nil, operator), 403, "not-permitted")
      refute_received {:fake_operations, _, _, _}
    end

    test "(c) a work route with a missing right is still 403" do
      body =
        problem(
          request("GET", "/v1/capacity", nil, {"local:test", [:inspect, :operate]}),
          403,
          "not-permitted"
        )

      assert body["detail"] =~ "read"
      refute_received {:fake_work, _, _, _}
    end
  end

  describe "bad input: 400 invalid, through the facade's new/1; nothing is called" do
    for {name, method, path, body} <- [
          {"(a) an unknown key next to force", "POST", "/v1/control/stop",
           %{"force" => true, "x" => 1}},
          {"(b) force as a string", "POST", "/v1/control/stop", %{"force" => "yes"}},
          {"force as the text true", "POST", "/v1/control/stop", %{"force" => "true"}},
          {"a body that is no JSON object", "POST", "/v1/control/stop", "[]"},
          {"a body on pause", "POST", "/v1/control/pause", %{}},
          {"a body on release", "POST", "/v1/slots/s1/release", %{"slot" => "s2"}},
          {"a query parameter", "GET", "/v1/runtime?verbose=1", nil}
        ] do
      test name do
        conn = request(unquote(method), unquote(path), unquote(Macro.escape(body)))
        assert %{"detail" => _} = problem(conn, 400, "invalid")
        refute_received {:fake_operations, _, _, _}
      end
    end
  end

  test "no route: GET on a control action, and /v1/control alone" do
    problem(request("GET", "/v1/control/pause"), 404, "no-route")
    problem(request("POST", "/v1/control"), 404, "no-route")
    problem(request("DELETE", "/v1/slots/s1/release"), 404, "no-route")
  end

  test "a value the facade should never give raises (the facade checks outcomes first)" do
    FakeOperations.answer(:runtime_info, fn _, _ -> %{} end)

    assert_raise AtlasRuntimeBoundary.Generator.ContractError, fn ->
      request("GET", "/v1/runtime")
    end
  end
end
