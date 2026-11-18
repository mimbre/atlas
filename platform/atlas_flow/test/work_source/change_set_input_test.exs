defmodule AtlasFlow.WorkSource.ChangeSetInputTest do
  # F2-S (F2/F3 plan rev 3 §5; Main's base ruling, option A): the work source serves a
  # change-set input. A review's lease reads the author's frozen change set (its manifest
  # and every blob it names) from the result store, and nothing else; the reported
  # `change_set.base` (the Runtime's imported baseline id, not the lease's `base_id`) is
  # stored as reported and re-offered byte-equal; review and diagnose read only; no
  # offered lease has a slot, folder, resume_from, repository or absolute path (lesson 8).
  # Real Dispatch, Delivery, Results and Bases (on FakeCode), FakeFacts, a manual clock.
  # Asserted on outcome tags, fact values, keys and bytes, never on wording.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Dispatch, FakeCode, FakeFacts, Results, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @laptop {"laptop", "ada"}
  @readme "# hello\n"
  @offer %{"deep_coding" => 2, "independent_review" => 2}
  @contract_fields [:work_key, :title, :instructions, :profile, :cost_class, :input, :after_check]
  @forbidden ~w(slot folder resume_from repository workspace branch url path)

  setup do
    dir = Path.join(System.tmp_dir!(), "change-set-input-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    FakeFacts.put("clerk", %{"key" => "ada"})

    fake = start_supervised!({FakeCode, %{}}, id: :fake)
    FakeCode.put(fake, "example.org/acme/repo", "develop", "rev_1", %{"README.md" => @readme})
    start_supervised!({Bases, client: FakeCode.client(fake), clock: ctx.clock})
    :ok = Bases.request("example.org/acme/repo", "develop", {self(), :base})
    assert_receive :base
    {:ok, base} = Bases.cached("example.org/acme/repo", "develop")

    # The base the Runtime reports: the sha256 of its own canonical import of the served
    # base. Content-derived, and never the lease's `base_id` (base-meaning report).
    imported = "sha256:" <> L.sha256("imported " <> base.manifest)
    Map.merge(ctx, %{base: base, imported: imported})
  end

  ## Helpers

  defp spec(kind, opts \\ []) do
    %{
      "kind" => kind,
      "profile" =>
        Keyword.get(
          opts,
          :profile,
          if(kind == "review", do: "independent_review", else: "deep_coding")
        ),
      "cost_class" => "standard",
      "instructions" => "Look at the bin.",
      "fields" => [],
      "check" => Keyword.get(opts, :check)
    }
  end

  defp intent(kind, key, base, change_set, opts \\ []) do
    subject = %{"key" => key, "values" => %{}}
    Translate.intent(spec(kind, opts), subject, key, base, change_set, "robot-1", L.epoch())
  end

  # A bin `bin`, supervised by ada, whose run holds `intent`; its task fact.
  defp hold!(bin, intent) do
    FakeFacts.put("bin", %{"key" => bin, "values" => %{"phase" => "first"}})
    L.run("bin", bin, intent: intent, supervisor: "ada")
    L.task(intent["key"], bin)
    intent["key"]
  end

  defp poll(client, holdings) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings, @offer))
  end

  # The single lease the mini is granted now, as offered.
  defp grant!(holdings \\ []) do
    Dispatch.resync()
    assert {:polled, %{leases: [lease]}} = poll(@mini, holdings)
    lease
  end

  defp report(client, lease, revision, report),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: report})

  defp entries(files) do
    for {path, bytes} <- files,
        do: %{
          path: path,
          op: :write,
          kind: :file,
          mode: :"100644",
          size: byte_size(bytes),
          sha256: L.sha256(bytes)
        }
  end

  # A change set as the Runtime reports it (work_source 0.2.0): its `base` and each root's
  # csf_ fingerprint computed on that base.
  defp change_set(files, base) do
    entries = entries(files)
    fingerprint = AtlasChangeset.fingerprint(base, "repo", Translate.normal(entries))
    %{base: base, roots: [%{root: "repo", fingerprint: fingerprint, entries: entries}]}
  end

  defp put(client, lease, bytes) do
    WorkSource.put_blob(client, %{
      lease_id: lease,
      sha256: L.sha256(bytes),
      size: byte_size(bytes),
      content: [bytes]
    })
  end

  defp fetch(client, lease, sha) do
    case WorkSource.get_blob(client, %{lease_id: lease, sha256: sha}) do
      {:blob, %{content: content, sha256: ^sha, size: size}} ->
        bytes = IO.iodata_to_binary(Enum.to_list(content))
        assert byte_size(bytes) == size
        {:ok, bytes}

      :not_found ->
        :not_found
    end
  end

  # An author task on `bin` leased, ended with `files` on the reported `base`, and every
  # blob uploaded: its lease, task key and the change set it reported.
  defp authored!(ctx, bin, files, holdings \\ []) do
    task = hold!(bin, intent("author", "TK-#{bin}-1", ctx.base, nil))
    %{lease_id: lease} = grant!(holdings)
    reported = change_set(files, ctx.imported)

    assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})
    assert {:recorded, _} = report(@mini, lease, 2, %{state: :started})
    assert {:recorded, %{missing: missing}} = report(@mini, lease, 3, L.ended(reported))

    for {_path, bytes} <- files,
        L.sha256(bytes) in missing,
        do: assert(:stored = put(@mini, lease, bytes))

    %{lease: lease, task: task, reported: reported}
  end

  # The change set as Flow stores and serves it: as reported, each root without its
  # fingerprint (the plain change set the Runtime validates as an input manifest).
  defp plain(reported) do
    reported = Translate.normal(reported)
    %{reported | "roots" => Enum.map(reported["roots"], &Map.delete(&1, "fingerprint"))}
  end

  defp review_input(task) do
    v = L.values(task)
    %{manifest: v["result_manifest"], fingerprints: v["result_fingerprints"]}
  end

  defp walk(term, fun) when is_map(term),
    do: Enum.each(term, fn {k, v} -> fun.(k) && walk(v, fun) end)

  defp walk(term, fun) when is_list(term), do: Enum.each(term, &walk(&1, fun))
  defp walk(term, fun), do: fun.(term)

  # Lesson 8: the offered work's fields are the contract's, and no key names a place on a
  # machine and no value is an absolute path.
  defp placeless!(%{} = work) do
    work = Translate.normal(work)
    assert Map.keys(work) -- Enum.map(@contract_fields, &Atom.to_string/1) == []
    assert Map.keys(work["input"]) -- ~w(base change_set permissions) == []
    assert Map.keys(work["input"]["change_set"] || %{}) -- ~w(manifest fingerprints) == []

    walk(work, fn
      key when is_binary(key) -> refute key in @forbidden
      _ -> true
    end)

    walk(Map.values(work), fn
      value when is_binary(value) -> refute String.starts_with?(value, "/")
      _ -> true
    end)
  end

  ## Acceptance 3: the reported base is stored as reported, and re-offered byte-equal

  describe "the reported change_set.base (acceptance 3; option A)" do
    test "is stored as reported, its csf_ recompute on it, and the review is offered the same bytes",
         ctx do
      author = authored!(ctx, "B-1", [{"a.txt", "a\n"}, {"b.txt", "b\n"}])
      refute ctx.imported == ctx.base.base_id

      v = L.values(author.task)
      assert %{"result_state" => "complete", "lease_state" => "done"} = v
      assert {:ok, stored} = Results.manifest(author.task)
      assert stored["base"] == ctx.imported
      assert stored == plain(author.reported)

      review = hold!("B-2", intent("review", "TK-B-2-1", ctx.base, review_input(author.task)))
      %{lease_id: lease, work: work} = grant!([author.lease])
      assert work.input.change_set.manifest == v["result_manifest"]

      assert {:ok, bytes} = fetch(@mini, lease, v["result_manifest"])
      assert bytes == Results.canonical(plain(author.reported))
      assert L.sha256(bytes) == v["result_manifest"]
      assert JSON.decode!(bytes)["base"] == ctx.imported
      assert L.values(review)["lease_state"] == "offered"
    end

    test "a change set without a base is invalid, and nothing is stored", ctx do
      task = hold!("B-1", intent("author", "TK-B-1-1", ctx.base, nil))
      %{lease_id: lease} = grant!()
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})

      for base <- [nil, "", 7] do
        baseless = %{change_set([{"a.txt", "a\n"}], ctx.imported) | base: base}
        assert {:rejected, :invalid} = report(@mini, lease, 2, L.ended(baseless))
      end

      v = L.values(task)
      assert v["lease_revision"] == 1
      assert v["result_manifest"] == nil
      assert v["result_state"] == nil
      assert Results.manifest(task) == :not_found

      assert {:recorded, _} =
               report(@mini, lease, 2, L.ended(change_set([{"a.txt", "a\n"}], ctx.imported)))
    end
  end

  ## Acceptance 1 and 2: get_blob serves exactly the lease's change set

  describe "a review lease's get_blob (acceptances 1, 2)" do
    test "serves the change-set manifest and each blob it names, to its own Runtime only", ctx do
      files = [{"a.txt", "a\n"}, {"lib/b.ex", "b\n"}]
      author = authored!(ctx, "B-1", files)
      input = review_input(author.task)
      hold!("B-2", intent("review", "TK-B-2-1", ctx.base, input))
      %{lease_id: lease} = grant!([author.lease])

      assert {:ok, _} = fetch(@mini, lease, input.manifest)

      for {_path, bytes} <- files,
          do: assert({:ok, ^bytes} = fetch(@mini, lease, L.sha256(bytes)))

      # The base is still the lease's own.
      assert {:ok, base_bytes} = fetch(@mini, lease, ctx.base.manifest)
      assert L.sha256(base_bytes) == ctx.base.manifest
      assert {:ok, @readme} = fetch(@mini, lease, L.sha256(@readme))

      assert :not_found = fetch(@mini, lease, L.sha256("never named"))
      assert :not_found = fetch(@laptop, lease, input.manifest)
      assert :not_found = fetch(@laptop, lease, L.sha256("a\n"))
      assert :not_found = fetch(@mini, "TK-B-2-1~1~AAAAAAAAAAAAAAAAAAAAAA", input.manifest)
    end

    test "a fix's input manifest is a valid change set that hashes to its name (fix path b)",
         ctx do
      author = authored!(ctx, "B-1", [{"a.txt", "a\n"}, {"lib/b.ex", "b\n"}])
      input = review_input(author.task)
      hold!("B-2", intent("fix", "TK-B-2-1", ctx.base, input, check: ["bin/check"]))
      %{lease_id: lease, work: work} = grant!([author.lease])
      assert work.input.change_set.manifest == input.manifest

      assert {:ok, bytes} = fetch(@mini, lease, input.manifest)
      assert L.sha256(bytes) == input.manifest
      manifest = JSON.decode!(bytes)

      # What the Runtime's import checks (sources/import.ex decode_change_set): the plain
      # change set, and each offered fingerprint recomputes on it.
      assert AtlasChangeset.validate(manifest) == :ok

      offered = for f <- work.input.change_set.fingerprints, do: {f.root, f.fingerprint}

      assert Enum.sort(offered) ==
               Enum.sort(
                 for f <- AtlasChangeset.fingerprints(manifest), do: {f.root, f.fingerprint}
               )
    end

    test "a blob or manifest of another task's result is not served", ctx do
      author = authored!(ctx, "B-1", [{"a.txt", "a\n"}])
      other = authored!(ctx, "B-3", [{"z.txt", "z\n"}], [author.lease])
      other_manifest = L.values(other.task)["result_manifest"]
      assert {:ok, _, _} = Results.blob(L.sha256("z\n"))

      hold!("B-2", intent("review", "TK-B-2-1", ctx.base, review_input(author.task)))
      %{lease_id: lease} = grant!([author.lease, other.lease])

      assert {:ok, "a\n"} = fetch(@mini, lease, L.sha256("a\n"))
      assert :not_found = fetch(@mini, lease, L.sha256("z\n"))
      assert :not_found = fetch(@mini, lease, other_manifest)
    end

    test "an author lease (no change-set input) is served no result blob", ctx do
      author = authored!(ctx, "B-1", [{"a.txt", "a\n"}])
      hold!("B-2", intent("author", "TK-B-2-1", ctx.base, nil))
      %{lease_id: lease} = grant!([author.lease])
      assert :not_found = fetch(@mini, lease, L.sha256("a\n"))
      assert :not_found = fetch(@mini, lease, L.values(author.task)["result_manifest"])
    end
  end

  ## Acceptance 4: permissions

  describe "permissions (acceptance 4)" do
    test "review and diagnose read only; fix, author and plan may write", ctx do
      input = %{manifest: L.sha256("m"), fingerprints: [%{root: "repo", fingerprint: "csf_x"}]}

      for {kind, permissions} <- [
            {"review", "read-only"},
            {"diagnose", "read-only"},
            {"fix", "workspace-write"},
            {"author", "workspace-write"},
            {"plan", "workspace-write"}
          ] do
        change_set = if kind in ~w(review diagnose fix), do: input
        intent = intent(kind, "TK-B-1-1", ctx.base, change_set)
        assert Translate.intent?(intent)
        assert Translate.permissions(kind) == permissions
        assert Translate.offered_work(intent).input.permissions == permissions
      end
    end

    test "the change-set input carries the reviewed manifest and fingerprints as offered", ctx do
      fingerprints = JSON.encode!([%{"root" => "repo", "fingerprint" => "csf_" <> L.sha256("f")}])
      input = %{manifest: L.sha256("m"), fingerprints: fingerprints}
      intent = intent("fix", "TK-B-1-1", ctx.base, input)

      assert %{
               base: %{base_id: base_id, manifest: base_manifest},
               change_set: %{
                 manifest: manifest,
                 fingerprints: [%{root: "repo", fingerprint: "csf_" <> _}]
               },
               permissions: "workspace-write"
             } = Translate.offered_work(intent).input

      assert {base_id, base_manifest, manifest} ==
               {ctx.base.base_id, ctx.base.manifest, input.manifest}

      assert JSON.decode!(Translate.lease_input(intent))["change_set"]["manifest"] == manifest

      # An intent's change set must name a manifest and at least one fingerprint.
      refute Translate.intent?(intent("fix", "TK-B-1-1", ctx.base, %{input | manifest: ""}))
      refute Translate.intent?(intent("fix", "TK-B-1-1", ctx.base, %{input | fingerprints: []}))

      assert Translate.intent(
               spec("author"),
               %{"key" => "TK-B-1-1", "values" => %{}},
               "TK-B-1-1",
               ctx.base,
               "robot-1",
               L.epoch()
             ) ==
               intent("author", "TK-B-1-1", ctx.base, nil)
    end
  end

  ## Acceptance 5: the lesson-8 guard

  describe "no offered lease names a place (acceptance 5, lesson 8)" do
    test "over random intents with and without a change set" do
      for seed <- 1..200 do
        :rand.seed(:exsss, {seed, seed * 7, seed * 13})
        kind = Enum.random(~w(plan author review fix diagnose))

        spec =
          spec(kind, check: Enum.random([nil, ["bin/check"]]))
          |> Map.merge(%{
            "input" => %{
              "repository" => "/home/someone/repo-#{seed}",
              "resume_from" => "c-#{seed}"
            },
            "slot" => "slot-#{seed}",
            "folder" => "/Users/someone/work"
          })

        change_set =
          Enum.random([
            nil,
            %{
              manifest: L.sha256("m#{seed}"),
              fingerprints: [%{root: "repo", fingerprint: "csf_#{seed}"}]
            }
          ])

        subject = %{"key" => "B-#{seed}", "values" => %{"step" => "/var/tmp/somewhere"}}

        intent =
          Translate.intent(
            spec,
            subject,
            "TK-B-#{seed}-1",
            L.base(),
            change_set,
            "robot-1",
            L.epoch()
          )

        assert Translate.intent?(intent)
        placeless!(Translate.offered_work(intent))
      end
    end

    test "the leases Dispatch grants for a review and a fix", ctx do
      author = authored!(ctx, "B-1", [{"a.txt", "a\n"}])
      input = review_input(author.task)
      hold!("B-2", intent("review", "TK-B-2-1", ctx.base, input))
      hold!("B-3", intent("fix", "TK-B-3-1", ctx.base, input, check: ["bin/check"]))
      Dispatch.resync()

      assert {:polled, %{leases: [_, _] = leases}} = poll(@mini, [author.lease])

      for %{work: work} <- leases do
        assert work.input.change_set.manifest == input.manifest
        placeless!(work)
      end
    end
  end
end
