defmodule AtlasCode.EffectsTest do
  @moduledoc """
  Code's effect receiver against a fake GitHub (`AtlasCode.FakeGitHub`): integrate a pull
  at exactly the revision asked about, once, whatever is repeated or lost.
  """
  use ExUnit.Case, async: true
  alias AtlasBus.{Digest, SubjectFingerprint}
  alias AtlasCode.{Effects, FakeGitHub}

  @moduletag :tmp_dir
  @target "https://github.com/o/r/pull/7"
  @definition %{"fields" => ["revision"], "relations" => []}

  setup %{tmp_dir: dir} do
    gh = start_supervised!(FakeGitHub)
    base = FakeGitHub.commit(gh, "base")
    revision = FakeGitHub.commit(gh, "revision", ["base"])
    FakeGitHub.branch(gh, "main", "base")
    FakeGitHub.put_pull(gh, 7, %{"head" => revision})
    %{gh: gh, dir: dir, base: base, revision: revision, s: receiver(dir, gh)}
  end

  defp receiver(dir, gh),
    do: Effects.new(dir: dir, github: {FakeGitHub, FakeGitHub.config(gh)}, repositories: ["o/r"])

  # A request as Flow's effect activity freezes one.
  defp request(revision, changes \\ %{}) do
    payload = %{"revision" => revision}
    fingerprint = SubjectFingerprint.of(%{"values" => payload}, @definition)

    Map.merge(
      %{
        "version" => 1,
        "id" => String.duplicate("a", 64),
        "run" => "run-1",
        "entry" => 4,
        "name" => "integrate",
        "subject" => "S-1",
        "service" => "code",
        "operation" => "integrate",
        "fingerprint_definition" => @definition,
        "fingerprint" => fingerprint,
        "payload" => payload,
        "target" => @target,
        "approved" => fingerprint
      },
      changes
    )
  end

  defp call(s, operation, r, digest \\ nil),
    do:
      Effects.handle(s, %{
        "operation" => operation,
        "request" => r,
        "digest" => digest || Digest.of_term(r)
      })

  defp merges(gh), do: for({:merge, _, _} = w <- FakeGitHub.writes(gh), do: w)

  test "green CI on an up-to-date revision: merged once, the same answer for every repeat", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    r = request(c.revision)
    first = call(c.s, "submit", r)

    assert %{"status" => "done", "reference" => sha, "outputs" => %{"sha" => sha, "head" => head}} =
             first

    assert head == c.revision

    assert {first["id"], first["digest"], first["fingerprint"]} ==
             {r["id"], Digest.of_term(r), r["fingerprint"]}

    assert FakeGitHub.get_pull(c.gh, 7)["merge_commit"] == sha
    assert [{:merge, 7, ^head}] = merges(c.gh)

    # Repeated, looked up, or asked of a restarted receiver: the original result, no merge.
    assert call(c.s, "submit", r) == first
    assert call(c.s, "lookup", r) == first
    assert call(receiver(c.dir, c.gh), "lookup", r) == first
    assert length(FakeGitHub.writes(c.gh)) == 1
  end

  test "red CI: blocked with the failing checks, nothing merged", c do
    FakeGitHub.ci(c.gh, c.revision, {:failure, ["unit"]})
    r = request(c.revision)

    assert %{"status" => "refused", "reason" => "ci_failed", "details" => details} =
             call(c.s, "submit", r)

    assert details == %{"head" => c.revision, "checks" => ["unit"]}
    # Durable: CI going green later changes nothing for this request.
    FakeGitHub.ci(c.gh, c.revision, :success)
    assert call(c.s, "lookup", r)["reason"] == "ci_failed"
    assert FakeGitHub.writes(c.gh) == []
  end

  test "a conflict, seen on the pull or when updating it from its base: blocked, nothing merged",
       c do
    FakeGitHub.set_pull(c.gh, 7, %{"mergeable" => false})
    FakeGitHub.ci(c.gh, c.revision, :success)

    assert %{"status" => "refused", "reason" => "conflict"} =
             call(c.s, "submit", request(c.revision))

    assert FakeGitHub.writes(c.gh) == []

    # Behind its base; GitHub has not worked out mergeability yet, the update conflicts.
    FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")
    other = request(c.revision, %{"id" => String.duplicate("b", 64)})
    FakeGitHub.set_pull(c.gh, 7, %{"mergeable" => nil})
    assert %{"status" => "working", "phase" => "updating"} = call(c.s, "submit", other)
    FakeGitHub.set_pull(c.gh, 7, %{"mergeable" => false})
    assert %{"status" => "refused", "reason" => "conflict"} = call(c.s, "lookup", other)
    assert merges(c.gh) == []
  end

  test "a crash between GitHub's merge and the outcome write: done on the repeat, no second merge",
       c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :crash)
    r = request(c.revision)
    assert_raise RuntimeError, fn -> call(c.s, "submit", r) end
    assert [{:merge, 7, _}] = merges(c.gh)

    # A restarted receiver: the request is known, its merge asked for; GitHub says merged.
    s = receiver(c.dir, c.gh)
    assert %{"status" => "done", "reference" => sha} = call(s, "lookup", r)
    assert sha == FakeGitHub.get_pull(c.gh, 7)["merge_commit"]
    assert call(s, "submit", r)["reference"] == sha
    assert length(merges(c.gh)) == 1
  end

  test "a stale revision is refused: the pull's head is not the revision asked about", c do
    pushed = FakeGitHub.commit(c.gh, "pushed", ["revision"])
    FakeGitHub.set_pull(c.gh, 7, %{"head" => pushed})
    FakeGitHub.ci(c.gh, pushed, :success)

    assert %{
             "status" => "refused",
             "reason" => "stale_revision",
             "details" => %{"head" => ^pushed}
           } =
             call(c.s, "submit", request(c.revision))

    assert FakeGitHub.writes(c.gh) == []

    # And a head that moves while CI runs, after it was accepted.
    FakeGitHub.set_pull(c.gh, 7, %{"head" => c.revision})
    late = request(c.revision, %{"id" => String.duplicate("c", 64)})
    assert %{"status" => "working", "phase" => "checking"} = call(c.s, "submit", late)
    FakeGitHub.set_pull(c.gh, 7, %{"head" => pushed})
    assert %{"status" => "refused", "reason" => "stale_revision"} = call(c.s, "lookup", late)
    assert FakeGitHub.writes(c.gh) == []
  end

  test "behind its base: updated, CI waited for on the update, then that update merged", c do
    base2 = FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")
    r = request(c.revision)

    assert %{"status" => "working", "phase" => "updating"} = call(c.s, "submit", r)
    assert [{:update_branch, 7, head}] = FakeGitHub.writes(c.gh)
    assert head == c.revision
    # GitHub has not applied it yet: asked again, fenced by the same head.
    assert %{"phase" => "updating"} = call(c.s, "lookup", r)

    FakeGitHub.apply_updates(c.gh)
    update = FakeGitHub.get_pull(c.gh, 7)["head"]

    assert FakeGitHub.parents(FakeGitHub.config(c.gh), "o/r", update) ==
             {:ok, [c.revision, base2]}

    assert %{"status" => "working", "phase" => "checking"} = call(c.s, "lookup", r)
    # CI on the revision alone is not CI on the update.
    FakeGitHub.ci(c.gh, c.revision, :success)
    assert %{"phase" => "checking"} = call(c.s, "lookup", r)
    FakeGitHub.ci(c.gh, update, :success)

    assert %{"status" => "done", "outputs" => %{"head" => ^update}} = call(c.s, "lookup", r)
    assert [{:merge, 7, ^update}] = merges(c.gh)
  end

  test "a head that is no update of the revision from its base is refused", c do
    FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")
    r = request(c.revision)
    assert %{"phase" => "updating"} = call(c.s, "submit", r)
    # A merge of something else than the base into the revision.
    stray = FakeGitHub.commit(c.gh, "stray", ["revision", "elsewhere"])
    FakeGitHub.commit(c.gh, "elsewhere", [])
    FakeGitHub.set_pull(c.gh, 7, %{"head" => stray})
    assert %{"status" => "refused", "reason" => "stale_revision"} = call(c.s, "lookup", r)
    assert merges(c.gh) == []
  end

  test "merged or closed by someone else", c do
    r = request(c.revision)
    FakeGitHub.set_pull(c.gh, 7, %{"merged" => true, "state" => "closed", "merge_commit" => "m"})
    assert %{"status" => "done", "reference" => "m"} = call(c.s, "submit", r)

    pushed = FakeGitHub.commit(c.gh, "pushed", ["revision"])
    FakeGitHub.set_pull(c.gh, 7, %{"head" => pushed})
    elsewhere = request(c.revision, %{"id" => String.duplicate("d", 64)})

    assert %{"status" => "refused", "reason" => "merged_elsewhere"} =
             call(c.s, "submit", elsewhere)

    FakeGitHub.set_pull(c.gh, 7, %{"merged" => false, "head" => c.revision})
    closed = request(c.revision, %{"id" => String.duplicate("e", 64)})
    assert %{"status" => "refused", "reason" => "closed"} = call(c.s, "submit", closed)
    assert FakeGitHub.writes(c.gh) == []
  end

  test "GitHub unreachable: still working, the record as it was; nothing decided", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    r = request(c.revision)
    FakeGitHub.fail(c.gh, :pull, :unavailable)
    assert %{"status" => "working", "phase" => "accepted"} = call(c.s, "submit", r)
    FakeGitHub.fail(c.gh, :merge, :unavailable)
    assert %{"status" => "working", "phase" => "merging"} = call(c.s, "lookup", r)
    assert %{"status" => "done"} = call(c.s, "lookup", r)
    assert length(merges(c.gh)) == 1
  end

  test "access refused before anything was asked, or on the write itself: blocked, nothing merged",
       c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :pull, {:refused, "unauthorized"})
    r = request(c.revision)
    assert %{"status" => "refused", "reason" => "unauthorized"} = call(c.s, "submit", r)
    assert call(c.s, "lookup", r)["reason"] == "unauthorized"

    # The merge refused, just after the pull was read open at that head: nothing merged.
    FakeGitHub.fail(c.gh, :merge, {:refused, "forbidden"})
    other = request(c.revision, %{"id" => String.duplicate("b", 64)})

    assert %{"status" => "refused", "reason" => "forbidden", "details" => %{"head" => head}} =
             call(c.s, "submit", other)

    assert head == c.revision
    assert FakeGitHub.writes(c.gh) == []
  end

  test "a merge whose answer was lost, then access refused: still working, then done once", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :lost)
    r = request(c.revision)
    assert %{"status" => "working", "phase" => "merging"} = call(c.s, "submit", r)
    assert [{:merge, 7, _}] = merges(c.gh)

    # The token expired or went missing meanwhile: the pull's read proves nothing.
    for reason <- ["unauthorized", "no_token", "not_found"] do
      FakeGitHub.fail(c.gh, :pull, {:refused, reason})
      assert %{"status" => "working", "phase" => "merging"} = call(c.s, "lookup", r)
    end

    # Access back: GitHub says merged, at that head.
    assert %{"status" => "done", "reference" => sha} = call(c.s, "lookup", r)
    assert sha == FakeGitHub.get_pull(c.gh, 7)["merge_commit"]
    assert length(merges(c.gh)) == 1
  end

  for {label, fault} <- [
        {"access refused", {:refused, "no_token"}},
        {"not mergeable", {:not_mergeable, "try later"}}
      ] do
    test "a delayed earlier merge survives a later #{label}, restart and repeated submit", c do
      FakeGitHub.ci(c.gh, c.revision, :success)
      FakeGitHub.fail(c.gh, :merge, :delayed)
      r = request(c.revision)
      assert %{"status" => "working", "phase" => "merging"} = call(c.s, "submit", r)
      assert FakeGitHub.get_pull(c.gh, 7)["state"] == "open"

      # A fresh receiver must recover uncertainty from disk, not process memory.
      s = receiver(c.dir, c.gh)
      FakeGitHub.fail(c.gh, :merge, unquote(Macro.escape(fault)))
      assert %{"status" => "working", "phase" => "merging"} = call(s, "lookup", r)
      file = Path.join([c.dir, "effects", r["id"] <> ".json"])
      record = file |> File.read!() |> JSON.decode!()
      refute Map.has_key?(record, "outcome")

      FakeGitHub.ci(c.gh, c.revision, :pending)
      assert %{"status" => "working"} = call(receiver(c.dir, c.gh), "submit", r)
      assert length(FakeGitHub.merge_attempts(c.gh)) == 2

      assert [{:ok, sha}] = FakeGitHub.complete_merges(c.gh)
      assert %{"status" => "done", "reference" => ^sha} = done = call(s, "lookup", r)
      assert call(receiver(c.dir, c.gh), "submit", r) == done
      assert length(merges(c.gh)) == 1
    end
  end

  test "a persisted merge attempt rechecks failed and pending CI before any retry", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :unavailable)
    r = request(c.revision)
    assert %{"status" => "working", "phase" => "merging"} = call(c.s, "submit", r)

    for ci <- [{:failure, ["rerun-failed"]}, :pending] do
      FakeGitHub.ci(c.gh, c.revision, ci)

      assert %{"status" => "working", "phase" => "merging"} =
               call(receiver(c.dir, c.gh), "lookup", r)

      assert length(FakeGitHub.merge_attempts(c.gh)) == 1
      assert merges(c.gh) == []
    end

    FakeGitHub.ci(c.gh, c.revision, :success)
    assert %{"status" => "done"} = call(receiver(c.dir, c.gh), "lookup", r)
    assert length(FakeGitHub.merge_attempts(c.gh)) == 2
    assert length(merges(c.gh)) == 1
  end

  test "incomplete commit statuses cannot authorize a merge through the receiver", c do
    visible = for i <- 1..30, do: %{"context" => "green-#{i}", "state" => "success"}

    for {state, expected} <- [
          {"failure", "refused"},
          {"pending", "working"},
          {"success", "working"}
        ] do
      evidence =
        {:evidence, %{"check_runs" => [], "total_count" => 0},
         %{"state" => state, "total_count" => 31, "statuses" => visible}}

      FakeGitHub.ci(c.gh, c.revision, evidence)
      r = request(c.revision, %{"id" => Digest.of_term(state) |> String.slice(7, 64)})
      assert %{"status" => ^expected} = call(c.s, "submit", r)
      assert FakeGitHub.merge_attempts(c.gh) == []
    end
  end

  test "base advancement after a timed-out merge pauses retries but still reconciles its completion",
       c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :delayed)
    r = request(c.revision)
    assert %{"status" => "working"} = call(c.s, "submit", r)
    FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")

    assert %{"status" => "working", "phase" => "merging"} =
             call(receiver(c.dir, c.gh), "lookup", r)

    assert length(FakeGitHub.merge_attempts(c.gh)) == 1
    assert FakeGitHub.writes(c.gh) == []
    assert [{:ok, sha}] = FakeGitHub.complete_merges(c.gh)
    assert %{"status" => "done", "reference" => ^sha} = call(c.s, "lookup", r)
  end

  test "changed head and mergeability never authorize another attempt or erase uncertainty", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :delayed)
    r = request(c.revision)
    assert %{"status" => "working"} = call(c.s, "submit", r)
    moved = FakeGitHub.commit(c.gh, "pushed", ["revision"])

    for changes <- [%{"head" => moved}, %{"head" => c.revision, "mergeable" => false}] do
      FakeGitHub.set_pull(c.gh, 7, changes)

      assert %{"status" => "working", "phase" => "merging"} =
               call(receiver(c.dir, c.gh), "lookup", r)

      assert length(FakeGitHub.merge_attempts(c.gh)) == 1
    end

    FakeGitHub.set_pull(c.gh, 7, %{"mergeable" => true})
    assert [{:ok, sha}] = FakeGitHub.complete_merges(c.gh)
    assert %{"status" => "done", "reference" => ^sha} = call(c.s, "lookup", r)
  end

  test "legacy merging journals without an attempt marker remain uncertain", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :delayed)
    r = request(c.revision)
    assert %{"status" => "working"} = call(c.s, "submit", r)
    file = Path.join([c.dir, "effects", r["id"] <> ".json"])
    legacy = file |> File.read!() |> JSON.decode!() |> Map.delete("merge_attempted")
    File.write!(file, JSON.encode!(legacy))
    FakeGitHub.fail(c.gh, :merge, {:refused, "forbidden"})
    assert %{"status" => "working"} = call(receiver(c.dir, c.gh), "lookup", r)
    assert [{:ok, sha}] = FakeGitHub.complete_merges(c.gh)
    assert %{"status" => "done", "reference" => ^sha} = call(c.s, "lookup", r)
  end

  test "an update asked, then access refused: still working, and the update taken later", c do
    FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")
    r = request(c.revision)
    assert %{"phase" => "updating"} = call(c.s, "submit", r)
    FakeGitHub.apply_updates(c.gh)

    for call <- [:pull, :parents, :compare] do
      FakeGitHub.fail(c.gh, call, {:refused, "forbidden"})
      assert %{"status" => "working", "phase" => "updating"} = call(c.s, "lookup", r)
    end

    assert %{"status" => "working", "phase" => "checking"} = call(c.s, "lookup", r)
    assert merges(c.gh) == []
  end

  test "an update GitHub will not make for another reason: blocked when the head stayed", c do
    FakeGitHub.commit(c.gh, "base 2", ["base"])
    FakeGitHub.branch(c.gh, "main", "base 2")
    FakeGitHub.fail(c.gh, :update_branch, {:unprocessable, "maintainers may not edit"})
    r = request(c.revision)

    assert %{"status" => "refused", "reason" => "update_refused", "details" => details} =
             call(c.s, "submit", r)

    assert details["head"] == c.revision and is_binary(details["why"])
    assert call(c.s, "lookup", r)["reason"] == "update_refused"
    assert FakeGitHub.writes(c.gh) == []
  end

  test "the request is checked before anything is asked of GitHub, and the refusal kept", c do
    other = FakeGitHub.commit(c.gh, "other", ["base"])

    for {changes, reason} <- [
          {%{"approved" => "sha256:" <> String.duplicate("0", 64)}, "not_approved"},
          # The fingerprint is of another revision than the one in the payload.
          {%{"payload" => %{"revision" => other}}, "fingerprint_mismatch"},
          {%{"fingerprint_definition" => %{"fields" => ["title"], "relations" => []}},
           "fingerprint_mismatch"},
          {%{"target" => "https://github.com/x/y/pull/7"}, "repository_not_allowed"},
          {%{"target" => "https://example.com/o/r/pull/7"}, "invalid_target"},
          {%{"operation" => "create"}, "unsupported_operation"}
        ] do
      r =
        request(
          c.revision,
          Map.put(changes, "id", Digest.of_term(changes) |> String.slice(7, 64))
        )

      assert %{"status" => "refused", "reason" => ^reason} = call(c.s, "submit", r)
      assert call(c.s, "lookup", r)["reason"] == reason
    end

    assert %{"status" => "refused", "reason" => "invalid_revision"} =
             call(c.s, "submit", request("r1", %{"id" => String.duplicate("f", 64)}))

    assert FakeGitHub.writes(c.gh) == []
  end

  test "one id names one request: changed, forged and unknown requests act on nothing", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    r = request(c.revision)
    assert %{"status" => "not_found"} = call(c.s, "lookup", r)
    assert %{"status" => "invalid"} = call(c.s, "submit", r, "forged")
    assert FakeGitHub.writes(c.gh) == []

    first = call(c.s, "submit", r)
    changed = put_in(r, ["payload", "changed"], "yes")
    for op <- ["submit", "lookup"], do: assert(call(c.s, op, changed)["status"] == "conflict")
    assert call(c.s, "submit", r, "forged")["status"] == "conflict"
    assert %{"status" => "invalid"} = call(c.s, "submit", Map.put(r, "id", "short"))
    assert call(c.s, "lookup", r) == first
    assert length(merges(c.gh)) == 1
  end

  test "the Fly test configuration refuses integration before contacting GitHub", c do
    settings =
      Path.expand("../../../../fly/test/core.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    s = %{c.s | repositories: settings["code"]["repositories"]}
    r = request(c.revision, %{"target" => "https://github.com/eyra/atlas/pull/7"})
    FakeGitHub.fail(c.gh, :pull, {:refused, "unauthorized"})

    assert %{"status" => "refused", "reason" => "repository_not_allowed"} = call(s, "submit", r)
    assert call(s, "lookup", r)["reason"] == "repository_not_allowed"
    # The read fault is still pending: even the first read was never asked for.
    assert {:error, {:refused, "unauthorized"}} =
             FakeGitHub.pull(FakeGitHub.config(c.gh), "eyra/atlas", 7)

    assert FakeGitHub.writes(c.gh) == []
  end

  test "disabling a repository pauses an uncertain request without any GitHub call", c do
    FakeGitHub.ci(c.gh, c.revision, :success)
    FakeGitHub.fail(c.gh, :merge, :lost)
    r = request(c.revision)
    assert %{"status" => "working", "phase" => "merging"} = call(c.s, "submit", r)
    file = Path.join([c.dir, "effects", r["id"] <> ".json"])
    journal = File.read!(file)
    disabled = %{c.s | repositories: []}
    FakeGitHub.fail(c.gh, :pull, {:refused, "unauthorized"})

    for op <- ["submit", "lookup"] do
      assert %{"status" => "working", "phase" => "merging"} = call(disabled, op, r)
      assert File.read!(file) == journal
    end

    assert {:error, {:refused, "unauthorized"}} =
             FakeGitHub.pull(FakeGitHub.config(c.gh), "o/r", 7)

    assert %{"status" => "done", "reference" => sha} = call(c.s, "lookup", r)
    assert sha == FakeGitHub.get_pull(c.gh, 7)["merge_commit"]
    assert call(disabled, "lookup", r)["reference"] == sha
    assert length(merges(c.gh)) == 1
  end

  test "a request the receiver fails on is answered working on the Bus, never crashing it", c do
    r = request(c.revision)
    File.write!(Path.join([c.dir, "effects", r["id"] <> ".json"]), "{damaged")
    body = %{"operation" => "lookup", "request" => r, "digest" => Digest.of_term(r)}
    assert_raise JSON.DecodeError, fn -> Effects.handle(c.s, body) end

    ExUnit.CaptureLog.capture_log(fn ->
      assert %{"status" => "working", "id" => id} = Effects.Endpoint.answer(c.s, body)
      assert id == r["id"]
    end)

    assert FakeGitHub.writes(c.gh) == []
  end

  test "how GitHub's HTTP answers are read" do
    alias AtlasCode.Effects.GitHub
    limit = [{~c"x-ratelimit-remaining", ~c"0"}]

    for {status, headers, raw, read} <- [
          {200, [], ~s({"a":1}), {:ok, %{"a" => 1}}},
          {204, [], "", {:ok, %{}}},
          {200, [], "[1]", {:error, :unavailable}},
          {401, [], "", {:error, {:refused, "unauthorized"}}},
          {403, [], "", {:error, {:refused, "forbidden"}}},
          # A rate limit is no refusal: nothing to conclude, ask again later.
          {403, limit, "", {:error, :unavailable}},
          {404, [], "", {:error, {:refused, "not_found"}}},
          {409, [], "x", {:error, {:status, 409, "x"}}},
          {422, [], "x", {:error, {:status, 422, "x"}}},
          {429, [], "", {:error, :unavailable}},
          {500, [], "", {:error, :unavailable}}
        ],
        do: assert(GitHub.classify(status, headers, raw) == read, inspect(status))

    conflict = JSON.encode!(%{"message" => "merge conflict between base and head"})
    other = JSON.encode!(%{"message" => "expected head sha didn't match current head ref"})
    assert GitHub.update_answer({:ok, %{}}) == :ok
    assert GitHub.update_answer({:error, {:status, 422, conflict}}) == {:error, :conflict}
    assert {:error, {:unprocessable, _}} = GitHub.update_answer({:error, {:status, 422, other}})
    assert GitHub.update_answer({:error, {:status, 409, ""}}) == {:error, :unavailable}

    assert GitHub.update_answer({:error, {:refused, "forbidden"}}) ==
             {:error, {:refused, "forbidden"}}

    assert GitHub.merge_answer({:ok, %{"merged" => true, "sha" => "m"}}) == {:ok, "m"}
    assert GitHub.merge_answer({:ok, %{"merged" => false}}) == {:error, :unavailable}
    assert GitHub.merge_answer({:error, {:status, 409, ""}}) == {:error, :head_moved}

    for status <- [405, 422],
        do:
          assert(
            {:error, {:not_mergeable, _}} =
              GitHub.merge_answer({:error, {:status, status, other}})
          )
  end

  test "what GitHub's check runs and statuses say about a commit" do
    alias AtlasCode.Effects.GitHub

    run = fn name, status, conclusion ->
      %{"name" => name, "status" => status, "conclusion" => conclusion}
    end

    runs = fn entries -> %{"check_runs" => entries, "total_count" => length(entries)} end

    statuses = fn entries, state ->
      %{"statuses" => entries, "total_count" => length(entries), "state" => state}
    end

    empty = statuses.([], "pending")
    green = runs.([run.("a", "completed", "success"), run.("b", "completed", "skipped")])

    assert GitHub.conclusion(runs.([]), empty) == :pending
    assert GitHub.conclusion(green, empty) == :success
    assert GitHub.conclusion(runs.([run.("a", "in_progress", nil)]), empty) == :pending

    assert GitHub.conclusion(
             runs.([run.("a", "in_progress", nil), run.("b", "completed", "failure")]),
             empty
           ) == {:failure, ["b"]}

    assert GitHub.conclusion(runs.([run.("a", "completed", "cancelled")]), empty) ==
             {:failure, ["a"]}

    for {state, expected} <- [
          {"success", :success},
          {"pending", :pending},
          {"error", {:failure, ["ci"]}}
        ] do
      status = statuses.([%{"context" => "ci", "state" => state}], state)
      assert GitHub.conclusion(runs.([]), status) == expected
    end

    assert GitHub.conclusion(Map.put(green, "total_count", 101), empty) == :pending

    # Failed/pending contexts outside the visible page: aggregate state is authoritative.
    visible = for i <- 1..30, do: %{"context" => "green-#{i}", "state" => "success"}

    for state <- ["failure", "error", "pending", "success"] do
      status = %{"statuses" => visible, "total_count" => 31, "state" => state}

      expected =
        if state in ["failure", "error"], do: {:failure, ["combined_status"]}, else: :pending

      assert GitHub.conclusion(runs.([]), status) == expected
      assert GitHub.conclusion(green, status) == expected
    end

    # Even a complete visible page cannot override a non-green aggregate.
    for state <- ["failure", "pending"] do
      result = GitHub.conclusion(green, statuses.(visible, state))
      assert result == if(state == "failure", do: {:failure, ["combined_status"]}, else: :pending)
    end

    complete = statuses.(visible, "success")
    assert GitHub.conclusion(green, complete) == :success

    for count <- [nil, -1, "30", 29, 31] do
      assert GitHub.conclusion(green, Map.put(complete, "total_count", count)) == :pending
      assert GitHub.conclusion(Map.put(green, "total_count", count), empty) == :pending
    end

    assert GitHub.conclusion(green, Map.delete(complete, "state")) == :pending
  end
end
