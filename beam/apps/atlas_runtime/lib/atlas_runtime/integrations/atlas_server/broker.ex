defmodule AtlasRuntime.Agent.Claude.Broker do
  @moduledoc """
  The one way out of a turn's sandbox (IS-Atlas-94): the agent's `atlas` inside it is a
  few lines of bash that send their arguments here, on 127.0.0.1, with bash's own
  `/dev/tcp`; the sandbox lets it reach this port and nothing else. Outside the sandbox,
  this runs the build's `atlas` on the machine's instance, as the turn's agent, and sends
  back what it printed and its exit status.

  It refuses `--env` and any command but the allowed ones (`get list set`), as the wrapper
  of IS-Atlas-18 did. The instance and the agent are its own, not the caller's: nothing the
  agent sets in its environment reaches the command (`ATLAS_AS`, `ATLAS_ENV_FILE`).

  The wire, both ways NUL-separated: the caller sends its argument count, then each
  argument; the answer is the output, then the exit status.
  """

  require Logger

  @read 10_000
  @run 120_000

  @doc """
  Listen for one turn, on a free port of 127.0.0.1: `{:ok, %{socket: s, port: p}}`. The
  calling process owns the socket: when it ends, so does the broker.
  """
  def open(%{atlas: atlas, env_file: file} = config)
      when is_binary(atlas) and is_binary(file) and file != "" do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    spawn_link(fn -> accept(socket, config) end)
    {:ok, %{socket: socket, port: port}}
  end

  def open(_config), do: {:error, :no_instance}

  defp accept(socket, config) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, pid} = Task.start(fn -> serve(client, config) end)
        :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(socket, config)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(client, config) do
    receive do
      :go -> :ok
    end

    {output, status} =
      case read(client, "") do
        {:ok, args} -> answer(args, config)
        :error -> {"atlas (turn): the broker got no command\n", 2}
      end

    :gen_tcp.send(client, [output, 0, Integer.to_string(status), 0])
    :gen_tcp.close(client)
  end

  # Its count, then that many arguments, each ending in NUL.
  defp read(client, got) do
    with [count | rest] <- :binary.split(got, <<0>>, [:global]),
         {n, ""} <- Integer.parse(count),
         true <- length(rest) > n do
      {:ok, Enum.take(rest, n)}
    else
      _ ->
        case :gen_tcp.recv(client, 0, @read) do
          {:ok, more} -> read(client, got <> more)
          {:error, _} -> :error
        end
    end
  end

  @doc "What the turn's `atlas` answers for `args`: `{output, exit status}`."
  def answer(args, config) do
    allowed = String.split(config[:allowed] || "get list set")

    cond do
      Enum.any?(args, &(&1 == "--env" or String.starts_with?(&1, "--env="))) ->
        {"atlas (turn): refused: --env; this turn works on its own instance only\n", 2}

      List.first(args) not in allowed ->
        {"atlas (turn): refused: only atlas #{Enum.join(allowed, ", ")}\n", 2}

      true ->
        run(args, config)
    end
  end

  @doc "The build's `atlas` with `args`, on the instance, as the agent: `{output, status}`."
  def run(args, config) do
    env = [
      {"ATLAS_ENV_FILE", config.env_file},
      {"ATLAS_AS", config[:agent] || ""},
      {"ATLAS_NO_UPDATE", "1"}
    ]

    task =
      Task.async(fn ->
        try do
          System.cmd(config.atlas, args,
            env: env,
            stderr_to_stdout: true,
            cd: config[:folder] || File.cwd!()
          )
        rescue
          # No atlas there, or it cannot run: an answer like any other failure.
          error in ErlangError ->
            {"atlas (turn): atlas did not run: #{inspect(error.original)}\n", 2}
        end
      end)

    case Task.yield(task, @run) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _ ->
        Logger.warning("runtime: atlas #{Enum.join(args, " ")} ran longer than #{@run} ms")
        {"atlas (turn): it ran longer than #{div(@run, 1000)} s\n", 2}
    end
  end
end
