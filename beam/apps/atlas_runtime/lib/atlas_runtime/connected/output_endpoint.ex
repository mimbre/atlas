defmodule AtlasRuntime.OutputEndpoint do
  @moduledoc "Read-only Bus endpoint for retained exact-attempt output; viewers never open a ring."
  use GenServer

  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: Wire
  alias AtlasBus.Envelope
  alias AtlasRuntime.Output

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    machine = Keyword.fetch!(opts, :machine)
    endpoint = "runtime@#{machine}/output"
    :ok = AtlasBus.attach(endpoint)
    {:ok, %{machine: machine, endpoint: endpoint, output: Keyword.get(opts, :output, Output)}}
  end

  @impl true
  def handle_info(
        {:atlas_bus, %Envelope{class: "request", kind: "runtime.output"} = envelope, content},
        state
      ) do
    # Bus stamps sender identities. Remote runtimes cannot attach control/* endpoints.
    if envelope.environment == AtlasBus.environment() and envelope.address == state.endpoint and
         is_binary(envelope.sender) and String.starts_with?(envelope.sender, "control/") do
      dispatch(envelope, content, state)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(envelope, content, state) do
    case Wire.decode_request(content) do
      {:ok, operation, request} ->
        result =
          if request["id"] == envelope.id and
               get_in(request, ["execution", "worker", "environment"]) == envelope.environment and
               get_in(request, ["execution", "worker", "machine"]) == state.machine do
            read(operation, request, state.output)
          else
            {:error, "invalid_request"}
          end

        reply(envelope, operation, result)

      {:invalid, _} ->
        case operation(content) do
          nil -> :ok
          operation -> reply(envelope, operation, {:error, "invalid_request"})
        end
    end
  end

  defp operation(%{"op" => "runtime_output_snapshot"}), do: :runtime_output_snapshot
  defp operation(%{"op" => "runtime_output_read"}), do: :runtime_output_read
  defp operation(_), do: nil

  defp read(operation, request, output) do
    case operation do
      :runtime_output_snapshot -> Output.snapshot(request["execution"], request["cursor"], output)
      :runtime_output_read -> Output.read(request["execution"], request["cursor"], output)
    end
  catch
    :exit, {:noproc, _} -> {:error, "output_unavailable"}
    :exit, {:timeout, _} -> {:error, "output_unavailable"}
  end

  defp reply(envelope, operation, {:ok, result}) do
    content = Wire.reply(operation, :result, Map.put(result, "id", envelope.id))
    AtlasBus.send(Envelope.reply(envelope, "answer"), content)
  end

  defp reply(envelope, operation, {:error, reason}) do
    content =
      Wire.reply(operation, :error, %{
        "id" => envelope.id,
        "error" => %{
          "code" => reason,
          "message" => error_message(reason),
          "retryable" => reason == "output_unavailable"
        }
      })

    AtlasBus.send(Envelope.reply(envelope, "answer"), content)
  end

  defp error_message("invalid_cursor"), do: "Output cursor does not identify this retained stream"
  defp error_message("output_unavailable"), do: "Output is not retained for this exact execution"
  defp error_message(_), do: "Invalid exact-execution output request"
end
