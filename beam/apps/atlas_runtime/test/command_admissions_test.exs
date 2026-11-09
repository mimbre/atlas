defmodule AtlasRuntime.CommandAdmissionsTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.CommandAdmissions, as: Admissions
  @moduletag :tmp_dir
  @turn "turn-0000000000000001"
  @source "turn-0000000000000002"

  setup %{tmp_dir: dir} do
    request =
      Admissions.canonical(%{"command" => "start", "cwd" => dir, "assignment" => " Do work.\n"})

    binding = %{
      "worker_id" => "alpha",
      "source_turn_id" => nil,
      "cwd" => request["cwd"],
      "sandbox" => "read-only",
      "permissions" => nil,
      "repository" => nil,
      "backend" => "codex",
      "model" => nil,
      "session_id" => nil,
      "questions_enabled" => false
    }

    run = %{
      id: @turn,
      request_id: "Request_1",
      worker_id: "alpha",
      state: "running",
      backend: "codex",
      cwd: request["cwd"],
      assignment: request["assignment"],
      sandbox: "read-only",
      session_id: nil,
      requested_model: nil,
      model: nil,
      questions_enabled: false,
      started_at: "2026-11-07T10:00:00Z"
    }

    %{dir: dir, request: request, binding: binding, run: run}
  end

  defp reserve(context),
    do:
      Admissions.reserve(
        context.dir,
        "Request_1",
        context.request,
        context.binding,
        @turn,
        context.run
      )

  defp load(context), do: Admissions.load(context.dir, "Request_1")

  defp save(context, record),
    do: File.write!(Path.join(context.dir, "admissions/Request_1.json"), JSON.encode!(record))

  test "canonical defaults and cwd aliases agree without changing assignment bytes", context do
    alias_path = Path.join(context.dir, "alias")
    File.ln_s!(context.dir, alias_path)

    explicit =
      context.request |> Map.put("cwd", alias_path) |> Map.put("request_id", "Another-ID")

    assert Admissions.canonical(explicit) == context.request
    assert context.request["assignment"] == " Do work.\n"
    assert context.request["sandbox"] == "read-only"
    assert context.request["questions_enabled"] == false
    refute Map.has_key?(context.request, "backend")
    refute Map.has_key?(context.request, "worker_id")
    refute Map.has_key?(context.request, "request_id")
  end

  test "explicit selections and changed assignment remain distinct", context do
    for {key, value} <- [
          {"worker_id", "alpha"},
          {"backend", "codex"},
          {"assignment", "Do work."},
          {"sandbox", "workspace-write"}
        ] do
      refute Admissions.canonical(Map.put(context.request, key, value)) == context.request
    end

    request = %{"command" => "continue", "assignment" => "next"}
    assert Admissions.canonical(request) == request
    refute Admissions.canonical(Map.put(request, "worker_id", "alpha")) == request
    refute Admissions.canonical(Map.put(request, "turn_id", @source)) == request
    refute Admissions.canonical(request) == context.request
  end

  test "malformed IDs and path traversal fail before touching storage", context do
    for id <- [
          nil,
          1,
          "",
          "../outside",
          "a/b",
          "a.b",
          "-a",
          "_a",
          "é",
          "a\n",
          String.duplicate("a", 65)
        ] do
      assert_raise ArgumentError, fn -> Admissions.load(context.dir, id) end

      assert_raise ArgumentError, fn ->
        Admissions.reserve(context.dir, id, context.request, context.binding, @turn, context.run)
      end

      assert_raise ArgumentError, fn ->
        Admissions.canonical(Map.put(context.request, "request_id", id))
      end
    end

    for id <- ["a", "A", "0", "A_0-z", String.duplicate("Z", 64)] do
      assert Admissions.load(context.dir, id) == nil
      assert Admissions.canonical(Map.put(context.request, "request_id", id)) == context.request
    end

    refute File.exists?(Path.join(context.dir, "admissions"))
  end

  test "invalid and unknown start options are rejected", context do
    for {key, value} <- [
          {"unknown", true},
          {"worker_id", nil},
          {"worker_id", "UPPER"},
          {"backend", nil},
          {"backend", "other"},
          {"turn_id", @source},
          {"permissions", nil},
          {"permissions", "other"},
          {"sandbox", nil},
          {"sandbox", "unsafe"},
          {"questions_enabled", nil},
          {"questions_enabled", "true"},
          {"assignment", " \n"},
          {"assignment", 1},
          {"cwd", nil},
          {"cwd", "bad\0path"},
          {"repository", "https://github.com/owner/repo"},
          {"branch", "task"}
        ] do
      assert_raise ArgumentError, fn ->
        Admissions.canonical(Map.put(context.request, key, value))
      end
    end

    assert_raise ArgumentError, fn -> Admissions.canonical(%{command: "start"}) end
    assert_raise ArgumentError, fn -> Admissions.canonical([]) end
    assert_raise ArgumentError, fn -> Admissions.canonical(%{"command" => "status"}) end

    assert_raise ArgumentError, fn ->
      Admissions.canonical(
        Map.merge(context.request, %{"backend" => "codex", "questions_enabled" => true})
      )
    end
  end

  test "continue accepts no new override fields", context do
    request = %{
      "command" => "continue",
      "assignment" => "next",
      "worker_id" => "alpha",
      "turn_id" => @source
    }

    assert Admissions.canonical(Map.put(request, "request_id", "continue-1")) == request

    for {key, value} <- [
          {"cwd", context.dir},
          {"backend", "claude"},
          {"questions_enabled", false},
          {"sandbox", "read-only"},
          {"permissions", "dedicated-repository"},
          {"repository", "url"},
          {"branch", "task"},
          {"turn_id", "bad"}
        ] do
      assert_raise ArgumentError, fn -> Admissions.canonical(Map.put(request, key, value)) end
    end
  end

  test "dedicated and managed requests preserve caller input", context do
    request =
      context.request |> Map.delete("sandbox") |> Map.put("permissions", "dedicated-repository")

    assert Admissions.canonical(request) == request

    assert_raise ArgumentError, fn ->
      Admissions.canonical(Map.put(request, "sandbox", "read-only"))
    end

    managed =
      request
      |> Map.delete("cwd")
      |> Map.merge(%{"repository" => "https://github.com/Owner/Repo", "branch" => "task/admit"})

    assert Admissions.canonical(managed) == managed

    assert_raise ArgumentError, fn ->
      Admissions.canonical(Map.put(managed, "cwd", context.dir))
    end
  end

  test "canonical encoded request boundary includes JSON escaping", context do
    base = Map.put(context.request, "assignment", "")
    available = 128 * 1024 - byte_size(JSON.encode!(base))
    exact = Map.put(base, "assignment", String.duplicate("x", available))
    assert byte_size(JSON.encode!(Admissions.canonical(exact))) == 128 * 1024

    assert_raise ArgumentError, fn ->
      Admissions.canonical(Map.update!(exact, "assignment", &(&1 <> "x")))
    end

    assert_raise ArgumentError, fn ->
      Admissions.canonical(Map.put(base, "assignment", String.duplicate("\n", available)))
    end
  end

  test "reservation reload stays indeterminate even beside a completed turn", context do
    record = reserve(context)
    File.mkdir_p!(Path.join([context.dir, "turns", @turn]))

    File.write!(
      Path.join([context.dir, "turns", @turn, "turn.json"]),
      JSON.encode!(%{context.run | state: "finished"})
    )

    assert load(context) == record

    assert Admissions.public(record) == %{
             "request_id" => "Request_1",
             "admission" => "indeterminate",
             "worker_id" => "alpha",
             "turn_id" => @turn,
             "source_turn_id" => nil,
             "recorded_result" => nil,
             "requires_reconciliation" => true
           }

    refute File.exists?(Path.join(context.dir, "admissions/Request_1.json.tmp"))
  end

  test "accept persists original snapshot and refuses replacement", context do
    record = reserve(context)
    accepted = Admissions.accept(context.dir, record, context.run)
    assert load(context) == accepted
    assert accepted["recorded_result"] == JSON.decode!(JSON.encode!(context.run))
    assert Admissions.public(accepted)["recorded_result"]["state"] == "running"
    refute Admissions.public(accepted)["requires_reconciliation"]

    for candidate <- [record, accepted] do
      assert_raise Admissions.StorageError, fn ->
        Admissions.accept(context.dir, candidate, context.run)
      end
    end

    assert_raise Admissions.StorageError, fn -> reserve(context) end
    assert load(context) == accepted
    refute File.exists?(Path.join(context.dir, "admissions/Request_1.json.tmp"))
  end

  test "continued binding pins omitted worker and source selection", context do
    request = %{"command" => "continue", "assignment" => "next"}

    binding =
      Map.merge(context.binding, %{"source_turn_id" => @source, "session_id" => "native-session"})

    run = %{context.run | assignment: "next", session_id: "native-session"}
    record = Admissions.reserve(context.dir, "Request_1", request, binding, @turn, run)
    assert record["request"] == request
    assert Admissions.public(record)["source_turn_id"] == @source
    assert load(context) == record
    accepted = Admissions.accept(context.dir, record, run)
    assert load(context) == accepted
  end

  test "read validation needs no current working directory or provider preferences", context do
    request = Map.put(context.request, "cwd", Path.join(context.request["cwd"], "gone"))

    binding = %{
      context.binding
      | "cwd" => request["cwd"],
        "backend" => "claude",
        "model" => "pinned-model"
    }

    run = %{context.run | cwd: request["cwd"], backend: "claude", requested_model: "pinned-model"}
    record = Admissions.reserve(context.dir, "Request_1", request, binding, @turn, run)
    File.write!(Path.join(context.dir, "backends.json"), "corrupt irrelevant preferences")
    refute File.exists?(request["cwd"])
    assert load(context) == record
    assert load(context)["binding"]["model"] == "pinned-model"
  end

  test "ownership, state and canonical corruption fail closed", context do
    record = reserve(context)

    for corrupt <- [
          Map.put(record, "version", 2),
          Map.put(record, "extra", true),
          Map.put(record, "request_id", "other"),
          Map.put(record, "record_ref", "../outside"),
          Map.put(record, "turn_id", "../turn"),
          Map.put(record, "admission", "running"),
          Map.put(record, "recorded_result", %{}),
          Map.put(record, "request", %{}),
          put_in(record, ["request", "request_id"], "Request_1"),
          put_in(record, ["request", "cwd"], "relative"),
          put_in(record, ["binding", "worker_id"], "../worker"),
          put_in(record, ["binding", "source_turn_id"], @source),
          put_in(record, ["binding", "cwd"], "/different"),
          put_in(record, ["binding", "sandbox"], "workspace-write"),
          put_in(record, ["binding", "questions_enabled"], true),
          put_in(record, ["binding", "permissions"], %{})
        ] do
      save(context, corrupt)
      assert_raise Admissions.StorageError, fn -> load(context) end
      assert_raise Admissions.StorageError, fn -> reserve(context) end
    end

    save(context, record)
    assert load(context) == record
  end

  test "accepted result attribution corruption fails closed", context do
    record = reserve(context)
    accepted = Admissions.accept(context.dir, record, context.run)

    for {key, value} <- [
          {"id", @source},
          {"request_id", "other"},
          {"worker_id", "other"},
          {"state", "finished"},
          {"assignment", "changed"},
          {"backend", "claude"},
          {"requested_model", "changed"},
          {"cwd", "/other"},
          {"session_id", "changed"},
          {"questions_enabled", true}
        ] do
      save(context, put_in(accepted, ["recorded_result", key], value))
      assert_raise Admissions.StorageError, fn -> load(context) end
    end
  end

  test "changed caller reservation cannot overwrite persisted binding", context do
    record = reserve(context)
    forged = put_in(record, ["binding", "worker_id"], "other")

    assert_raise Admissions.StorageError, fn ->
      Admissions.accept(context.dir, forged, %{context.run | worker_id: "other"})
    end

    assert load(context) == record
  end

  test "oversize accepted result is rejected before reserving", context do
    run = Map.put(context.run, :extra, String.duplicate("x", 1024 * 1024))

    assert_raise Admissions.StorageError, fn ->
      Admissions.reserve(context.dir, "Request_1", context.request, context.binding, @turn, run)
    end

    assert load(context) == nil
    record = reserve(context)
    assert_raise Admissions.StorageError, fn -> Admissions.accept(context.dir, record, run) end
    assert load(context) == record
  end

  test "corrupt and oversized files are never treated as absent", context do
    record = reserve(context)
    path = Path.join(context.dir, record["record_ref"])

    for bytes <- ["{", "", "null", String.duplicate(" ", 1024 * 1024 + 1)] do
      File.write!(path, bytes)
      assert_raise Admissions.StorageError, fn -> load(context) end
      assert_raise Admissions.StorageError, fn -> reserve(context) end
      assert File.read!(path) == bytes
    end
  end

  test "symlinked, hardlinked and directory record paths fail closed", context do
    File.mkdir_p!(Path.join(context.dir, "admissions"))
    outside = Path.join(context.dir, "outside")
    File.write!(outside, "untouched")
    path = Path.join(context.dir, "admissions/Request_1.json")
    File.ln_s!(outside, path)
    assert_raise Admissions.StorageError, fn -> load(context) end
    assert_raise Admissions.StorageError, fn -> reserve(context) end
    assert File.read!(outside) == "untouched"
    File.rm!(path)
    File.ln!(outside, path)
    assert_raise Admissions.StorageError, fn -> load(context) end
    File.rm!(path)
    File.mkdir!(path)
    assert_raise Admissions.StorageError, fn -> load(context) end
  end

  test "admissions directory and stale temporary files cannot redirect writes", context do
    outside = Path.join(context.dir, "outside")
    File.mkdir!(outside)
    admissions = Path.join(context.dir, "admissions")
    File.ln_s!(outside, admissions)
    assert_raise Admissions.StorageError, fn -> load(context) end
    assert_raise Admissions.StorageError, fn -> reserve(context) end
    File.rm!(admissions)
    File.mkdir!(admissions)
    tmp = Path.join(admissions, "Request_1.json.tmp")
    File.write!(tmp, "previous interrupted write")
    assert_raise Admissions.StorageError, fn -> reserve(context) end
    assert File.read!(tmp) == "previous interrupted write"
    assert_raise Admissions.StorageError, fn -> load(context) end
    File.rm!(tmp)
    File.ln_s!(Path.join(outside, "victim"), tmp)
    assert_raise Admissions.StorageError, fn -> reserve(context) end
    assert_raise Admissions.StorageError, fn -> load(context) end
    refute File.exists?(Path.join(outside, "victim"))
  end

  test "interrupted acceptance never promotes the authoritative reservation", context do
    record = reserve(context)

    candidate =
      Map.merge(record, %{
        "admission" => "accepted",
        "recorded_result" => JSON.decode!(JSON.encode!(context.run))
      })

    tmp = Path.join(context.dir, record["record_ref"] <> ".tmp")
    File.write!(tmp, JSON.encode!(candidate))
    assert load(context) == record
    assert Admissions.public(load(context))["requires_reconciliation"]

    assert_raise Admissions.StorageError, fn ->
      Admissions.accept(context.dir, record, context.run)
    end

    assert load(context) == record
    assert JSON.decode!(File.read!(tmp)) == candidate
  end

  test "missing planned result cannot bypass reservation preflight", context do
    for run <- [nil, %{}] do
      assert_raise Admissions.StorageError, fn ->
        Admissions.reserve(context.dir, "Request_1", context.request, context.binding, @turn, run)
      end

      assert load(context) == nil
    end
  end

  test "accepted encoded record boundary is enforced exactly", context do
    record = reserve(context)
    run = Map.put(context.run, :extra, "")

    candidate =
      Map.merge(record, %{
        "admission" => "accepted",
        "recorded_result" => JSON.decode!(JSON.encode!(run))
      })

    available = 1024 * 1024 - byte_size(JSON.encode!(candidate))
    run = %{run | extra: String.duplicate("x", available)}
    dir = Path.join(context.dir, "boundary")

    assert_raise Admissions.StorageError, fn ->
      Admissions.reserve(dir, "Request_1", context.request, context.binding, @turn, %{
        run
        | extra: run.extra <> "x"
      })
    end

    assert Admissions.load(dir, "Request_1") == nil
    record = Admissions.reserve(dir, "Request_1", context.request, context.binding, @turn, run)
    accepted = Admissions.accept(dir, record, run)
    assert byte_size(JSON.encode!(accepted)) == 1024 * 1024
    assert Admissions.load(dir, "Request_1") == accepted
  end

  test "oversize stored canonical input and valid foreign ownership fail closed", context do
    record = reserve(context)
    oversized = put_in(record, ["request", "assignment"], String.duplicate("x", 128 * 1024))
    save(context, oversized)
    assert_raise Admissions.StorageError, fn -> load(context) end

    foreign =
      Map.merge(record, %{"request_id" => "other", "record_ref" => "admissions/other.json"})

    save(context, foreign)
    assert_raise Admissions.StorageError, fn -> load(context) end
    assert_raise Admissions.StorageError, fn -> reserve(context) end
  end

  test "dedicated managed binding retains exact scope without reopening the repository",
       context do
    cwd = context.request["cwd"]

    request =
      context.request
      |> Map.delete("cwd")
      |> Map.delete("sandbox")
      |> Map.merge(%{
        "permissions" => "dedicated-repository",
        "repository" => "https://github.com/Owner/Repo",
        "branch" => "task/admission"
      })

    scope = %{
      "profile" => "dedicated-repository",
      "version" => 1,
      "root" => cwd,
      "git_dir" => Path.join(cwd, ".git"),
      "network_hosts" => ["github.com", "api.github.com"]
    }

    resolved = %{
      "url" => "https://github.com/owner/repo.git",
      "branch" => "task/admission",
      "resolved_commit" => String.duplicate("b", 40)
    }

    # Admissions recorded while Code resolved the base carry its commit; fresh ones carry only url
    # and branch. Both stay loadable.
    for {repository, index} <-
          Enum.with_index([resolved, Map.delete(resolved, "resolved_commit")]) do
      dir = Path.join(context.dir, "managed-#{index}")

      binding = %{
        context.binding
        | "sandbox" => nil,
          "permissions" => scope,
          "repository" => repository
      }

      run = Map.merge(context.run, %{sandbox: nil, permissions: scope, repository: repository})
      record = Admissions.reserve(dir, "Request_1", request, binding, @turn, run)
      assert Admissions.load(dir, "Request_1") == record
      accepted = Admissions.accept(dir, record, run)
      assert Admissions.load(dir, "Request_1") == accepted
      assert accepted["binding"]["permissions"] == scope
      assert accepted["binding"]["repository"] == repository
    end

    for bad <- [
          Map.put(resolved, "resolved_commit", "not-a-commit"),
          Map.put(resolved, "resolved_commit", nil),
          Map.put(resolved, "base_sha", String.duplicate("a", 40))
        ] do
      binding = %{context.binding | "sandbox" => nil, "permissions" => scope, "repository" => bad}
      run = Map.merge(context.run, %{sandbox: nil, permissions: scope, repository: bad})

      assert_raise Admissions.StorageError, fn ->
        Admissions.reserve(
          Path.join(context.dir, "bad"),
          "Request_1",
          request,
          binding,
          @turn,
          run
        )
      end
    end
  end

  test "materialized-folder binding retains exactly the verified folder scope for either backend",
       context do
    cwd = context.request["cwd"]

    request =
      context.request |> Map.delete("sandbox") |> Map.put("permissions", "materialized-folder")

    assert Admissions.canonical(request) == request

    assert_raise ArgumentError, fn ->
      Admissions.canonical(Map.put(request, "sandbox", "read-only"))
    end

    assert_raise ArgumentError, fn ->
      Admissions.canonical(
        request
        |> Map.delete("cwd")
        |> Map.merge(%{"repository" => "https://github.com/Owner/Repo", "branch" => "task"})
      )
    end

    home = Path.join(context.dir, "runtime")

    scope = %{
      "profile" => "materialized-folder",
      "version" => 1,
      "root" => cwd,
      "snapshot_id" => "sha256:" <> String.duplicate("c", 64),
      "repositories" => ["repo"],
      "home" => home,
      "record" => Path.join(home, "materializations/x.json"),
      "baseline" => Path.join(home, "snapshots/" <> String.duplicate("c", 64))
    }

    binding = %{context.binding | "sandbox" => nil, "permissions" => scope}
    run = Map.merge(context.run, %{sandbox: nil, permissions: scope})

    record =
      Admissions.reserve(
        Path.join(context.dir, "folder"),
        "Request_1",
        request,
        binding,
        @turn,
        run
      )

    assert Admissions.load(Path.join(context.dir, "folder"), "Request_1") == record
    assert record["binding"]["permissions"] == scope
    claude = %{binding | "backend" => "claude", "questions_enabled" => true}
    claude_request = request |> Map.put("backend", "claude") |> Map.put("questions_enabled", true)
    claude_run = %{run | backend: "claude", questions_enabled: true}

    claude_record =
      Admissions.reserve(
        Path.join(context.dir, "claude"),
        "Request_1",
        claude_request,
        claude,
        @turn,
        claude_run
      )

    assert claude_record["binding"]["permissions"] == scope

    for {bad_request, bad_binding} <- [
          {request, %{binding | "repository" => %{"url" => "u", "branch" => "b"}}},
          {request,
           %{binding | "permissions" => Map.put(scope, "git_dir", Path.join(cwd, ".git"))}},
          {request, %{binding | "permissions" => Map.delete(scope, "home")}},
          {request, %{binding | "permissions" => %{scope | "root" => home}}},
          {request, %{binding | "permissions" => %{scope | "version" => 2}}},
          {request, %{binding | "permissions" => %{scope | "repositories" => []}}},
          {request, %{binding | "permissions" => %{scope | "snapshot_id" => "sha256:x"}}},
          {request, %{binding | "permissions" => %{scope | "record" => "relative.json"}}},
          {Map.put(request, "permissions", "dedicated-repository"), binding}
        ] do
      assert_raise Admissions.StorageError, fn ->
        Admissions.reserve(
          Path.join(context.dir, "bad"),
          "Request_1",
          bad_request,
          bad_binding,
          @turn,
          run
        )
      end
    end
  end

  test "managed saved continuation preserves base revision and rejects unrelated metadata",
       context do
    cwd = context.request["cwd"]
    request = %{"command" => "continue", "assignment" => "next", "turn_id" => @source}

    scope = %{
      "profile" => "dedicated-repository",
      "version" => 1,
      "root" => cwd,
      "git_dir" => Path.join(cwd, ".git"),
      "network_hosts" => ["github.com", "api.github.com"]
    }

    for length <- [40, 64] do
      dir = Path.join(context.dir, "sha-#{length}")

      repository = %{
        "url" => "https://github.com/owner/repo.git",
        "branch" => "task/admission",
        "base_sha" => String.duplicate("a", length)
      }

      binding =
        Map.merge(context.binding, %{
          "sandbox" => nil,
          "permissions" => scope,
          "repository" => repository,
          "source_turn_id" => @source,
          "session_id" => "saved-session"
        })

      run =
        Map.merge(context.run, %{
          sandbox: nil,
          permissions: scope,
          repository: repository,
          assignment: "next",
          session_id: "saved-session"
        })

      record = Admissions.reserve(dir, "Request_1", request, binding, @turn, run)
      assert Admissions.load(dir, "Request_1") == record
      accepted = Admissions.accept(dir, record, run)
      assert Admissions.load(dir, "Request_1") == accepted
      assert accepted["binding"]["repository"] == repository
      assert accepted["recorded_result"]["repository"] == repository

      for bad <- [
            Map.delete(repository, "base_sha"),
            Map.put(repository, "base_sha", nil),
            Map.put(repository, "base_sha", "not-a-commit"),
            Map.put(repository, "extra", true)
          ] do
        corrupt =
          accepted
          |> put_in(["binding", "repository"], bad)
          |> put_in(["recorded_result", "repository"], bad)

        File.write!(Path.join(dir, accepted["record_ref"]), JSON.encode!(corrupt))
        assert_raise Admissions.StorageError, fn -> Admissions.load(dir, "Request_1") end
      end
    end
  end
end
