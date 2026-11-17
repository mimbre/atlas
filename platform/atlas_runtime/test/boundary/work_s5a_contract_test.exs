defmodule AtlasRuntime.Boundary.WorkS5aContractTest do
  @moduledoc """
  S5a P4 (s5a-plan §3 I-B5, B1, B2): the work contract's S5a additions as callers see
  them, through the real facade and the core.

  - The facade validates the `base` and `from_work` workspace forms and `after_check`.
  - A work whose model holds every S5a field translates to the boundary and back, and none
    of the core's private S5a fields reaches the public structs.
  - `submit` declares `pruned`; `get_frozen` and `get_frozen_blob` answer `not_found` until
    frozen results exist (P8).
  - `after_check` landed with P10a (test/work/after_check_test.exs): it runs only in a `base`
    or `from_work` workspace, so on a `folder` it is `unsupported_workspace`, and nothing is
    written. (`base` landed with P7a, `from_work` with P9: a `from_work` naming no work it can
    read is `not_permitted`, and writes nothing either.)
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness, except: [request: 2, request: 3]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Model.FrozenResult, as: FR
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Translation

  @moduletag capture_log: true

  @t ~U[2026-11-17 09:00:00.000000Z]
  @base_id "sha256:" <> String.duplicate("ab", 32)
  @sha String.duplicate("cd", 32)
  @csf "csf_" <> String.duplicate("ef", 32)

  # The core's private S5a fields (I-M5) and the work's pinned source: never public.
  @private [:source, :checking, :check_pgid, :folder, :preparing, :prepare_pid]

  # S3 (D44): the core's translation takes the caller's rights. With choose_path (as the
  # socket's client) a work keeps its paths, as the generated translation does.
  @paths [:submit, :cancel, :read, :choose_path]

  defp req(workspace, extra \\ %{}) do
    Map.merge(
      %{
        title: "t",
        instructions: "i",
        profile: "light_work",
        cost_class: "standard",
        workspace: workspace
      },
      extra
    )
  end

  defp base(extra \\ %{}),
    do: Map.merge(%{kind: "base", base_id: @base_id, permissions: "read-only"}, extra)

  defp from_work(extra \\ %{}),
    do: Map.merge(%{kind: "from_work", work_id: "work-0", permissions: "workspace-write"}, extra)

  ## The facade's own validation (no core needed: it answers before calling it)

  describe "the facade validates the S5a inputs" do
    test "base: an unknown permissions value, or no base_id, is invalid" do
      for workspace <- [
            base(%{permissions: "materialized-folder"}),
            base(%{permissions: "write"}),
            Map.delete(base(), :base_id),
            Map.delete(base(), :permissions),
            base(%{base_id: 7}),
            base(%{path: "/tmp/x"})
          ] do
        assert %F.Outcome.Refused{reason: :invalid} = F.submit(client(), req(workspace)),
               inspect(workspace)
      end
    end

    test "from_work: an unknown permissions value, no work_id, or a non-integer attempt, is invalid" do
      for workspace <- [
            from_work(%{permissions: "materialized-folder"}),
            Map.delete(from_work(), :work_id),
            Map.delete(from_work(), :permissions),
            from_work(%{attempt: "1"})
          ] do
        assert %F.Outcome.Refused{reason: :invalid} = F.submit(client(), req(workspace)),
               inspect(workspace)
      end
    end

    test "after_check: command must be a list of strings, timeout an integer" do
      folder = %{kind: "folder", path: "/tmp/x", permissions: "read-only"}

      for check <- [
            %{},
            %{command: "bin/check"},
            %{command: [1]},
            %{command: ["bin/check"], timeout: "60"},
            %{command: ["bin/check"], shell: true}
          ] do
        assert %F.Outcome.Refused{reason: :invalid} =
                 F.submit(client(), req(folder, %{after_check: check})),
               inspect(check)
      end
    end

    test "get_frozen and get_frozen_blob need their required fields" do
      assert %{} = invalid = F.get_frozen(client(), %{})
      refute match?(%F.Outcome.NotFound{}, invalid)

      for input <- [%{work_id: "w"}, %{work_id: "w", attempt: 1}, %{attempt: 1, sha256: @sha}] do
        refute match?(%F.Outcome.NotFound{}, F.get_frozen_blob(client(), input)), inspect(input)
      end
    end
  end

  ## The schema (B1, B2)

  test "submit declares pruned; the frozen reads answer frozen and blob, never found" do
    by_name =
      Map.new(
        AtlasRuntimeBoundary.Work.__schema__().capabilities,
        &{&1.name, Enum.map(&1.outcomes, fn o -> o.name end)}
      )

    assert :pruned in by_name.submit
    assert by_name.get_frozen == [:frozen, :fingerprint_mismatch, :pruned, :not_found]
    assert by_name.get_frozen_blob == [:blob, :pruned, :not_found]
  end

  # S5a P11 exposes them, with their resources (backend/contract/test/work_api_test.exs).
  test "the backend contract exposes the frozen reads (S5a P11)" do
    schema = AtlasRuntimeBackend.Work.__schema__()
    assert schema.not_exposed == []
    assert :get_frozen in schema.exposed and :get_frozen_blob in schema.exposed
  end

  ## Translation (I-B5: every new field, no private one)

  defp full_record(workspace) do
    fingerprints = [M.RootFingerprint.new!(root: "atlas", fingerprint: @csf)]

    product =
      M.WorkProduct.new!(
        workspace: M.ProductWorkspace.new!(path: "/home/w", changed: true),
        frozen: M.FrozenRef.new!(base: @base_id, fingerprints: fingerprints),
        based_on: M.BasedOn.new!(work_id: "work-0", attempt: 2, fingerprints: fingerprints),
        check:
          M.CheckResult.new!(
            command: ["bin/check"],
            exit_status: 1,
            signal: "SIGINT",
            error: :not_found,
            timed_out: true,
            cancelled: false,
            interrupted: true,
            duration_ms: 1234,
            output: M.CheckOutput.new!(tail: "FAIL", complete: false)
          )
      )

    attempt =
      M.Attempt.new!(
        attempt: 1,
        state: :completed,
        timestamps:
          M.Timestamps.new!(
            received_at: @t,
            accepted_at: @t,
            started_at: @t,
            running_at: @t,
            check_started_at: @t,
            check_ended_at: @t,
            ended_at: @t
          ),
        quiescent: false,
        result:
          M.Result.new!(
            kind: :completed,
            retryable: false,
            never_started: false,
            work_product: product,
            log: M.Log.new!(complete: true, missing_bytes: 0, ref: "turn-1")
          ),
        checking: true,
        check_pgid: 4242,
        folder: "/home/workers/work-work-0",
        preparing: false,
        prepare_pid: 4243
      )

    M.WorkRecord.new!(
      work_id: "work-1",
      client: "local:test",
      idempotency_key: "work-1",
      revision: 3,
      sequence: 9,
      request:
        M.Request.new!(
          title: "t",
          instructions: "i",
          profile: "light_work",
          cost_class: :standard,
          workspace: workspace,
          after_check: M.AfterCheck.new!(command: ["bin/check", "--fast"], timeout: 60)
        ),
      attempts: [attempt],
      source: M.Source.new!(work_id: "work-0", attempt: 2)
    )
  end

  # Every key of every struct or map inside a public value.
  defp keys(%{__struct__: _} = struct), do: keys(Map.from_struct(struct))

  defp keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | keys(value)] end)

  defp keys(list) when is_list(list), do: Enum.flat_map(list, &keys/1)
  defp keys(_), do: []

  test "a work with every S5a field translates to the boundary, with no private field" do
    for {workspace, public} <- [
          {M.Base.new!(base_id: @base_id, permissions: :read_only),
           %F.Base{base_id: @base_id, permissions: :"read-only"}},
          {M.FromWork.new!(work_id: "work-0", attempt: 2, permissions: :workspace_write),
           %F.FromWork{work_id: "work-0", attempt: 2, permissions: :"workspace-write"}},
          {M.FromWork.new!(work_id: "work-0", permissions: :read_only),
           %F.FromWork{work_id: "work-0", attempt: nil, permissions: :"read-only"}}
        ] do
      record = full_record(workspace)
      work = Translation.from_model(record, @paths)

      assert %F.Work{request: request, attempts: [attempt]} = work
      assert request.workspace == public
      assert request.after_check == %F.AfterCheck{command: ["bin/check", "--fast"], timeout: 60}
      assert attempt.timestamps.check_started_at == @t
      assert attempt.timestamps.check_ended_at == @t

      assert %F.WorkProduct{frozen: frozen, based_on: based_on, check: check} =
               attempt.result.work_product

      fingerprint = %F.RootFingerprint{root: "atlas", fingerprint: @csf}
      assert frozen == %F.FrozenRef{base: @base_id, fingerprints: [fingerprint]}

      assert based_on == %F.BasedOn{work_id: "work-0", attempt: 2, fingerprints: [fingerprint]}

      assert check == %F.CheckResult{
               command: ["bin/check"],
               exit_status: 1,
               signal: "SIGINT",
               error: :not_found,
               timed_out: true,
               cancelled: false,
               interrupted: true,
               duration_ms: 1234,
               output: %F.CheckOutput{tail: "FAIL", complete: false}
             }

      # Valid as the contract has it.
      assert :ok = F.Work.validate(work)

      for key <- @private, do: refute(key in keys(work), "#{key} is public")

      # And back: the request the core stores.
      assert Translation.to_model(request) == record.request
    end
  end

  test "the generated translation (the mappings) agrees and drops the private fields" do
    record = full_record(M.Base.new!(base_id: @base_id, permissions: :workspace_write))
    assert {:ok, %F.Work{} = work} = F.from_model(record, supply: [state: :completed])

    for key <- @private, do: refute(key in keys(work), "#{key} is public")
    assert work.request.workspace == %F.Base{base_id: @base_id, permissions: :"workspace-write"}

    [attempt] = work.attempts
    [expected] = Translation.from_model(record, @paths).attempts
    assert attempt.result.work_product == expected.result.work_product
    assert attempt.timestamps == expected.timestamps

    # Back: the request, as the core stores it.
    assert {:ok, request} = F.to_model(work.request)
    assert request == record.request
  end

  test "a frozen result's record translates to frozen, without frozen_id, frozen_at or pruned" do
    entries = [
      FR.ChangeEntry.new!(
        path: "a.txt",
        op: :write,
        kind: :file,
        mode: "100644",
        size: 3,
        sha256: @sha
      ),
      FR.ChangeEntry.new!(
        path: "bin/x",
        op: :write,
        kind: :file,
        mode: "100755",
        size: 1,
        sha256: @sha
      ),
      FR.ChangeEntry.new!(
        path: "l",
        op: :write,
        kind: :symlink,
        mode: "120000",
        size: 1,
        sha256: @sha,
        target: "a.txt"
      ),
      FR.ChangeEntry.new!(path: "gone", op: :delete)
    ]

    record =
      FR.FrozenResult.new!(
        frozen_id: "work-1.1",
        work_id: "work-1",
        attempt: 1,
        base: @base_id,
        frozen_at: @t,
        pruned: false,
        roots: [
          FR.FrozenRoot.new!(root: "atlas", fingerprint: @csf, entries: entries),
          FR.FrozenRoot.new!(root: "other", fingerprint: @csf, entries: [])
        ]
      )

    frozen = Translation.frozen(record)
    assert :ok = F.Frozen.validate(frozen)

    assert %F.Frozen{work_id: "work-1", attempt: 1, base: @base_id, roots: [atlas, other]} =
             frozen

    assert other == %F.FrozenRoot{root: "other", fingerprint: @csf, entries: []}
    assert Enum.map(atlas.entries, & &1.mode) == [:"100644", :"100755", :"120000", nil]
    assert List.last(atlas.entries) == %F.ChangeEntry{path: "gone", op: :delete}

    for key <- [:frozen_id, :frozen_at, :pruned], do: refute(key in keys(frozen))

    # A tombstone is no readable frozen result: the core answers pruned for it (P8).
    tombstone = FR.FrozenResult.new!(record |> Map.from_struct() |> Map.put(:pruned, true))
    assert_raise FunctionClauseError, fn -> Translation.frozen(tombstone) end
  end

  ## The core: skeletons and guards

  describe "the core" do
    setup do
      %{bench: start!()}
    end

    test "get_frozen and get_frozen_blob answer not_found through the real facade", %{
      bench: bench
    } do
      work = submit!(bench, "complete frozen read")

      assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: work.work_id})

      assert %F.Outcome.NotFound{} =
               F.get_frozen(client(), %{work_id: work.work_id, attempt: 1, fingerprint: @csf})

      assert %F.Outcome.NotFound{} =
               F.get_frozen_blob(client(), %{work_id: work.work_id, attempt: 1, sha256: @sha})

      # The right is read: a client without it is refused before the core.
      refute match?(%F.Outcome.NotFound{}, F.get_frozen({"c9", [:submit]}, %{work_id: "w"}))
    end

    # base landed with P7a (test/work/base_workspace_test.exs), from_work with P9
    # (test/work/from_work_test.exs), after_check with P10a (test/work/after_check_test.exs).
    test "after_check on a folder is unsupported_workspace, a from_work on no readable work is not_permitted, and nothing is written",
         %{bench: bench} do
      before = files(bench.dir)

      # client() holds choose_path, as the socket's client does, so it gets each refusal's
      # detail (S3, D44); a client without it gets the reason only (below).
      assert :choose_path in elem(client(), 1)

      assert %F.Outcome.Refused{reason: :not_permitted} = F.submit(client(), req(from_work()))

      assert %F.Outcome.Refused{reason: :not_permitted} =
               F.submit(client(), req(from_work(%{attempt: 1})))

      folder =
        bench
        |> AtlasRuntime.WorkHarness.request("after check")
        |> Map.put(:after_check, %{command: ["bin/check"]})

      assert %F.Outcome.Refused{
               reason: :unsupported_workspace,
               detail: "after_check runs only in a base or from_work workspace"
             } = F.submit(client(), folder)

      # S3 (D44): the TCP ceiling has no choose_path, so the same refusals carry no detail.
      tcp = {"token:t", [:submit, :cancel, :read, :read_all]}

      assert %F.Outcome.Refused{reason: :not_permitted, detail: nil} =
               F.submit(tcp, req(from_work()))

      repository = %{
        kind: "repository",
        url: "https://example.invalid/r.git",
        branch: "b",
        base: "develop"
      }

      assert %F.Outcome.Refused{reason: :unsupported_workspace, detail: nil} =
               F.submit(tcp, req(repository, %{after_check: %{command: ["bin/check"]}}))

      assert files(bench.dir) == before
      assert %F.Outcome.Works{works: []} = F.list_work(client(), %{})

      # The core is still serving.
      assert %F.Outcome.Accepted{} =
               F.submit(
                 client(),
                 AtlasRuntime.WorkHarness.request(bench, "complete after guards")
               )
    end
  end

  defp files(dir) do
    for path <- Path.wildcard(Path.join(dir, "work/**"), match_dot: true), do: path
  end
end
