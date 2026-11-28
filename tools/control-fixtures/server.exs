Code.require_file("scenarios.exs", __DIR__)

defmodule ControlFixtures.Server do
  @moduledoc false
  alias ControlFixtures.Scenarios

  def run(scenario, port) do
    {:ok, listener} = :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    IO.puts("Control fixture #{scenario} listening on 127.0.0.1:#{port}")
    accept(listener, scenario)
  end

  defp accept(listener, scenario) do
    {:ok, socket} = :gen_tcp.accept(listener)
    pid = spawn(fn -> receive do :ready -> session(socket, scenario) end end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :ready)
    accept(listener, scenario)
  end

  defp session(socket, scenario), do: receive_line(socket, %{hello: false, surface: nil, path: Scenarios.initial(scenario), scenario: scenario})

  defp receive_line(socket, state) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        case JSON.decode(line) do
          {:ok, message} when is_map(message) ->
            case handle(socket, message, state) do
              {:ok, next} -> receive_line(socket, next)
              :close -> :gen_tcp.close(socket)
            end
          _ -> close(socket, "Invalid JSON request")
        end
      {:error, _} -> :gen_tcp.close(socket)
    end
  end

  defp handle(socket, %{"op" => "hello", "env" => "test", "client" => client, "spec" => spec} = request, %{hello: false} = state) when is_binary(client) and is_binary(spec) do
    surface = request["surface"]
    version = AtlasControl.Blocks.version()
    case {surface, Version.parse(spec), Version.parse(version)} do
      {s, {:ok, client_version}, {:ok, server_version}} when s in [nil, "console"] ->
        if Version.compare(client_version, server_version) == :lt do
          close(socket, "Client contract is older than the fixture contract")
        else
          welcome = %{"op" => "welcome", "env" => "test", "spec" => version}
          welcome = if s, do: Map.put(welcome, "surface", s), else: welcome
          send_line(socket, welcome)
          next = %{state | hello: true, surface: s}
          send_page(socket, next, "open")
          {:ok, next}
        end
      _ -> close(socket, "Unsupported surface or contract version")
    end
  end
  defp handle(socket, %{"op" => "boot"} = request, %{hello: true} = state) do
    requested = request["to"]
    cond do
      not is_nil(requested) and (not is_binary(requested) or is_nil(Scenarios.page(requested))) ->
        send_line(socket, %{"op" => "boot", "error" => "Unknown fixture target"})
        {:ok, state}

      true ->
        target = requested || Scenarios.initial(state.scenario)
        active = Enum.find(Scenarios.tabs(), &(&1["to"] == target))
        shell = %{"op" => "boot", "title" => "Atlas Console fixtures", "env" => "test", "spec" => AtlasControl.Blocks.version(), "revision" => "shared-fixtures", "tabs" => Scenarios.tabs(), "initial_to" => target}
        shell = if active, do: Map.put(shell, "active_tab", active["id"]), else: shell
        send_line(socket, shell)
        {:ok, state}
    end
  end

  defp handle(socket, %{"op" => "open", "to" => path}, %{hello: true} = state) when is_binary(path) do
    if Scenarios.page(path) do
      next = %{state | path: path}
      send_page(socket, next, "open")
      {:ok, next}
    else
      close(socket, "Fixture has no page for #{inspect(path)}")
    end
  end

  defp handle(socket, %{"op" => "refresh"}, %{hello: true} = state) do
    send_page(socket, state, "reconcile")
    {:ok, state}
  end

  defp handle(socket, request, _state), do: close(socket, "Read-only fixture does not support #{inspect(request["op"])}")

  defp send_page(socket, state, reason) do
    page = Scenarios.page(state.path) |> Map.put("reason", reason)
    page = if state.surface == "console" do
      case AtlasControl.Console.project(page, Scenarios.tabs()) do
        {:ok, projected} -> projected
        {:error, error} -> raise "Fixture projection failed: #{inspect(error)}"
      end
    else
      page
    end
    send_line(socket, page)
  end

  defp send_line(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])
  defp close(socket, reason) do
    send_line(socket, %{"op" => "bye", "text" => reason})
    :gen_tcp.close(socket)
    :close
  end
end

[scenario, port] = System.argv()
ControlFixtures.Server.run(scenario, String.to_integer(port))
