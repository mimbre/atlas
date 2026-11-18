defmodule AtlasRuntime.ListenerCheckTest do
  @moduledoc """
  No network listener on an agent machine (the pull design): the service's ready-time check
  (`AtlasRuntime.ListenerCheck`, run by `host/service.exs`) counts this VM's IP listen
  sockets, however they were opened, and the service started as the host starts it, without
  Mix, fails its start when one exists and is ready when none does.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.ListenerCheck

  @root Path.expand("../../..", __DIR__)
  @project Path.join(@root, "products/software_factory")
  @boot Path.join(@root, "platform/atlas_runtime/host/boot.exs")
  @service Path.join(@root, "platform/atlas_runtime/host/service.exs")

  @loopback4 {127, 0, 0, 1}
  @loopback6 {0, 0, 0, 0, 0, 0, 0, 1}

  # Each opens one IP listen socket on loopback, port 0, as Elixir code.
  @listeners %{
    "gen_tcp" => "{:ok, _} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})",
    "gen_tcp, socket backend" =>
      "{:ok, _} = :gen_tcp.listen(0, inet_backend: :socket, ip: {127, 0, 0, 1})",
    ":socket inet, default protocol" => """
    {:ok, s} = :socket.open(:inet, :stream)
    :ok = :socket.bind(s, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    :ok = :socket.listen(s)
    """,
    ":socket inet, protocol tcp" => """
    {:ok, s} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.bind(s, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    :ok = :socket.listen(s)
    """,
    ":socket inet6, default protocol" => """
    {:ok, s} = :socket.open(:inet6, :stream)
    :ok = :socket.bind(s, %{family: :inet6, addr: {0, 0, 0, 0, 0, 0, 0, 1}, port: 0})
    :ok = :socket.listen(s)
    """
  }

  describe "ip_listeners/0 and verify/0" do
    test "count a gen_tcp listen socket of either backend, until it closes" do
      for options <- [[], [inet_backend: :socket]] do
        {:ok, listen} = :gen_tcp.listen(0, options ++ [ip: @loopback4])
        {:ok, port} = :inet.port(listen)

        assert port in ListenerCheck.ip_listeners()
        assert {:error, %{reason: :ip_listener, ports: ports}} = ListenerCheck.verify()
        assert port in ports

        :ok = :gen_tcp.close(listen)
        refute port in ListenerCheck.ip_listeners()
      end
    end

    test "skip a gen_tcp port whose info is gone as it closes, whatever :inet.info/1 returns" do
      {:ok, listen} = :gen_tcp.listen(0, ip: @loopback4)
      {:ok, port} = :inet.port(listen)

      # What `:inet.info/1` itself returns for a port that is no inet socket: a map without
      # `:states`. It returns the same for an inet port that closes between its own two reads,
      # as one in `Port.list/0` did in CI run 44203281242.
      other = :erlang.open_port({:spawn_driver, ~c"ram_file_drv"}, [:binary])
      no_states = :inet.info(other)
      true = Port.close(other)
      refute Map.has_key?(no_states, :states)

      seen = ListenerCheck.ip_listeners()
      assert port in seen

      answers = [no_states, %{states: [:closed]}, %{states: :undefined}, nil, :undefined, :raise]

      for gone <- answers do
        listeners =
          ListenerCheck.ip_listeners(fn
            ^listen when gone == :raise -> raise ArgumentError
            ^listen -> gone
            other -> :inet.info(other)
          end)

        assert count(listeners, port) == count(seen, port) - 1, inspect(gone)
      end

      :ok = :gen_tcp.close(listen)
    end

    test "count a listening :socket whatever its protocol, IPv6 included" do
      for {domain, address} <- [inet: @loopback4, inet6: @loopback6],
          protocol <- [:default, :tcp, 0] do
        {:ok, socket} =
          if protocol == :default,
            do: :socket.open(domain, :stream),
            else: :socket.open(domain, :stream, protocol)

        :ok = :socket.bind(socket, %{family: domain, addr: address, port: 0})
        {:ok, %{port: port}} = :socket.sockname(socket)
        refute port in ListenerCheck.ip_listeners(), "#{domain} #{protocol}: bound only"

        :ok = :socket.listen(socket)
        assert port in ListenerCheck.ip_listeners(), "#{domain} #{protocol}: listening"
        assert {:error, %{reason: :ip_listener, ports: ports}} = ListenerCheck.verify()
        assert port in ports

        :ok = :socket.close(socket)
        refute port in ListenerCheck.ip_listeners(), "#{domain} #{protocol}: closed"
      end
    end

    test "count a :socket the registry does not hold, as it cannot be looked at" do
      before = ListenerCheck.unregistered_sockets()
      {:ok, socket} = :socket.open(:inet, :stream, %{use_registry: false})
      :ok = :socket.bind(socket, %{family: :inet, addr: @loopback4, port: 0})
      :ok = :socket.listen(socket)

      assert ListenerCheck.unregistered_sockets() >= before + 1

      :ok = :socket.close(socket)
    end

    test "do not count connected sockets or Unix-domain listeners of either backend" do
      {:ok, listen} = :gen_tcp.listen(0, ip: @loopback4)
      {:ok, port} = :inet.port(listen)
      {:ok, client} = :gen_tcp.connect(@loopback4, port, [])
      {:ok, accepted} = :gen_tcp.accept(listen)
      {:ok, client_port} = :inet.port(client)
      {:ok, accepted_port} = :inet.port(accepted)
      {:ok, outbound} = :socket.open(:inet, :stream)
      :ok = :socket.connect(outbound, %{family: :inet, addr: @loopback4, port: port})
      {:ok, %{port: outbound_port}} = :socket.sockname(outbound)
      :ok = :gen_tcp.close(listen)

      # A Unix socket path is short (104 bytes on macOS).
      [path, socket_path] =
        for _ <- 1..2,
            do: Path.join(System.tmp_dir!(), "alc-#{System.unique_integer([:positive])}.sock")

      on_exit(fn -> Enum.each([path, socket_path], &File.rm/1) end)
      {:ok, local} = :gen_tcp.listen(0, ifaddr: {:local, path})
      {:ok, local_socket} = :socket.open(:local, :stream)
      :ok = :socket.bind(local_socket, %{family: :local, path: socket_path})
      :ok = :socket.listen(local_socket)

      listeners = ListenerCheck.ip_listeners()
      refute port in listeners
      refute client_port in listeners
      refute accepted_port in listeners
      refute outbound_port in listeners
      assert Enum.all?(listeners, &is_integer/1)

      Enum.each([client, accepted, local], &:gen_tcp.close/1)
      Enum.each([outbound, local_socket], &:socket.close/1)
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

    test "is ready with no IP listener in its VM", %{dir: dir} do
      assert {:ready, _output} = start(Path.join(dir, "home"), [])
    end

    test "is ready with Unix-domain listeners and an outbound connection in its VM",
         %{dir: dir} do
      # The outbound connection goes to this test VM, from the service's.
      {:ok, listen} = :gen_tcp.listen(0, ip: @loopback4)
      {:ok, port} = :inet.port(listen)

      script =
        write(dir, "unix_and_outbound.exs", """
        {:ok, _} = :gen_tcp.listen(0, ifaddr: {:local, #{inspect(Path.join(dir, "g.sock"))}})
        {:ok, s} = :socket.open(:local, :stream)
        :ok = :socket.bind(s, %{family: :local, path: #{inspect(Path.join(dir, "s.sock"))}})
        :ok = :socket.listen(s)
        {:ok, _} = :gen_tcp.connect({127, 0, 0, 1}, #{port}, [])
        {:ok, o} = :socket.open(:inet, :stream)
        :ok = :socket.connect(o, %{family: :inet, addr: {127, 0, 0, 1}, port: #{port}})
        """)

      assert {:ready, _output} = start(Path.join(dir, "home"), ["-r", script])
      :gen_tcp.close(listen)
    end

    test "keeps only the loaded applications loadable, as Mix prunes the code path",
         %{dir: dir} do
      # Each line fails the start if the module is still loadable after host/boot.exs.
      script =
        write(dir, "pruned.exs", """
        {:error, _} = Code.ensure_loaded(:ssh)
        {:error, _} = Code.ensure_loaded(:observer)
        {:error, _} = Code.ensure_loaded(Mix.Project)
        {:module, _} = Code.ensure_loaded(AtlasRuntime.ListenerCheck)
        """)

      assert {:ready, _output} = start(Path.join(dir, "home"), ["-r", script])
    end

    test "fails its start on an IP listener in its VM, however it was opened, with the reason and the port only",
         %{dir: dir} do
      results =
        @listeners
        |> Enum.with_index()
        |> Task.async_stream(
          fn {{name, code}, index} ->
            script = write(dir, "listener-#{index}.exs", code)
            {name, start(Path.join(dir, "home-#{index}"), ["-r", script])}
          end,
          timeout: 90_000,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {name, result} <- results do
        assert {:exited, status, output} = result, "#{name}: #{inspect(result)}"
        assert status != 0, name
        refute output =~ "Runtime ready", name
        assert match?([_], refusals(output)), "#{name}:\n#{output}"
        [refusal] = refusals(output)
        assert %{"reason" => "ip_listener", "ports" => [port]} = refusal, name
        assert map_size(refusal) == 2, name
        assert is_integer(port) and port > 0, name
      end
    end

    test "fails its start on a :socket outside the registry", %{dir: dir} do
      script =
        write(dir, "unregistered.exs", """
        {:ok, s} = :socket.open(:inet, :stream, %{use_registry: false})
        :ok = :socket.bind(s, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
        :ok = :socket.listen(s)
        """)

      assert {:exited, status, output} = start(Path.join(dir, "home"), ["-r", script])
      assert status != 0
      refute output =~ "Runtime ready"
      assert match?([_], refusals(output)), output
      [refusal] = refusals(output)
      assert %{"reason" => "unregistered_socket", "sockets" => unseen} = refusal
      assert map_size(refusal) == 2
      assert is_integer(unseen) and unseen > 0
    end
  end

  # The refusal is the JSON object that ends a log line: found by its structure, not its
  # wording.
  defp refusals(output) do
    for line <- String.split(output, "\n"),
        [_, json] <- [Regex.run(~r/(\{.*\})\s*$/, line)],
        {:ok, %{"reason" => _} = refusal} <- [JSON.decode(json)],
        do: refusal
  end

  defp count(ports, port), do: Enum.count(ports, &(&1 == port))

  defp write(dir, name, code) do
    path = Path.join(dir, name)
    File.write!(path, code)
    path
  end

  # `elixir`, not `mix run` (host/main.go, serviceCommands): this build's ebin paths, then
  # host/boot.exs, then host/service.exs for the home, in the umbrella project. `extra` is
  # required between the boot and the service.
  defp start(home, extra) do
    File.mkdir_p!(home)
    build = Mix.Project.build_path()
    elixir = Path.expand(Path.join(:code.lib_dir(:elixir), "../../bin/elixir"))

    args =
      ["-pz", Path.join(build, "lib/*/ebin"), "-pa", Path.join(build, "consolidated")] ++
        ["-r", @boot] ++ extra ++ [@service, home]

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
