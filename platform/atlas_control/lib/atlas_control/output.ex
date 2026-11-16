defmodule AtlasControl.Output do
  @moduledoc "Connection-owned bounded output subscriptions; durable authority stays in Workers."
  use GenServer
  alias AtlasBus.Envelope
  alias AtlasBFFContract.Wire.Runtime.OutputProtocol, as: Wire

  @max_viewers 128
  @timeout 2_000
  @idle_timeout 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def idle_timeout, do: @idle_timeout

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:acquire, {pid, _}, state) do
    cond do
      Map.has_key?(state, pid) -> {:reply, :ok, state}
      map_size(state) >= @max_viewers -> {:reply, {:error, "viewer_limit"}, state}
      true -> {:reply, :ok, Map.put(state, pid, Process.monitor(pid))}
    end
  end

  def handle_call(:release, {pid, _}, state) do
    {ref, state} = Map.pop(state, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    {:noreply, if(state[pid] == ref, do: Map.delete(state, pid), else: state)}
  end

  def capability(execution) do
    case request(:runtime_output_snapshot, execution, nil) do
      {:ok, _} -> %{"available" => true, "replay" => true}
      {:error, reason} -> %{"available" => false, "replay" => false, "reason" => reason}
    end
  end

  def handle("worker_output_subscribe", request, previous, inspect)
      when is_nil(previous) or previous.closed == true do
    execution = request["execution"]

    with {:ok, %{"view" => view}} <- inspect.(execution),
         :ok <- GenServer.call(__MODULE__, :acquire) do
      case request(:runtime_output_snapshot, execution, request["cursor"]) do
        {:ok, snapshot} ->
          secret = if previous, do: previous.secret, else: :crypto.strong_rand_bytes(32)
          nonce = :crypto.strong_rand_bytes(24)
          signature = :crypto.mac(:hmac, :sha256, secret, nonce)
          token = Base.url_encode64(nonce <> signature, padding: false)
          state = %{token: token, secret: secret, execution: execution, closed: false}
          result = snapshot |> Map.put("subscription", token) |> Map.put("view", available(view))
          {:ok, result, state}

        {:error, reason} ->
          GenServer.call(__MODULE__, :release)
          {:error, reason, unavailable(view, reason), previous}
      end
    else
      {:error, reason} -> {:error, reason, %{}, previous}
    end
  end

  def handle("worker_output_subscribe", _request, state, _inspect),
    do: {:error, "subscription_exists", %{}, state}

  def handle(
        "worker_output_unsubscribe",
        %{"subscription" => token},
        %{token: token} = state,
        _inspect
      ) do
    GenServer.call(__MODULE__, :release)
    {:ok, %{"subscription" => token}, %{state | closed: true}}
  end

  def handle(
        "worker_output_unsubscribe",
        %{"subscription" => token},
        %{secret: secret} = state,
        _inspect
      ) do
    # Authenticate old tokens without an unbounded tombstone list or closing a newer subscription.
    case Base.url_decode64(token, padding: false) do
      {:ok, <<nonce::binary-size(24), signature::binary-size(32)>>} ->
        if :crypto.hash_equals(signature, :crypto.mac(:hmac, :sha256, secret, nonce)),
          do: {:ok, %{"subscription" => token}, state},
          else: {:error, "invalid_subscription", %{}, state}

      _ ->
        {:error, "invalid_subscription", %{}, state}
    end
  end

  def handle(
        "worker_output_next",
        %{"subscription" => token} = request,
        %{token: token, closed: false} = state,
        inspect
      ) do
    with {:ok, %{"view" => view}} <- inspect.(state.execution) do
      case request(:runtime_output_read, state.execution, request["cursor"]) do
        {:ok, batch} ->
          result = Map.put(batch, "subscription", token)
          result = if batch["reset"], do: Map.put(result, "view", available(view)), else: result
          {:ok, result, state}

        {:error, reason} ->
          {:error, reason, unavailable(view, reason), state}
      end
    else
      {:error, reason} -> {:error, reason, %{}, state}
    end
  end

  def handle(_operation, _request, state, _inspect),
    do: {:error, "invalid_subscription", %{}, state}

  defp available(view), do: Map.put(view, "output", %{"available" => true, "replay" => true})

  defp unavailable(view, "output_unavailable") do
    %{
      "view" =>
        Map.put(view, "output", %{
          "available" => false,
          "replay" => false,
          "reason" => "output_unavailable"
        }),
      "reset" => %{"reason" => "output_unavailable"}
    }
  end

  defp unavailable(_view, _reason), do: %{}

  def request(operation, execution, cursor) do
    with %{
           "worker" => %{"environment" => environment, "machine" => machine},
           "attempt" => attempt
         } <- execution,
         true <-
           environment == AtlasBus.environment() and is_binary(machine) and
             Regex.match?(~r/^[A-Za-z0-9_.-]+$/, machine) and is_binary(attempt) and attempt != "",
         address = "runtime@#{machine}/output",
         [_ | _] <- Registry.lookup(AtlasBus.Endpoints, address) do
      envelope = %{Envelope.new("request", "runtime.output") | address: address}
      props = %{"id" => envelope.id, "execution" => execution}
      props = if is_nil(cursor), do: props, else: Map.put(props, "cursor", cursor)
      payload = Wire.request(operation, props)

      case AtlasBus.send(envelope, payload) do
        :ok -> await(operation, envelope, address, execution)
        {:error, _} -> {:error, "output_unavailable"}
      end
    else
      _ -> {:error, "output_unavailable"}
    end
  end

  defp await(operation, envelope, address, execution) do
    id = envelope.id
    environment = envelope.environment
    [receiver] = Registry.keys(AtlasBus.Endpoints, self())

    receive do
      {:atlas_bus,
       %Envelope{
         class: "answer",
         kind: "runtime.output",
         id: ^id,
         environment: ^environment,
         sender: ^address,
         address: ^receiver,
         position: nil
       }, payload} ->
        case Wire.decode_reply(operation, payload) do
          {:ok, :result, %{"id" => ^id, "stream" => %{"execution" => ^execution}} = result} ->
            if byte_size(JSON.encode!(result)) <= 262_144,
              do: {:ok, Map.drop(result, ~w(id op channel version))},
              else: {:error, "invalid_output_reply"}

          {:ok, :error, %{"id" => ^id, "error" => %{"code" => code}}} ->
            {:error, code}

          _ ->
            {:error, "invalid_output_reply"}
        end
    after
      @timeout -> {:error, "output_unavailable"}
    end
  end
end
