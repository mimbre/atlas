defmodule AtlasRuntime.RuntimeHomeSocketsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.{Service, TestHost}

  @moduletag capture_log: true

  # S2 removed read.sock (design 2026-11-16-runtime-backend §11, §13 S2): history is read
  # through the history contract on backend.sock and the journal on runtime.sock.
  test "a booted Service binds runtime.sock and no read.sock" do
    dir = TestHost.short_dir!("arh", "/runtime.sock")
    {:ok, pid} = GenServer.start(Service, dir)

    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end)

    assert {:ok, %File.Stat{type: :other}} = File.stat(Path.join(dir, "runtime.sock"))
    refute File.exists?(Path.join(dir, "read.sock"))

    assert {:error, _} =
             :gen_tcp.connect({:local, Path.join(dir, "read.sock")}, 0, [:binary], 1_000)

    assert dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".sock")) == ["runtime.sock"]
  end
end
