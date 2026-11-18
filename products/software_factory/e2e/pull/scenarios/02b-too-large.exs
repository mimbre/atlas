# S2b A result Flow refuses for its room (plan rev 2 §9 S2b, with re-review C1). 15 000 000
# bytes: under the Runtime's cap, over Flow's test result_cap of 12 000 000 (D6). Needs D2
# (a chunked put_blob reaches Results.put, which answers too_large at begin). Only Flow's
# facts are asserted: the wire status (413 or a reset) depends on sockets and is kept in
# wire.jsonl only. C1: the manifest is written at `ended`, so the store is compared by its
# blobs only.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Facts, Hub, Stub}
alias AtlasE2E.Pull.Steps, as: S

scenario(
  "s2b",
  "Refused by Flow's room (too_large)",
  [subjects: ["s2b"], requires: [:d2]],
  fn ctx ->
    s = S.subject(ctx, "s2b")
    since = Hub.mark()
    step("pick up", 30, fn -> S.pick_up(ctx, s) end)
    lease = step("grant", 30, fn -> S.lease(s, since) end)

    started =
      step("import and started", 60, fn ->
        started = S.stub(s, "started", since)
        S.report(lease.id, "started", since, status: 200)
        started
      end)

    huge = S.xorshift_sha(15_000_000, 9)
    before = Facts.store(ctx.results)
    s0 = Facts.blob_bytes(before)

    step("complete: ended names the blob; its put_blob, whatever its answer", 60, fn ->
      mark = Hub.mark()

      :ok =
        Stub.gate(
          ctx.run,
          started.data,
          Stub.complete([Stub.blob("huge.bin", 15_000_000, 9)], "done #{s.token}")
        )

      ended = S.report(lease.id, "ended", mark, status: 200)

      check!(
        huge in (ended.data.resp["missing"] || []),
        "missing names huge.bin",
        ended.data.resp
      )

      AtlasE2E.Pull.Await.event(
        mark,
        &(S.wire?(&1, :put_blob) and &1.data.lease_id == lease.id and &1.data.sha256 == huge),
        label: "a put_blob of huge.bin (any status)"
      )
    end)

    step("Flow settles it too_large", 30, fn ->
      {task, _} =
        S.await_task(
          ctx,
          s,
          &(S.v(&1, "result_state") == "too_large" and S.v(&1, "lease_state") == "done"),
          "#{s.task} too_large and done"
        )

      check!(is_binary(S.v(task, "result_manifest")), "the manifest from ended is set", task)
      store = Facts.store(ctx.results)

      check!(
        not Map.has_key?(store.blobs, huge),
        "no blob huge.bin in the store",
        Map.keys(store.blobs)
      )

      check!(
        Facts.blob_bytes(store) == s0,
        "the store's blobs are as before (#{s0} bytes)",
        Facts.blob_bytes(store)
      )

      check!(store.tmp == [], "nothing left in the store's tmp/", store.tmp)
    end)
  end
)
