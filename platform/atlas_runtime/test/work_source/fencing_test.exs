defmodule AtlasRuntime.WorkSource.FencingTest do
  # Decision 2026-11-17-work-acquisition §6.6 M1: the fencing and blob tests of the work
  # source contract, through its in-BEAM Elixir target (the facade) against an in-test
  # source (AtlasRuntime.Test.FakeWorkSource). The HTTP client target has its own test.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: F

  @mini {"mini", [:lease]}
  @laptop {"laptop", [:lease]}

  @base_manifest ~s({"entries":[{"path":"README.md","op":"write","sha256":"…"}]})
  @readme "# hello\n"

  setup do
    source = Source.start(name: "flow-test")
    Source.use(source)
    %{source: source}
  end

  defp work(key, base_manifest_sha) do
    %{
      work_key: key,
      title: "Author package #{key}",
      instructions: "Write it.",
      profile: "deep_coding",
      cost_class: :standard,
      input: %{
        base: %{base_id: "base-#{key}", manifest: base_manifest_sha},
        permissions: :"workspace-write"
      }
    }
  end

  # Queues one work whose input names the base manifest and README.md's blob.
  defp add(source, key \\ "task-1") do
    blobs = %{Source.sha256(@base_manifest) => @base_manifest, Source.sha256(@readme) => @readme}
    Source.add_work(source, work(key, Source.sha256(@base_manifest)), blobs)
  end

  defp poll(client, holdings \\ [], offer \\ %{"deep_coding" => 1}) do
    {id, _} = client

    F.poll(client, %{
      runtime_id: id,
      incarnation: "inc-1",
      build: "test",
      policy_version: 1,
      offer: offer,
      holdings: for(h <- holdings, do: %{lease_id: h, state: :running})
    })
  end

  defp lease!(client) do
    %F.Outcome.Polled{leases: [%F.Lease{lease_id: id}]} = poll(client)
    id
  end

  defp report(client, lease, revision, report),
    do: F.report(client, %{lease_id: lease, revision: revision, report: report})

  defp accepted, do: %F.Accepted{}
  defp started, do: %F.Started{}

  defp ended(blobs) do
    %F.Ended{
      result: %F.Result{kind: :completed, retryable: false, never_started: false},
      provenance: [],
      change_set: %F.ChangeSet{
        # The work's base (add/2's default key), as the Runtime freezes it.
        base: "base-task-1",
        roots: [
          %F.ChangeRoot{
            root: "repo",
            fingerprint: "csf_test",
            entries:
              for {path, bytes} <- blobs do
                %F.ChangeEntry{
                  path: path,
                  op: :write,
                  kind: :file,
                  mode: :"100644",
                  size: byte_size(bytes),
                  sha256: Source.sha256(bytes)
                }
              end
          }
        ]
      }
    }
  end

  # A lease that is accepted, started and ended with these blobs in its manifest.
  defp ended_lease!(client, blobs) do
    lease = lease!(client)
    assert %F.Outcome.Recorded{missing: []} = report(client, lease, 1, accepted())
    assert %F.Outcome.Recorded{missing: []} = report(client, lease, 2, started())
    assert %F.Outcome.Recorded{missing: missing} = report(client, lease, 3, ended(blobs))
    {lease, missing}
  end

  describe "accept (§5.3 item 1)" do
    test "an accepted within the accept deadline is recorded; the lease's work is the offer",
         %{source: source} do
      add(source)

      assert %F.Outcome.Polled{
               leases: [%F.Lease{lease_id: lease, work: %F.OfferedWork{work_key: "task-1"}}],
               timing: %F.Timing{lease_ttl: 900, poll_max: 25}
             } = poll(@mini)

      Source.advance(source, 30)
      assert %F.Outcome.Recorded{missing: []} = report(@mini, lease, 1, accepted())
    end

    test "a late accept gets lease_lost, and the work is offered again as a fresh lease",
         %{source: source} do
      add(source)
      lease = lease!(@mini)

      Source.advance(source, 31)
      assert %F.Outcome.LeaseLost{} = report(@mini, lease, 1, accepted())
      # A replay of the same late accept is lost too: nothing of it was recorded.
      assert %F.Outcome.LeaseLost{} = report(@mini, lease, 1, accepted())

      assert %F.Outcome.Polled{leases: [%F.Lease{lease_id: fresh}], lease_lost: [^lease]} =
               poll(@mini, [lease])

      assert fresh != lease
      assert Source.current(source, "task-1") == fresh
    end
  end

  describe "fencing (§5.3 items 2-4)" do
    test "poll renews only current, unexpired holdings; any other is lease_lost",
         %{source: source} do
      add(source)
      lease = lease!(@mini)
      assert %F.Outcome.Recorded{} = report(@mini, lease, 1, accepted())

      # Renewed before it expires: still current after a further lease_ttl - 1.
      Source.advance(source, 899)
      assert %F.Outcome.Polled{lease_lost: []} = poll(@mini, [lease], %{})
      Source.advance(source, 899)
      assert %F.Outcome.Recorded{} = report(@mini, lease, 2, started())

      # Unknown and another Runtime's leases are lost to this one.
      assert %F.Outcome.Polled{lease_lost: ["lease-unknown"]} =
               poll(@mini, [lease, "lease-unknown"], %{})

      assert %F.Outcome.Polled{lease_lost: [^lease]} = poll(@laptop, [lease], %{})
    end

    test "a stale report gets lease_lost: expired, and after the work was leased again",
         %{source: source} do
      add(source)
      lease = lease!(@mini)
      assert %F.Outcome.Recorded{} = report(@mini, lease, 1, accepted())

      # Not renewed for lease_ttl: expired, so no report of it lands.
      Source.advance(source, 900)
      assert %F.Outcome.LeaseLost{} = report(@mini, lease, 2, started())

      # After lease_ttl + grace the work goes to another Runtime under a new lease; the
      # old one's reports, results and renewals stay lost.
      Source.advance(source, 120)
      fresh = lease!(@laptop)
      assert %F.Outcome.Recorded{} = report(@laptop, fresh, 1, accepted())

      assert %F.Outcome.LeaseLost{} = report(@mini, lease, 2, ended([{"a.txt", "a"}]))
      assert %F.Outcome.Polled{lease_lost: [^lease]} = poll(@mini, [lease], %{})
      assert %F.Outcome.Recorded{} = report(@laptop, fresh, 2, started())
    end

    test "another Runtime's report on a lease gets lease_lost; the leaseholder's still lands",
         %{source: source} do
      add(source)
      lease = lease!(@mini)

      assert %F.Outcome.LeaseLost{} = report(@laptop, lease, 1, accepted())
      assert %F.Outcome.Recorded{missing: []} = report(@mini, lease, 1, accepted())
      assert %F.Outcome.LeaseLost{} = report(@laptop, lease, 2, started())
      assert Source.current(source, "task-1") == lease
    end

    test "a cancel comes through poll; the lease stays current until its work ends",
         %{source: source} do
      add(source)
      lease = lease!(@mini)
      assert %F.Outcome.Recorded{} = report(@mini, lease, 1, accepted())

      Source.cancel(source, "task-1")
      assert %F.Outcome.Polled{cancel: [^lease], lease_lost: []} = poll(@mini, [lease], %{})
      assert %F.Outcome.Recorded{} = report(@mini, lease, 2, ended([]))
    end

    test "reports are idempotent by (lease, revision); any other revision is a conflict",
         %{source: source} do
      add(source)
      lease = lease!(@mini)
      assert %F.Outcome.Recorded{} = report(@mini, lease, 1, accepted())
      assert %F.Outcome.Recorded{} = report(@mini, lease, 1, accepted())

      assert %F.Outcome.Rejected{reason: :conflict} = report(@mini, lease, 1, started())
      assert %F.Outcome.Rejected{reason: :conflict} = report(@mini, lease, 3, started())
      assert %F.Outcome.Recorded{} = report(@mini, lease, 2, started())
    end

    test "an input that does not fit the contract is rejected as invalid, before the source" do
      assert %F.Outcome.Rejected{reason: :invalid} =
               F.report(@mini, %{
                 lease_id: "flow-test-lease-1",
                 revision: 0,
                 report: %F.Accepted{}
               })

      assert %AtlasRuntimeBoundary.Generator.NotPermitted{right: :lease} =
               F.poll({"mini", []}, %{})
    end
  end

  describe "results (work_source 0.5.0, IS-Atlas-100)" do
    test "ended is recorded with nothing missing; no blob is uploaded, there is no put_blob",
         %{source: source} do
      add(source)
      {lease, missing} = ended_lease!(@mini, [{"a.txt", "a\n"}])
      assert missing == []

      assert %F.Outcome.Recorded{missing: []} =
               report(@mini, lease, 3, ended([{"a.txt", "a\n"}]))

      refute Map.has_key?(Source.blobs(source), Source.sha256("a\n"))
      refute function_exported?(F, :put_blob, 2)
    end
  end

  describe "input blobs (§3 F6)" do
    defp fetch(client, lease, sha) do
      case F.get_blob(client, %{lease_id: lease, sha256: sha}) do
        %F.Outcome.Blob{content: content} -> {:ok, IO.iodata_to_binary(Enum.to_list(content))}
        %F.Outcome.NotFound{} -> :not_found
      end
    end

    test "get_blob serves only the blobs the current lease's input names", %{source: source} do
      add(source)
      lease = lease!(@mini)
      manifest = Source.sha256(@base_manifest)

      assert {:ok, @base_manifest} = fetch(@mini, lease, manifest)
      assert {:ok, @readme} = fetch(@mini, lease, Source.sha256(@readme))

      # Not named by the input, though the source may hold it.
      assert :not_found = fetch(@mini, lease, Source.sha256("other"))
      # Through another Runtime, or once the lease is lost, nothing is found.
      assert :not_found = fetch(@laptop, lease, manifest)
      Source.advance(source, 31)
      assert :not_found = fetch(@mini, lease, manifest)
    end

    test "get_blob does not serve a blob the same source holds for another work's input",
         %{source: source} do
      first = "named by task-1 only\n"
      second = "named by task-2 only\n"

      Source.add_work(source, work("task-1", Source.sha256(first)), %{
        Source.sha256(first) => first
      })

      Source.add_work(source, work("task-2", Source.sha256(second)), %{
        Source.sha256(second) => second
      })

      lease = lease!(@mini)
      assert Source.current(source, "task-1") == lease
      assert Map.has_key?(Source.blobs(source), Source.sha256(second))

      assert {:ok, ^first} = fetch(@mini, lease, Source.sha256(first))
      assert :not_found = fetch(@mini, lease, Source.sha256(second))
      assert Source.served(source) == [{lease, Source.sha256(first)}]
    end

    test "a blob from another source is downloaded from the source that names it, never reused" do
      a = Source.start(name: "a")
      b = Source.start(name: "b")
      shared = "the same bytes in both sources\n"
      only_a = "only source a holds this\n"

      Source.add_work(a, work("task-a", Source.sha256(@base_manifest)), %{
        Source.sha256(@base_manifest) => @base_manifest,
        Source.sha256(shared) => shared,
        Source.sha256(only_a) => only_a
      })

      Source.add_work(b, work("task-b", Source.sha256(@base_manifest)), %{
        Source.sha256(@base_manifest) => @base_manifest,
        Source.sha256(shared) => shared
      })

      Source.use(a)
      lease_a = lease!(@mini)
      assert {:ok, ^shared} = fetch(@mini, lease_a, Source.sha256(shared))

      Source.use(b)
      lease_b = lease!(@mini)

      # The same sha256, for b's work: downloaded from b, under b's lease.
      assert {:ok, ^shared} = fetch(@mini, lease_b, Source.sha256(shared))
      assert Source.served(b) == [{lease_b, Source.sha256(shared)}]

      # a's blob is not visible through b: not under b's lease, and not under a's lease
      # asked of b. The "missing" answer is per source.
      assert :not_found = fetch(@mini, lease_b, Source.sha256(only_a))
      assert :not_found = fetch(@mini, lease_a, Source.sha256(shared))
      assert Source.served(a) == [{lease_a, Source.sha256(shared)}]
    end
  end
end
