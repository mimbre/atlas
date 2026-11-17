defmodule AtlasRuntime.WorkSource.HttpClientTest do
  # Decision 2026-11-17-work-acquisition §5, §6.6 M1: the work source contract's HTTP
  # client target (AtlasRuntimeBackend.Generator.Targets.Client on
  # AtlasRuntimeBackend.WorkSource) against the router generated from the same backend
  # contract, on the in-test source. The fencing answers reach the Runtime as typed
  # outcomes. put_blob (a streamed request body) has its own tests, http_put_blob_test.exs.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceClient, as: Client

  @as [transport: [credential: "cred-mini"]]
  @readme "# hello\n"

  setup do
    source = Source.start(name: "flow-test")
    Source.use(source)
    manifest = ~s({"entries":[]})

    Source.add_work(
      source,
      %{
        work_key: "task-1",
        title: "Author package 1",
        instructions: "Write it.",
        profile: "deep_coding",
        cost_class: :standard,
        input: %{
          base: %{base_id: "base-1", manifest: Source.sha256(manifest)},
          permissions: :"workspace-write"
        }
      },
      %{Source.sha256(manifest) => manifest, Source.sha256(@readme) => @readme}
    )

    %{source: source}
  end

  defp poll(holdings \\ [], opts \\ @as) do
    Client.poll(
      %{
        runtime_id: "mini",
        incarnation: "inc-1",
        build: "test",
        policy_version: 1,
        offer: %{"deep_coding" => 1},
        holdings: for(h <- holdings, do: %{lease_id: h, state: :running})
      },
      opts
    )
  end

  defp report(lease, revision, report),
    do: Client.report(%{lease_id: lease, revision: revision, report: report}, @as)

  test "the client's calls are the exposed capabilities" do
    assert Client.__capabilities__() == [:poll, :report, :get_blob, :put_blob]
  end

  test "poll leases the work, decoded into the contract's values" do
    assert {:polled,
            %{
              leases: [
                %{
                  lease_id: lease,
                  expires_at: %DateTime{},
                  work: %{work_key: "task-1", cost_class: :standard, input: %{base: %{}}}
                }
              ],
              cancel: [],
              lease_lost: [],
              timing: %{lease_ttl: 900, poll_max: 25}
            }} = poll()

    assert {:polled, %{leases: [], lease_lost: []}} = poll([lease])
  end

  test "a late accept gets lease_lost (410 lease-lost)", %{source: source} do
    {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    Source.advance(source, 31)
    assert report(lease, 1, %{state: :accepted}) == :lease_lost
    assert {:polled, %{lease_lost: [^lease], leases: [%{lease_id: fresh}]}} = poll([lease])
    assert fresh != lease
  end

  test "a stale report gets lease_lost; a current one is recorded", %{source: source} do
    {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    assert {:recorded, %{missing: []}} = report(lease, 1, %{state: :accepted})
    assert {:rejected, %{reason: :conflict}} = report(lease, 3, %{state: :started})

    Source.advance(source, 900)
    assert report(lease, 2, %{state: :started}) == :lease_lost
  end

  test "ended answers the missing blobs" do
    {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    assert {:recorded, _} = report(lease, 1, %{state: :accepted})

    ended = %{
      state: :ended,
      result: %{kind: :completed, retryable: false, never_started: false},
      provenance: [],
      change_set: %{
        roots: [
          %{
            root: "repo",
            fingerprint: "csf_test",
            entries: [
              %{
                path: "a.txt",
                op: :write,
                kind: :file,
                mode: :"100644",
                size: 2,
                sha256: Source.sha256("a\n")
              },
              %{
                path: "README.md",
                op: :write,
                kind: :file,
                mode: :"100644",
                size: 8,
                sha256: Source.sha256(@readme)
              }
            ]
          }
        ]
      }
    }

    assert {:recorded, %{missing: [missing]}} = report(lease, 2, ended)
    assert missing == Source.sha256("a\n")
  end

  test "get_blob streams a named blob with its sha256 and size; any other is not_found",
       %{source: source} do
    {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    sha = Source.sha256(@readme)

    assert {:blob, %{sha256: ^sha, size: 8, content: content}} =
             Client.get_blob(%{lease_id: lease, sha256: sha}, @as)

    assert IO.iodata_to_binary(Enum.to_list(content)) == @readme

    assert Client.get_blob(%{lease_id: lease, sha256: Source.sha256("x")}, @as) == :not_found
    Source.advance(source, 31)
    assert Client.get_blob(%{lease_id: lease, sha256: sha}, @as) == :not_found
  end

  test "without a valid credential the listener answers 401, before the source" do
    assert poll([], transport: [credential: "nope"]) == {:error, :unauthenticated}
    assert poll([], transport: []) == {:error, :unauthenticated}
  end

  test "an input that does not fit is refused by the client, without a request" do
    assert {:error, {:invalid, [_ | _]}} = Client.poll(%{runtime_id: "mini"}, @as)
  end
end
