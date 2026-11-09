Code.require_file("../../../transport/test/support/tls_fixture.ex", __DIR__)

defmodule AtlasTui.ControlTLSTest do
  use ExUnit.Case, async: false
  alias AtlasControlTLSFixture, as: TLS
  alias AtlasTui.{Protocol, WorkerOutputConnection}

  setup context do
    fallback = if context[:without_tmpdir], do: TLS.without_tmpdir()
    fixture = TLS.setup()
    if fallback, do: assert(Path.dirname(fixture.dir) == fallback)
    fixture
  end

  @tag timeout: 30_000
  @tag :without_tmpdir
  test "terminal App uses TLS, handles remote closure and closes TLS on quit", %{dir: dir} do
    {:ok, listener} = TLS.listener(dir)
    TLS.select(listener)
    server = "atlas-tls-#{System.unique_integer([:positive])}"
    tmux_socket = Path.join(System.get_env("TMPDIR") || System.tmp_dir!(), server)

    on_exit(fn ->
      :ssl.close(listener)
      System.cmd("tmux", ["-S", tmux_socket, "kill-server"], stderr_to_stdout: true)
      File.rm(tmux_socket)
      refute File.exists?(tmux_socket)
    end)

    expression =
      "Application.ensure_all_started(:ssl); " <>
        ":public_key.cacerts_load(#{inspect(String.to_charlist(Path.join(dir, "ca.pem")))}); " <>
        ":inet_db.set_lookup([:file]); " <>
        ":inet_db.add_host({127,0,0,1}, [#{inspect(String.to_charlist(TLS.host()))}]); " <>
        "parent = self(); spawn(fn -> wait = fn wait -> " <>
        "if File.exists?(#{inspect(Path.join(dir, "quit"))}), do: send(parent, {:input, <<3>>}), " <>
        "else: (Process.sleep(20); wait.(wait)) end; wait.(wait) end); " <>
        "AtlasTui.App.run(\"test\", %{\"control\" => %{}, \"reconcile_seconds\" => 60})"

    # Encode the expression so shell quoting cannot alter the literal test certificate path.
    encoded = Base.encode64(expression)

    command =
      "#{System.find_executable("mix")} run -e 'Code.eval_string(Base.decode64!(\"#{encoded}\"))'"

    {output, status} =
      System.cmd("tmux", ["-S", tmux_socket, "new-session", "-d", "-s", "console", "sleep 60"],
        stderr_to_stdout: true
      )

    assert status == 0, output

    {_, 0} =
      System.cmd(
        "tmux",
        ["-S", tmux_socket, "set-option", "-t", "console", "remain-on-exit", "on"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("tmux", ["-S", tmux_socket, "respawn-pane", "-k", "-t", "console", command],
        stderr_to_stdout: true
      )

    accepted = :ssl.transport_accept(listener, 10_000)

    if not match?({:ok, _}, accepted) do
      {screen, _} =
        System.cmd("tmux", ["-S", tmux_socket, "capture-pane", "-p", "-t", "console"],
          stderr_to_stdout: true
        )

      flunk("terminal TLS connection failed: #{inspect(accepted)}; #{screen}")
    end

    {:ok, accepted} = accepted
    {:ok, socket} = :ssl.handshake(accepted, 2_000)
    assert TLS.read(socket)["surface"] == "console"

    TLS.send_line(socket, %{
      "op" => "welcome",
      "env" => "test",
      "surface" => "console",
      "spec" => Protocol.version()
    })

    TLS.send_line(socket, TLS.page())
    assert TLS.read(socket)["op"] == "boot"
    :ssl.close(socket)
    {:ok, accepted} = :ssl.transport_accept(listener, 5_000)
    {:ok, reconnected} = :ssl.handshake(accepted, 2_000)
    assert TLS.read(reconnected)["op"] == "hello"
    # Inject the same parsed input event independently of the terminal driver's ISIG mode.
    File.write!(Path.join(dir, "quit"), "quit")
    assert {:error, :closed} = :ssl.recv(reconnected, 0, 3_000)
  end

  test "output TLS sends Console hello, becomes ready and closes independently", %{dir: dir} do
    {:ok, listener} = TLS.listener(dir)
    TLS.select(listener)
    settings = %{"control" => %{"host" => "127.0.0.1", "port" => 1}}
    {:ok, {pid, monitor}} = WorkerOutputConnection.start_monitor(self(), "test", settings)
    {:ok, accepted} = :ssl.transport_accept(listener, 2_000)
    {:ok, socket} = :ssl.handshake(accepted, 2_000)
    assert TLS.read(socket) == AtlasTui.Console.hello(%{env: "test"})

    TLS.send_line(socket, %{
      "op" => "welcome",
      "env" => "test",
      "surface" => "console",
      "spec" => Protocol.version()
    })

    TLS.send_line(socket, TLS.page())
    assert_receive {:worker_output_connection, ^pid, :ready}, 1_000
    WorkerOutputConnection.stop(pid)
    assert_receive {:worker_output_connection, ^pid, {:closed, :stopped}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert {:error, :closed} = :ssl.recv(socket, 0, 1_000)
    :ssl.close(listener)
  end

  test "output reports remote TLS closure and wrong-host connection failure", %{dir: dir} do
    for host <- [TLS.host(), "wrong.tail8263c4.ts.net"] do
      {:ok, listener} = TLS.listener(dir)
      TLS.select(listener, host)

      {:ok, {pid, monitor}} =
        WorkerOutputConnection.start_monitor(self(), "test", %{"control" => %{}})

      {:ok, accepted} = :ssl.transport_accept(listener, 2_000)

      if host == TLS.host() do
        {:ok, socket} = :ssl.handshake(accepted, 2_000)
        assert TLS.read(socket)["op"] == "hello"
        :ssl.close(socket)
        assert_receive {:worker_output_connection, ^pid, {:closed, :closed}}, 1_000
      else
        assert {:error, _} = :ssl.handshake(accepted, 2_000)
        assert_receive {:worker_output_connection, ^pid, {:closed, {:connect, _}}}, 1_000
      end

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      :ssl.close(listener)
    end
  end
end
