defmodule AtlasRuntime.ListenerCheckTest do
  @moduledoc """
  No network listener on an agent machine (the pull design): the service's ready-time check
  (`AtlasRuntime.ListenerCheck`, run by `host/service.exs`) counts this VM's TCP listen
  sockets, and the service started as the host starts it, without Mix, fails its start when
  one exists and is ready when none does.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.ListenerCheck

  @root Path.expand("../../..", __DIR__)
  @project Path.join(@root, "products/software_factory")
  @boot Path.join(@root, "platform/atlas_runtime/host/boot.exs")
  @service Path.join(@root, "platform/atlas_runtime/host/service.exs")

  describe "tcp_listeners/0 and verify/0" do
    test "count a TCP listen socket of either backend, until it closes" do
      for options <- [[], [inet_backend: :socket]] do
        {:ok, listen} = :gen_tcp.listen(0, options ++ [ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listen)

        assert port in ListenerCheck.tcp_listeners()
        assert {:error, %{reason: :tcp_listener, ports: ports}} = ListenerCheck.verify()
        assert port in ports

        :ok = :gen_tcp.close(listen)
        refute port in ListenerCheck.tcp_listeners()
      end
    end

    test "count a listening :socket, IPv6 included" do
      {:ok, socket} = :socket.open(:inet6, :stream, :tcp)
      :ok = :socket.bind(socket, %{family: :inet6, addr: {0, 0, 0, 0, 0, 0, 0, 1}, port: 0})
      {:ok, %{port: port}} = :socket.sockname(socket)
      refute port in ListenerCheck.tcp_listeners()

      :ok = :socket.listen(socket)
      assert port in ListenerCheck.tcp_listeners()
      :socket.close(socket)
    end

    test "do not count a connected TCP socket or a Unix-domain listener" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [])
      {:ok, accepted} = :gen_tcp.accept(listen)
      {:ok, client_port} = :inet.port(client)
      {:ok, accepted_port} = :inet.port(accepted)
      :ok = :gen_tcp.close(listen)

      # A Unix socket path is short (104 bytes on macOS).
      path = Path.join(System.tmp_dir!(), "alc-#{System.unique_integer([:positive])}.sock")
      on_exit(fn -> File.rm(path) end)
      {:ok, local} = :gen_tcp.listen(0, ifaddr: {:local, path})

      listeners = ListenerCheck.tcp_listeners()
      refute port in listeners
      refute client_port in listeners
      refute accepted_port in listeners
      assert Enum.all?(listeners, &is_integer/1)

      Enum.each([client, accepted, local], &:gen_tcp.close/1)
    end
  end

  describe "the service, started as the host starts it" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "alc-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "is ready with no TCP listener in its VM", %{dir: dir} do
      assert {:ready, _output} = start(dir, [])
    end

    test "fails its start on a TCP listener in its VM, with the reason and the port only",
         %{dir: dir} do
      listener = Path.join(dir, "listener.exs")
      File.write!(listener, "{:ok, _} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})\n")

      assert {:exited, status, output} = start(dir, ["-r", listener])
      assert status != 0
      refute output =~ "Runtime ready"

      assert [refusal] =
               for(
                 line <- String.split(output, "\n"),
                 [_, json] <- [Regex.run(~r/Runtime not ready: (\{.*\})$/, line)],
                 do: JSON.decode!(json)
               )

      assert %{"reason" => "tcp_listener", "ports" => [port]} = refusal
      assert map_size(refusal) == 2
      assert is_integer(port) and port > 0
    end
  end

  # `elixir`, not `mix run` (host/main.go, serviceCommands): this build's ebin paths, then
  # host/boot.exs, then host/service.exs for the home, in the umbrella project. `extra` is
  # required between the boot and the service.
  defp start(dir, extra) do
    build = Mix.Project.build_path()
    elixir = Path.expand(Path.join(:code.lib_dir(:elixir), "../../bin/elixir"))

    args =
      ["-pz", Path.join(build, "lib/*/ebin"), "-pa", Path.join(build, "consolidated")] ++
        ["-r", @boot] ++ extra ++ [@service, dir]

    env =
      for {k, v} <- [
            {"MIX_ENV", "test"},
            {"MIX_BUILD_PATH", build},
            {"ELIXIR_ERL_OPTIONS", "+S 2:2"},
            {"ATLAS_RUNTIME_HOME", false}
          ],
          do: {String.to_charlist(k), v && String.to_charlist(v)}

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: @project,
        env: env
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      await(port, "", System.monotonic_time(:millisecond) + 60_000)
    after
      System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      receive do: ({^port, {:exit_status, _}} -> :ok), after: (5_000 -> :ok)
    end
  end

  defp await(port, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if output =~ "Runtime ready; Atlas core services remain stopped",
          do: {:ready, output},
          else: await(port, output, deadline)

      {^port, {:exit_status, status}} ->
        send(self(), {port, {:exit_status, status}})
        {:exited, status, output}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("the service neither became ready nor exited:\n#{output}")
    end
  end
end
