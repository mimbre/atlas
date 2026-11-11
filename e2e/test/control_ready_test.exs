defmodule AtlasE2E.ControlReadyTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @contract Path.join(@root, "bff/targets/json/blocks.json")

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-ready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp endpoint(dir, reply) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn(fn -> accept(listener, reply) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    file = Path.join(dir, "test.json")

    File.write!(
      file,
      JSON.encode!(%{
        "env" => "test",
        "control" => %{"host" => "127.0.0.1", "port" => port},
        "fly" => %{
          "app" => "private-fixture",
          "rela_app" => "private-fixture-rela",
          "control_port" => 1,
          "local" => dir
        }
      })
    )

    file
  end

  defp accept(listener, reply) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, hello} -> reply.(socket, JSON.decode!(hello))
          _ -> :ok
        end

        :gen_tcp.close(socket)
        accept(listener, reply)

      {:error, :closed} ->
        :ok
    end
  end

  defp probe(file) do
    System.cmd("python3", [Path.join(@root, "fly/control-ready.py"), file, @contract],
      stderr_to_stdout: true
    )
  end

  test "a listening proxy that closes upstream is not ready", %{dir: dir} do
    file = endpoint(dir, fn _socket, _hello -> :ok end)
    assert {out, 1} = probe(file)
    assert out =~ "closed before Control answered"
  end

  test "a split welcome for the intended environment proves transport", %{dir: dir} do
    file =
      endpoint(dir, fn socket, hello ->
        :gen_tcp.send(socket, ~s({"op":"welcome",))

        :gen_tcp.send(
          socket,
          JSON.encode!(%{"env" => hello["env"], "spec" => "0.1.0"}) |> String.trim_leading("{")
        )

        :gen_tcp.send(socket, "\n")
      end)

    assert {"", 0} = probe(file)
  end

  test "a protocol refusal is reachable and must not cause proxy restart", %{dir: dir} do
    file =
      endpoint(dir, fn socket, _hello ->
        :gen_tcp.send(
          socket,
          JSON.encode!(%{"op" => "bye", "text" => "Update this client"}) <> "\n"
        )
      end)

    assert {"", 0} = probe(file)
  end

  test "a welcome for another environment is not ready", %{dir: dir} do
    file =
      endpoint(dir, fn socket, _hello ->
        :gen_tcp.send(socket, ~s({"op":"welcome","env":"prod","spec":"0.1.0"}\n))
      end)

    assert {out, 1} = probe(file)
    assert out =~ "for this environment"
  end

  test "partial traffic does not extend the handshake deadline", %{dir: dir} do
    file =
      endpoint(dir, fn socket, _hello ->
        for _ <- 1..5 do
          :gen_tcp.send(socket, " ")
          Process.sleep(1_000)
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert {out, 1} = probe(file)
    assert out =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 4_500
  end

  test "status distinguishes a broken upstream from a listening local proxy", %{dir: dir} do
    file = endpoint(dir, fn _socket, _hello -> :ok end)
    File.write!(Path.join(dir, "tunnel.pid"), System.pid())
    fly = Path.join(dir, "fly")
    File.write!(fly, "#!/bin/sh\n[ \"$1\" = status ] || exit 99\n")
    File.chmod!(fly, 0o755)

    {out, 0} =
      System.cmd(Path.join(@root, "bin/atlas-ops"), ["status", "--env", "test"],
        env: [
          {"ATLAS_ENV_FILE", file},
          {"ATLAS_NO_UPDATE", "1"},
          {"PATH", dir <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "tunnel: unavailable"
    refute out =~ "tunnel: open"
  end
end
