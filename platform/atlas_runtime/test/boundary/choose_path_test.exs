defmodule AtlasRuntime.Boundary.ChoosePathTest do
  # D44 (design §3.1, §3.3, §3.5, §8.1), in the form of §13 case 10: in-BEAM clients call
  # the facade directly with {id, rights}. Only a client holding choose_path (the socket's)
  # names a folder on the Runtime's machine, and only such a client is given a path from it
  # (request.workspace.path, work_product.workspace.path, resume_point.workspace.path) or a
  # refusal's detail (§3.2). read_all grants reading, never acting (§3.2 Ownership).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Translation

  @moduletag capture_log: true

  # The most a TCP token can hold (§8.1): no choose_slot, no choose_path.
  @remote {"token:flow", [:submit, :cancel, :read, :read_all]}

  defp paths(%F.Work{attempts: attempts}) do
    for a <- attempts,
        path <- [
          a.resume_point && a.resume_point.workspace && a.resume_point.workspace.path,
          a.result && a.result.work_product && a.result.work_product.workspace.path
        ],
        path != nil,
        do: path
  end

  test "without choose_path a folder workspace is refused, and no work shows a path" do
    bench = start!()
    local = client("local:me")
    assert :choose_path in elem(local, 1)

    # The remote client may not name a folder: refused before anything is stored, and the
    # refusal carries its reason only, no detail (§3.2: no refusal text reaches it).
    assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
             F.submit(@remote, request(bench, "complete for flow", %{client_key: "k"}))

    assert %F.Outcome.NotFound{} = F.find_work(@remote, %{client_key: "k"})
    assert %F.Outcome.Works{works: []} = F.list_work(@remote, %{})

    # A client holding choose_path keeps a refusal's detail (here: a slot without choose_slot).
    assert %F.Outcome.Refused{reason: :not_permitted, detail: detail} =
             F.submit(local, request(bench, "complete for slot", %{slot: "s1"}))

    assert detail =~ "choose_slot"

    # The local client names one; its finished work carries the path back to it only.
    mine = submit!(bench, "complete for me", %{}, local)
    done = await_state(mine.work_id, :completed, local)
    [%{resume_point: %F.ResumePoint{workspace: %F.ResumeWorkspace{path: path}}}] = done.attempts
    assert is_binary(path) and path != ""
    assert paths(done) != []
    assert %F.Folder{path: folder} = done.request.workspace
    assert is_binary(folder) and folder != ""

    # The remote client reads it through read_all, by every outcome that carries a work, and
    # sees neither the folder it ran in nor any other path.
    assert %F.Outcome.Found{work: found} = F.get_work(@remote, %{work_id: mine.work_id})
    assert %F.Outcome.Works{works: [listed]} = F.list_work(@remote, %{})

    for work <- [found, listed] do
      assert work.work_id == mine.work_id
      assert %F.Folder{path: nil, permissions: :"read-only"} = work.request.workspace
      assert [%{resume_point: %F.ResumePoint{workspace: workspace}}] = work.attempts
      assert workspace.path == nil
      assert paths(work) == []
      refute inspect(work) =~ path
      refute inspect(work) =~ folder
    end

    # read_all grants reading, never acting (§3.2 Ownership): no detail, nothing changes.
    assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
             F.cancel(@remote, %{work_id: mine.work_id, mode: "graceful"})

    assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
             F.retry(@remote, %{work_id: mine.work_id})

    # The local client still sees its paths, and its work is as it was.
    assert %F.Outcome.Found{work: own} = F.get_work(local, %{work_id: mine.work_id})
    assert path in paths(own)
    assert own.request.workspace.path == folder
    assert [_one] = own.attempts
    assert own.state == :completed
  end

  test "an invalid input's refusal has no detail for a client without choose_path" do
    _bench = start!()
    bad = %{title: "t", instructions: "i", profile: "p", cost_class: "standard"}

    assert %F.Outcome.Refused{reason: :invalid, detail: nil} = F.submit(@remote, bad)

    assert %F.Outcome.Refused{reason: :invalid, detail: detail} =
             F.submit(client("local:me"), bad)

    assert is_binary(detail)
  end

  test "a request must name its folder's path, which the contract leaves optional" do
    bench = start!()
    input = request(bench, "complete pathless", %{})
    input = update_in(input.workspace, &Map.delete(&1, :path))

    assert %F.Outcome.Refused{reason: :invalid, detail: detail} =
             F.submit(client("local:me"), input)

    assert detail =~ "path"
  end

  @t ~U[2026-11-17 09:00:00.000000Z]

  defp record do
    product =
      M.WorkProduct.new!(
        workspace:
          M.ProductWorkspace.new!(
            path: "/runtime/home/turns/t1",
            branch: "b",
            base_sha: "a1",
            head_sha: "b2",
            changed: true
          )
      )

    M.WorkRecord.new!(
      work_id: "work-1",
      client: "local:me",
      idempotency_key: "work-1",
      revision: 1,
      sequence: 1,
      request:
        M.Request.new!(
          title: "t",
          instructions: "i",
          profile: "p",
          cost_class: :standard,
          workspace: M.Folder.new!(path: "/f", permissions: :read_only)
        ),
      attempts: [
        M.Attempt.new!(
          attempt: 1,
          state: :completed,
          timestamps: M.Timestamps.new!(received_at: @t, accepted_at: @t, ended_at: @t),
          turn_id: "t1",
          resume_point:
            M.ResumePoint.new!(
              turn_id: "t1",
              conversation_id: "c1",
              workspace: M.WorkspaceState.new!(path: "/runtime/home/turns/t1", branch: "b")
            ),
          quiescent: true,
          result:
            M.Result.new!(
              kind: :completed,
              retryable: false,
              never_started: false,
              work_product: product
            )
        )
      ]
    )
  end

  test "work_product.workspace.path and resume_point.workspace.path only with choose_path" do
    [%{resume_point: point, result: %{work_product: %{workspace: product}}}] =
      Translation.from_model(record(), [:read, :choose_path]).attempts

    assert point.workspace.path == "/runtime/home/turns/t1"
    assert product.path == "/runtime/home/turns/t1"

    [%{resume_point: point, result: %{work_product: %{workspace: product}}}] =
      Translation.from_model(record(), [:submit, :cancel, :read, :read_all, :choose_slot]).attempts

    assert point.workspace == %F.ResumeWorkspace{path: nil, branch: "b", commit: nil}

    assert product == %F.WorkProductWorkspace{
             path: nil,
             branch: "b",
             base_sha: "a1",
             head_sha: "b2",
             changed: true
           }
  end
end
