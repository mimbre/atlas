defmodule AtlasFlow.PublishTest do
  # F3-P: a task's frozen result → a Code draft review, or an update of the package's open
  # one. FakeCode keeps changes and reviews as Code does; the result store runs on a tmp
  # dir with a manual clock. Structural asserts only: call logs, ids, fields, revisions.
  use ExUnit.Case, async: true

  alias AtlasFlow.Code.Client
  alias AtlasFlow.{FakeCode, ManualClock, Publish, Results}
  alias AtlasFlow.Results.Store

  @repository "github.com/test/app"
  @snapshot "sha256:" <> String.duplicate("a", 64)
  @base_revision "rev_" <> String.duplicate("b", 64)
  @base_id "code-" <> String.duplicate("a", 64)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, clock} = ManualClock.start_link(~U[2026-11-17 12:00:00Z])
    store = Path.join(dir, "results")

    results =
      start_supervised!(
        {Results, name: nil, dir: store, clock: {ManualClock, clock}, pins: fn -> [] end}
      )

    {:ok, fake} = FakeCode.start_link()
    %{results: results, fake: fake, client: FakeCode.client(fake), store: store}
  end

  describe "a first publication" do
    test "create → only the missing blobs → seal → one draft review", c do
      shared = "shared bytes\n"

      entries = [
        write("README.md", "new readme\n"),
        write("a/one.txt", shared),
        write("a/two.txt", shared),
        symlink("link", "README.md"),
        %{"path" => "old.txt", "op" => "delete"}
      ]

      task = task(c, "TK-P-1", entries)
      assert {:ok, pub} = Publish.publish(request("TK-P-1", task), opts(c))

      assert names(c.fake) ==
               [:create_change, :put_change_blob, :put_change_blob, :seal_change, :create_review]

      # Only the written files' distinct blobs: none for the symlink or the delete.
      puts = for {:put_change_blob, input} <- FakeCode.requests(c.fake), do: input["sha256"]
      assert Enum.sort(puts) == Enum.sort([sha("new readme\n"), sha(shared)])

      [change] = requests(c.fake, :create_change)
      assert change["change_id"] == pub.change_id
      assert change["snapshot_id"] == @snapshot
      assert change["base_revision"] == @base_revision
      assert change["repository"] == @repository

      assert change["entries"] |> Enum.map(& &1["path"]) |> Enum.sort() ==
               ~w(README.md a/one.txt a/two.txt link old.txt)

      [review] = requests(c.fake, :create_review)
      assert review["draft"] == true
      assert review["change_id"] == pub.change_id
      assert review["target"] == "develop"

      assert FakeCode.locations(c.fake) == %{
               pub.review_id => "work/flow-review-" <> pub.review_id
             }

      assert %{kind: :created, update_id: nil} = pub
    end

    test "a repeat opens no second review: the ids come from the task key", c do
      task = task(c, "TK-P-2", [write("README.md", "two\n")])

      assert {:ok, first} = Publish.publish(request("TK-P-2", task), opts(c))
      assert {:ok, again} = Publish.publish(request("TK-P-2", task), opts(c))
      assert again == first

      assert first.change_id == Publish.id("change", "TK-P-2")
      assert first.review_id == Publish.id("review", "TK-P-2")
      assert map_size(FakeCode.locations(c.fake)) == 1

      ids = for r <- requests(c.fake, :create_review), uniq: true, do: r["review_id"]
      assert ids == [first.review_id]

      # Another task is another change and review; every id is a lowercase UUID.
      assert Publish.id("change", "TK-P-3") != first.change_id
      assert Publish.id("review", "TK-P-3") != first.review_id
      assert Publish.id("update", "TK-P-2") not in [first.change_id, first.review_id]
      assert first.change_id =~ @uuid and first.review_id =~ @uuid
    end

    test "the body carries the check, the provenance, why_now and the attribution as fields", c do
      task = task(c, "TK-P-4", [write("README.md", "four\n")])

      request =
        "TK-P-4"
        |> request(task)
        |> Map.merge(%{why_now: "the base moved on", provenance: %{turn_id: "turn-9"}})

      assert {:ok, _pub} = Publish.publish(request, opts(c))
      [review] = requests(c.fake, :create_review)
      fields = Publish.body_fields(review["body"])

      assert fields == Publish.fields(request)
      assert fields["task"] == "TK-P-4"
      assert fields["check"] == %{"exit_status" => 0, "ending" => nil}
      assert fields["why_now"] == request.why_now

      assert fields["provenance"] == %{
               "turn_id" => "turn-9",
               "attempt" => 1,
               "runtime" => "rt-1",
               "base" => @base_id
             }

      # Code's contract: the body carries the attribution.
      assert String.contains?(review["body"], fields["attribution"])
      assert String.contains?(fields["attribution"], "Written by an AI agent")
    end

    test "without base_revision on the task, the revision is Code's record of the snapshot", c do
      FakeCode.put(c.fake, @repository, "develop", @base_revision, %{"README.md" => "x"})

      {:ok, snapshot} =
        Client.create_snapshot(c.client, [
          %{repository: @repository, revision: @base_revision, path: "app"}
        ])

      task =
        c
        |> task("TK-P-5", [write("README.md", "five\n")])
        |> Map.delete("base_revision")
        |> Map.put("base_snapshot", snapshot)

      assert {:ok, _pub} = Publish.publish(request("TK-P-5", task), opts(c))
      [change] = requests(c.fake, :create_change)
      assert change["base_revision"] == @base_revision
      assert change["snapshot_id"] == snapshot
    end
  end

  describe "refused before anything reaches Code" do
    test "a recorded fingerprint that is not the change set's own", c do
      task = task(c, "TK-R-1", [write("README.md", "one\n")])
      other = AtlasChangeset.fingerprint(@base_id, "app", [write("README.md", "other\n")])
      task = Map.put(task, "result_fingerprints", fingerprints_json(other))

      assert Publish.publish(request("TK-R-1", task), opts(c)) == {:error, :fingerprint_mismatch}
      assert FakeCode.calls(c.fake) == []
    end

    test "a stored change set whose own fingerprint is not its content's (recomputed)", c do
      # The change set claims a fingerprint, and the task records the same one; neither is
      # the fingerprint of the entries.
      claimed = AtlasChangeset.fingerprint(@base_id, "app", [write("README.md", "claimed\n")])
      entries = [write("README.md", "actual\n")]
      put_blobs(c, entries)

      manifest = %{
        "base" => @base_id,
        "roots" => [%{"root" => "app", "entries" => entries, "fingerprint" => claimed}]
      }

      {:ok, msha} = Results.put_manifest(manifest, c.results)
      :ok = Results.pin("TK-R-2", msha, c.results)
      task = c |> base_task() |> Map.put("result_fingerprints", fingerprints_json(claimed))

      assert Publish.publish(request("TK-R-2", task), opts(c)) == {:error, :fingerprint_mismatch}
      assert FakeCode.calls(c.fake) == []
    end

    test "a blob whose size is not its entry's", c do
      bytes = "sized\n"
      entry = %{write("README.md", bytes) | "size" => byte_size(bytes) + 1}
      task = task(c, "TK-R-3", [entry], blobs: [{bytes, entry}])

      assert Publish.publish(request("TK-R-3", task), opts(c)) == {:error, :blob_mismatch}
      assert FakeCode.calls(c.fake) == []
    end

    test "a stored blob whose bytes are not its sha256", c do
      bytes = "digest\n"
      task = task(c, "TK-R-4", [write("README.md", bytes)])
      # The same size, other bytes: the store's file no longer holds the entry's blob.
      File.write!(Store.blob_path(c.store, sha(bytes)), "DIGEST\n")

      assert Publish.publish(request("TK-R-4", task), opts(c)) == {:error, :blob_mismatch}
      assert FakeCode.calls(c.fake) == []
    end

    test "a blob the store does not hold", c do
      entry = write("README.md", "absent\n")
      task = task(c, "TK-R-5", [entry], blobs: [])

      assert Publish.publish(request("TK-R-5", task), opts(c)) == {:error, :blob_missing}
      assert FakeCode.calls(c.fake) == []
    end

    test "no passed check, no complete result, not an author or fix, another root", c do
      task = task(c, "TK-R-6", [write("README.md", "six\n")])

      for {field, value} <- [
            {"check_exit_status", 1},
            {"check_exit_status", nil},
            {"result_state", "incomplete"},
            {"kind", "review"},
            {"base_snapshot", nil}
          ] do
        assert Publish.publish(request("TK-R-6", Map.put(task, field, value)), opts(c)) ==
                 {:error, :not_publishable}
      end

      assert Publish.publish(
               %{request("TK-R-6", task) | repository: "github.com/test/other"},
               opts(c)
             ) ==
               {:error, :unmapped_root}

      assert Publish.publish(request("TK-NONE", task), opts(c)) == {:error, :no_result}
      assert FakeCode.calls(c.fake) == []
    end
  end

  describe "a fix on the package's open review" do
    test "updates the same review from the last published revision; records Code's commit (N1)",
         c do
      author = task(c, "TK-F-1", [write("README.md", "first\n")])
      assert {:ok, first} = Publish.publish(request("TK-F-1", author), opts(c))

      # First review: the published revision is the review's, which is the seal's.
      [review] = requests(c.fake, :create_review)
      assert first.published_revision == first.sealed_revision
      assert review["fingerprint"] == first.fingerprint

      fix = task(c, "TK-F-2", [write("README.md", "fixed\n")], kind: "fix")
      open = %{review_id: first.review_id, revision: first.published_revision}
      assert {:ok, second} = Publish.publish(%{request("TK-F-2", fix) | review: open}, opts(c))

      # No second review: an update of the open one, from the last published revision.
      assert length(requests(c.fake, :create_review)) == 1
      [update] = requests(c.fake, :update_review)
      assert update["review_id"] == first.review_id
      assert update["revision"] == first.published_revision
      assert update["update_id"] == Publish.id("update", "TK-F-2")
      assert update["change_id"] == Publish.id("change", "TK-F-2")
      assert update["fingerprint"] == second.fingerprint

      # N1: a fix's published revision is the update's (Code's commit on the review's head),
      # not the seal's.
      assert %{kind: :updated, review_id: review_id} = second
      assert review_id == first.review_id
      assert second.published_revision != second.sealed_revision
      assert {:ok, %{revision: current}} = Client.review_status(c.client, first.review_id)
      assert second.published_revision == current

      # A repeat of the fix is the same update.
      assert Publish.publish(%{request("TK-F-2", fix) | review: open}, opts(c)) == {:ok, second}
    end

    test "the fingerprint sent is the one Flow decided on: its own change's fpr_", c do
      task = task(c, "TK-F-3", [write("README.md", "fpr\n"), symlink("l", "README.md")])
      assert {:ok, pub} = Publish.publish(request("TK-F-3", task), opts(c))
      [change] = requests(c.fake, :create_change)
      assert pub.fingerprint == Publish.fingerprint(change)
      assert pub.fingerprint =~ ~r/\Afpr_[0-9a-f]{64}\z/
      [review] = requests(c.fake, :create_review)
      assert review["fingerprint"] == pub.fingerprint
    end
  end

  describe "the publishing client" do
    test "Publish's client has change and review; Bases' default has snapshot only" do
      {module, {"flow", rights}} = Client.publishing()
      assert module == AtlasFlow.Code.Client.Boundary
      assert Enum.sort(rights) == [:change, :review]

      assert {AtlasFlow.Code.Client.Boundary, {"flow", [:snapshot]}} = Client.default()
      {_module, {_id, bases}} = Client.default()
      refute :review in bases or :change in bases
    end
  end

  # -- Helpers ---------------------------------------------------------------------------

  defp opts(c), do: [client: c.client, snapshot_client: c.client, results: c.results]

  defp request(key, task),
    do: %{
      task_key: key,
      task: task,
      repository: @repository,
      target: "develop",
      title: "Package P",
      why_now: nil,
      provenance: nil,
      review: nil
    }

  defp base_task(_c),
    do: %{
      "kind" => "author",
      "result_state" => "complete",
      "check_exit_status" => 0,
      "check_ending" => nil,
      "attempt" => 1,
      "runtime" => "rt-1",
      "base_id" => @base_id,
      "base_snapshot" => @snapshot,
      "base_revision" => @base_revision
    }

  # A task whose complete result is `entries` on root `app`: its blobs and change set in the
  # store, pinned for `key`, as Delivery stores an `ended` report.
  defp task(c, key, entries, opts \\ []) do
    blobs =
      Keyword.get_lazy(opts, :blobs, fn ->
        for e <- entries, e["op"] == "write", e["kind"] == "file", do: {bytes_of(e), e}
      end)

    for {bytes, _entry} <- blobs,
        do:
          :stored =
            Results.put(
              sha(bytes),
              byte_size(bytes),
              [bytes],
              Results.room(0, c.results),
              c.results
            )

    fingerprint = AtlasChangeset.fingerprint(@base_id, "app", entries)

    manifest = %{
      "base" => @base_id,
      "roots" => [%{"root" => "app", "entries" => entries, "fingerprint" => fingerprint}]
    }

    {:ok, msha} = Results.put_manifest(manifest, c.results)
    :ok = Results.pin(key, msha, c.results)

    c
    |> base_task()
    |> Map.merge(%{
      "kind" => Keyword.get(opts, :kind, "author"),
      "result_fingerprints" => fingerprints_json(fingerprint)
    })
  end

  defp put_blobs(c, entries) do
    for e <- entries, e["kind"] == "file" do
      bytes = bytes_of(e)

      :stored =
        Results.put(sha(bytes), byte_size(bytes), [bytes], Results.room(0, c.results), c.results)
    end
  end

  defp fingerprints_json(fingerprint),
    do: JSON.encode!([%{"root" => "app", "fingerprint" => fingerprint}])

  defp write(path, bytes) do
    Process.put({:bytes, sha(bytes)}, bytes)

    %{
      "path" => path,
      "op" => "write",
      "kind" => "file",
      "mode" => "100644",
      "size" => byte_size(bytes),
      "sha256" => sha(bytes)
    }
  end

  defp symlink(path, target),
    do: %{
      "path" => path,
      "op" => "write",
      "kind" => "symlink",
      "mode" => "120000",
      "target" => target,
      "size" => byte_size(target),
      "sha256" => sha(target)
    }

  defp bytes_of(entry), do: Process.get({:bytes, entry["sha256"]})

  defp names(fake), do: Enum.map(FakeCode.calls(fake), &elem(&1, 0))

  defp requests(fake, name), do: for({^name, input} <- FakeCode.requests(fake), do: input)

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
