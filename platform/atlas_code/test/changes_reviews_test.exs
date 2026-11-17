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
  # `pr create` fail before it creates the provider review.
  @gh """
  #!/bin/sh
  state=$(dirname "$0")
  echo "$GH_PROMPT_DISABLED $*" >> "$state/gh-calls"
  case "$1 $2" in
    "pr list")
      if [ -e "$state/pr-url" ]; then printf '[{"url":"%s"}]\\n' "$(cat "$state/pr-url")"; else echo '[]'; fi ;;
    "pr create")
      if [ -e "$state/fail-before" ]; then echo "ghp_secret failed" >&2; exit 1; fi
      for arg; do case "$arg" in --body-file=*) cp "${arg#--body-file=}" "$state/pr-body" ;; esac; done
      echo https://github.com/test/app/pull/7 > "$state/pr-url"
      cat "$state/pr-url" ;;
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
