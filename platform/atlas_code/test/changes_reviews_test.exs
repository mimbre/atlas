defmodule AtlasCode.ChangesReviewsTest do
  # C1b: changes and reviews through the facade AtlasCode.Boundary (create_change,
  # put_change_blob, seal_change, create_review, update_review) on a running Code: a
  # temporary home with a local bare repository, started with register: true. No GitHub:
  # github.com/test/app reaches the bare remote through a GitHub URL that Code's cache
  # rewrites to it, and its provider reviews go to the fixture `gh` of atlas_code_test. Not
  # async: one instance holds the registered name at a time.
  use ExUnit.Case, async: false

  alias AtlasCode.{Boundary, Service}
  alias AtlasCode.Boundary.{ChangeEntry, Outcome}
  alias AtlasCodeBoundary.Generator.{InvalidInput, NotPermitted}

  setup {AtlasCode.TestDir, :tmp_dir}

  @token "runtime-secret-token"
  @orchestrator "orchestrator-secret-token"
  @attribution "\n\n<sub>Written by an AI agent (test).</sub>\n"
  @client {"test:flow", [:snapshot, :change, :review]}
  @hub "https://github.com/test/app.git"
  # The fixture provider of atlas_code_test: records each call; `fail-before` makes
  # `pr create` fail before it creates the provider review. For K2 it also stands in for
  # GitHub's pull 7: `pr create --draft` makes it a draft and `pr ready` (unless
  # `fail-ready`) ready; `gh api` answers the pull from `pr-head`, `pr-state` (open, closed or
  # merged) and `pr-mergeable`, and its reviews, check runs, combined status and comparison
  # from the JSON files of those names (`fail-api` fails every read).
  @gh """
  #!/bin/sh
  state=$(dirname "$0")
  echo "$GH_PROMPT_DISABLED $*" >> "$state/gh-calls"
  case "$1 $2" in
    "pr list")
      if [ -e "$state/pr-url" ]; then printf '[{"url":"%s"}]\\n' "$(cat "$state/pr-url")"; else echo '[]'; fi ;;
    "pr create")
      if [ -e "$state/fail-before" ]; then echo "ghp_secret failed" >&2; exit 1; fi
      for arg; do case "$arg" in
        --body-file=*) cp "${arg#--body-file=}" "$state/pr-body" ;;
        --draft) touch "$state/pr-draft" ;;
      esac; done
      echo https://github.com/test/app/pull/7 > "$state/pr-url"
      cat "$state/pr-url" ;;
    "pr ready")
      if [ -e "$state/fail-ready" ]; then echo "ghp_secret failed" >&2; exit 1; fi
      rm -f "$state/pr-draft" ;;
    "api "*)
      if [ -e "$state/fail-api" ]; then echo "ghp_secret failed" >&2; exit 1; fi
      case "$2" in
        repos/test/app/pulls/7)
          pr=$(cat "$state/pr-state" 2>/dev/null || echo open); merged=false
          if [ "$pr" = merged ]; then pr=closed; merged=true; fi
          draft=false; if [ -e "$state/pr-draft" ]; then draft=true; fi
          printf '{"state":"%s","merged":%s,"draft":%s,"head":{"sha":"%s"},"base":{"ref":"develop"},"mergeable":%s}\\n' \\
            "$pr" "$merged" "$draft" "$(cat "$state/pr-head")" "$(cat "$state/pr-mergeable" 2>/dev/null || echo null)" ;;
        repos/test/app/pulls/7/reviews\\?*) cat "$state/reviews.json" 2>/dev/null || echo '[]' ;;
        repos/test/app/commits/*/check-runs\\?*) cat "$state/check-runs.json" ;;
        repos/test/app/commits/*/status\\?*) cat "$state/status.json" ;;
        repos/test/app/compare/develop...*) cat "$state/compare.json" ;;
        *) exit 2 ;;
      esac ;;
    *) exit 2 ;;
  esac
  """

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])
    File.write!(Path.join(source, "README.md"), "hello\n")
    File.write!(Path.join(source, "other.txt"), "other\n")
    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    remote = Path.join(dir, "remote.git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    gh = Path.join(dir, "gh")
    File.write!(gh, @gh)
    File.chmod!(gh, 0o755)

    home = Path.join(dir, "home")
    File.mkdir!(home)

    config = %{
      "port" => 0,
      "gh" => gh,
      "repositories" => %{
        "github.com/test/app" => @hub,
        "github.com/test/plain" => "file://" <> remote
      }
    }

    File.write!(Path.join(home, "config.json"), JSON.encode!(config))

    for {file, token} <- [{"runtime.token", @token}, {"orchestrator.token", @orchestrator}] do
      File.write!(Path.join(home, file), token <> "\n")
      File.chmod!(Path.join(home, file), 0o600)
    end

    cache = Path.join([home, "cache", sha256(["github.com/test/app", 0, @hub]) <> ".git"])
    git(dir, ["init", "-q", "--bare", cache])
    git(cache, ["config", "url.file://#{remote}.insteadOf", @hub])

    {:ok, pid, port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)

    # Resolving the GitHub URL would leave this machine, so github.com/test/app's handle is
    # recorded through Code's own mapping, as atlas_code_test does.
    %Outcome.Resolved{revision: plain} =
      Boundary.resolve_reference(@client, %{
        repository: "github.com/test/plain",
        reference: "develop"
      })

    base = remote |> git(["rev-parse", "develop"]) |> String.trim()
    app = AtlasCode.put_revision(home, "github.com/test/app", base)

    %Outcome.Created{snapshot_id: snapshot_id} =
      Boundary.create_snapshot(@client, %{
        repositories: [
          %{repository: "github.com/test/app", revision: app, path: "app"},
          %{repository: "github.com/test/plain", revision: plain, path: "plain"}
        ]
      })

    %{
      dir: dir,
      home: home,
      port: port,
      remote: remote,
      snapshot_id: snapshot_id,
      revisions: %{"github.com/test/app" => app, "github.com/test/plain" => plain}
    }
  end

  describe "create_change, put_change_blob and seal_change" do
    test "a change is created open, gets its blobs and seals into a revision, as over HTTP",
         %{home: home, port: port} = context do
      bytes = <<0, 255, 1, 254>> <> :crypto.strong_rand_bytes(100)
      input = change(context, uuid(1), "github.com/test/app", [write("bin/data", bytes)])
      digest = sha256(bytes)

      assert %Outcome.Change{change_id: id, state: :open, missing: [^digest], revision: nil} =
               open = Boundary.create_change(@client, input)

      assert id == uuid(1)
      # A repeat is the same change; over HTTP it answers the same.
      assert Boundary.create_change(@client, input) == open
      assert post(port, "/v1/changes", input) == {200, Outcome.Change.dump(open)}

      # A blob's bytes are any binary, not only text.
      assert %Outcome.Change{state: :open, missing: []} =
               Boundary.put_change_blob(@client, %{change_id: id, sha256: digest, content: bytes})

      assert File.read!(Path.join([home, "changes", id, "blobs", digest])) == bytes

      assert %Outcome.Change{state: :sealed, missing: [], revision: "rev_" <> _ = revision} =
               sealed = Boundary.seal_change(@client, %{change_id: id})

      # Sealing again is the recorded revision; the routes and the Service answer it too.
      assert Boundary.seal_change(@client, %{change_id: id}) == sealed

      assert request(port, :post, "/v1/changes/#{id}/seal", "") ==
               {200, Outcome.Change.dump(sealed)}

      assert Service.seal_change(AtlasCode.settings(), id) == {200, Outcome.Change.dump(sealed)}

      assert request(port, :put, "/v1/changes/#{id}/blobs/#{digest}", bytes) ==
               {200, Outcome.Change.dump(sealed)}

      # The revision is the sealed commit, with the base as its one parent.
      %{"commit" => commit} =
        JSON.decode!(File.read!(Path.join([home, "revisions", revision <> ".json"])))

      assert File.read!(Path.join([home, "changes", id, "revision"])) == revision
      assert commit =~ ~r/\A[0-9a-f]{40}\z/
    end

    test "entries are typed values; a symlink's target travels in the change", context do
      input =
        change(context, uuid(2), "github.com/test/app", [
          symlink("link", "README.md"),
          %ChangeEntry{path: "other.txt", op: :delete}
        ])

      # Built structs are taken as they are; a symlink's blob is its target, so none is missing.
      assert %Outcome.Change{state: :open, missing: []} = Boundary.create_change(@client, input)

      assert %Outcome.Change{state: :sealed} =
               Boundary.seal_change(@client, %{change_id: uuid(2)})
    end

    test "answers each refusal of create_change as its outcome, as the HTTP route does",
         %{home: home, port: port} = context do
      ok = change(context, uuid(10), "github.com/test/app", [write("a.txt", "a")])
      %Outcome.Change{} = Boundary.create_change(@client, ok)
      unknown = "sha256:" <> String.duplicate("0", 64)
      old = String.duplicate("a", 64)
      File.write!(Path.join([home, "snapshots", old <> ".json"]), ~s({"version":1}))

      cases = [
        {%{ok | change_id: "NOT-A-UUID"}, Outcome.InvalidRequest, change_id: "NOT-A-UUID"},
        {%{ok | change_id: uuid(11), entries: [delete("missing.txt")]}, Outcome.InvalidRequest,
         path: "missing.txt"},
        {%{ok | change_id: uuid(11), repository: "github.com/test/other"}, Outcome.Forbidden,
         repository: "github.com/test/other"},
        {%{ok | change_id: uuid(11), snapshot_id: unknown}, Outcome.NotFound,
         snapshot_id: unknown},
        {%{ok | change_id: uuid(11), snapshot_id: "sha256:" <> old}, Outcome.SnapshotSuperseded,
         snapshot_id: "sha256:" <> old, successor: nil},
        {%{ok | change_id: uuid(11), base_revision: context.revisions["github.com/test/plain"]},
         Outcome.BaseMismatch,
         repository: "github.com/test/app",
         base_revision: context.revisions["github.com/test/plain"],
         revision: context.revisions["github.com/test/app"]},
        {%{ok | entries: [write("b.txt", "b")]}, Outcome.Conflict, change_id: uuid(10)},
        {%{ok | change_id: uuid(11), entries: [symlink("escape", "../../etc/passwd")]},
         Outcome.UnsupportedContent, []}
      ]

      for {input, outcome, fields} <- cases do
        assert %^outcome{message: message} = answer = Boundary.create_change(@client, input)
        assert is_binary(message)

        for {field, value} <- fields,
            do: assert(Map.fetch!(answer, field) == value, "#{inspect(outcome)} #{field}")

        # The route answers as the Service does, through the facade.
        response = post(port, "/v1/changes", input)

        assert response == Service.create_change(AtlasCode.settings(), stringify(input)),
               inspect(outcome)

        assert {_status, %{"error" => %{"message" => ^message}}} = response
      end

      assert %Outcome.UnsupportedContent{
               entries: [%{repository: "github.com/test/app", path: "escape"}]
             } =
               Boundary.create_change(@client, %{
                 ok
                 | change_id: uuid(11),
                   entries: [symlink("escape", "../../etc/passwd")]
               })

      refute File.exists?(Path.join([home, "changes", uuid(11)]))
    end

    test "refuses what the contract does not allow before it reaches Code",
         %{home: home} = context do
      input = change(context, uuid(20), "github.com/test/app", [write("a.txt", "a")])

      assert %NotPermitted{capability: :create_change, right: :change} =
               Boundary.create_change({"test:reader", [:snapshot]}, input)

      for capability <- [:put_change_blob, :seal_change] do
        assert %NotPermitted{capability: ^capability, right: :change} =
                 apply(Boundary, capability, [
                   {"test:reader", [:snapshot]},
                   %{change_id: uuid(20)}
                 ])
      end

      assert %InvalidInput{capability: :create_change} =
               Boundary.create_change(@client, Map.delete(input, :entries))

      assert %InvalidInput{capability: :create_change} =
               Boundary.create_change(@client, %{input | entries: [%{path: "a", op: "move"}]})

      assert %InvalidInput{capability: :put_change_blob} =
               Boundary.put_change_blob(@client, %{change_id: uuid(20), sha256: "x"})

      refute File.exists?(Path.join([home, "changes", uuid(20)]))
    end

    test "a body the Service refuses is refused as before, also where the facade would take it",
         %{port: port} = context do
      input = change(context, uuid(21), "github.com/test/app", [write("a.txt", "a")])
      [entry] = input.entries

      bodies = [
        # An optional member given as null: the facade leaves it out, the Service refuses it.
        %{input | entries: [Map.put(entry, :target, nil)]},
        # A mistyped member: the facade's reason would differ from the Service's.
        %{input | entries: [%{entry | size: "1"}]},
        %{input | base_revision: nil},
        Map.put(input, :extra, 1),
        %{input | entries: []}
      ]

      for body <- bodies do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 response = post(port, "/v1/changes", body)

        assert response ==
                 Service.create_change(AtlasCode.settings(), stringify(body))
      end
    end

    test "answers each refusal of put_change_blob and seal_change as its outcome, as HTTP does",
         %{home: home, port: port} = context do
      input = change(context, uuid(30), "github.com/test/app", [write("a.txt", "a")])
      %Outcome.Change{} = Boundary.create_change(@client, input)
      digest = sha256("a")

      puts = [
        {%{change_id: "nope", sha256: digest, content: "a"}, Outcome.InvalidRequest, []},
        {%{change_id: uuid(31), sha256: digest, content: "a"}, Outcome.NotFound,
         change_id: uuid(31)},
        {%{change_id: uuid(30), sha256: sha256("b"), content: "b"}, Outcome.NotFound, []},
        {%{change_id: uuid(30), sha256: digest, content: "ab"}, Outcome.InvalidRequest,
         sha256: digest},
        {%{change_id: uuid(30), sha256: digest, content: "b"}, Outcome.InvalidRequest,
         sha256: digest}
      ]

      for {put, outcome, fields} <- puts do
        assert %^outcome{} = answer = Boundary.put_change_blob(@client, put)
        for {field, value} <- fields, do: assert(Map.fetch!(answer, field) == value)

        assert request(
                 port,
                 :put,
                 "/v1/changes/#{put.change_id}/blobs/#{put.sha256}",
                 put.content
               ) ==
                 Service.put_change_blob(
                   AtlasCode.settings(),
                   put.change_id,
                   put.sha256,
                   put.content
                 )
      end

      assert %Outcome.IncompleteUpload{missing: [^digest]} =
               Boundary.seal_change(@client, %{change_id: uuid(30)})

      assert %Outcome.NotFound{change_id: id} =
               Boundary.seal_change(@client, %{change_id: uuid(31)})

      assert id == uuid(31)
      assert %Outcome.InvalidRequest{} = Boundary.seal_change(@client, %{change_id: "nope"})

      for id <- [uuid(30), uuid(31), "nope"] do
        assert request(port, :post, "/v1/changes/#{id}/seal", "") ==
                 Service.seal_change(AtlasCode.settings(), id)
      end

      # The base revision's record is gone: sealing cannot reach the base.
      %Outcome.Change{} =
        Boundary.put_change_blob(@client, %{change_id: uuid(30), sha256: digest, content: "a"})

      app = context.revisions["github.com/test/app"]
      File.rm!(Path.join([home, "revisions", app <> ".json"]))

      assert %Outcome.UnknownRevision{repository: "github.com/test/app", revision: ^app} =
               Boundary.seal_change(@client, %{change_id: uuid(30)})
    end
  end

  describe "create_review" do
    test "opens a GitHub review once, on its provider; a repeat answers the open review",
         %{dir: dir, port: port, home: home, remote: remote} = context do
      sealed(context, uuid(40), "github.com/test/app", %{"README.md" => "review\n"})
      input = review(uuid(41), uuid(40))

      assert %Outcome.Review{
               review_id: review_id,
               change_id: change_id,
               repository: "github.com/test/app",
               target: "develop",
               revision: revision,
               state: :open,
               link: "https://github.com/test/app/pull/7"
             } = opened = Boundary.create_review(@client, input)

      assert {review_id, change_id} == {uuid(41), uuid(40)}
      assert revision == File.read!(Path.join([home, "changes", uuid(40), "revision"]))
      assert Boundary.create_review(@client, input) == opened

      # Over HTTP the link is the provider review's review_url, as before the facade.
      assert {200, %{"review_url" => "https://github.com/test/app/pull/7"} = body} =
               orchestrate(port, "/v1/reviews", input)

      assert body == Service.create_review(AtlasCode.settings(), stringify(input)) |> elem(1)
      assert Map.delete(body, "review_url") == Map.delete(Outcome.Review.dump(opened), "link")

      # One provider review, at the review's location, with the review's body.
      location = "work/review-" <> uuid(41)
      assert git(remote, ["rev-parse", "refs/heads/" <> location]) != ""
      assert File.read!(Path.join(dir, "pr-body")) == input.body

      calls = dir |> Path.join("gh-calls") |> File.read!() |> String.split("\n", trim: true)
      assert Enum.count(calls, &String.contains?(&1, "pr create")) == 1
    end

    test "the review's pull closes no other pull or issue on merge (IS-Atlas-136)",
         %{dir: dir} = context do
      sealed(context, uuid(42), "github.com/test/app", %{"README.md" => "closing\n"})
      input = %{review(uuid(43), uuid(42)) | body: "Fixes #12, see #13." <> @attribution}

      assert %Outcome.Review{state: :open} = Boundary.create_review(@client, input)
      assert File.read!(Path.join(dir, "pr-body")) == "Fixes (#12), see #13." <> @attribution
    end

    test "a repository without a provider gets its pushed location as the review, no link",
         %{dir: dir, remote: remote} = context do
      sealed(context, uuid(42), "github.com/test/plain", %{"README.md" => "plain\n"})
      input = review(uuid(43), uuid(42))

      assert %Outcome.Review{repository: "github.com/test/plain", link: nil, state: :open} =
               Boundary.create_review(@client, input)

      assert git(remote, ["rev-parse", "refs/heads/work/review-" <> uuid(43)]) != ""
      refute File.exists?(Path.join(dir, "gh-calls"))
    end

    test "a provider review that fails after the push is review_incomplete; a repeat opens it",
         %{dir: dir, port: port} = context do
      sealed(context, uuid(44), "github.com/test/app", %{"README.md" => "retried\n"})
      input = review(uuid(45), uuid(44))
      File.write!(Path.join(dir, "fail-before"), "")

      assert %Outcome.ReviewIncomplete{phase: "pushed", message: message} =
               Boundary.create_review(@client, input)

      refute message =~ "ghp_secret"

      assert {502, %{"error" => %{"code" => "review_incomplete", "message" => ^message}}} =
               orchestrate(port, "/v1/reviews", input)

      File.rm!(Path.join(dir, "fail-before"))

      assert %Outcome.Review{link: "https://github.com/test/app/pull/7"} =
               Boundary.create_review(@client, input)
    end

    test "answers each refusal as its outcome, as the HTTP route does",
         %{port: port, home: home} = context do
      sealed(context, uuid(50), "github.com/test/app", %{"README.md" => "x\n"})

      %Outcome.Change{} =
        Boundary.create_change(
          @client,
          change(context, uuid(51), "github.com/test/app", [write("a.txt", "a")])
        )

      %Outcome.Review{} = Boundary.create_review(@client, review(uuid(52), uuid(50)))
      wrong = "fpr_" <> String.duplicate("0", 64)

      cases = [
        {%{review(uuid(53), uuid(50)) | body: "no attribution"}, Outcome.InvalidRequest, []},
        {%{review(uuid(53), uuid(50)) | target: "bad..name"}, Outcome.InvalidRequest, []},
        {review(uuid(53), uuid(59)), Outcome.NotFound, change_id: uuid(59)},
        {review(uuid(53), uuid(51)), Outcome.ChangeNotSealed, change_id: uuid(51)},
        {Map.put(review(uuid(53), uuid(50)), :fingerprint, wrong), Outcome.FingerprintMismatch,
         change_id: uuid(50), fingerprint: fingerprint_of(home, uuid(50))},
        {%{review(uuid(52), uuid(50)) | title: "Other"}, Outcome.Conflict, review_id: uuid(52)}
      ]

      for {input, outcome, fields} <- cases do
        assert %^outcome{} = answer = Boundary.create_review(@client, input)
        for {field, value} <- fields, do: assert(Map.fetch!(answer, field) == value)

        assert orchestrate(port, "/v1/reviews", input) ==
                 Service.create_review(AtlasCode.settings(), stringify(input)),
               inspect(outcome)
      end

      # The matching fingerprint opens it.
      assert %Outcome.Review{} =
               Boundary.create_review(
                 @client,
                 Map.put(review(uuid(54), uuid(50)), :fingerprint, fingerprint_of(home, uuid(50)))
               )
    end

    test "a review body the Service refuses is refused as before, also where the facade would take it",
         %{dir: dir, port: port, home: home, remote: remote} = context do
      sealed(context, uuid(57), "github.com/test/app", %{"README.md" => "z\n"})
      input = review(uuid(58), uuid(57))

      bodies = [
        # An optional member given as null: the facade leaves it out and would open the
        # review without its fingerprint check; the Service refuses it.
        Map.put(input, :fingerprint, nil),
        # A mistyped member and an extra one: the facade's reason would differ.
        %{input | title: 1},
        Map.put(input, :extra, 1)
      ]

      for body <- bodies do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 response = orchestrate(port, "/v1/reviews", body)

        assert response == Service.create_review(AtlasCode.settings(), stringify(body)),
               inspect(body)
      end

      # Nothing was opened: no review record, no location, no provider review.
      refute File.exists?(Path.join([home, "reviews", uuid(58) <> ".json"]))

      assert {_, status} =
               System.cmd("git", ["rev-parse", "--verify", "refs/heads/work/review-" <> uuid(58)],
                 cd: remote,
                 stderr_to_stdout: true
               )

      assert status != 0
      refute File.exists?(Path.join(dir, "gh-calls"))
    end

    test "needs the review right; over HTTP, the orchestrator token", %{port: port} = context do
      sealed(context, uuid(55), "github.com/test/app", %{"README.md" => "y\n"})
      input = review(uuid(56), uuid(55))

      assert %NotPermitted{capability: :create_review, right: :review} =
               Boundary.create_review({"test:worker", [:snapshot, :change]}, input)

      assert %NotPermitted{capability: :update_review, right: :review} =
               Boundary.update_review({"test:worker", [:snapshot, :change]}, %{})

      assert {403, %{"error" => %{"code" => "forbidden"}}} =
               orchestrate(port, "/v1/reviews", input, @token)

      assert %InvalidInput{capability: :create_review} =
               Boundary.create_review(@client, Map.delete(input, :title))
    end
  end

  describe "update_review" do
    test "moves an open review to another sealed change once, as over HTTP",
         %{port: port, home: home, remote: remote} = context do
      sealed(context, uuid(60), "github.com/test/app", %{"README.md" => "first\n"})

      %Outcome.Review{revision: first} =
        Boundary.create_review(@client, review(uuid(61), uuid(60)))

      sealed(context, uuid(62), "github.com/test/app", %{"README.md" => "second\n"})
      input = update(uuid(63), uuid(61), uuid(62), first, fingerprint_of(home, uuid(62)))

      assert %Outcome.Updated{
               update_id: update_id,
               review_id: review_id,
               change_id: change_id,
               repository: "github.com/test/app",
               previous_revision: ^first,
               revision: revision,
               state: :open,
               link: "https://github.com/test/app/pull/7"
             } = updated = Boundary.update_review(@client, input)

      assert {update_id, review_id, change_id} == {uuid(63), uuid(61), uuid(62)}
      assert revision != first
      assert Boundary.update_review(@client, input) == updated

      assert {200, %{"review_url" => "https://github.com/test/app/pull/7"} = body} =
               orchestrate(port, "/v1/review-updates", input)

      assert body == elem(Service.update_review(AtlasCode.settings(), stringify(input)), 1)
      assert Map.delete(body, "review_url") == Map.delete(Outcome.Updated.dump(updated), "link")

      # The location is at the update; the review follows it.
      %{"commit" => commit} =
        JSON.decode!(File.read!(Path.join([home, "revisions", revision <> ".json"])))

      assert git(remote, ["rev-parse", "refs/heads/work/review-" <> uuid(61)]) == commit <> "\n"

      assert %{"revision" => ^revision, "change_id" => ^change_id} =
               JSON.decode!(File.read!(Path.join([home, "reviews", uuid(61) <> ".json"])))
    end

    test "answers each refusal as its outcome, as the HTTP route does",
         %{port: port, home: home} = context do
      sealed(context, uuid(70), "github.com/test/app", %{"README.md" => "r\n"})

      %Outcome.Review{revision: head} =
        Boundary.create_review(@client, review(uuid(71), uuid(70)))

      sealed(context, uuid(72), "github.com/test/app", %{"README.md" => "u\n"})
      sealed(context, uuid(73), "github.com/test/plain", %{"README.md" => "p\n"})

      %Outcome.Change{} =
        Boundary.create_change(
          @client,
          change(context, uuid(74), "github.com/test/app", [write("a.txt", "a")])
        )

      good = fingerprint_of(home, uuid(72))
      wrong = "fpr_" <> String.duplicate("0", 64)
      stale = context.revisions["github.com/test/app"]

      cases = [
        {update("nope", uuid(71), uuid(72), head, good), Outcome.InvalidRequest, []},
        {update(uuid(75), uuid(71), uuid(72), head, "fpr_x"), Outcome.InvalidRequest, []},
        {update(uuid(75), uuid(79), uuid(72), head, good), Outcome.NotFound, review_id: uuid(79)},
        {update(uuid(75), uuid(71), uuid(78), head, good), Outcome.NotFound, change_id: uuid(78)},
        {update(uuid(75), uuid(71), uuid(74), head, good), Outcome.ChangeNotSealed,
         change_id: uuid(74)},
        {update(uuid(75), uuid(71), uuid(73), head, fingerprint_of(home, uuid(73))),
         Outcome.RepositoryMismatch, repository: "github.com/test/app", change_id: uuid(73)},
        {update(uuid(75), uuid(71), uuid(72), stale, good), Outcome.RevisionMismatch,
         review_id: uuid(71), revision: head},
        {update(uuid(75), uuid(71), uuid(72), head, wrong), Outcome.FingerprintMismatch,
         change_id: uuid(72), fingerprint: good}
      ]

      for {input, outcome, fields} <- cases do
        assert %^outcome{} = answer = Boundary.update_review(@client, input)
        for {field, value} <- fields, do: assert(Map.fetch!(answer, field) == value)

        assert orchestrate(port, "/v1/review-updates", input) ==
                 Service.update_review(AtlasCode.settings(), stringify(input)),
               inspect(outcome)
      end

      # An update_id used with another body is a conflict.
      %Outcome.Updated{} =
        Boundary.update_review(@client, update(uuid(76), uuid(71), uuid(72), head, good))

      assert %Outcome.Conflict{update_id: id} =
               Boundary.update_review(@client, update(uuid(76), uuid(71), uuid(72), stale, good))

      assert id == uuid(76)
    end

    test "an update body the Service refuses is refused as before, also where the facade would take it",
         %{port: port, home: home, remote: remote} = context do
      sealed(context, uuid(64), "github.com/test/app", %{"README.md" => "v\n"})

      %Outcome.Review{revision: head} =
        Boundary.create_review(@client, review(uuid(65), uuid(64)))

      sealed(context, uuid(66), "github.com/test/app", %{"README.md" => "w\n"})
      input = update(uuid(67), uuid(65), uuid(66), head, fingerprint_of(home, uuid(66)))
      ref = "refs/heads/work/review-" <> uuid(65)
      before = git(remote, ["rev-parse", ref])

      bodies = [
        # Null where the Service names the member: the facade would answer its own words.
        %{input | fingerprint: nil},
        %{input | revision: nil},
        Map.put(input, :extra, 1)
      ]

      for body <- bodies do
        assert {400, %{"error" => %{"code" => "invalid_request"}}} =
                 response = orchestrate(port, "/v1/review-updates", body)

        assert response == Service.update_review(AtlasCode.settings(), stringify(body)),
               inspect(body)
      end

      # Nothing was updated: no update record, the location where it was.
      refute File.exists?(Path.join([home, "review-updates", uuid(67) <> ".json"]))
      assert git(remote, ["rev-parse", ref]) == before
    end

    test "a location someone else moved is location_moved, never overwritten",
         %{port: port, home: home, remote: remote} = context do
      sealed(context, uuid(80), "github.com/test/plain", %{"README.md" => "m\n"})

      %Outcome.Review{revision: head} =
        Boundary.create_review(@client, review(uuid(81), uuid(80)))

      sealed(context, uuid(82), "github.com/test/plain", %{"README.md" => "n\n"})
      ref = "refs/heads/work/review-" <> uuid(81)

      # Someone else removes the location.
      git(remote, ["update-ref", "-d", ref])
      input = update(uuid(83), uuid(81), uuid(82), head, fingerprint_of(home, uuid(82)))

      assert %Outcome.LocationMoved{review_id: review_id, current: nil} =
               Boundary.update_review(@client, input)

      assert review_id == uuid(81)

      # The wire still names a gone location's current revision as null.
      assert {409, %{"error" => %{"code" => "location_moved", "details" => %{"current" => nil}}}} =
               orchestrate(port, "/v1/review-updates", input)

      assert {_, status} =
               System.cmd("git", ["rev-parse", "--verify", ref],
                 cd: remote,
                 stderr_to_stdout: true
               )

      assert status != 0
    end
  end

  # K3: Code's own integrate (AtlasCode.Effects, its journal in Code's home) updates a review's
  # pull from its base before it refuses; the next update moves the review on from that head.
  describe "update_review after Code's own integrate (K3)" do
    @describetag :k3

    test "moves the review on from a head a refused integrate of its pull produced",
         %{home: home, remote: remote} = context do
      {review_id, revision, head} = app_review(context, 300)
      ref = "refs/heads/work/review-" <> review_id
      {base2, merged} = behind(remote, head)
      git(remote, ["update-ref", ref, merged])

      # Integrated by its handle (B-1): updated from its base by "GitHub", then red CI.
      assert %{"status" => "refused", "reason" => "ci_failed", "details" => %{"head" => ^merged}} =
               integrate(context, 300, 7, revision, base2, merged, {:failure, ["unit"]})

      sealed(context, uuid(302), "github.com/test/app", %{"README.md" => "fix\n"})
      input = update(uuid(303), review_id, uuid(302), revision, fingerprint_of(home, uuid(302)))

      assert %Outcome.Updated{previous_revision: ^revision, revision: moved} =
               updated = Boundary.update_review(@client, input)

      # The location holds the update, built on the review's revision; the review follows it.
      child = commit_of(home, moved)
      assert git(remote, ["rev-parse", ref]) == child <> "\n"
      assert git(remote, ["rev-parse", child <> "^"]) == head <> "\n"
      assert record(home, review_id)["revision"] == moved
      assert Boundary.update_review(@client, input) == updated

      # That head was produced from the earlier revision: put back now, it is someone else's.
      git(remote, ["update-ref", ref, merged])
      sealed(context, uuid(304), "github.com/test/app", %{"README.md" => "fix 2\n"})
      again = update(uuid(305), review_id, uuid(304), moved, fingerprint_of(home, uuid(304)))
      assert %Outcome.LocationMoved{current: current} = Boundary.update_review(@client, again)
      assert current == AtlasCode.handle("github.com/test/app", merged)
      assert git(remote, ["rev-parse", ref]) == merged <> "\n"
    end

    test "any other move is location_moved, never overwritten",
         %{home: home, remote: remote} = context do
      {review_id, revision, head} = app_review(context, 310)
      ref = "refs/heads/work/review-" <> review_id
      base = remote |> git(["rev-parse", "develop"]) |> String.trim()
      {base2, merged} = behind(remote, head)
      sealed(context, uuid(312), "github.com/test/app", %{"README.md" => "fix\n"})
      fingerprint = fingerprint_of(home, uuid(312))

      refused_at = fn n, at ->
        input = update(uuid(n), review_id, uuid(312), revision, fingerprint)
        assert %Outcome.LocationMoved{current: current} = Boundary.update_review(@client, input)
        assert current == AtlasCode.handle("github.com/test/app", at)
        assert git(remote, ["rev-parse", ref]) == at <> "\n"
      end

      # Someone else pushed on top of the review's revision; no integrate of it at all.
      pushed = commit_tree(remote, head, [head], "someone else")
      git(remote, ["update-ref", ref, pushed])
      refused_at.(320, pushed)

      # Code's integrate updated it but is still waiting for CI: not refused (yet).
      git(remote, ["update-ref", ref, merged])

      assert %{"status" => "working", "phase" => "checking"} =
               integrate(context, 321, 7, revision, base2, merged, :pending)

      refused_at.(322, merged)

      # A refused integrate with that line, but of another pull.
      assert %{"status" => "refused"} =
               integrate(context, 323, 8, revision, base2, merged, {:failure, ["unit"]})

      refused_at.(324, merged)

      # Code's integrate of this pull with that very line, but done: GitHub merged that head.
      # Only a refused integrate's head is moved on from; a merged one is never overwritten.
      assert %{"status" => "done", "outputs" => %{"head" => ^merged}} =
               integrate(context, 327, 7, revision, base2, merged, :success)

      refused_at.(328, merged)

      # A refused integrate of this pull whose line only starts at the moved head (asked about
      # the pushed commit itself, by its commit): Code's integrate did not produce it.
      git(remote, ["update-ref", ref, pushed])

      assert %{"status" => "refused", "reason" => "ci_failed"} =
               integrate(context, 325, 7, pushed, base, nil, {:failure, ["unit"]})

      refused_at.(326, pushed)
    end

    test "a remote that refuses the leased push is update_refused, pushed once",
         %{dir: dir, home: home, remote: remote} = context do
      {review_id, revision, head} = app_review(context, 330)
      ref = "refs/heads/work/review-" <> review_id
      {base2, merged} = behind(remote, head)
      git(remote, ["update-ref", ref, merged])

      assert %{"status" => "refused", "reason" => "ci_failed"} =
               integrate(context, 330, 7, revision, base2, merged, {:failure, ["unit"]})

      # The remote refuses the first push it receives (as a rule against force pushes on work
      # branches would) and takes any later one: a retry of the refused push would land.
      pushes = Path.join(dir, "pushes")
      hook = Path.join([remote, "hooks", "pre-receive"])
      File.mkdir_p!(Path.dirname(hook))

      File.write!(hook, """
      #!/bin/sh
      echo push >> '#{pushes}'
      [ -e '#{pushes}.refused' ] && exit 0
      : > '#{pushes}.refused'
      exit 1
      """)

      File.chmod!(hook, 0o755)
      sealed(context, uuid(332), "github.com/test/app", %{"README.md" => "fix\n"})
      input = update(uuid(333), review_id, uuid(332), revision, fingerprint_of(home, uuid(332)))

      assert %Outcome.UpdateRefused{} = refused = Boundary.update_review(@client, input)
      assert File.read!(pushes) == "push\n"
      assert git(remote, ["rev-parse", ref]) == merged <> "\n"
      assert record(home, review_id)["revision"] == revision

      # Terminal: a repeat answers the same and pushes nothing.
      assert Boundary.update_review(@client, input) == refused
      assert File.read!(pushes) == "push\n"
      assert git(remote, ["rev-parse", ref]) == merged <> "\n"
    end
  end

  describe "draft, mark_ready and review_status (K2)" do
    @describetag :k2

    test "a draft opens once as a draft pull at Flow's location; a repeat is the same draft",
         %{dir: dir, port: port, remote: remote} = context do
      sealed(context, uuid(90), "github.com/test/app", %{"README.md" => "draft\n"})
      input = Map.put(review(uuid(91), uuid(90)), :draft, true)

      assert %Outcome.Review{state: :open, link: "https://github.com/test/app/pull/7"} =
               opened = Boundary.create_review(@client, input)

      assert Boundary.create_review(@client, input) == opened

      # The route takes the same body and answers the same review.
      assert {200, body} = orchestrate(port, "/v1/reviews", input)
      assert Map.delete(body, "review_url") == Map.delete(Outcome.Review.dump(opened), "link")

      # Flow's identifier: the draft's location has Flow's prefix, never the plain one.
      assert Service.flow_location() == "work/flow-review-"
      assert ref?(remote, "refs/heads/work/flow-review-" <> uuid(91))
      refute ref?(remote, "refs/heads/work/review-" <> uuid(91))

      assert [create] = calls(dir, "pr create")
      assert "--draft" in String.split(create)
      assert ("--head=work/flow-review-" <> uuid(91)) in String.split(create)

      # Still a draft after the repeats.
      green(context, uuid(91))

      assert %Outcome.Report{draft: true, state: :open} =
               Boundary.review_status(@client, %{review_id: uuid(91)})
    end

    test "draft false is the review without draft: same record, plain location, no --draft",
         %{dir: dir, remote: remote} = context do
      sealed(context, uuid(92), "github.com/test/app", %{"README.md" => "plain draft\n"})
      opened = Boundary.create_review(@client, review(uuid(93), uuid(92)))
      assert %Outcome.Review{} = opened

      # A review opened before K2 is repeated by Flow with draft false: no conflict.
      assert Boundary.create_review(@client, Map.put(review(uuid(93), uuid(92)), :draft, false)) ==
               opened

      assert ref?(remote, "refs/heads/work/review-" <> uuid(93))
      assert [create] = calls(dir, "pr create")
      refute "--draft" in String.split(create)

      green(context, uuid(93))

      assert %Outcome.Report{draft: false} =
               Boundary.review_status(@client, %{review_id: uuid(93)})
    end

    test "mark_ready marks the draft ready once; a repeat reads the pull and writes nothing",
         %{dir: dir, home: home} = context do
      draft(context, uuid(94), uuid(95))
      green(context, uuid(95))

      assert %Outcome.Ready{
               review_id: id,
               revision: "rev_" <> _,
               link: "https://github.com/test/app/pull/7"
             } =
               ready = Boundary.mark_ready(@client, %{review_id: uuid(95)})

      assert id == uuid(95)
      assert [ready_call] = calls(dir, "pr ready")
      assert String.split(ready_call) -- ["1"] == ["pr", "ready", "7", "--repo=test/app"]
      assert record(home, uuid(95))["ready"] == "marked"

      assert Boundary.mark_ready(@client, %{review_id: uuid(95)}) == ready
      assert length(calls(dir, "pr ready")) == 1

      assert %Outcome.Report{draft: false} =
               Boundary.review_status(@client, %{review_id: uuid(95)})
    end

    test "a failed gh pr ready leaves the journal at asked; a repeat completes it",
         %{dir: dir, home: home} = context do
      draft(context, uuid(96), uuid(97))
      green(context, uuid(97))
      File.write!(Path.join(dir, "fail-ready"), "")

      assert %Outcome.ProviderUnavailable{message: message} =
               Boundary.mark_ready(@client, %{review_id: uuid(97)})

      refute message =~ "ghp_secret"
      assert record(home, uuid(97))["ready"] == "asked"

      File.rm!(Path.join(dir, "fail-ready"))
      assert %Outcome.Ready{} = Boundary.mark_ready(@client, %{review_id: uuid(97)})
      assert record(home, uuid(97))["ready"] == "marked"
      assert length(calls(dir, "pr ready")) == 2
    end

    test "mark_ready of a closed or merged pull is review_not_open and writes nothing",
         %{dir: dir, home: home} = context do
      draft(context, uuid(98), uuid(99))
      green(context, uuid(99))

      for state <- ["closed", "merged"] do
        File.write!(Path.join(dir, "pr-state"), state)

        assert %Outcome.ReviewNotOpen{review_id: id} =
                 Boundary.mark_ready(@client, %{review_id: uuid(99)})

        assert id == uuid(99)

        assert %Outcome.Report{state: reported} =
                 Boundary.review_status(@client, %{review_id: uuid(99)})

        assert Atom.to_string(reported) == state
      end

      assert calls(dir, "pr ready") == []
      refute Map.has_key?(record(home, uuid(99)), "ready")
    end

    test "review_status maps CI exactly as integrate's conclusion does", %{dir: dir} = context do
      draft(context, uuid(100), uuid(101))
      green(context, uuid(101))

      run = fn name, status, conclusion ->
        %{"name" => name, "status" => status, "conclusion" => conclusion}
      end

      runs = fn list -> %{"total_count" => length(list), "check_runs" => list} end
      none = %{"state" => "pending", "total_count" => 0, "statuses" => []}

      cases = [
        # Nothing reported yet is not green.
        {runs.([]), none, :pending, nil},
        {runs.([run.("unit", "completed", "success")]), none, :success, nil},
        {runs.([run.("unit", "completed", "success"), run.("lint", "in_progress", nil)]), none,
         :pending, nil},
        {runs.([run.("unit", "completed", "failure"), run.("lint", "completed", "success")]),
         none, :failure, ["unit"]},
        {runs.([run.("unit", "completed", "success")]),
         %{
           "state" => "failure",
           "total_count" => 1,
           "statuses" => [%{"context" => "deploy", "state" => "failure"}]
         }, :failure, ["deploy"]},
        # A page that does not hold every run is not green evidence.
        {%{"total_count" => 2, "check_runs" => [run.("unit", "completed", "success")]}, none,
         :pending, nil}
      ]

      for {check_runs, status, ci, failing} <- cases do
        stand_in(dir, "check-runs.json", check_runs)
        stand_in(dir, "status.json", status)

        assert %Outcome.Report{ci: ^ci, failing: ^failing} =
                 Boundary.review_status(@client, %{review_id: uuid(101)})

        # The same reading as Code's integrate.
        expected =
          case AtlasCode.Effects.GitHub.conclusion(check_runs, status) do
            {:failure, _} -> :failure
            other -> other
          end

        assert ci == expected
      end
    end

    test "review_status reports approvals of the head, standing change requests and the base",
         %{dir: dir} = context do
      draft(context, uuid(102), uuid(103))
      head = green(context, uuid(103))
      old = String.duplicate("a", 40)

      review = fn id, login, state, commit ->
        %{"id" => id, "user" => %{"login" => login}, "state" => state, "commit_id" => commit}
      end

      stand_in(dir, "reviews.json", [
        review.(1, "alice", "APPROVED", head),
        # An approval of an earlier head does not approve this one.
        review.(2, "bob", "APPROVED", old),
        review.(3, "carol", "CHANGES_REQUESTED", old),
        # A comment decides nothing: carol's request stands.
        review.(4, "carol", "COMMENTED", head),
        review.(5, "dave", "CHANGES_REQUESTED", old),
        review.(6, "dave", "APPROVED", head),
        review.(7, "erin", "APPROVED", head),
        review.(8, "erin", "DISMISSED", head)
      ])

      File.write!(Path.join(dir, "pr-mergeable"), "true")

      assert %Outcome.Report{
               review_id: id,
               state: :open,
               draft: true,
               at_revision: true,
               ci: :success,
               approvals: ["alice", "dave"],
               changes_requested: ["carol"],
               mergeable: true,
               behind_base: false,
               link: "https://github.com/test/app/pull/7"
             } = Boundary.review_status(@client, %{review_id: uuid(103)})

      assert id == uuid(103)

      # The base moved on; someone else moved the head; GitHub is still working out mergeability.
      stand_in(dir, "compare.json", %{"ahead_by" => 1, "behind_by" => 2})
      File.write!(Path.join(dir, "pr-head"), old)
      File.rm!(Path.join(dir, "pr-mergeable"))

      assert %Outcome.Report{
               behind_base: true,
               at_revision: false,
               approvals: ["bob"],
               mergeable: nil
             } =
               Boundary.review_status(@client, %{review_id: uuid(103)})

      # More reviews than one page holds are not read rather than misread.
      stand_in(dir, "reviews.json", for(n <- 1..100, do: review.(n, "r#{n}", "APPROVED", old)))

      assert %Outcome.ProviderUnavailable{} =
               Boundary.review_status(@client, %{review_id: uuid(103)})

      # Reads only.
      assert calls(dir, "pr ready") == []
    end

    test "a review without a provider: ci none, a draft until mark_ready makes it ready",
         %{dir: dir, remote: remote} = context do
      sealed(context, uuid(104), "github.com/test/plain", %{"README.md" => "plain\n"})
      input = Map.put(review(uuid(105), uuid(104)), :draft, true)

      assert %Outcome.Review{link: nil} = Boundary.create_review(@client, input)
      assert ref?(remote, "refs/heads/work/flow-review-" <> uuid(105))

      assert %Outcome.Report{
               state: :open,
               draft: true,
               at_revision: true,
               ci: :none,
               approvals: [],
               changes_requested: [],
               mergeable: nil,
               behind_base: nil,
               link: nil
             } = Boundary.review_status(@client, %{review_id: uuid(105)})

      assert %Outcome.Ready{link: nil} =
               ready = Boundary.mark_ready(@client, %{review_id: uuid(105)})

      assert Boundary.mark_ready(@client, %{review_id: uuid(105)}) == ready

      assert %Outcome.Report{draft: false, ci: :none} =
               Boundary.review_status(@client, %{review_id: uuid(105)})

      refute File.exists?(Path.join(dir, "gh-calls"))
    end

    test "needs the review right; answers each refusal as its outcome",
         %{dir: dir, port: port} = context do
      worker = {"test:worker", [:snapshot, :change]}

      for capability <- [:mark_ready, :review_status] do
        assert %NotPermitted{capability: ^capability, right: :review} =
                 apply(Boundary, capability, [worker, %{review_id: uuid(106)}])

        assert %Outcome.NotFound{review_id: id} =
                 apply(Boundary, capability, [@client, %{review_id: uuid(106)}])

        assert id == uuid(106)

        assert %Outcome.InvalidRequest{} =
                 apply(Boundary, capability, [@client, %{review_id: "nope"}])

        assert %InvalidInput{capability: ^capability} =
                 apply(Boundary, capability, [@client, %{}])
      end

      # A draft that is not opened yet is not open.
      sealed(context, uuid(107), "github.com/test/app", %{"README.md" => "incomplete\n"})
      File.write!(Path.join(dir, "fail-before"), "")

      assert %Outcome.ReviewIncomplete{} =
               Boundary.create_review(
                 @client,
                 Map.put(review(uuid(108), uuid(107)), :draft, true)
               )

      for capability <- [:mark_ready, :review_status],
          do:
            assert(
              %Outcome.ReviewNotOpen{} =
                apply(Boundary, capability, [@client, %{review_id: uuid(108)}])
            )

      File.rm!(Path.join(dir, "fail-before"))

      assert %Outcome.Review{} =
               Boundary.create_review(
                 @client,
                 Map.put(review(uuid(108), uuid(107)), :draft, true)
               )

      green(context, uuid(108))

      # The provider unreachable.
      File.write!(Path.join(dir, "fail-api"), "")

      for capability <- [:mark_ready, :review_status] do
        assert %Outcome.ProviderUnavailable{message: message} =
                 apply(Boundary, capability, [@client, %{review_id: uuid(108)}])

        refute message =~ "ghp_secret"
      end

      File.rm!(Path.join(dir, "fail-api"))

      # The repository no longer allowed.
      settings = %{AtlasCode.settings() | repositories: %{}}

      for call <- [&Service.mark_ready/2, &Service.review_status/2],
          do: assert({403, %{"error" => %{"code" => "forbidden"}}} = call.(settings, uuid(108)))

      # draft must be a boolean, through the facade and over HTTP.
      bad = Map.put(review(uuid(109), uuid(107)), :draft, "yes")
      assert %InvalidInput{capability: :create_review} = Boundary.create_review(@client, bad)

      assert {400, %{"error" => %{"code" => "invalid_request"}}} =
               response = orchestrate(port, "/v1/reviews", bad)

      assert response == Service.create_review(AtlasCode.settings(), stringify(bad))
    end
  end

  # K3: a review `uuid(n + 1)` of a new sealed change `uuid(n)` on github.com/test/app (its pull is
  # the fixture's pull 7): its ID, revision and commit.
  defp app_review(context, n) do
    sealed(context, uuid(n), "github.com/test/app", %{"README.md" => "k3 #{n}\n"})

    %Outcome.Review{revision: revision} =
      Boundary.create_review(@client, review(uuid(n + 1), uuid(n)))

    {uuid(n + 1), revision, commit_of(context.home, revision)}
  end

  defp commit_of(home, handle),
    do: JSON.decode!(File.read!(Path.join([home, "revisions", handle <> ".json"])))["commit"]

  # The remote's develop moves on to `base2`, and `merged` is GitHub's update of `head` from it.
  defp behind(remote, head) do
    base = remote |> git(["rev-parse", "develop"]) |> String.trim()
    base2 = commit_tree(remote, base, [base], "base 2")
    git(remote, ["update-ref", "refs/heads/develop", base2])
    {base2, commit_tree(remote, head, [head, base2], "Merge develop")}
  end

  defp commit_tree(remote, tree, parents, message) do
    args = ["-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", tree <> "^{tree}"]
    remote |> git(args ++ Enum.flat_map(parents, &["-p", &1]) ++ ["-m", message]) |> String.trim()
  end

  # Code's integrate of pull `number` at `revision` (a handle or a commit), journaled in Code's
  # home, against a stand-in GitHub that mirrors the remote's commits, with `base` as the pull's
  # base. Behind it, an update is asked for, which "GitHub" makes as `update`; `ci` is CI on the
  # pull's last head. Its answer once the update (if any) is seen.
  defp integrate(context, n, number, revision, base, update, ci) do
    gh = start_supervised!(Supervisor.child_spec(AtlasCode.FakeGitHub, id: {:github, n}))

    for line <- context.remote |> git(["rev-list", "--parents", "--all"]) |> String.split("\n"),
        [commit | parents] <- [String.split(line)],
        do: AtlasCode.FakeGitHub.commit(gh, commit, parents)

    head = commit_or(context.home, revision)
    AtlasCode.FakeGitHub.branch(gh, "develop", base)
    AtlasCode.FakeGitHub.put_pull(gh, number, %{"head" => head, "base" => "develop"})
    AtlasCode.FakeGitHub.ci(gh, update || head, ci)

    receiver =
      AtlasCode.Effects.new(
        dir: context.home,
        github: {AtlasCode.FakeGitHub, AtlasCode.FakeGitHub.config(gh)},
        repositories: ["test/app"]
      )

    definition = %{"fields" => ["revision"], "relations" => []}
    payload = %{"revision" => revision}
    fingerprint = AtlasBus.SubjectFingerprint.of(%{"values" => payload}, definition)

    request = %{
      "version" => 1,
      "id" => sha256("k3 #{n}"),
      "run" => "run-#{n}",
      "entry" => 1,
      "name" => "integrate",
      "subject" => "S-#{n}",
      "service" => "code",
      "operation" => "integrate",
      "fingerprint_definition" => definition,
      "fingerprint" => fingerprint,
      "payload" => payload,
      "target" => "https://github.com/test/app/pull/#{number}",
      "approved" => fingerprint
    }

    call = fn operation ->
      AtlasCode.Effects.handle(receiver, %{
        "operation" => operation,
        "request" => request,
        "digest" => AtlasBus.Digest.of_term(request)
      })
    end

    if update do
      assert %{"status" => "working", "phase" => "updating"} = call.("submit")
      AtlasCode.FakeGitHub.set_pull(gh, number, %{"head" => update})
      call.("lookup")
    else
      call.("submit")
    end
  end

  defp commit_or(home, "rev_" <> _ = handle), do: commit_of(home, handle)
  defp commit_or(_home, commit), do: commit

  # A draft review `id` of a new sealed change `change` on github.com/test/app.
  defp draft(context, change, id) do
    sealed(context, change, "github.com/test/app", %{"README.md" => "draft #{id}\n"})

    %Outcome.Review{} =
      Boundary.create_review(@client, Map.put(review(id, change), :draft, true))
  end

  # The stand-in's pull is at the review's revision, green, current with its base; its commit.
  defp green(%{dir: dir, home: home}, id) do
    %{"revision" => revision} = record(home, id)

    %{"commit" => commit} =
      JSON.decode!(File.read!(Path.join([home, "revisions", revision <> ".json"])))

    File.write!(Path.join(dir, "pr-head"), commit)

    stand_in(dir, "check-runs.json", %{
      "total_count" => 1,
      "check_runs" => [%{"name" => "unit", "status" => "completed", "conclusion" => "success"}]
    })

    stand_in(dir, "status.json", %{"state" => "pending", "total_count" => 0, "statuses" => []})
    stand_in(dir, "compare.json", %{"ahead_by" => 1, "behind_by" => 0})
    commit
  end

  defp stand_in(dir, name, value), do: File.write!(Path.join(dir, name), JSON.encode!(value))

  defp record(home, id),
    do: JSON.decode!(File.read!(Path.join([home, "reviews", id <> ".json"])))

  # The stand-in's recorded calls that start with `prefix` (after GH_PROMPT_DISABLED).
  defp calls(dir, prefix) do
    case File.read(Path.join(dir, "gh-calls")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            String.starts_with?(line, "1 " <> prefix),
            do: line

      {:error, :enoent} ->
        []
    end
  end

  defp ref?(remote, ref) do
    {_, status} =
      System.cmd("git", ["rev-parse", "--verify", "--quiet", ref],
        cd: remote,
        stderr_to_stdout: true
      )

    status == 0
  end

  # A change of `entries` on `repository`'s revision in the setup's snapshot.
  defp change(context, id, repository, entries),
    do: %{
      change_id: id,
      snapshot_id: context.snapshot_id,
      repository: repository,
      base_revision: context.revisions[repository],
      entries: entries
    }

  # A change of `files` created, uploaded and sealed through the facade.
  defp sealed(context, id, repository, files) do
    entries = for {path, bytes} <- files, do: write(path, bytes)
    %Outcome.Change{} = Boundary.create_change(@client, change(context, id, repository, entries))

    for {_path, bytes} <- files,
        do:
          %Outcome.Change{} =
            Boundary.put_change_blob(@client, %{
              change_id: id,
              sha256: sha256(bytes),
              content: bytes
            })

    %Outcome.Change{state: :sealed, revision: revision} =
      Boundary.seal_change(@client, %{change_id: id})

    revision
  end

  defp write(path, bytes),
    do: %{
      path: path,
      op: "write",
      kind: "file",
      mode: "100644",
      size: byte_size(bytes),
      sha256: sha256(bytes)
    }

  defp symlink(path, target),
    do: %{
      path: path,
      op: "write",
      kind: "symlink",
      mode: "120000",
      target: target,
      size: byte_size(target),
      sha256: sha256(target)
    }

  defp delete(path), do: %{path: path, op: "delete"}

  defp review(id, change),
    do: %{
      review_id: id,
      change_id: change,
      target: "develop",
      title: "Fix",
      body: "Fixes it." <> @attribution
    }

  defp update(id, review, change, revision, fingerprint),
    do: %{
      update_id: id,
      review_id: review,
      change_id: change,
      revision: revision,
      fingerprint: fingerprint
    }

  # Recomputed from the stored request the way Runtime's submit computes it.
  defp fingerprint_of(home, change) do
    request = JSON.decode!(File.read!(Path.join([home, "changes", change, "request.json"])))
    "fpr_" <> sha256(JSON.encode!(Map.delete(request, "change_id")))
  end

  # As decoded JSON, the way the Service takes a request.
  defp stringify(input), do: input |> JSON.encode!() |> JSON.decode!()

  defp uuid(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp post(port, path, body), do: request(port, :post, path, JSON.encode!(body))

  defp orchestrate(port, path, body, token \\ @orchestrator),
    do: request(port, :post, path, JSON.encode!(body), token)

  defp request(port, method, path, body, token \\ @token) do
    request =
      {~c"http://127.0.0.1:#{port}#{path}",
       [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}], ~c"application/json",
       body}

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(method, request, [timeout: 30_000, ssl: []], body_format: :binary)

    {status, JSON.decode!(reply)}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
