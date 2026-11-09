defmodule AtlasLearn.Observations.WorkerPassesTest do
  use ExUnit.Case, async: true
  alias AtlasLearn.Fixtures
  alias AtlasLearn.Observations.WorkerPasses

  test "turns that started or ended in the window are records; the others are context" do
    observation = WorkerPasses.observe(Fixtures.window(), read: Fixtures.runtime_read())

    assert observation.status == :read
    ids = Enum.map(observation.records, & &1.id)
    assert "turn-00000000000000a2" in ids
    assert "turn-00000000000000a7" in ids
    assert length(ids) == 6

    assert Enum.map(observation.context, & &1.id) |> Enum.sort() ==
             ["turn-00000000000000a1", "turn-00000000000000a8"]
  end

  test "a turn keeps its chain link, model and the first line of its error" do
    observation = WorkerPasses.observe(Fixtures.window(), read: Fixtures.runtime_read())
    failed = Enum.find(observation.records, &(&1.id == "turn-00000000000000a6"))

    assert failed.error == "codex exited with status 1"
    assert failed.model == "gpt-5"
    follow_up = Enum.find(observation.records, &(&1.id == "turn-00000000000000a3"))
    assert follow_up.source == "turn-00000000000000a2"
  end

  test "an unreachable or refusing Runtime is reported, not raised" do
    window = Fixtures.window()

    assert {:unavailable, "cannot reach" <> _} =
             WorkerPasses.observe(window, runtime_home: Fixtures.scratch("no-runtime")).status

    refusing = fn "turns" ->
      {:ok, %{"api" => "runtime.read/1", "error" => %{"code" => "read_failed"}}}
    end

    assert {:unavailable, "Runtime refused the read: read_failed"} =
             WorkerPasses.observe(window, read: refusing).status

    assert WorkerPasses.observe(window, []).status == :not_asked
  end

  test "reads `turns` from read.sock with one runtime.read/1 request" do
    home = Fixtures.scratch("rt")
    File.mkdir_p!(home)
    path = Path.join(home, "read.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    reply = File.read!(Path.expand("fixtures/runtime_turns.json", __DIR__))
    test = self()

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, request} = :gen_tcp.recv(socket, 0)
      send(test, {:request, request})
      # Sent in two parts, as a large reply may arrive.
      {first, rest} = String.split_at(JSON.encode!(JSON.decode!(reply)) <> "\n", 100)
      :ok = :gen_tcp.send(socket, first)
      :ok = :gen_tcp.send(socket, rest)
      :gen_tcp.close(socket)
    end)

    observation = WorkerPasses.observe(Fixtures.window(), runtime_home: home)
    assert_received {:request, request}
    assert JSON.decode!(request) == %{"api" => "runtime.read/1", "op" => "turns"}
    assert observation.status == :read
    assert length(observation.records) == 6
    :gen_tcp.close(listener)
  end
end
