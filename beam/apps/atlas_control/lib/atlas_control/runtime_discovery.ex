defmodule AtlasControl.RuntimeDiscovery do
  @moduledoc "Exact-machine registry read. Hello actor attribution never grants this capability."
  alias AtlasBFFContract.Wire.Control.DiscoveryProtocol, as: Wire

  def read(message, admitted?, registry \\ &AtlasBus.endpoints/0) do
    case Wire.decode_request(message) do
      {:ok, :runtime_machine_discover, request} ->
        if admitted? and authorized?(request) do
          observe(request, registry)
        else
          refuse(request, "unauthorized", "An explicit exact-machine read grant is required")
        end

      _ ->
        id = if is_map(message) and is_binary(message["id"]), do: message["id"], else: "invalid"

        Wire.reply(:runtime_machine_discover, :error,
          id: id,
          error: %{
            code: "invalid_request",
            message: "Invalid machine discovery request",
            retryable: false
          }
        )
    end
  end

  defp authorized?(request) do
    target = request["target"]
    machine = target["machine"]

    target["environment"] == AtlasBus.environment() and
      Regex.match?(~r/^[A-Za-z0-9_.-]+$/, machine) and
      AtlasBus.Link.same_token?(request["grant"], grants()[machine])
  end

  defp grants do
    with name when is_binary(name) and name != "" <-
           Application.get_env(:atlas_control, :runtime_read_token_env),
         true <- Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
         value when is_binary(value) <- System.get_env(name),
         {:ok, %{} = grants} <- JSON.decode(value),
         true <-
           Enum.all?(grants, fn {machine, token} ->
             Regex.match?(~r/^[A-Za-z0-9_.-]+$/, machine) and is_binary(token) and token != ""
           end) do
      grants
    else
      _ -> %{}
    end
  end

  defp observe(request, registry) do
    # Authority has already been checked. Never return the global endpoint list.
    case snapshot(registry) do
      {:ok, endpoints} ->
        registered = ("runtime@" <> request["target"]["machine"]) in endpoints

        Wire.reply(:runtime_machine_discover, :result,
          id: request["id"],
          target: request["target"],
          availability: %{
            target: request["target"],
            registered: registered,
            basis: "bus_endpoint_registry"
          }
        )

      :unavailable ->
        refuse(request, "registry_unavailable", "Bus registry read unavailable")
    end
  end

  defp snapshot(registry) do
    try do
      case registry.() do
        endpoints when is_list(endpoints) ->
          if Enum.all?(endpoints, &is_binary/1), do: {:ok, endpoints}, else: :unavailable

        _ ->
          :unavailable
      end
    rescue
      # Registry.select raises ArgumentError if its registry has stopped.
      ArgumentError -> :unavailable
    catch
      :exit, _ -> :unavailable
    end
  end

  defp refuse(request, code, message) do
    Wire.reply(:runtime_machine_discover, :error,
      id: request["id"],
      target: request["target"],
      error: %{code: code, message: message, retryable: code == "registry_unavailable"}
    )
  end
end
