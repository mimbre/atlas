defmodule AtlasAgent.RuntimeDiscovery do
  @moduledoc "Exact-machine read through the ordinary Control client, never a local process action."
  alias AtlasAgent.{Client, Protocol}

  def read(client, machine) do
    props = %{
      id: Integer.to_string(System.unique_integer([:positive])),
      target: %{environment: client.env, machine: machine},
      grant: System.get_env("ATLAS_RUNTIME_READ_TOKEN")
    }

    {:ok, :runtime_machine_discover, request} = Protocol.cli(["discover"], props)

    case Client.exchange(client, :runtime_machine_discover, request, 2_000) do
      {:ok, reply} ->
        {:runtime_discovery, reply, 0}

      {:error, %{"code" => _} = error} ->
        {:runtime_discovery,
         Protocol.reply(:runtime_machine_discover, :error,
           id: request["id"],
           target: request["target"],
           error: error
         ), 2}

      {:error, why} ->
        {:error, why}
    end
  end
end
