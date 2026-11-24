defmodule AtlasFlow.Backend.RuntimeClientContractTest do
  # Plan m3 A3: the Runtime's own generated client (AtlasRuntimeBackend.Generator.Targets
  # .Client on the backend contract AtlasRuntimeBackend.WorkSource, 0.2.0 with put_blob)
  # against Flow's listener and router, end to end on the real work source (Dispatch,
  # Delivery, the result store, Bases on FakeCode; FakeFacts and a manual clock). The
  # transport goes through Plug.Test, in the calling process, and carries the bearer
  # credential as a header, so the listener checks it. A streamed request body is pulled
  # from the client's enumerable one element per server read. Asserted on the client's
  # typed outcomes, never on text.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Dispatch, FakeCode, FakeFacts}
  alias AtlasFlow.Backend.{Listener, Router}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Credentials

  defmodule Upload do
    @moduledoc """
    Plug.Test's adapter, but the request body is the client's enumerable: each read takes
    the next element (split at the read's `length`), so nothing is pulled before the
    server reads it.
    """
    @behaviour Plug.Conn.Adapter
    alias Plug.Adapters.Test.Conn, as: T

    def wrap(%Plug.Conn{adapter: {T, state}} = conn, enumerable) do
      pull = &Enumerable.reduce(enumerable, &1, fn x, _ -> {:suspend, x} end)
      %{conn | adapter: {__MODULE__, Map.merge(state, %{pull: pull, rest: ""})}}
    end

    @impl true
    def read_req_body(%{rest: rest} = state, opts) when rest != "" do
      length = Keyword.get(opts, :length, 8_000_000)
      <<data::binary-size(min(length, byte_size(rest))), rest::binary>> = rest
      {:more, data, %{state | rest: rest}}
    end

    def read_req_body(%{pull: nil} = state, _opts), do: {:ok, "", state}

    def read_req_body(%{pull: pull} = state, opts) do
      case pull.({:cont, nil}) do
        {:suspended, element, next} ->
          read_req_body(%{state | pull: next, rest: IO.iodata_to_binary(element)}, opts)

        _done ->
          {:ok, "", %{state | pull: nil}}
      end
    end

    @impl true
    defdelegate send_resp(state, status, headers, body), to: T
    @impl true
    defdelegate send_file(state, status, headers, path, offset, length), to: T
    @impl true
    defdelegate send_chunked(state, status, headers), to: T
    @impl true
    defdelegate chunk(state, body), to: T
    @impl true
    defdelegate inform(state, status, headers), to: T
    @impl true
    defdelegate upgrade(state, protocol, opts), to: T
    @impl true
    defdelegate push(state, path, headers), to: T
    @impl true
    defdelegate get_peer_data(state), to: T
    @impl true
    defdelegate get_http_protocol(state), to: T
    @impl true
    defdelegate get_sock_data(state), to: T
    @impl true
    defdelegate get_ssl_data(state), to: T
  end

  defmodule Transport do
    @moduledoc "The client's transport: Plug.Test into Flow's listener, in this process."
    @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

    @credentials %{
      "mini" => %{holder: "ada", token_sha256: Credentials.token_sha256("tok-mini")},
      "laptop" => %{holder: "bea", token_sha256: Credentials.token_sha256("tok-laptop")}
    }

    @impl true
    def request(request, opts) do
      conn = run(request, opts)
      {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
    end

    @impl true
    def stream(request, opts) do
      conn = run(request, opts)
      {:ok, %{status: conn.status, headers: conn.resp_headers, body: [conn.resp_body]}}
    end

    defp run(request, opts) do
      path = if request.query == "", do: request.path, else: request.path <> "?" <> request.query
      method = request.method

      conn =
        case request.body do
          body when is_binary(body) or is_nil(body) ->
            Plug.Test.conn(method, path, body || "")

          enumerable ->
            method
            |> Plug.Test.conn(path, "")
            |> AtlasFlow.Backend.RuntimeClientContractTest.Upload.wrap(enumerable)
        end

      conn =
        Enum.reduce(request.headers, conn, fn {k, v}, conn ->
          Plug.Conn.put_req_header(conn, k, v)
        end)

      conn =
        case opts[:credential] do
          nil -> conn
          token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
        end

      AtlasFlow.Backend.Listener.call(conn, %{
        credentials: @credentials,
        router: AtlasFlow.Backend.Router.init([])
      })
    end
  end

  defmodule Client do
    @moduledoc "The Runtime's work source client, generated from its backend contract."
    use AtlasRuntimeBackend.Generator.Targets.Client,
      contract: AtlasRuntimeBackend.WorkSource,
      transport: AtlasFlow.Backend.RuntimeClientContractTest.Transport
  end

  @mini [transport: [credential: "tok-mini"]]
  @readme "# hello\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "contract-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir, results: [result_cap: 64])
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})

    fake = start_supervised!({FakeCode, %{}}, id: :fake)
    FakeCode.put(fake, "example.org/acme/repo", "develop", "rev_1", %{"README.md" => @readme})
    start_supervised!({Bases, client: FakeCode.client(fake), clock: ctx.clock})
    :ok = Bases.request("example.org/acme/repo", "develop", {self(), :base})
    assert_receive :base
    {:ok, base} = Bases.cached("example.org/acme/repo", "develop")

    %{task: task} = L.supervised_task("B-1", "ada", base: base)
    Dispatch.resync()
    Map.merge(ctx, %{base: base, task: task})
  end

  defp poll(holdings \\ [], opts \\ @mini) do
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

  defp lease! do
    {:polled, %{leases: [%{lease_id: lease}]}} = poll()
    lease
  end

  defp report(lease, revision, report),
    do: Client.report(%{lease_id: lease, revision: revision, report: report}, @mini)

  defp ended(files, base) do
    entries =
      for {path, bytes} <- files,
          do: %{
            path: path,
            op: :write,
            kind: :file,
            mode: :"100644",
            size: byte_size(bytes),
            sha256: L.sha256(bytes)
          }

    %{
      state: :ended,
      result: %{kind: :completed, retryable: false, never_started: false},
      provenance: [],
      change_set: %{
        # K1 (work_source 0.2.0): `base` is required; the lease's base, as the Runtime sends it.
        base: base.base_id,
        roots: [
          %{
            root: "repo",
            fingerprint:
              AtlasChangeset.fingerprint(
                base.base_id,
                "repo",
                AtlasFlow.WorkSource.Translate.normal(entries)
              ),
            entries: entries
          }
        ]
      }
    }
  end

  defp ended_lease!(ctx, files) do
    lease = lease!()
    assert {:recorded, %{missing: []}} = report(lease, 1, %{state: :accepted})
    assert {:recorded, %{missing: []}} = report(lease, 2, %{state: :started})
    assert {:recorded, %{missing: missing}} = report(lease, 3, ended(files, ctx.base))
    {lease, missing}
  end

  # The bytes as a stream that tells the test each element it makes.
  defp watched(chunks), do: Stream.map(chunks, &(send(self(), {:made, &1}) && &1))

  defp put(lease, bytes, opts \\ []) do
    Client.put_blob(
      %{
        lease_id: lease,
        sha256: Keyword.get(opts, :sha256, L.sha256(bytes)),
        size: Keyword.get(opts, :size, byte_size(bytes)),
        content: Keyword.get(opts, :content, watched(chunks(bytes)))
      },
      @mini
    )
  end

  defp chunks(bytes), do: for(<<c::binary-size(1) <- bytes>>, do: c)

  defp made do
    receive do
      {:made, c} -> [c | made()]
    after
      0 -> []
    end
  end

  test "the client's calls are the contract's four capabilities" do
    assert Client.__capabilities__() == [:poll, :report, :get_blob, :put_blob]
  end

  test "the router's blob cap is the contract's blob_max_bytes" do
    assert Router.init([]).blob_max_bytes == AtlasRuntimeBackend.WorkSource.blob_max_bytes()
  end

  test "poll leases the work, decoded into the contract's values", ctx do
    task = ctx.task

    assert {:polled,
            %{
              leases: [
                %{
                  lease_id: lease,
                  expires_at: %DateTime{},
                  work: %{
                    work_key: ^task,
                    cost_class: :standard,
                    input: %{base: %{base_id: base_id}}
                  }
                }
              ],
              cancel: [],
              lease_lost: [],
              timing: %{lease_ttl: 900, poll_max: 25}
            }} = poll()

    assert base_id == ctx.base.base_id
    assert {:polled, %{leases: [], lease_lost: []}} = poll([lease])
    assert {:polled, %{lease_lost: ["nope"]}} = poll(["nope"])
  end

  test "a poll for another Runtime than the credential's is rejected(invalid)" do
    assert {:rejected, %{reason: :invalid}} =
             Client.poll(
               %{
                 runtime_id: "laptop",
                 incarnation: "i",
                 build: "b",
                 policy_version: 1,
                 offer: %{},
                 holdings: []
               },
               @mini
             )
  end

  test "a late accept gets lease_lost (410 lease-lost)", ctx do
    lease = lease!()
    L.advance(ctx, 31)
    assert report(lease, 1, %{state: :accepted}) == :lease_lost
    Dispatch.sweep()
    assert {:polled, %{lease_lost: [^lease], leases: [%{lease_id: fresh}]}} = poll([lease])
    assert fresh != lease
  end

  test "a stale report gets lease_lost; a current one is recorded; a skipped revision conflicts",
       ctx do
    lease = lease!()
    assert {:recorded, %{missing: []}} = report(lease, 1, %{state: :accepted})
    assert {:rejected, %{reason: :conflict}} = report(lease, 3, %{state: :started})

    L.advance(ctx, 900)
    Dispatch.sweep()
    assert report(lease, 2, %{state: :started}) == :lease_lost
  end

  test "a report Facts cannot answer is unreachable to the Runtime, never lease_lost; sent again it lands",
       ctx do
    lease = lease!()
    assert {:recorded, %{missing: []}} = report(lease, 1, %{state: :accepted})

    # A deploy restarts rela: the task fact cannot be read.
    :ok = GenServer.call(FakeFacts, {:busy, "task", ctx.task})
    assert report(lease, 2, %{state: :started}) == {:error, :unreachable}

    :ok = GenServer.call(FakeFacts, {:free, "task", ctx.task})
    assert {:recorded, %{missing: []}} = report(lease, 2, %{state: :started})
    assert {:polled, %{lease_lost: []}} = poll([lease])
  end

  test "ended answers the missing blobs", ctx do
    {_lease, missing} = ended_lease!(ctx, [{"a.txt", "a\n"}, {"README.md", @readme}])
    assert Enum.sort(missing) == Enum.sort([L.sha256("a\n"), L.sha256(@readme)])
  end

  test "get_blob streams a named blob with its sha256 and size; any other is not_found", ctx do
    lease = lease!()
    sha = L.sha256(@readme)

    assert {:blob, %{sha256: ^sha, size: 8, content: content}} =
             Client.get_blob(%{lease_id: lease, sha256: sha}, @mini)

    assert IO.iodata_to_binary(Enum.to_list(content)) == @readme

    manifest = ctx.base.manifest

    assert {:blob, %{sha256: ^manifest}} =
             Client.get_blob(%{lease_id: lease, sha256: manifest}, @mini)

    assert Client.get_blob(%{lease_id: lease, sha256: L.sha256("x")}, @mini) == :not_found

    assert Client.get_blob(%{lease_id: lease, sha256: sha}, transport: [credential: "tok-laptop"]) ==
             :not_found

    L.advance(ctx, 31)
    Dispatch.sweep()
    assert Client.get_blob(%{lease_id: lease, sha256: sha}, @mini) == :not_found
  end

  describe "put_blob, streamed" do
    test "a referenced blob is stored, its bytes pulled as the server reads; again is stored",
         ctx do
      {lease, [missing]} = ended_lease!(ctx, [{"a.txt", "abc"}])
      assert missing == L.sha256("abc")

      assert put(lease, "abc") == :stored
      assert made() == ["a", "b", "c"]
      assert put(lease, "abc") == :stored
      assert L.values(ctx.task)["result_state"] == "complete"
    end

    test "fenced first, then the reference, then the room: none of them reads a byte", ctx do
      {lease, _} = ended_lease!(ctx, [{"a.txt", "abc"}])

      assert put(lease, "zzz") == :not_referenced
      assert made() == []

      assert put("TK-B-1-1~1~AAAAAAAAAAAAAAAAAAAAAA", "abc") == :lease_lost
      assert made() == []

      # 65 bytes declared against the 64 a result may hold.
      assert put(lease, "abc", size: 65, content: watched([String.duplicate("x", 65)])) ==
               :too_large

      assert made() == []
    end

    test "too large by the declared size reads nothing", ctx do
      big = String.duplicate("y", 65)
      {lease, _} = ended_lease!(ctx, [{"big.txt", big}])
      assert put(lease, big) == :too_large
      assert made() == []
      assert L.values(ctx.task)["result_state"] == "too_large"
    end

    test "more bytes than Blob-Size: the server reads one past it, keeps nothing, too_large",
         ctx do
      {lease, _} = ended_lease!(ctx, [{"a.txt", "abc"}])
      more = watched(chunks(String.duplicate("a", 40)))
      # A body past its cap is too_large (the contract's body-limit answer), not the source's
      # answer to the bytes it saw.
      assert put(lease, "abc", content: more) == :too_large
      assert length(made()) == 4
      assert put(lease, "abc") == :stored
    end

    test "bytes that do not match the sha256 or the size are rejected(digest_mismatch)", ctx do
      {lease, _} = ended_lease!(ctx, [{"a.txt", "abc"}])
      assert {:rejected, %{reason: :digest_mismatch}} = put(lease, "abd", sha256: L.sha256("abc"))
      assert {:rejected, %{reason: :digest_mismatch}} = put(lease, "abc", size: 4)
      assert L.values(ctx.task)["result_state"] != "complete"
    end

    test "a lease expired by the sweep is lease_lost, and nothing is read", ctx do
      {lease, _} = ended_lease!(ctx, [{"a.txt", "abc"}])
      L.advance(ctx, 900)
      Dispatch.sweep()
      assert put(lease, "abc") == :lease_lost
      assert made() == []
    end

    test "a binary content is refused by the client, without a request" do
      assert {:error, {:invalid, _}} =
               Client.put_blob(
                 %{lease_id: "L", sha256: L.sha256("a"), size: 1, content: "a"},
                 @mini
               )
    end
  end

  test "without a valid credential the listener answers 401 to every capability" do
    for opts <- [[transport: []], [transport: [credential: "nope"]]] do
      assert poll([], opts) == {:error, :unauthenticated}

      assert Client.report(%{lease_id: "L", revision: 1, report: %{state: :accepted}}, opts) ==
               {:error, :unauthenticated}

      assert Client.get_blob(%{lease_id: "L", sha256: L.sha256("a")}, opts) ==
               {:error, :unauthenticated}

      assert Client.put_blob(
               %{lease_id: "L", sha256: L.sha256("a"), size: 1, content: watched(["a"])},
               opts
             ) == {:error, :unauthenticated}

      assert made() == []
    end
  end

  test "the listener and router are Flow's: no Runtime module serves these answers" do
    assert Listener.module_info(:module) == AtlasFlow.Backend.Listener

    assert Router.__routes__() |> Enum.map(& &1.capability) == [
             :poll,
             :report,
             :get_blob,
             :put_blob
           ]
  end
end
