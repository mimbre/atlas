defmodule AtlasFlow.Backend.RuntimeClientContractTest do
  # Plan m3 A3: the Runtime's own generated client (AtlasRuntimeBackend.Generator.Targets
  # .Client on the backend contract AtlasRuntimeBackend.WorkSource, 0.4.0: no put_blob,
  # IS-Atlas-100) against Flow's listener and router, end to end on the real work source
  # (Dispatch, Delivery, Bases on FakeCode; FakeFacts and a manual clock). The
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
    ctx = L.start(dir)
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

  test "the client's calls are the contract's three capabilities: no put_blob" do
    assert Client.__capabilities__() == [:poll, :report, :get_blob]
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

  test "IS-Atlas-27: the configuration on the machinery fact reaches the client; a refusal comes back" do
    kind = AtlasFlow.WorkSource.Configuration.kind()
    document = JSON.encode!(%{"version" => 2, "profiles" => %{}})

    FakeFacts.put(kind, %{
      "key" => "mini",
      "values" => %{"name" => "mini", "configuration" => document},
      "version" => 1
    })

    assert {:polled, %{configuration: ^document}} = poll()

    refused = %{version: 2, reason: "invalid: profiles"}

    input = %{
      runtime_id: "mini",
      incarnation: "inc-1",
      build: "test",
      policy_version: 1,
      offer: %{},
      holdings: [],
      configuration_refused: refused
    }

    assert {:polled, %{configuration: nil}} = Client.poll(input, @mini)

    assert %{
             "applied_version" => 1,
             "refused_version" => 2,
             "refused_reason" => "invalid: profiles"
           } =
             FakeFacts.get(kind, "mini")["values"]
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

  test "ended asks for no blob: a result travels over Git (IS-Atlas-100)", ctx do
    {_lease, missing} = ended_lease!(ctx, [{"a.txt", "a\n"}, {"README.md", @readme}])
    assert missing == []
    assert L.values(ctx.task)["lease_state"] == "done"
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

  test "without a valid credential the listener answers 401 to every capability" do
    for opts <- [[transport: []], [transport: [credential: "nope"]]] do
      assert poll([], opts) == {:error, :unauthenticated}

      assert Client.report(%{lease_id: "L", revision: 1, report: %{state: :accepted}}, opts) ==
               {:error, :unauthenticated}

      assert Client.get_blob(%{lease_id: "L", sha256: L.sha256("a")}, opts) ==
               {:error, :unauthenticated}
    end
  end

  test "the listener and router are Flow's: no Runtime module serves these answers" do
    assert Listener.module_info(:module) == AtlasFlow.Backend.Listener

    assert Router.__routes__() |> Enum.map(& &1.capability) == [:poll, :report, :get_blob]
  end
end
