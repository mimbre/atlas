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
