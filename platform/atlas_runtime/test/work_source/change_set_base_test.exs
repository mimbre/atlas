defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest.Facade do
  @moduledoc false
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.WorkSource,
    implementation: AtlasRuntime.WorkSource.ChangeSetBaseTest.Capture
end

defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest.Capture do
  @moduledoc false
  # A source that records nothing and answers every report recorded: it sends the decoded
  # report to the calling process (the in-test transport runs there).
  use AtlasRuntime.WorkSource.ChangeSetBaseTest.Facade.Implementation

  alias AtlasRuntime.WorkSource.ChangeSetBaseTest.Facade, as: F

  @impl true
  def poll(_client, _input),
    do: %F.Outcome.Polled{
      leases: [],
      cancel: [],
      lease_lost: [],
      timing: %F.Timing{lease_ttl: 900, poll_max: 25}
    }

  @impl true
  def report(_client, %F.ReportInput{} = input) do
    send(self(), {:reported, input})
    %F.Outcome.Recorded{missing: []}
  end

  @impl true
  def get_blob(_client, _input), do: %F.Outcome.NotFound{}

  @impl true
  def put_blob(_client, _input), do: %F.Outcome.NotReferenced{}
end

defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest.Rest do
  @moduledoc false
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contract: AtlasRuntimeBackend.WorkSource,
    facade: AtlasRuntime.WorkSource.ChangeSetBaseTest.Facade
end

defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest.Transport do
  @moduledoc false
  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  alias AtlasRuntime.WorkSource.ChangeSetBaseTest.Rest

  @impl true
  def request(request, _opts) do
    conn =
      Enum.reduce(
        request.headers,
        Plug.Test.conn(request.method, request.path, request.body || ""),
        fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end
      )
      |> Plug.Conn.assign(:client, {"mini", [:lease]})
      |> Rest.call(Rest.init([]))

    send(self(), {:wire, request.body})
    {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
  end

  @impl true
  def stream(request, opts), do: request(request, opts)
end

defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest.Client do
  @moduledoc false
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.WorkSource,
    transport: AtlasRuntime.WorkSource.ChangeSetBaseTest.Transport
end

defmodule AtlasRuntime.WorkSource.ChangeSetBaseTest do
  # K1 (work_source 0.2.0): the ended change set's `base`, which Sources.Upload always
  # sends (upload.ex `manifest/3`) and Sources.Import requires back (import.ex
  # `decode_change_set/1`, `compose_input/5`), is a declared field: it crosses the
  # generated HTTP client, the generated router and the generated in-BEAM facade as a
  # typed value, and a change set without it is refused as invalid at each of them.
  use ExUnit.Case, async: true

  alias AtlasRuntime.WorkSource.ChangeSetBaseTest.{Client, Facade, Rest}

  @base "sha256:" <> String.duplicate("b", 64)
  @client {"mini", [:lease]}

  defp ended(change_set) do
    %{
      state: :ended,
      result: %{kind: :completed, retryable: false, never_started: false},
      provenance: [],
      change_set: change_set
    }
  end

  defp change_set do
    %{
      base: @base,
      roots: [
        %{
          root: "atlas",
          fingerprint: "csf_test",
          entries: [
            %{
              path: "a.txt",
              op: :write,
              kind: :file,
              mode: :"100644",
              size: 2,
              sha256: String.duplicate("a", 64)
            }
          ]
        }
      ]
    }
  end

  @routes Path.expand("../../backend/targets/rest/work_source_api/routes.json", __DIR__)

  defp invalid_type do
    routes = @routes |> File.read!() |> JSON.decode!()
    report = Enum.find(routes["routes"], &(&1["capability"] == "report"))
    rejected = Enum.find(report["outcomes"], &(&1["outcome"] == "rejected"))
    Enum.find(rejected["cases"], &(&1["value"] == "invalid"))["type"]
  end

  defp report(change_set),
    do: %{lease_id: "lease-1", revision: 2, report: ended(change_set)}

  test "base round-trips: generated client → wire → generated router → facade struct" do
    assert {:recorded, %{missing: []}} = Client.report(report(change_set()), [])

    assert_received {:wire, body}
    assert %{"report" => %{"change_set" => %{"base" => @base}}} = JSON.decode!(body)

    assert_received {:reported,
                     %Facade.ReportInput{
                       report: %Facade.Ended{
                         change_set: %Facade.ChangeSet{roots: [%Facade.ChangeRoot{}]} = set
                       }
                     }}

    assert Map.get(set, :base) == @base
  end

  test "base round-trips through the in-BEAM facade, and dump/new keep it" do
    assert %Facade.Outcome.Recorded{missing: []} = Facade.report(@client, report(change_set()))

    assert_received {:reported, %Facade.ReportInput{report: %Facade.Ended{change_set: set}}}
    assert Map.get(set, :base) == @base
    assert %{"base" => @base} = dumped = Facade.ChangeSet.dump(set)
    assert {:ok, ^set} = Facade.ChangeSet.new(dumped)
  end

  test "a change set without base is invalid, before the source is called" do
    without = Map.delete(change_set(), :base)

    assert {:error, [_ | _]} = Facade.ChangeSet.new(without)

    assert %Facade.Outcome.Rejected{reason: :invalid} = Facade.report(@client, report(without))
    refute_received {:reported, _}

    # The generated client refuses it before anything is sent.
    assert {:error, {:invalid, [_ | _]}} = Client.report(report(without), [])
    refute_received {:wire, _}
    refute_received {:reported, _}
  end

  test "the generated router answers 400 invalid to a wire change set without base" do
    body = fn set ->
      JSON.encode!(%{
        "revision" => 2,
        "report" => %{
          "state" => "ended",
          "result" => %{"kind" => "completed", "retryable" => false, "never_started" => false},
          "provenance" => [],
          "change_set" => set
        }
      })
    end

    post = fn set ->
      Plug.Test.conn(:post, "/v1/leases/lease-1/reports", body.(set))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:client, @client)
      |> Rest.call(Rest.init([]))
    end

    wire = change_set() |> Facade.ChangeSet.new!() |> Facade.ChangeSet.dump()

    assert %{status: 200} = post.(wire)
    assert_received {:reported, %Facade.ReportInput{report: %Facade.Ended{change_set: set}}}
    assert Map.get(set, :base) == @base

    assert %{status: 400} = conn = post.(Map.delete(wire, "base"))
    # The problem type routes.json gives report's rejected(invalid).
    assert %{"type" => type} = JSON.decode!(conn.resp_body)
    assert type == invalid_type()
    refute_received {:reported, _}
  end
end
