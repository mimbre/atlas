defmodule AtlasRuntime.Agent.FakeInbox do
  @moduledoc """
  Private, model-free proof harness. Deliberately absent from Agent.port/1.
  Initialization is explicit; reopening missing/corrupt history fails closed.
  One owner per physical directory on this BEAM node. No distributed/disk-loss guarantee.
  consume/2 simulates a safe boundary, with no external side effect or model execution.
  """
  use GenServer
  @behaviour AtlasRuntime.Agent
  alias AtlasRuntime.Agent.Input

  @impl true
  def start(turn, opts) when is_map(turn) and is_list(opts) do
    identity = %{
      "environment" => turn[:environment],
      "worker" => turn[:agent],
      "turn" => turn[:key],
      "attempt" => turn[:attempt],
      "interaction" => "validate"
    }

    with true <- Keyword.keyword?(opts),
         :ok <- Input.validate_identity(identity),
         true <- Input.identifier?(turn[:machine]),
         true <- is_binary(Keyword.get(opts, :inbox_dir)),
         true <- Keyword.get(opts, :initialize, false) in [true, false] do
      GenServer.start(__MODULE__, {self(), turn, opts})
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def start(_, _), do: {:error, :invalid_identity}
  @impl true
  def describe(_turn, _opts), do: {:ok, descriptor()}
  @impl true
  def accept(pid, request, deadline), do: GenServer.call(pid, {:accept, request, deadline})
  @impl true
  def close_input(pid), do: close_attempt(pid)
  @impl true
  def recover_input(turn, opts),
    do: start(turn, Keyword.merge(opts, initialize: false, recovery: true))

  @impl true
  def stop(pid), do: GenServer.stop(pid)
  @impl true
  def capabilities(pid), do: GenServer.call(pid, :capabilities)
  @impl true
  def accept(pid, request), do: GenServer.call(pid, {:accept, request})
  @impl true
  def query(pid, identity), do: GenServer.call(pid, {:query, identity})
  def consume(pid, identity), do: GenServer.call(pid, {:consume, identity})
  def close_attempt(pid), do: GenServer.call(pid, :close_attempt)

  @doc "Inspect one simulated context input, bounded to the admitted request size."
  def context_input(pid, identity), do: GenServer.call(pid, {:context, identity})

  @impl true
  def init({owner, turn, opts}) do
    dir = Keyword.fetch!(opts, :inbox_dir)

    target = %{
      "environment" => turn.environment,
      "worker" => turn.agent,
      "turn" => turn.key,
      "attempt" => turn.attempt
    }

    scope = %{"environment" => turn.environment, "machine" => turn.machine}

    with :ok <- Input.validate_identity(Map.put(target, "interaction", "validate")),
         true <- Input.identifier?(turn.machine),
         :ok <- directory(dir, Keyword.get(opts, :initialize, false)),
         {:ok, stat} <- File.stat(dir),
         lock = {__MODULE__, node(), stat.major_device, stat.minor_device, stat.inode},
         :yes <- :global.register_name(lock, self()) do
      case open(
             dir,
             scope,
             target,
             Keyword.get(opts, :initialize, false),
             physical_id(stat),
             Keyword.get(opts, :recovery, false)
           ) do
        {:ok, table, meta, binding} ->
          seal = Keyword.get(opts, :recovery, false) and meta.active == target

          if seal do
            # Recovery must never activate a successor or accept new input.
            sync(table, [{:meta, %{meta | closed: true}}, {{:closed, meta.active}, true}])
          end

          {:ok,
           %{
             table: table,
             meta: if(seal, do: %{meta | closed: true}, else: meta),
             owner: owner,
             lock: lock,
             binding: binding,
             barrier: Keyword.get(opts, :barrier),
             failed: false,
             owner_ref: Process.monitor(owner),
             recovery: Keyword.get(opts, :recovery, false)
           }}

        {:error, reason} ->
          :global.unregister_name(lock)
          {:stop, reason}
      end
    else
      :no -> {:stop, :inbox_in_use}
      _ -> {:stop, :uncertain}
    end
  end

  defp directory(dir, true), do: File.mkdir_p(dir)

  defp directory(dir, false) do
    if File.dir?(dir), do: :ok, else: {:error, :uncertain}
  end

  defp open(dir, scope, target, initialize, directory_id, recovery) do
    file = Path.join(dir, "inbox.dets")
    marker = Path.join(dir, "identity.json")
    new? = initialize and File.ls!(dir) == []

    if new? do
      {:ok, io} = File.open(marker, [:write, :exclusive, :binary])
      :ok = IO.binwrite(io, JSON.encode!(scope))
      :ok = :file.sync(io)
      :ok = File.close(io)
    end

    with true <- new? or (File.exists?(file) and File.exists?(marker)),
         {:ok, contents} <- File.read(marker),
         {:ok, ^scope} <- JSON.decode(contents),
         {:ok, marker_id} <- named_file_id(marker),
         {:ok, history_id} <- if(new?, do: {:ok, nil}, else: named_file_id(file)),
         {:ok, table} <-
           :dets.open_file(make_ref(), file: String.to_charlist(file), repair: false) do
      result =
        with {:ok, meta} <- load(table, scope, target, new?, recovery),
             {:ok, opened_id} <- named_file_id(file) do
          binding = %{
            directory: dir,
            directory_id: directory_id,
            history: file,
            history_id: history_id || opened_id,
            marker: marker,
            marker_id: marker_id,
            contents: contents
          }

          if binding_intact?(binding), do: {:ok, meta, binding}, else: {:error, :uncertain}
        end

      case result do
        {:ok, meta, binding} ->
          {:ok, table, meta, binding}

        error ->
          :dets.close(table)
          error
      end
    else
      _ -> {:error, :uncertain}
    end
  rescue
    _ -> {:error, :uncertain}
  end

  defp physical_id(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp named_file_id(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, physical_id(stat)}
      _ -> {:error, :uncertain}
    end
  end

  defp binding_intact?(binding) do
    with {:ok, %{type: :directory} = directory} <- File.stat(binding.directory),
         true <- physical_id(directory) == binding.directory_id,
         {:ok, history_id} <- named_file_id(binding.history),
         true <- history_id == binding.history_id,
         {:ok, marker_id} <- named_file_id(binding.marker),
         true <- marker_id == binding.marker_id,
         {:ok, contents} <-
           File.open(binding.marker, [:read, :binary], fn io ->
             IO.binread(io, byte_size(binding.contents) + 1)
           end),
         true <- contents == binding.contents do
      true
    else
      _ -> false
    end
  end

  defp ensure_binding!(state), do: true = binding_intact?(state.binding)

  defp load(table, scope, target, true, false) do
    meta = %{version: 1, scope: scope, active: target, closed: false}
    sync(table, {:meta, meta})
    {:ok, meta}
  end

  defp load(table, scope, target, false, recovery) do
    with [{:meta, %{version: 1, scope: ^scope} = meta}] <- :dets.lookup(table, :meta),
         true <- intact?(table, meta) do
      cond do
        meta.active == target ->
          {:ok, meta}

        recovery and :dets.lookup(table, {:closed, target}) == [{{:closed, target}, true}] ->
          {:ok, meta}

        not recovery and meta.closed and :dets.lookup(table, {:closed, target}) == [] ->
          meta = %{meta | active: target, closed: false}
          sync(table, {:meta, meta})
          {:ok, meta}

        true ->
          {:error, :target_conflict}
      end
    else
      _ -> {:error, :uncertain}
    end
  end

  defp intact?(table, meta) do
    is_boolean(meta.closed) and
      Input.validate_identity(Map.put(meta.active, "interaction", "validate")) == :ok and
      :dets.foldl(
        fn
          {:meta, _}, valid ->
            valid

          {{:closed, target}, true}, valid ->
            valid and Input.validate_identity(Map.put(target, "interaction", "validate")) == :ok and
              target["environment"] == meta.scope["environment"]

          {{:input, id}, %{request: request, evidence: evidence} = record}, valid ->
            valid and request["interaction"] == id and Input.validate(request) == :ok and
              request["environment"] == meta.scope["environment"] and
              byte_size(JSON.encode!(record)) <= 32_768 and
              Input.valid_evidence?(evidence, identity(request))

          _, _ ->
            false
        end,
        true,
        table
      )
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    # Owner loss seals admission; restarting Runtime may only query this history.
    try do
      ensure_binding!(state)
      if not state.recovery, do: operation(:close_attempt, state)
    rescue
      _ -> :uncertain
    end

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    :dets.close(state.table)
    :global.unregister_name(state.lock)
  end

  @impl true
  def handle_call(_, _, %{failed: true} = state), do: {:reply, {:error, :uncertain}, state}

  def handle_call(call, _, state) do
    ensure_binding!(state)
    {answer, updated} = operation(call, state)
    ensure_binding!(updated)
    {:reply, answer, updated}
  rescue
    _ -> {:reply, {:error, :uncertain}, %{state | failed: true}}
  catch
    :exit, _ -> {:reply, {:error, :uncertain}, %{state | failed: true}}
  end

  defp descriptor do
    %{
      "capability_version" => "1",
      "harness" => "private_fake",
      "harness_version" => "1",
      "configured_model" => nil,
      "reported_model" => nil,
      "queued_input" => true,
      "durable_accept_query" => true,
      "consumption_evidence" => true,
      "literal_text" => true
    }
  end

  defp operation(:capabilities, state), do: {{:ok, descriptor()}, state}

  defp operation(:close_attempt, %{recovery: true} = state), do: {:ok, state}

  defp operation(:close_attempt, state) do
    meta = %{state.meta | closed: true}
    sync(state.table, [{:meta, meta}, {{:closed, meta.active}, true}])
    {:ok, %{state | meta: meta}}
  end

  defp operation({:accept, request}, state), do: operation({:accept, request, nil}, state)

  defp operation({:accept, request, deadline}, state) do
    result =
      with :ok <- Input.validate(request),
           :ok <- environment(request, state) do
        case :dets.lookup(state.table, {:input, request["interaction"]}) do
          [{_, %{request: ^request, evidence: evidence}}] -> {:ok, evidence}
          [_] -> {:error, :conflict}
          [] -> admit(state, request, deadline)
        end
      end

    {result, state}
  end

  defp operation({op, identity}, state) when op in [:query, :consume, :context] do
    result =
      with :ok <- Input.validate_identity(identity),
           :ok <- environment(identity, state) do
        case :dets.lookup(state.table, {:input, identity["interaction"]}) do
          [{_, record}] ->
            if identity(record.request) == identity,
              do: existing(op, record, state),
              else: {:error, :conflict}

          [] ->
            {:not_admitted, identity}
        end
      end

    {result, state}
  end

  defp environment(request, state) do
    if request["environment"] == state.meta.scope["environment"],
      do: :ok,
      else: {:error, :wrong_environment}
  end

  defp active?(request, state),
    do:
      not state.recovery and not state.meta.closed and
        Map.drop(identity(request), ["interaction"]) == state.meta.active

  defp admit(state, request, deadline) do
    if active?(request, state) do
      barrier(state, :before_accept, request)
      ensure_binding!(state)

      if is_integer(deadline) and System.system_time(:millisecond) >= deadline do
        {:error, :stale}
      else
        evidence = %{
          "identity" => identity(request),
          "stage" => "admitted",
          "admission_id" => evidence_id(),
          "consumption_id" => nil
        }

        record = %{request: request, evidence: evidence}
        # Reserve room for consumption proof before admission becomes durable.
        largest = put_in(record, [:evidence, "consumption_id"], String.duplicate("x", 24))

        if byte_size(JSON.encode!(largest)) <= 32_768 do
          sync(state.table, {{:input, request["interaction"]}, record})
          barrier(state, :after_accept, request)
          ensure_binding!(state)
          {:ok, evidence}
        else
          {:error, :record_too_large}
        end
      end
    else
      {:error, :stale}
    end
  end

  defp existing(:query, record, _state), do: {:ok, record.evidence}

  defp existing(:context, record, _state) do
    if record.evidence["stage"] == "consumed",
      do: {:ok, record.request["body"]},
      else: {:error, :not_consumed}
  end

  defp existing(:consume, %{evidence: %{"stage" => "consumed"}} = record, _state),
    do: {:ok, record.evidence}

  defp existing(:consume, record, state) do
    if active?(record.request, state) do
      barrier(state, :before_consume, record.request)
      ensure_binding!(state)

      evidence =
        Map.merge(record.evidence, %{"stage" => "consumed", "consumption_id" => evidence_id()})

      sync(state.table, {{:input, record.request["interaction"]}, %{record | evidence: evidence}})
      barrier(state, :after_consume, record.request)
      ensure_binding!(state)
      send(state.owner, {:agent, self(), {:guidance, evidence}})
      {:ok, evidence}
    else
      {:error, :stale}
    end
  end

  defp identity(request), do: Map.drop(request, ["body", "mode"])
  defp evidence_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp sync(table, entry) do
    :ok = :dets.insert(table, entry)
    :ok = :dets.sync(table)
  end

  defp barrier(%{barrier: {owner, phase}}, phase, request) do
    send(owner, {:inbox_barrier, self(), phase, request["interaction"]})
    receive do: ({:release, ^phase} -> :ok)
  end

  defp barrier(_, _, _), do: :ok
end
