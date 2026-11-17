Code.require_file("fixtures.exs", __DIR__)

defmodule AtlasRuntime.History.BootHomeTest do
  # HR review R1: the history reads find the Runtime home that the host's boot
  # (`host/service.exs`) is given, also when `$ATLAS_RUNTIME_HOME` is unset, as the host
  # leaves it for the default home. The boot runs in a peer VM of this test's, without Mix:
  # the service refuses to start in a VM that owns a TCP listener (AtlasRuntime.ListenerCheck),
  # and this one runs under Mix, whose PubSub listens on loopback.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Boundary.History, as: Facade
  import AtlasRuntime.HistoryFixtures, only: [id: 1, turn!: 3]

  @moduletag capture_log: true
  @service_exs Path.expand("../../host/service.exs", __DIR__)
  @all {"local:admin", [:read, :read_all]}
  @owner {"local:owner", [:read]}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arb-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    File.mkdir_p!(dir)
    AtlasRuntime.WorkHarness.write_policy!(dir)
    env = System.get_env("ATLAS_RUNTIME_HOME")
    app = Application.get_env(:atlas_runtime, :runtime_home)
    System.delete_env("ATLAS_RUNTIME_HOME")
    Application.delete_env(:atlas_runtime, :runtime_home)

    on_exit(fn ->
      if env, do: System.put_env("ATLAS_RUNTIME_HOME", env)

      if app,
        do: Application.put_env(:atlas_runtime, :runtime_home, app),
        else: Application.delete_env(:atlas_runtime, :runtime_home)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Runs host/service.exs for `dir` in a process of its own in a peer VM, until it says it is
  # ready, and returns the peer. The peer is connected over its standard I/O (no distribution)
  # and has this VM's code paths and application environment, as the boot had in this VM.
  # Stopping the peer ends the boot's processes with it.
  defp boot!(dir) do
    erl = String.to_charlist(Path.join(:code.root_dir(), "bin/erl"))

    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, exec: erl, args: [~c"-pa" | :code.get_path()]})

    on_exit(fn -> :peer.stop(peer) end)
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:logger])

    env =
      for {app, _, _} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :compiler, :elixir, :logger, :mix, :hex, :ex_unit],
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [env, [persistent: true]])

    # The output's owner outlives the call, and the boot if it fails, so its output can be shown.
    boot = """
    parent = self()
    spawn(fn -> send(parent, StringIO.open("")) && Process.sleep(:infinity) end)
    {:ok, io} = receive(do: ({:ok, io} -> {:ok, io}))

    pid =
      spawn(fn ->
        Process.group_leader(self(), io)
        System.argv([dir])
        Code.eval_file(service)
      end)

    {io, pid}
    """

    {{io, pid}, _} =
      :peer.call(peer, Code, :eval_string, [boot, [dir: dir, service: @service_exs]])

    await_ready(peer, io, pid, System.monotonic_time(:millisecond) + 20_000)
    peer
  end

  defp await_ready(peer, io, pid, deadline) do
    {_in, out} = :peer.call(peer, StringIO, :contents, [io])

    cond do
      out =~ "Runtime ready" -> :ok
      not :peer.call(peer, Process, :alive?, [pid]) -> flunk("the boot ended: #{out}")
      System.monotonic_time(:millisecond) > deadline -> flunk("not ready: #{out}")
      true -> Process.sleep(20) && await_ready(peer, io, pid, deadline)
    end
  end

  test "after the host's boot, history reads through the started Service without $ATLAS_RUNTIME_HOME",
       %{dir: dir} do
    turn!(dir, id(1), %{})
    turn!(dir, id(2), %{"worker_id" => "beta"})

    peer = boot!(dir)
    assert :peer.call(peer, GenServer, :whereis, [AtlasRuntime.Service])
    assert :peer.call(peer, System, :get_env, ["ATLAS_RUNTIME_HOME"]) == nil

    assert %Facade.Outcome.Turns{turns: turns} =
             :peer.call(peer, Facade, :list_turns, [@all, %{}])

    assert Enum.map(turns, &{&1.turn_id, &1.slot}) == [{id(1), "alpha"}, {id(2), "beta"}]
    # Turns of no work: not the owner's.
    assert %Facade.Outcome.Turns{turns: []} = :peer.call(peer, Facade, :list_turns, [@owner, %{}])

    assert %Facade.Outcome.Found{} =
             :peer.call(peer, Facade, :get_turn, [@all, %{turn_id: id(2)}])
  end
end
