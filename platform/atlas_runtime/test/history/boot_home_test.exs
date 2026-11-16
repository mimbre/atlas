Code.require_file("fixtures.exs", __DIR__)

defmodule AtlasRuntime.History.BootHomeTest do
  # HR review R1: the history reads find the Runtime home that the host's boot
  # (`host/service.exs`) is given, also when `$ATLAS_RUNTIME_HOME` is unset, as the host
  # leaves it for the default home. The boot runs in this BEAM; nothing else starts it.
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
    argv = System.argv()
    System.delete_env("ATLAS_RUNTIME_HOME")
    Application.delete_env(:atlas_runtime, :runtime_home)

    on_exit(fn ->
      System.argv(argv)
      if env, do: System.put_env("ATLAS_RUNTIME_HOME", env)

      if app,
        do: Application.put_env(:atlas_runtime, :runtime_home, app),
        else: Application.delete_env(:atlas_runtime, :runtime_home)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Runs host/service.exs for `dir` in a process of its own, until it says it is ready.
  defp boot!(dir) do
    {:ok, io} = StringIO.open("")

    pid =
      spawn(fn ->
        Process.group_leader(self(), io)
        System.argv([dir])
        Code.eval_file(@service_exs)
      end)

    ref = Process.monitor(pid)
    on_exit(fn -> halt(pid) end)
    await_ready(io, ref, System.monotonic_time(:millisecond) + 20_000)
  end

  defp await_ready(io, ref, deadline) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> flunk("the boot ended: #{inspect(reason)}")
    after
      20 ->
        {_in, out} = StringIO.contents(io)

        cond do
          out =~ "Runtime ready" -> :ok
          System.monotonic_time(:millisecond) > deadline -> flunk("not ready: #{out}")
          true -> await_ready(io, ref, deadline)
        end
    end
  end

  # The boot's processes are linked to it (the Service, the work core and the listener) and
  # end with it; the listener reports its parent's kill.
  defp halt(pid) do
    ExUnit.CaptureLog.capture_log(fn ->
      {:links, linked} = Process.info(pid, :links) || {:links, []}
      refs = for p <- [pid | linked], is_pid(p), do: {Process.monitor(p), p}
      Process.exit(pid, :kill)
      for {ref, p} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^p, _}, 5_000)
    end)
  end

  test "after the host's boot, history reads through the started Service without $ATLAS_RUNTIME_HOME",
       %{dir: dir} do
    turn!(dir, id(1), %{})
    turn!(dir, id(2), %{"worker_id" => "beta"})

    boot!(dir)
    assert GenServer.whereis(AtlasRuntime.Service)
    assert System.get_env("ATLAS_RUNTIME_HOME") == nil

    assert %Facade.Outcome.Turns{turns: turns} = Facade.list_turns(@all, %{})
    assert Enum.map(turns, &{&1.turn_id, &1.slot}) == [{id(1), "alpha"}, {id(2), "beta"}]
    # Turns of no work: not the owner's.
    assert %Facade.Outcome.Turns{turns: []} = Facade.list_turns(@owner, %{})
    assert %Facade.Outcome.Found{} = Facade.get_turn(@all, %{turn_id: id(2)})
  end
end
