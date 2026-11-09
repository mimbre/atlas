defmodule AtlasE2E.RelaStopTest do
  # rela/scripts/stop.sh on its own: it stops rela by the pid file start-bg.sh writes, and
  # signals that pid only while it is the one listening on rela's port; it lists no
  # processes (a sandboxed worker may not). The stand-in rela is a listener on a free port
  # that says its port once it listens.
  use ExUnit.Case, async: true

  @stop Path.expand("../../rela/scripts/stop.sh", __DIR__)
  @listener ~S"""
  use IO::Socket::INET; $| = 1;
  my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or die;
  print $s->sockport, "\n"; sleep;
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-rela-stop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp listener do
    port =
      Port.open({:spawn_executable, System.find_executable("perl")}, [
        :binary,
        :exit_status,
        line: 64,
        args: ["-e", @listener]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true) end)
    assert_receive {^port, {:data, {:eol, listening}}}, 10_000
    {port, pid, listening}
  end

  defp stop(dir, rela_port, pid) do
    File.write!(Path.join(dir, "rela-server.pid"), "#{pid}\n")

    System.cmd("bash", [@stop],
      env: [{"ATLAS_TEST_ROOT", dir}, {"ATLAS_RELA_PORT", rela_port}],
      stderr_to_stdout: true
    )
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  test "the pid in the pid file, listening on rela's port, is stopped and the file goes", %{
    dir: dir
  } do
    {port, pid, listening} = listener()
    assert {_, 0} = stop(dir, listening, pid)
    assert_receive {^port, {:exit_status, _}}, 10_000
    refute File.exists?(Path.join(dir, "rela-server.pid"))
  end

  test "a live pid that does not listen on rela's port is not signalled; its file stays", %{
    dir: dir
  } do
    {_rela, _rela_pid, listening} = listener()
    {other, other_pid, _} = listener()

    assert {_, 1} = stop(dir, listening, other_pid)
    assert alive?(other_pid)
    refute_received {^other, {:exit_status, _}}
    assert File.exists?(Path.join(dir, "rela-server.pid"))
  end

  test "a pid that no longer runs: the stale file goes, nothing is signalled", %{dir: dir} do
    {port, pid, listening} = listener()
    System.cmd("kill", ["-KILL", "#{pid}"])
    assert_receive {^port, {:exit_status, _}}, 10_000

    assert {_, 0} = stop(dir, listening, pid)
    refute File.exists?(Path.join(dir, "rela-server.pid"))
  end

  test "no pid file: nothing to stop, an error", %{dir: dir} do
    assert {_, 1} =
             System.cmd("bash", [@stop],
               env: [{"ATLAS_TEST_ROOT", dir}, {"ATLAS_RELA_PORT", "1"}],
               stderr_to_stdout: true
             )
  end
end
