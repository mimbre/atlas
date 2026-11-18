# S2 Happy path with a 9 MiB chunked blob (plan rev 2 §9 S2). Needs D2: before it the
# Runtime keeps every blob local (HttpTarget.put_blob/2 answers too_large), so the result
# never reaches Flow.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Facts, Hub, Stub}
alias AtlasE2E.Pull.Steps, as: S

scenario("s2", "Happy path, chunked blob", [subjects: ["s2"], requires: [:d2]], fn ctx ->
  s = S.subject(ctx, "s2")
  since = Hub.mark()
  step("pick up", 30, fn -> S.pick_up(ctx, s) end)
  lease = step("grant", 30, fn -> S.lease(s, since) end)

  started =
    step("accepted before the base's blobs; import", 60, fn ->
      accepted = S.report(lease.id, "accepted", since, status: 200)
      started = S.stub(s, "started", since)

      gets = Hub.select(since, &(S.wire?(&1, :get_blob) and &1.data.lease_id == lease.id))
      check!(gets != [], "the base was read with get_blob")

      check!(
        # When each exchange began, against when accepted was answered (F7).
        Enum.all?(gets, &(&1.data.began >= accepted.data.ended)),
        "every get_blob of #{lease.id} began after its accepted report was answered"
      )

      check!(
        Enum.all?(gets, &(&1.data.status == 200)),
        "every get_blob answered 200",
        Enum.map(gets, & &1.data.status)
      )

      base = Enum.find(gets, &(&1.data.sha256 == S.base_sha(ctx)))

      check!(
        base != nil and base.data.bytes_out == AtlasE2E.Pull.Fixture.base_size(),
        "the fixture blob streamed whole",
        base && base.data
      )

      check!(
        started.data["base_sha256"] == S.base_sha(ctx),
        "the agent read the base's bytes",
        started.data
      )

      started
    end)

  step("started", 30, fn ->
    S.report(lease.id, "started", since, status: 200)
    S.await_task(ctx, s, &(S.v(&1, "lease_state") == "started"), "#{s.task} started")
  end)

  readme = "pull-e2e s2\n"
  big = S.xorshift_sha(9_437_184, 7)

  result =
    step("complete: ended, missing, two chunked put_blobs", 60, fn ->
      edits = [
        Stub.write("README.pull", readme),
        Stub.blob("big.bin", 9_437_184, 7),
        Stub.delete("README.md")
      ]

      result = S.complete_and_store(ctx, s, started, lease.id, edits)
      wanted = [big, AtlasE2E.Pull.Fixture.sha_of(readme)]

      check!(
        Enum.all?(wanted, &(&1 in result.missing)),
        "missing names both new blobs",
        result.missing
      )

      puts =
        Hub.select(
          since,
          &(S.wire?(&1, :put_blob) and &1.data.lease_id == lease.id and &1.data.status == 200)
        )

      for {sha, size} <- [
            {big, 9_437_184},
            {AtlasE2E.Pull.Fixture.sha_of(readme), byte_size(readme)}
          ] do
        put = Enum.find(puts, &(&1.data.sha256 == sha))

        check!(
          put != nil and put.data.chunked? == true and put.data.bytes_in == size,
          "put_blob #{sha} chunked, #{size} bytes",
          put && put.data
        )
      end

      result
    end)

  step("completion facts and the store", 30, fn ->
    task = result.task
    manifest = S.v(task, "result_manifest")
    check!(is_binary(manifest), "a result manifest", task)
    store = Facts.store(ctx.results)

    check!(
      Map.has_key?(store.manifests, manifest),
      "the manifest is in the store",
      Map.keys(store.manifests)
    )

    check!(Map.get(store.blobs, big) == 9_437_184, "big.bin is in the store whole", store.blobs)

    check!(
      Map.has_key?(store.blobs, AtlasE2E.Pull.Fixture.sha_of(readme)),
      "README.pull is in the store"
    )

    attempts = Facts.attempts(ctx.rela, s.task)

    check!(
      Enum.map(attempts, &S.v(&1, "result_kind")) == ["completed"],
      "one completed attempt",
      attempts
    )

    Await.facts(
      fn -> Facts.run(ctx.rela, "package", s.package) end,
      &(S.v(&1, "state") == "authored"),
      label: "#{s.package}'s run authored (a complete author result)"
    )
  end)
end)
