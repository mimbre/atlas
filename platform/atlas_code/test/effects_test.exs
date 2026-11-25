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

  test "a subject's result is published as one pull, the same answer for every repeat", c do
    # The fix's result, on the author's, after a review that asked for changes.
    result = FakeGitHub.sha("result")
    ref = "refs/atlas/results/TK-JB-1-3"

    results = fn
      "github.com/o/r", ^ref -> {:ok, %{"dir" => "/cache.git", "commit" => result}}
      _, _ -> :error
    end

    s =
      Effects.new(
        dir: c.dir,
        github: {FakeGitHub, FakeGitHub.config(c.gh)},
        repositories: ["o/r"],
        results: results
      )

    r =
      request(nil, %{
        "id" => String.duplicate("b", 64),
        "name" => "publish",
        "subject" => "JB-1",
        "operation" => "publish",
        "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
        "payload" => %{"title" => "Fix the README", "description" => "One typo."},
        "input" => %{
          "repository" => "github.com/o/r",
          "base" => "main",
          "result" => ref,
          "review" => %{
            "task" => "TK-JB-1-2",
            "verdict" => "changes_required",
            "findings" => ["README has a second typo."]
          },
          "fix" => %{"task" => "TK-JB-1-3", "answer" => "Fixed the second typo."}
        }
      })
      |> Map.drop(["target", "approved"])

    assert %{"status" => "done", "reference" => url, "outputs" => %{"url" => url}} =
             first = call(s, "submit", r)

    assert url == "https://github.com/o/r/pull/8"

    assert %{"head" => ^result, "base" => "main", "title" => "Fix the README"} =
             pull = FakeGitHub.get_pull(c.gh, 8)

    assert pull["body"] =~ "One typo."
    assert pull["body"] =~ "TK-JB-1-2"
    assert pull["body"] =~ "README has a second typo."
    assert pull["body"] =~ "> Fixed the second typo."
    assert pull["body"] =~ "Written by an AI agent"
    refute pull["body"] =~ "No review was made"

    # Repeated, or its record lost: the same pull, never a second one.
    assert call(s, "lookup", r) == first
    File.rm!(Path.join([c.dir, "effects", r["id"] <> ".json"]))
    assert call(s, "submit", r) == first
    assert [{:push, "atlas/TK-JB-1-3", ^result}, {:create_pull, 8}] = FakeGitHub.writes(c.gh)

    # A result Code does not hold publishes nothing.
    unknown =
      Map.merge(r, %{
        "id" => String.duplicate("c", 64),
        "input" => %{r["input"] | "result" => "refs/atlas/results/TK-X"}
      })

    assert %{"status" => "refused", "reason" => "unknown_result"} = call(s, "submit", unknown)
  end

  test "a result published without a review says that no review was made", c do
    # Its review ended without a result; its supervisor published the author's result.
    result = FakeGitHub.sha("unreviewed")
    ref = "refs/atlas/results/TK-JB-1-1"

    results = fn
      "github.com/o/r", ^ref -> {:ok, %{"dir" => "/cache.git", "commit" => result}}
      _, _ -> :error
    end

    s =
      Effects.new(
        dir: c.dir,
        github: {FakeGitHub, FakeGitHub.config(c.gh)},
        repositories: ["o/r"],
        results: results
      )

    r =
      request(nil, %{
        "id" => String.duplicate("9", 64),
        "name" => "publish",
        "subject" => "JB-1",
        "operation" => "publish",
        "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
        "payload" => %{"title" => "Fix the README", "description" => "One typo."},
        "input" => %{"repository" => "github.com/o/r", "base" => "main", "result" => ref}
      })
      |> Map.drop(["target", "approved"])

    assert %{"status" => "done", "outputs" => %{"url" => url}} = call(s, "submit", r)
    number = url |> String.split("/") |> List.last() |> String.to_integer()
    body = FakeGitHub.get_pull(c.gh, number)["body"]
    assert body =~ "One typo."
    assert body =~ "**Review.** No review was made of this result."
    refute body =~ "**Fix.**"
  end

  # GitHub's closing references, as GitHub reads them: a keyword, an optional colon, white
  # space, then `#n` or `owner/repo#n`.
  @github_closes ~r/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+(?:[\w.-]+\/[\w.-]+)?#\d+/i

  test "a published pull's body closes no other pull or issue on merge (IS-Atlas-136)", c do
    result = FakeGitHub.sha("closing")
    ref = "refs/atlas/results/TK-JB-1-4"

    results = fn
      "github.com/o/r", ^ref -> {:ok, %{"dir" => "/cache.git", "commit" => result}}
      _, _ -> :error
    end

    s =
      Effects.new(
        dir: c.dir,
        github: {FakeGitHub, FakeGitHub.config(c.gh)},
        repositories: ["o/r"],
        results: results
      )

    description = "This fixes #12. Closes owner/repo#3; closed #512/#514 earlier. See #12."

    r =
      request(nil, %{
        "id" => String.duplicate("8", 64),
        "name" => "publish",
        "subject" => "JB-1",
        "operation" => "publish",
        "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
        "payload" => %{"title" => "Fix the README", "description" => description},
        "input" => %{
          "repository" => "github.com/o/r",
          "base" => "main",
          "result" => ref,
          "review" => %{
            "task" => "TK-JB-1-2",
            "verdict" => "approved",
            "findings" => ["Resolves: #7 too."]
          },
          "fix" => %{"task" => "TK-JB-1-3", "answer" => "FIXED #9"}
        }
      })
      |> Map.drop(["target", "approved"])

    assert Regex.match?(@github_closes, description)
    assert %{"status" => "done", "outputs" => %{"url" => url}} = call(s, "submit", r)
    number = url |> String.split("/") |> List.last() |> String.to_integer()
    body = FakeGitHub.get_pull(c.gh, number)["body"]

    refute Regex.match?(@github_closes, body), body
    # A person still reads every reference; one without a keyword is untouched.
    for reference <- ["#12", "owner/repo#3", "#512/#514", "#7", "#9"],
        do: assert(body =~ reference)

    assert body =~ "fixes (#12)"
    assert body =~ "Closes (owner/repo#3)"
    assert body =~ "closed (#512/#514)"
    assert body =~ "See #12."
  end

  test "a result onto an open pull is pushed to its branch, never forced; done with its address",
       c do
    # The pull Code opened from the author's result; the CI fix's result sits on it. Code's
    # copy holds them on its main, and so does GitHub.
    {git_dir, commit} = copy(c.dir)
    base = commit.("base", nil, %{"README.md" => "base\n"})
    published = commit.("published", base, %{"README.md" => "published\n"})
    fixed = commit.("ci fix", published, %{"README.md" => "fixed\n"})
    other = commit.("other", base, %{"OTHER.md" => "other\n"})

    for {sha, parents} <- [{base, []}, {published, [base]}, {fixed, [published]}, {other, [base]}],
        do: FakeGitHub.commit(c.gh, sha, parents)

    FakeGitHub.branch(c.gh, "atlas/TK-JB-1-1", published)
    FakeGitHub.put_pull(c.gh, 9, %{"head" => published, "head_ref" => "atlas/TK-JB-1-1"})
    url = "https://github.com/o/r/pull/9"
    ref = "refs/atlas/results/TK-JB-1-5"

    results = fn
      "github.com/o/r", ^ref ->
        {:ok, %{"dir" => git_dir, "commit" => fixed}}

      "github.com/o/r", "refs/atlas/results/TK-JB-1-6" ->
        {:ok, %{"dir" => git_dir, "commit" => other}}

      _, _ ->
        :error
    end

    s =
      Effects.new(
        dir: c.dir,
        github: {FakeGitHub, FakeGitHub.config(c.gh)},
        repositories: ["o/r"],
        results: results
      )

    r =
      request(nil, %{
        "id" => String.duplicate("e", 64),
        "name" => "push",
        "subject" => "JB-1",
        "operation" => "publish",
        "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
        "payload" => %{"title" => "Fix the README"},
        "input" => %{
          "repository" => "github.com/o/r",
          "base" => "main",
          "result" => ref,
          "pull" => url
        }
      })
      |> Map.drop(["target", "approved"])

    assert %{"status" => "done", "reference" => ^url, "outputs" => %{"url" => ^url}} =
             first = call(s, "submit", r)

    assert FakeGitHub.get_pull(c.gh, 9)["head"] == fixed
    assert call(s, "lookup", r) == first
    File.rm!(Path.join([c.dir, "effects", r["id"] <> ".json"]))
    assert call(s, "submit", r) == first
    assert [{:push, "atlas/TK-JB-1-1", ^fixed}] = FakeGitHub.writes(c.gh)

    # A result that is not on the pull's head is never forced onto it.
    other = %{
      r
      | "id" => String.duplicate("f", 64),
        "input" => %{r["input"] | "result" => "refs/atlas/results/TK-JB-1-6"}
    }

    assert %{"status" => "refused", "reason" => "branch_taken"} = call(s, "submit", other)
    assert FakeGitHub.get_pull(c.gh, 9)["head"] == fixed
  end

  test "a result without changes against its base opens no pull", c do
    repo = Path.join(c.dir, "repo")
    git = fn args -> System.cmd("git", ["-C", repo | args]) |> elem(0) |> String.trim() end
    File.mkdir_p!(repo)
    git.(["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git.(["add", "README.md"])
    git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"])
    # The author's result and the fix on it, as a Runtime commits them: the base's tree.
    author =
      git.([
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit-tree",
        "HEAD^{tree}",
        "-p",
        "HEAD",
        "-m",
        "author"
      ])

    result =
      git.([
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit-tree",
        "HEAD^{tree}",
        "-p",
        author,
        "-m",
        "fix"
      ])

    ref = "refs/atlas/results/TK-JB-2-1"

    s =
      Effects.new(
        dir: c.dir,
        github: {FakeGitHub, FakeGitHub.config(c.gh)},
        repositories: ["o/r"],
        results: fn "github.com/o/r", ^ref ->
          {:ok, %{"dir" => Path.join(repo, ".git"), "commit" => result}}
        end
      )

    r =
      request(nil, %{
        "id" => String.duplicate("d", 64),
        "name" => "publish",
        "subject" => "JB-2",
        "operation" => "publish",
        "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
        "payload" => %{"title" => "Change nothing"},
        "input" => %{"repository" => "github.com/o/r", "base" => "main", "result" => ref}
      })
      |> Map.drop(["target", "approved"])

    assert %{"status" => "refused", "reason" => "no_changes", "details" => %{"base" => "main"}} =
             call(s, "submit", r)

    # Code's copy told: nothing asked of GitHub.
    assert FakeGitHub.writes(c.gh) == []
    assert FakeGitHub.compares(c.gh) == []
  end

  # No pull without changes (IS-Atlas-64): when Code's copy cannot tell, GitHub's compare
  # does, before any pull is opened; when neither can, the publication is refused.
  describe "a result whose copy cannot tell its changes" do
    # Code's copy of the repository without its base branch (main): only `develop`, with
    # the base commit and the result on it, which GitHub holds too. What its pull would
    # show is GitHub's to say (`FakeGitHub.files/3`: 0 is no changes).
    setup c do
      {git_dir, commit} = copy(c.dir, "develop")
      base = commit.("base", nil, %{"README.md" => "base\n"})
      result = commit.("result", base, %{"README.md" => "result\n"})
      FakeGitHub.commit(c.gh, base)
      FakeGitHub.commit(c.gh, result, [base])
      FakeGitHub.branch(c.gh, "main", base)
      %{copy: git_dir, result: result}
    end

    test "its base branch missing: Code's copy says so; GitHub's compare finds no changes, no pull is opened",
         c do
      assert Effects.changes(c.copy, c.result, "main") == {:unknown, "base_missing"}
      FakeGitHub.files(c.gh, c.result, 0)
      s = publisher(c, c.copy, c.result)

      assert %{"status" => "refused", "reason" => "no_changes", "details" => %{"base" => "main"}} =
               first = call(s, "submit", publication())

      assert [{"main", c.result}] == FakeGitHub.compares(c.gh)
      assert [{:push, "atlas/TK-JB-3-1", _}] = FakeGitHub.writes(c.gh)
      assert call(s, "lookup", publication()) == first
      refute Enum.any?(FakeGitHub.writes(c.gh), &match?({:create_pull, _}, &1))
    end

    test "its base branch missing: GitHub's compare finds changes, its pull is opened", c do
      s = publisher(c, c.copy, c.result)

      assert %{"status" => "done", "outputs" => %{"url" => "https://github.com/o/r/pull/8"}} =
               call(s, "submit", publication())

      assert [{"main", c.result}] == FakeGitHub.compares(c.gh)
    end

    test "Git failing (no copy): GitHub's compare tells, and an empty result opens no pull", c do
      assert Effects.changes(Path.join(c.dir, "none.git"), c.result, "main") ==
               {:unknown, "git_failed"}

      FakeGitHub.files(c.gh, c.result, 0)
      s = publisher(c, Path.join(c.dir, "none.git"), c.result)

      assert %{"status" => "refused", "reason" => "no_changes"} =
               call(s, "submit", publication())

      refute Enum.any?(FakeGitHub.writes(c.gh), &match?({:create_pull, _}, &1))
    end

    test "GitHub refusing its compare, or answering without its files: refused changes_unknown, no pull",
         c do
      s = publisher(c, c.copy, c.result)
      FakeGitHub.fail(c.gh, :compare, {:refused, "not_found"})

      assert %{
               "status" => "refused",
               "reason" => "changes_unknown",
               "details" => %{
                 "base" => "main",
                 "why" => "compare_refused",
                 "github" => "not_found"
               }
             } = refused = call(s, "submit", publication())

      assert call(s, "lookup", publication()) == refused

      FakeGitHub.files(c.gh, c.result, :unlisted)
      unlisted = publication(String.duplicate("2", 64))

      assert %{
               "status" => "refused",
               "reason" => "changes_unknown",
               "details" => %{"why" => "compare_without_files"}
             } = call(s, "submit", unlisted)

      refute Enum.any?(FakeGitHub.writes(c.gh), &match?({:create_pull, _}, &1))
    end

    test "GitHub unreachable for its compare: still working, no pull; told later", c do
      s = publisher(c, c.copy, c.result)
      FakeGitHub.fail(c.gh, :compare, :unavailable)
      assert %{"status" => "working"} = call(s, "submit", publication())
      refute Enum.any?(FakeGitHub.writes(c.gh), &match?({:create_pull, _}, &1))

      FakeGitHub.files(c.gh, c.result, 0)
      assert %{"status" => "refused", "reason" => "no_changes"} = call(s, "lookup", publication())
      refute Enum.any?(FakeGitHub.writes(c.gh), &match?({:create_pull, _}, &1))
    end

    test "onto an open pull: refused changes_unknown before anything is pushed", c do
      FakeGitHub.put_pull(c.gh, 9, %{"head" => c.result, "head_ref" => "atlas/TK-JB-3-0"})
      s = publisher(c, c.copy, c.result)
      onto = publication(String.duplicate("3", 64), %{"pull" => "https://github.com/o/r/pull/9"})

      assert %{
               "status" => "refused",
               "reason" => "changes_unknown",
               "details" => %{"base" => "main", "why" => "base_missing"}
             } = call(s, "submit", onto)

      assert FakeGitHub.writes(c.gh) == []
      assert FakeGitHub.compares(c.gh) == []
    end
  end

  test "Code's copy tells a result's changes against its base: none, some, or not" do
    dir = Path.join(System.tmp_dir!(), "changes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {git_dir, commit} = copy(dir)
    base = commit.("base", nil, %{"README.md" => "base\n"})
    same = commit.("same", base, %{"README.md" => "base\n"})
    changed = commit.("changed", base, %{"README.md" => "changed\n"})
    lone = commit.("lone", :root, %{"README.md" => "lone\n"})
    {_, 0} = System.cmd("git", ["--git-dir", git_dir, "update-ref", "refs/heads/main", base])

    assert Effects.changes(git_dir, same, "main") == :none
    assert Effects.changes(git_dir, changed, "main") == :some
    assert Effects.changes(git_dir, changed, "develop") == {:unknown, "base_missing"}
    assert Effects.changes(git_dir, lone, "main") == {:unknown, "no_merge_base"}
    assert Effects.changes(git_dir, String.duplicate("0", 40), "main") == {:unknown, "git_failed"}
    assert Effects.changes(Path.join(dir, "none.git"), same, "main") == {:unknown, "git_failed"}
  end

  # A Git copy of a repository in `dir`, as Code's (a bare one), and how to commit to it:
  # `commit.(message, parent, files)` makes a commit of exactly `files` on `parent` (nil:
  # the branch's first, which it moves; `:root`: a commit on no branch and no parent) and
  # answers its SHA. `branch` is the one branch it holds.
  defp copy(dir, branch \\ "main") do
    git_dir = Path.join(dir, "copy-#{System.unique_integer([:positive])}.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", git_dir])

    identity =
      [{"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@t"}] ++
        [{"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@t"}]

    git = fn args, input ->
      {out, 0} =
        System.cmd(
          "sh",
          ["-c", ~s(printf '%s' "$INPUT" | git --git-dir "$0" "$@"), git_dir | args],
          env: [{"INPUT", input} | identity]
        )

      String.trim(out)
    end

    commit = fn message, parent, files ->
      entries =
        for {name, content} <- files do
          "100644 blob #{git.(["hash-object", "-w", "--stdin"], content)}\t#{name}\n"
        end

      tree = git.(["mktree"], Enum.join(entries))
      parents = if is_binary(parent), do: ["-p", parent], else: []
      sha = git.(["commit-tree", tree | parents] ++ ["-m", message], "")
      if parent == nil, do: git.(["update-ref", "refs/heads/" <> branch, sha], "")
      sha
    end

    {git_dir, commit}
  end

  # Code's receiver whose result refs/atlas/results/TK-JB-3-1 is `commit` in `git_dir`.
  defp publisher(c, git_dir, commit) do
    Effects.new(
      dir: c.dir,
      github: {FakeGitHub, FakeGitHub.config(c.gh)},
      repositories: ["o/r"],
      results: fn "github.com/o/r", "refs/atlas/results/TK-JB-3-1" ->
        {:ok, %{"dir" => git_dir, "commit" => commit}}
      end
    )
  end

  # A publication of refs/atlas/results/TK-JB-3-1 onto main, as Flow's effect asks it.
  defp publication(id \\ String.duplicate("1", 64), input \\ %{}) do
    request(nil, %{
      "id" => id,
      "name" => "publish",
      "subject" => "JB-3",
      "operation" => "publish",
      "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
      "payload" => %{"title" => "Fix the README"},
      "input" =>
        Map.merge(
          %{
            "repository" => "github.com/o/r",
            "base" => "main",
            "result" => "refs/atlas/results/TK-JB-3-1"
          },
          input
        )
    })
    |> Map.drop(["target", "approved"])
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

  # K3: Flow holds only Code's `rev_` handles of commits.
  test "a rev_ handle of Code's is integrated as the commit Code recorded for it", c do
    handle = AtlasCode.put_revision(c.dir, "github.com/o/r", c.revision)
    FakeGitHub.ci(c.gh, c.revision, :success)
    r = request(handle)

    assert %{"status" => "done", "outputs" => %{"head" => head}} = call(c.s, "submit", r)
    assert head == c.revision
    assert [{:merge, 7, ^head}] = merges(c.gh)

    # The journal keeps the request as asked and its line from the resolved commit.
    record = JSON.decode!(File.read!(Path.join([c.dir, "effects", r["id"] <> ".json"])))
    assert {record["request"]["payload"]["revision"], record["line"]} == {handle, [c.revision]}

    # Resolved from another folder's record (`home`) just the same, and only there.
    home = Path.join(c.dir, "code-home")
    other = request(handle, %{"id" => String.duplicate("b", 64)})
    FakeGitHub.set_pull(c.gh, 7, %{"merged" => false, "state" => "open", "head" => c.revision})

    elsewhere =
      Effects.new(
        dir: Path.join(c.dir, "j"),
        home: home,
        github: c.s.github,
        repositories: ["o/r"]
      )

    assert %{"status" => "refused", "reason" => "unknown_revision"} =
             call(elsewhere, "submit", other)

    ^handle = AtlasCode.put_revision(home, "github.com/o/r", c.revision)
    third = request(handle, %{"id" => String.duplicate("c", 64)})
    assert %{"status" => "done"} = call(elsewhere, "submit", third)
  end

  test "an unknown, foreign or forged handle is refused unknown_revision, nothing asked of GitHub",
       c do
    unknown = "rev_" <> String.duplicate("1", 64)
    foreign = AtlasCode.put_revision(c.dir, "github.com/x/y", c.revision)

    # A record under a name that is not its handle.
    forged = "rev_" <> String.duplicate("2", 64)

    File.write!(
      Path.join([c.dir, "revisions", forged <> ".json"]),
      JSON.encode!(%{"commit" => c.revision, "repository" => "github.com/o/r"})
    )

    FakeGitHub.ci(c.gh, c.revision, :success)

    for {handle, n} <- Enum.with_index([unknown, foreign, forged]) do
      r = request(handle, %{"id" => String.duplicate(Integer.to_string(n + 3), 64)})

      assert %{"status" => "refused", "reason" => "unknown_revision", "details" => details} =
               call(c.s, "submit", r)

      assert details == %{"revision" => handle}
      # Kept: a repeat answers the same refusal.
      assert call(c.s, "lookup", r)["reason"] == "unknown_revision"
    end

    # Neither a commit nor a handle stays invalid_revision.
    assert %{"reason" => "invalid_revision"} =
             call(c.s, "submit", request("rev_x", %{"id" => String.duplicate("6", 64)}))

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
      Path.expand("../../../products/software_factory/environments/test/core.json", __DIR__)
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
          {200, [], "[1]", {:ok, [1]}},
          {200, [], "1", {:error, :unavailable}},
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
