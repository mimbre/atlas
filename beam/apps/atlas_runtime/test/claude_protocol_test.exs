defmodule AtlasRuntime.ClaudeProtocolTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent
  alias AtlasRuntime.ClaudeProtocolProbe, as: Probe
  @moduletag :tmp_dir
  @session "22222222-2222-4222-8222-222222222222"
  @uuid "11111111-1111-4111-8111-111111111111"
  @identity %{
    "environment" => "private",
    "worker" => "worker-private",
    "turn" => "turn-a",
    "attempt" => "attempt-a",
    "interaction" => "interaction-a"
  }
  @request Map.merge(@identity, %{
             "mode" => "queued_guidance",
             "body" => "/stop\n@/not/read\n$(not a command) — 🦉"
           })
  @profile Path.join(__DIR__, "fixtures/claude_2_1_280/profile.json")

  defp state do
    {:ok, state} = Probe.new("2.1.280", @identity, @session, @uuid)
    state
  end

  defp fake(dir, mode, request \\ @request) do
    {:ok, line, state} = Probe.input(state(), request)
    capture = Path.join(dir, "captured-#{System.unique_integer([:positive])}.jsonl")
    # Only this private synthetic fixture can run; no configurable executable or native CLI.
    port =
      Port.open(
        {:spawn_executable, AtlasRuntime.FakeNative.path()},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["protocol", Atom.to_string(mode), capture]
        ]
      )

    true = Port.command(port, line)
    {state, status} = collect(port, state, System.monotonic_time(:millisecond) + 5_000)
    {Probe.verdict(state), JSON.decode!(File.read!(capture)), status, state}
  end

  defp collect(port, state, deadline) do
    receive do
      {^port, {:data, bytes}} -> collect(port, Probe.feed(state, bytes), deadline)
      {^port, {:exit_status, status}} -> {Probe.eof(state), status}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        flunk("private transcript fixture did not finish")
    end
  end

  defp unsupported(verdict) do
    assert verdict["guidance"] == "unsupported"
    assert verdict["durable_admission"] == "unproven"
    assert verdict["durable_consumption"] == "unproven"
    assert length(verdict["gaps"]) == 3
    assert byte_size(JSON.encode!(verdict)) <= 8_192
  end

  test "candidate and protocol pins do not enable the live Claude adapter" do
    profile = @profile |> File.read!() |> JSON.decode!()
    assert profile["candidate"]["version"] == "2.1.280"
    assert profile["candidate"]["executed"] == false
    assert byte_size(profile["candidate"]["native_sha256"]) == 64
    assert profile["protocol"]["version"] == "0.3.280"
    assert profile["verdict"]["guidance"] == "unsupported"
    assert {:error, :unsupported} = Agent.capabilities(Agent.Claude, self())
    assert {:error, :unsupported} = Agent.accept(Agent.Claude, self(), @request)
    assert {:error, :unsupported} = Agent.query(Agent.Claude, self(), @identity)
    assert {:error, :unsupported_profile} = Probe.new("2.1.247", @identity, @session, @uuid)
    assert {:error, :unsupported_profile} = Probe.new("future", @identity, @session, @uuid)
  end

  test "literal text is one typed JSONL frame with client_composed", %{tmp_dir: dir} do
    sentinel = Path.join(dir, "not-created")

    request =
      Map.put(@request, "body", "/model other\n@#{sentinel}\n$(touch #{sentinel})\n\"quoted\" 🦉")

    {verdict, captured, 0, _} = fake(dir, :echo, request)
    assert captured["message"]["content"] == [%{"type" => "text", "text" => request["body"]}]
    assert captured["client_composed"] == true
    assert captured["uuid"] == @uuid
    assert captured["session_id"] == @session
    refute Map.has_key?(captured, "environment")
    refute File.exists?(sentinel)
    assert verdict["observations"]["transport_echo"]
    refute verdict["observations"]["source_derived_uuid_correlation"]
    unsupported(verdict)
  end

  test "echo, duplicate echo and generic result never become durable proof", %{tmp_dir: dir} do
    for mode <- [:echo, :duplicate, :uncorrelated] do
      {verdict, _, 0, _} = fake(dir, mode)
      unsupported(verdict)
      refute verdict["observations"]["source_derived_uuid_correlation"]
    end
  end

  test "scalar and batched UUID correlation remain observations, not admission lookup", %{
    tmp_dir: dir
  } do
    for mode <- [:correlated, :batch] do
      {verdict, _, 0, _} = fake(dir, mode)
      assert verdict["observations"]["source_derived_uuid_correlation"]
      unsupported(verdict)
    end

    {verdict, _, 0, _} = fake(dir, :subagent)
    refute verdict["observations"]["source_derived_uuid_correlation"]
    unsupported(verdict)
  end

  test "EOF and truncated response stay uncertain without reinjection", %{tmp_dir: dir} do
    for mode <- [:eof, :partial] do
      {verdict, _, 1, state} = fake(dir, mode)
      unsupported(verdict)
      assert {:error, :uncertain, ^state} = Probe.input(state, @request)
      assert Probe.recover(@identity) == {:error, :unsupported}
    end
  end

  test "wrong session or UUID and permission requests cannot produce receipts", %{tmp_dir: dir} do
    for mode <- [:wrong_session, :wrong_uuid, :control] do
      {verdict, _, 0, _} = fake(dir, mode)
      assert verdict["error"] != nil
      unsupported(verdict)
    end
  end

  test "same ID duplicate is uncertain; changed immutable identity cannot send again" do
    {:ok, _, state} = Probe.input(state(), @request)
    assert {:error, :uncertain, ^state} = Probe.input(state, @request)

    for {field, value} <- [
          {"body", "other"},
          {"mode", "interrupt"},
          {"worker", "other"},
          {"environment", "elsewhere"},
          {"turn", "successor"},
          {"attempt", "other"}
        ] do
      assert {:error, :conflict, ^state} = Probe.input(state, Map.put(@request, field, value))

      if field != "body",
        do:
          assert(
            {:error, :invalid_input, _} = Probe.input(state(), Map.put(@request, field, value))
          )
    end
  end

  test "split UTF-8 and coalesced frames preserve bounded observations", %{tmp_dir: dir} do
    {_, captured, _, _} = fake(dir, :echo)
    line = JSON.encode!(Map.put(captured, "isReplay", true)) <> "\n"
    {:ok, _, initial} = Probe.input(state(), @request)
    {at, _} = :binary.match(line, "🦉")
    split = at + 2
    <<first::binary-size(split), rest::binary>> = line
    result = initial |> Probe.feed(first) |> Probe.feed(rest <> line) |> Probe.eof()
    assert Probe.verdict(result)["observations"]["transport_echo"]
    unsupported(Probe.verdict(result))
  end

  test "malformed/unknown/oversized frames latch bounded failure", %{tmp_dir: dir} do
    for mode <- [:malformed, :oversized] do
      {verdict, _, 1, _} = fake(dir, mode)
      assert verdict["error"] != nil
      unsupported(verdict)
    end

    {:ok, _, state} = Probe.input(state(), @request)
    failed = Probe.feed(state, ~s({"type":"invented_consumed_receipt"}\n))
    assert Probe.verdict(failed)["error"] == "invalid_frame"
    assert Probe.feed(failed, "ignored") == failed
    oversized = Probe.feed(state, String.duplicate("x", 65_537))
    assert oversized.partial == ""
    assert Probe.verdict(oversized)["error"] == "frame_too_large"
  end

  test "request bounds and malformed identities fail before encoding" do
    for body <- ["", <<255>>, String.duplicate("x", 24_576)] do
      assert {:error, :invalid_input, _} = Probe.input(state(), %{@request | "body" => body})
    end

    assert {:error, :unsupported_profile} =
             Probe.new("2.1.280", %{@identity | "attempt" => ""}, @session, @uuid)

    assert {:error, :unsupported_profile} =
             Probe.new("2.1.280", @identity, "not-a-session", @uuid)
  end

  test "missing session, unsolicited frames and malformed correlation fail closed" do
    {:ok, line, state} = Probe.input(state(), @request)
    replay = line |> JSON.decode!() |> Map.put("isReplay", true) |> Map.delete("session_id")

    assert Probe.verdict(Probe.feed(state, JSON.encode!(replay) <> "\n"))["error"] ==
             "invalid_frame"

    event = %{"type" => "result", "session_id" => @session, "user_message_uuid" => @uuid}

    assert Probe.verdict(Probe.feed(state(), JSON.encode!(event) <> "\n"))["error"] ==
             "no_pending_input"

    for ids <- [false, "invalid", List.duplicate(@uuid, 65), ["not-a-uuid"]] do
      bad = Map.put(event, "user_message_uuids", ids)
      verdict = Probe.verdict(Probe.feed(state, JSON.encode!(bad) <> "\n"))
      assert verdict["error"] == "invalid_correlation"
      unsupported(verdict)
    end
  end
end
