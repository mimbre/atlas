defmodule AtlasRuntime.FlowPassesTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Digest
  alias AtlasRuntime.FlowPasses
  @moduletag :tmp_dir

  defmodule Receiver do
    def validate(_, r),
      do:
        if(r["request"]["packet"] == %{"fingerprint" => "frozen"},
          do: :ok,
          else: {:error, :packet_mismatch}
        )

    def accept(pid, r) do
      Agent.get_and_update(pid, fn s ->
        result = s[r["id"]] || %{"execution" => "execution-1", "status" => "running"}
        {{:ok, result}, Map.put(s, r["id"], result)}
      end)
    end

    def lookup(pid, r, _), do: {:ok, Agent.get(pid, & &1[r["id"]])}
  end

  defmodule FindingsConsumer do
    # Exercise the subprocess consumer and durable receiver without claiming Service
    # admission or packet validation: only the execution adapter is substituted.
    def validate(_, _), do: :ok
    def accept(_, _), do: {:ok, %{"execution" => "turn-1", "status" => "running"}}

    def lookup(home, r, execution) do
      result =
        AtlasRuntime.Workspaces.findings(Path.dirname(r["request"]["cwd"]), execution, home)

      FlowPasses.Native.review_result(result, r, execution, %{"state" => "finished"})
    end
  end

  setup %{tmp_dir: dir} do
    receiver = start_supervised!({Agent, fn -> %{} end})
    opts = [machine: "desk", dir: dir, backend: {Receiver, receiver}]
    endpoint = start_supervised!({FlowPasses, opts})

    r = %{
      "version" => 1,
      "id" => String.duplicate("a", 64),
      "run" => "r",
      "entry" => 1,
      "name" => "inspect",
      "machine" => "desk",
      "owner" => "clerk",
      "fingerprint" => "subject-fp",
      "request" => %{"packet" => %{"fingerprint" => "frozen"}}
    }

    body = %{"operation" => "accept", "request" => r, "digest" => Digest.of_term(r)}
    %{endpoint: endpoint, receiver: receiver, opts: opts, body: body, dir: dir}
  end

  test "concurrent duplicates and restart recover one execution and one immutable outcome", c do
    results = for _ <- 1..8, do: Task.async(fn -> FlowPasses.request(c.endpoint, c.body) end)
    [first] = results |> Enum.map(&Task.await/1) |> Enum.uniq()
    assert first["execution"] == "execution-1"
    assert map_size(Agent.get(c.receiver, & &1)) == 1
    stop_supervised!(FlowPasses)
    endpoint = start_supervised!({FlowPasses, c.opts})
    assert FlowPasses.request(endpoint, c.body) == first
    Agent.update(c.receiver, &put_in(&1, [c.body["request"]["id"], "status"], "completed"))
    Agent.update(c.receiver, &put_in(&1, [c.body["request"]["id"], "outcome"], "finished"))
    done = FlowPasses.request(endpoint, Map.put(c.body, "operation", "lookup"))
    assert done["status"] == "completed"
    assert FlowPasses.request(endpoint, c.body) == done
    assert map_size(Agent.get(c.receiver, & &1)) == 1
  end

  test "changed payload, wrong machine and packet refuse before execution", c do
    for {path, value} <- [{["machine"], "elsewhere"}, {["request", "packet"], %{}}] do
      r = put_in(c.body["request"], path, value)
      b = %{c.body | "request" => r, "digest" => Digest.of_term(r)}
      assert FlowPasses.request(c.endpoint, b)["error"]
    end

    assert Agent.get(c.receiver, & &1) == %{}
    assert FlowPasses.request(c.endpoint, c.body)["execution"]
    r = Map.put(c.body["request"], "owner", "other")
    b = %{c.body | "request" => r, "digest" => Digest.of_term(r)}
    assert FlowPasses.request(c.endpoint, b)["error"] =~ "pass_identity_conflict"
    assert map_size(Agent.get(c.receiver, & &1)) == 1
  end

  test "lost acknowledgement between receiver acceptance and journal update recovers by identity",
       c do
    r = c.body["request"]
    {:ok, _} = Receiver.accept(c.receiver, r)
    path = Path.join([c.dir, "passes", r["id"] <> ".json"])
    File.write!(path, JSON.encode!(Map.take(c.body, ~w(request digest))))
    assert FlowPasses.request(c.endpoint, c.body)["execution"] == "execution-1"
    assert map_size(Agent.get(c.receiver, & &1)) == 1
  end

  test "CLI refusal JSON reaches the findings consumer and survives receiver restart", c do
    binary = Path.join(c.dir, "runtime-test")
    root = Path.expand("../../../..", __DIR__)

    {output, status} =
      System.cmd("go", ["test", "-c", "-o", binary, "."],
        cd: Path.join(root, "tools/runtime"),
        stderr_to_stdout: true
      )

    assert status == 0, output
    cli = Path.join(c.dir, "findings-cli")

    File.write!(cli, """
    #!/bin/sh
    ATLAS_TEST_COMMAND_ERROR="${4##*/}"; export ATLAS_TEST_COMMAND_ERROR
    exec "#{binary}" '-test.run=^TestCommandErrorProcess$'
    """)

    File.chmod!(cli, 0o700)
    previous = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    System.put_env("ATLAS_RUNTIME_EXECUTABLE", cli)
    on_exit(fn -> System.put_env("ATLAS_RUNTIME_EXECUTABLE", previous) end)
    stop_supervised!(FlowPasses)

    for code <- ~w(findings_missing findings_invalid packet_modified unknown) do
      home = Path.join(c.dir, code)
      opts = [machine: "desk", dir: home, backend: {FindingsConsumer, home}]
      endpoint = start_supervised!({FlowPasses, opts})
      r = put_in(c.body["request"], ["request", "cwd"], "/#{code}/tree")
      body = %{c.body | "request" => r, "digest" => Digest.of_term(r)}
      assert FlowPasses.request(endpoint, body)["status"] == "running"
      result = FlowPasses.request(endpoint, Map.put(body, "operation", "lookup"))
      path = Path.join([home, "passes", r["id"] <> ".json"])
      before = File.read!(path)

      if code in ~w(findings_missing findings_invalid) do
        assert {result["status"], result["outcome"]} == {"completed", "failed"}
        assert result["evidence"]["refused"] == code
      else
        assert result["requires_reconciliation"]
        refute result["outcome"]
        assert JSON.decode!(before)["result"]["status"] == "running"
      end

      stop_supervised!(FlowPasses)
      endpoint = start_supervised!({FlowPasses, opts})
      assert FlowPasses.request(endpoint, body) == result
      assert File.read!(path) == before
      stop_supervised!(FlowPasses)
    end
  end

  test "a review pass ends as its recorded findings' verdict; refused findings end it as failed" do
    alias AtlasRuntime.FlowPasses.Native
    packet = %{"packet_id" => "p-1", "fingerprint" => "fpr_1"}

    r = %{
      "request" => %{
        "permissions" => "review-packet",
        "cwd" => "/p/tree",
        "packet" => Map.put(packet, "revision", "3f2a9c1")
      }
    }

    turn = %{"turn_id" => "turn-1", "state" => "finished"}

    record = fn verdict ->
      Map.merge(packet, %{
        "review_turn" => "turn-1",
        "findings" => %{"verdict" => verdict},
        "state" => "recorded",
        "record" => "/home/packets/p-1/findings/turn-1.json"
      })
    end

    for verdict <- ~w(pass changes_required uncertain) do
      assert {:ok, %{"status" => "completed", "outcome" => ^verdict} = result} =
               Native.review_result({:ok, record.(verdict)}, r, "turn-1", turn)

      assert result["evidence"]["findings"]["review_turn"] == "turn-1"
      refute Map.has_key?(result["evidence"]["findings"], "state")
    end

    for code <- ~w(findings_missing findings_invalid),
        do:
          assert(
            {:ok, %{"outcome" => "failed", "evidence" => %{"refused" => ^code}}} =
              Native.review_result({:refused, code}, r, "turn-1", turn)
          )

    # Another packet's or turn's record, an unknown verdict, or any other refusal: never an
    # outcome.
    for result <- [
          {:ok, Map.put(record.("pass"), "fingerprint", "fpr_2")},
          {:ok, Map.put(record.("pass"), "review_turn", "turn-2")},
          {:ok, record.("approved")},
          {:refused, "packet_modified"},
          {:refused, "packet_discarded"}
        ],
        do:
          assert(
            {:error, :execution_requires_reconciliation} =
              Native.review_result(result, r, "turn-1", turn)
          )
  end

  test "a native pass requires its frozen backend rather than a local default", c do
    alias AtlasRuntime.FlowPasses.Native

    for backend <- [nil, "other"] do
      r =
        put_in(c.body["request"], ["request"], %{
          "mode" => "start",
          "cwd" => "/p/tree",
          "assignment" => "Review",
          "permissions" => "read-only",
          "vendors" => ["claude", "codex"],
          "backend" => backend
        })

      assert Native.validate(c.dir, r) == {:error, :unsupported_pass_contract}

      assert Native.validate(c.dir, update_in(r, ["request"], &Map.delete(&1, "backend"))) ==
               {:error, :unsupported_pass_contract}
    end
  end

  test "a packet pass without a revision is refused before any packet or Service is read", c do
    alias AtlasRuntime.FlowPasses.Native

    for packet <- [%{}, %{"revision" => nil}, %{"revision" => ""}] do
      request = %{
        "request" => %{
          "mode" => "start",
          "assignment" => "Inspect",
          "backend" => "codex",
          "vendors" => ["codex"],
          "permissions" => "review-packet",
          "packet_contract" => 1,
          "cwd" => "/missing/tree",
          "packet" => packet
        }
      }

      assert Native.validate(c.dir, request) == {:error, :packet_mismatch}
    end
  end

  test "native acceptance recovers accepted and indeterminate admissions without a Service or second launch",
       c do
    alias AtlasRuntime.CommandAdmissions, as: Admissions
    alias AtlasRuntime.FlowPasses.Native
    # Recovery reads an already canonical admission and must need no workspace probe.
    cwd = Path.expand(c.dir)

    r =
      put_in(c.body["request"], ["request"], %{
        "mode" => "start",
        "cwd" => cwd,
        "assignment" => "Inspect",
        "permissions" => "read-only",
        "vendors" => ["codex"],
        "backend" => "codex"
      })

    id = r["id"]
    worker = "pass-" <> String.slice(id, 0, 59)
    turn = "turn-0000000000000001"

    command =
      %{
        "command" => "start",
        "request_id" => id,
        "worker_id" => worker,
        "assignment" => "Inspect",
        "cwd" => cwd,
        "sandbox" => "read-only",
        "backend" => "codex",
        "questions_enabled" => false
      }
      |> Map.delete("request_id")

    binding = %{
      "worker_id" => worker,
      "source_turn_id" => nil,
      "cwd" => cwd,
      "sandbox" => "read-only",
      "permissions" => nil,
      "repository" => nil,
      "backend" => "codex",
      "model" => nil,
      "session_id" => nil,
      "questions_enabled" => false
    }

    run = %{
      "id" => turn,
      "worker_id" => worker,
      "request_id" => id,
      "state" => "running",
      "assignment" => "Inspect",
      "cwd" => cwd,
      "sandbox" => "read-only",
      "backend" => "codex",
      "requested_model" => nil,
      "session_id" => nil,
      "questions_enabled" => false
    }

    reservation = Admissions.reserve(c.dir, id, command, binding, turn, run)
    assert {:error, :execution_requires_reconciliation} = Native.accept(c.dir, r)
    Admissions.accept(c.dir, reservation, run)
    assert {:ok, %{"execution" => ^turn, "status" => "running"}} = Native.accept(c.dir, r)
    assert {:ok, %{"execution" => ^turn}} = Native.accept(c.dir, r)
    assert Admissions.load(c.dir, id)["turn_id"] == turn
  end
end
