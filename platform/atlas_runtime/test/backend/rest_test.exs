defmodule AtlasRuntime.Backend.RestTest do
  @moduledoc """
  The generated router on the work contract (design §8.2, §8.3), one test per row,
  through the test facade (`AtlasRuntime.Test.WorkFacade` on `AtlasRuntime.Test.FakeWork`).
  """
  # FakeWork's answers are global.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntime.Test.{FakeWork, WorkRest}
  alias AtlasRuntime.Test.WorkFacade, as: F

  @rights [:submit, :cancel, :read, :read_all, :choose_slot]
  @client {"local:test", @rights}

  @request %{
    "title" => "Fix it",
    "instructions" => "Fix the bug.",
    "profile" => "deep_coding",
    "cost_class" => "standard",
    "workspace" => %{
      "kind" => "repository",
      "url" => "https://example.test/r.git",
      "branch" => "fix",
      "base" => "develop"
    }
  }

  setup do
    FakeWork.reset_all()
    FakeWork.owner(self())
    on_exit(&FakeWork.reset_all/0)
  end

  defp request(method, path, body \\ nil, headers \\ [], client \\ @client) do
    body = if is_map(body), do: JSON.encode!(body), else: body || ""
    conn = conn(method, path, body) |> assign(:client, client)

    # Appended, so a header can be given twice.
    conn = %{conn | req_headers: conn.req_headers ++ headers}

    WorkRest.call(conn, WorkRest.init([]))
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)

  defp problem(conn, status, type) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/problem+json"]
    body = json(conn)
    assert %{"type" => ^type, "status" => ^status, "title" => _} = body
    body
  end

  defp called(capability) do
    assert_received {:fake_work, ^capability, client, input}
    {client, input}
  end

  defp answer(capability, outcome),
    do: FakeWork.answer(capability, fn _client, _input -> outcome end)

  defp work(fields \\ []), do: FakeWork.a_work(fields)
  defp work_json, do: F.Work.dump(work())

  defp at_capacity(reason),
    do: %F.Outcome.AtCapacity{reason: reason, retry_after: 60, capacity: FakeWork.a_capacity()}

  defp refused(reason), do: %F.Outcome.Refused{reason: reason, detail: "because"}

  describe "§8.2 resources" do
    test "POST /v1/work: submit; the Idempotency-Key header carries the client key" do
      answer(:submit, %F.Outcome.Accepted{work: work()})

      conn =
        request("POST", "/v1/work", Map.put(@request, "slot", "s1"), [{"idempotency-key", "k-1"}])

      assert conn.status == 201
      assert get_resp_header(conn, "location") == ["/v1/work/w-1"]
      assert json(conn) == work_json()

      assert {@client,
              %F.WorkRequest{
                client_key: "k-1",
                slot: "s1",
                cost_class: :standard,
                workspace: %F.Repository{
                  url: "https://example.test/r.git",
                  branch: "fix",
                  base: "develop"
                }
              }} = called(:submit)
    end

    test "POST /v1/work: a folder workspace, and no key" do
      body =
        Map.put(@request, "workspace", %{
          "kind" => "folder",
          "path" => "/w",
          "permissions" => "read-only"
        })

      assert request("POST", "/v1/work", body).status == 201

      assert {_,
              %F.WorkRequest{
                client_key: nil,
                workspace: %F.Folder{path: "/w", permissions: :"read-only"}
              }} =
               called(:submit)
    end

    test "GET /v1/work/{id}: get_work" do
      answer(:get_work, %F.Outcome.Found{work: work()})
      conn = request("GET", "/v1/work/w-1")
      assert conn.status == 200
      assert json(conn) == work_json()
      # S1: no ETag.
      assert get_resp_header(conn, "etag") == []
      assert {@client, %F.GetWorkInput{work_id: "w-1"}} = called(:get_work)
    end

    test "GET /v1/work?key=: find_work" do
      answer(:find_work, %F.Outcome.Found{work: work()})
      assert request("GET", "/v1/work?key=k-1").status == 200
      assert {_, %F.FindWorkInput{client_key: "k-1"}} = called(:find_work)
    end

    test "GET /v1/work?state=&changed_since=: list_work, with its sequence" do
      answer(:list_work, %F.Outcome.Works{works: [work()], sequence: 12})
      conn = request("GET", "/v1/work?state=running&changed_since=5")
      assert conn.status == 200
      assert json(conn) == %{"works" => [work_json()], "sequence" => 12}
      assert {_, %F.ListWorkInput{state: :running, changed_since: 5}} = called(:list_work)

      assert request("GET", "/v1/work").status == 200
      assert {_, %F.ListWorkInput{state: nil, changed_since: nil}} = called(:list_work)
    end

    test "POST /v1/work/{id}/attempts: retry, body {resume}" do
      answer(:retry, %F.Outcome.Accepted{work: work()})
      conn = request("POST", "/v1/work/w-1/attempts", %{"resume" => true})
      assert conn.status == 201
      assert get_resp_header(conn, "location") == ["/v1/work/w-1"]
      assert {_, %F.RetryInput{work_id: "w-1", resume: true}} = called(:retry)
    end

    test "POST /v1/work/{id}/cancel: cancel, body {mode, reason}" do
      answer(:cancel, %F.Outcome.Cancelling{stage: :requested, work: work()})

      conn =
        request("POST", "/v1/work/w-1/cancel", %{"mode" => "graceful", "reason" => "not needed"})

      assert conn.status == 202
      # The work itself, no envelope.
      assert json(conn) == work_json()

      assert {_, %F.CancelInput{work_id: "w-1", mode: :graceful, reason: "not needed"}} =
               called(:cancel)

      # Not DELETE: the record stays.
      problem(request("DELETE", "/v1/work/w-1"), 404, "no-route")
    end

    test "GET /v1/capacity: capacity; Retry-After when no new work can be taken" do
      conn = request("GET", "/v1/capacity")
      assert conn.status == 200
      assert get_resp_header(conn, "retry-after") == ["60"]
      assert %{"accepting" => false, "retry_after" => 60, "slots" => %{"total" => 2}} = json(conn)
      assert {@client, nil} = called(:capacity)

      FakeWork.answer(:capacity, fn _, _ ->
        struct(F.Outcome.Capacity, Map.from_struct(FakeWork.a_capacity()))
      end)

      conn = request("GET", "/v1/capacity")
      assert conn.status == 200
      assert get_resp_header(conn, "retry-after") == []
    end

    test "GET /v1/turns/{turn_id}/output?cursor=: turn_output" do
      answer(:turn_output, %F.Outcome.Page{
        events: [%F.OutputEvent{sequence: 1, kind: :text, text: "hi"}],
        cursor: "c2",
        more: false
      })

      conn = request("GET", "/v1/turns/t-1/output?cursor=c1")
      assert conn.status == 200

      assert json(conn) == %{
               "events" => [%{"sequence" => 1, "kind" => "text", "text" => "hi"}],
               "cursor" => "c2",
               "more" => false
             }

      assert {_, %F.TurnOutputInput{turn_id: "t-1", cursor: "c1"}} = called(:turn_output)
    end
  end

  describe "§8.3 status codes" do
    test "accepted → 201 Created with Location (submit and retry)" do
      answer(:submit, %F.Outcome.Accepted{work: work(work_id: "w 2")})
      conn = request("POST", "/v1/work", @request)
      assert {201, ["/v1/work/w%202"]} = {conn.status, get_resp_header(conn, "location")}
    end

    test "existing → 200 OK, S1 without Idempotent-Replayed" do
      answer(:submit, %F.Outcome.Existing{work: work()})
      conn = request("POST", "/v1/work", @request, [{"idempotency-key", "k-1"}])
      assert conn.status == 200
      assert get_resp_header(conn, "idempotent-replayed") == []
      assert get_resp_header(conn, "location") == []
      assert json(conn) == work_json()
    end

    test "at_capacity → 503 with Retry-After, type at-capacity with reason and capacity" do
      for {capability, method, path, body} <- [
            {:submit, "POST", "/v1/work", @request},
            {:retry, "POST", "/v1/work/w-1/attempts", %{}}
          ],
          reason <- [:full, :profile_unavailable, :not_accepting] do
        answer(capability, at_capacity(reason))
        conn = request(method, path, body)
        body = problem(conn, 503, "at-capacity")
        assert get_resp_header(conn, "retry-after") == ["60"]
        assert body["reason"] == Atom.to_string(reason)
        assert body["retry_after"] == 60
        assert %{"accepting" => true, "buffer" => %{"free" => 0}} = body["capacity"]
      end
    end

    test "refused: conflict → 409 idempotency-conflict" do
      answer(:submit, refused(:conflict))

      body =
        problem(
          request("POST", "/v1/work", @request, [{"idempotency-key", "k-1"}]),
          409,
          "idempotency-conflict"
        )

      assert %{"reason" => "conflict", "detail" => "because"} = body
    end

    test "refused: invalid → 400 invalid" do
      answer(:submit, refused(:invalid))
      problem(request("POST", "/v1/work", @request), 400, "invalid")
    end

    test "refused: policy_forbids, no_permitted_option, resume_unavailable, unsupported_workspace → 422, type the reason" do
      for {reason, type} <- [
            policy_forbids: "policy-forbids",
            no_permitted_option: "no-permitted-option",
            resume_unavailable: "resume-unavailable",
            unsupported_workspace: "unsupported-workspace"
          ] do
        answer(:submit, refused(reason))
        assert %{"reason" => r} = problem(request("POST", "/v1/work", @request), 422, type)
        assert r == Atom.to_string(reason)
      end

      answer(:retry, refused(:resume_unavailable))

      problem(
        request("POST", "/v1/work/w-1/attempts", %{"resume" => true}),
        422,
        "resume-unavailable"
      )
    end

    test "refused: not_permitted → 403 not-permitted, from the implementation and from the facade's right check" do
      answer(:submit, refused(:not_permitted))
      problem(request("POST", "/v1/work", @request), 403, "not-permitted")
      called(:submit)

      # A client without the right: the facade refuses before the implementation.
      body =
        problem(
          request("POST", "/v1/work", @request, [], {"reader", [:read]}),
          403,
          "not-permitted"
        )

      assert body["detail"] =~ "submit"
      refute_received {:fake_work, :submit, _, _}

      problem(request("GET", "/v1/work/w-1", nil, [], {"nobody", []}), 403, "not-permitted")

      problem(
        request("POST", "/v1/work/w-1/cancel", %{"mode" => "force"}, [], {"reader", [:read]}),
        403,
        "not-permitted"
      )

      problem(request("GET", "/v1/capacity", nil, [], {"nobody", []}), 403, "not-permitted")
    end

    test "pruned → 410 Gone, type pruned with work_id and kind" do
      for {capability, path} <- [get_work: "/v1/work/w-1", find_work: "/v1/work?key=k-1"] do
        answer(capability, %F.Outcome.Pruned{work_id: "w-1", kind: :completed})
        body = problem(request("GET", path), 410, "pruned")
        assert %{"work_id" => "w-1", "kind" => "completed"} = body
      end
    end

    test "not_found → 404, never seen" do
      for {method, path, body} <- [
            {"GET", "/v1/work/w-9", nil},
            {"GET", "/v1/work?key=never", nil},
            {"POST", "/v1/work/w-9/attempts", %{}},
            {"POST", "/v1/work/w-9/cancel", %{"mode" => "graceful"}},
            {"GET", "/v1/turns/t-9/output", nil}
          ] do
        assert problem(request(method, path, body), 404, "not-found") |> Map.keys() |> Enum.sort() ==
                 ["status", "title", "type"]
      end
    end

    test "cancelling → 202 Accepted, ended → 200 OK; the body is the work" do
      [attempt] = work().attempts

      cancelling =
        work(
          state: :cancelling,
          attempts: [%{attempt | state: :cancelling, cancel_stage: :forced}]
        )

      answer(:cancel, %F.Outcome.Cancelling{stage: :forced, work: cancelling})
      conn = request("POST", "/v1/work/w-1/cancel", %{"mode" => "force"})
      assert conn.status == 202
      # The work, whose current attempt's cancel_stage holds the stage.
      assert json(conn) == F.Work.dump(cancelling)
      assert [%{"cancel_stage" => "forced", "state" => "cancelling"}] = json(conn)["attempts"]
      refute Map.has_key?(json(conn), "stage")

      answer(:cancel, %F.Outcome.Ended{work: work(state: :completed)})
      conn = request("POST", "/v1/work/w-1/cancel", %{"mode" => "graceful"})
      assert conn.status == 200
      assert json(conn)["state"] == "completed"
    end

    test "only at_capacity is a 503, and only it has Retry-After among the errors" do
      for route <- WorkRest.__routes__(), outcome <- route.outcomes do
        statuses = if outcome.by, do: Enum.map(outcome.cases, & &1.status), else: [outcome.status]
        retry_after? = Enum.any?(outcome.headers, &(elem(&1, 0) == "retry-after"))

        if outcome.outcome == :at_capacity do
          assert statuses == [503] and retry_after?
        else
          refute 503 in statuses, "#{route.capability} #{outcome.outcome} is a 503"
          if Enum.any?(statuses, &(&1 >= 400)), do: refute(retry_after?)
        end
      end
    end
  end

  describe "§8.3 decode errors → 400 invalid, through the facade's new/1; nothing is called" do
    for {name, method, path, body, headers} <- [
          {"an unknown body field", "POST", "/v1/work", Map.put(@request, "colour", "red"), []},
          {"the client key in the body (the header carries it)", "POST", "/v1/work",
           Map.put(@request, "client_key", "k"), []},
          {"a missing required field", "POST", "/v1/work", Map.delete(@request, "profile"), []},
          {"an unknown enum value", "POST", "/v1/work", Map.put(@request, "cost_class", "free"),
           []},
          {"an unknown workspace kind", "POST", "/v1/work",
           Map.put(@request, "workspace", %{"kind" => "packet"}), []},
          {"a wrong type", "POST", "/v1/work", Map.put(@request, "title", 7), []},
          {"no JSON", "POST", "/v1/work", ~s({"title":), []},
          {"no JSON object", "POST", "/v1/work", "[]", []},
          {"an unknown query parameter", "GET", "/v1/work?colour=red", nil, []},
          {"key and state together", "GET", "/v1/work?key=k&state=running", nil, []},
          {"changed_since no integer", "GET", "/v1/work?changed_since=soon", nil, []},
          {"an unknown state", "GET", "/v1/work?state=sleeping", nil, []},
          {"a work_id in the cancel body", "POST", "/v1/work/w-1/cancel",
           %{"mode" => "force", "work_id" => "w-2"}, []},
          {"a missing cancel mode", "POST", "/v1/work/w-1/cancel", %{}, []},
          {"a body on GET", "GET", "/v1/capacity", "{}", []},
          {"Idempotency-Key twice", "POST", "/v1/work", @request,
           [{"idempotency-key", "a"}, {"idempotency-key", "b"}]}
        ] do
      test name do
        conn =
          request(unquote(method), unquote(path), unquote(Macro.escape(body)), unquote(headers))

        assert %{"detail" => _} = problem(conn, 400, "invalid")
        refute_received {:fake_work, _, _, _}
      end
    end
  end

  test "an unknown resource → 404 no-route as problem+json" do
    problem(request("GET", "/v1/works"), 404, "no-route")
    problem(request("PUT", "/v1/work/w-1"), 404, "no-route")
  end

  test "the client comes from conn.assigns, unchanged" do
    request("GET", "/v1/capacity", nil, [], {"someone", [:read]})
    assert {{"someone", [:read]}, nil} = called(:capacity)
  end
end
