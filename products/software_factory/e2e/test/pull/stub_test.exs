Code.require_file("support.exs", __DIR__)

defmodule AtlasE2E.Pull.StubTest do
  @moduledoc """
  The stub (`pull/stub/main.go`): its `session --` mode gives a child a group of its own,
  and its agent mode acts only on its gate's command, reports in order, and writes the
  bytes the bench computes. Structure only.
  """
  use ExUnit.Case, async: true

  alias AtlasE2E.Pull.{Await, Fixture, Hub, Reader, Stub}
  alias AtlasE2E.PullTest.Support

  setup_all do
    %{stub: Support.stub!()}
  end

  test "the child's pgid is its pid and differs from the caller's", %{stub: stub} do
    # sh prints the ids of a child in its own group, then becomes the session helper.
    {out, 0} = System.cmd("/bin/sh", ["-c", ~s("$0" ids; exec "$0" session -- "$0" ids), stub])
    [caller, session, child] = out |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert session["session"] == child["pid"]
    assert child["pgid"] == child["pid"] and child["sid"] == child["pid"]
    refute child["pgid"] == caller["pgid"]
  end

  test "session prints its line first and exits with the child's status", %{stub: stub} do
    {out, 3} = System.cmd(stub, ["session", "--", "/bin/sh", "-c", "echo child; exit 3"])
    assert [first, "child"] = String.split(out, "\n", trim: true)
    assert %{"session" => pid} = JSON.decode!(first)
    assert is_integer(pid)
  end

  defp agent(stub, goal) do
    run = Support.tmp!("agent")
    hub = Support.hub!()
    ws = Path.join(run, "ws")
    File.mkdir_p!(Path.join(ws, "atlas/fixture"))
    File.write!(Path.join(ws, "atlas/fixture/base-2mib.bin"), "base bytes")
    File.write!(Path.join(ws, "atlas/README.md"), "# readme\n")
    bin = Path.join(run, "bin")
    Stub.wrappers!(bin, run, stub)
    reader = Stub.events!(run, stub: stub, hub: hub)

    on_exit(fn ->
      Reader.stop(reader)
      File.rm_rf!(run)
    end)

    # Tethered: if this test's BEAM ends however it ends, the agent ends with it.
    port =
      Port.open({:spawn_executable, stub}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "tether",
          "--",
          Path.join(bin, "codex"),
          "exec",
          "--cd",
          ws,
          "--json",
          "--output-last-message",
          Path.join(run, "answer.txt"),
          "--",
          goal
        ]
      ])

    # A test that fails leaves no agent: its end closes the Port, and the tether KILLs it.
    %{run: run, hub: hub, ws: ws, port: port, stub: stub}
  end

  defp event(a, name), do: Await.event(0, &Stub.event?(&1, name), hub: a.hub)

  defp output(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> output(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    end
  end

  test "no edit before the gate command; started, gated, ended in that order", %{stub: stub} do
    a = agent(stub, "A type-safe build: pe-s9 now")
    started = event(a, "started")
    assert %{"token" => "pe-s9", "root" => "atlas"} = started.data
    assert started.data["base_sha256"] == Fixture.sha_of("base bytes")
    assert File.exists?(started.data["gate"])
    refute File.exists?(Path.join(a.ws, "atlas/README.pull"))
    assert File.exists?(Path.join(a.ws, "atlas/README.md"))

    :ok =
      Stub.gate(
        a.run,
        started.data,
        Stub.complete([Stub.write("README.pull", "x\n"), Stub.delete("README.md")], "the answer"),
        stub: a.stub
      )

    event(a, "ended")
    {out, 0} = output(a.port)

    events = Hub.select(0, &(&1.source == :stub), a.hub) |> Enum.map(& &1.data["event"])
    assert events == ["started", "gated", "ended"]
    # Its gate is gone once read (F2): nothing is left for a reaper to write to.
    refute File.exists?(started.data["gate"])
    assert File.read!(Path.join(a.ws, "atlas/README.pull")) == "x\n"
    refute File.exists?(Path.join(a.ws, "atlas/README.md"))
    assert File.read!(Path.join(a.run, "answer.txt")) == "the answer"
    types = out |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["type"])
    assert types == ["thread.started", "item.completed", "turn.completed"]
    # Its start is in the registry, for the reaper.
    assert Enum.any?(
             AtlasE2E.Pull.Bench.registry(a.run),
             &(&1["what"] == "stub" and &1["pid"] == started.data["pid"])
           )
  end

  test "a blob edit writes the bytes the bench computes", %{stub: stub} do
    a = agent(stub, "pe-s7b")
    started = event(a, "started")

    :ok =
      Stub.gate(a.run, started.data, Stub.complete([Stub.blob("big.bin", 100_003, 7)]),
        stub: a.stub
      )

    event(a, "ended")
    {_, 0} = output(a.port)
    bytes = File.read!(Path.join(a.ws, "atlas/big.bin"))
    assert byte_size(bytes) == 100_003
    assert Fixture.sha_of(bytes) == Fixture.sha(100_003, 7)
  end

  test "a signal while it waits ends it signalled, not ended", %{stub: stub} do
    a = agent(stub, "pe-s8")
    started = event(a, "started")
    assert AtlasE2E.Pull.Bench.signal(started.data["pid"], "TERM")
    event(a, "signalled")
    {_, status} = output(a.port)
    assert status == 128 + 15
    assert Hub.select(0, &Stub.event?(&1, "ended"), a.hub) == []
    refute File.exists?(started.data["gate"])
  end

  @tag timeout: 30_000
  test "gate never blocks: no agent at the gate, or no gate, exits 3 at once (F2)", %{stub: stub} do
    dir = Support.tmp!("gate")
    gate = Path.join(dir, "gate")
    {_, 0} = System.cmd("mkfifo", [gate])
    assert {_, 3} = Support.tethered(stub, ["gate", gate, ~s({"cmd":"fail"})])
    assert {_, 3} = Support.tethered(stub, ["gate", Path.join(dir, "none"), ~s({"cmd":"fail"})])

    File.rm_rf!(dir)
  end

  test "codex sandbox runs the command in the folder it names", %{stub: stub} do
    dir = Support.tmp!("sandbox")

    {out, 0} =
      System.cmd(stub, [
        "agent",
        dir,
        Path.join(dir, "codex"),
        "sandbox",
        "-P",
        "atlas_folder",
        "-C",
        dir,
        "--",
        "/bin/sh",
        "-c",
        "pwd -P"
      ])

    assert String.trim(out) == dir
    File.rm_rf!(dir)
  end
end
