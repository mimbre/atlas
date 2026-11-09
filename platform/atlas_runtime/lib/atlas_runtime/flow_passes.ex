defmodule AtlasRuntime.FlowPasses do
  @moduledoc "Durable pass bindings; retries recover the original command admission."
  use GenServer
  alias AtlasBus.{Digest, Envelope}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def request(pid, body), do: GenServer.call(pid, {:request, body})

  @impl true
  def init(opts) do
    machine = Keyword.fetch!(opts, :machine)
    :ok = AtlasBus.attach("runtime@" <> machine <> "/passes")
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(Path.join(dir, "passes"))

    {:ok,
     %{machine: machine, dir: dir, backend: Keyword.get(opts, :backend, {__MODULE__.Native, dir})}}
  end

  @impl true
  def handle_call({:request, body}, _, state), do: {:reply, handle(body, state), state}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "flow_pass"} = e, body}, state) do
    answer =
      if e.sender == "flow/passes",
        do: handle(body, state),
        else: %{"error" => "unauthorized sender"}

    AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp handle(body, state) do
    r = body["request"]

    with true <- is_map(r) and r["version"] == 1,
         true <- is_binary(r["id"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, r["id"]),
         true <- r["machine"] == state.machine,
         true <- Digest.of_term(r) == body["digest"],
         true <- body["operation"] in ["accept", "lookup"],
         {module, context} = state.backend,
         path = Path.join([state.dir, "passes", r["id"] <> ".json"]),
         {:ok, record} <- bind(path, body, module, context),
         {:ok, execution} <- execute(record, path, body["operation"], module, context) do
      Map.merge(
        %{
          "version" => 1,
          "id" => r["id"],
          "digest" => body["digest"],
          "fingerprint" => r["fingerprint"],
          "packet" => r["request"]["packet"]
        },
        execution
      )
    else
      other -> failure(body, inspect(other), true)
    end
  rescue
    error -> failure(body, Exception.message(error), true)
  catch
    :exit, _ -> failure(body, "native service unavailable", false)
  end

  defp failure(body, reason, reconcile?) do
    r = if is_map(body) and is_map(body["request"]), do: body["request"], else: %{}

    %{
      "version" => 1,
      "id" => r["id"],
      "digest" => if(is_map(body), do: body["digest"], else: nil),
      "fingerprint" => r["fingerprint"],
      "packet" => r["request"]["packet"],
      "error" => reason,
      "requires_reconciliation" => reconcile?
    }
  end

  defp bind(path, body, module, context) do
    case File.read(path) do
      {:ok, bytes} ->
        record = JSON.decode!(bytes)

        if record["request"] == body["request"] and record["digest"] == body["digest"],
          do: {:ok, record},
          else: {:error, :pass_identity_conflict}

      {:error, :enoent} ->
        if body["operation"] == "lookup" do
          {:error, :unknown_pass}
        else
          with :ok <- module.validate(context, body["request"]) do
            record = Map.take(body, ~w(request digest))
            persist(path, record)
            {:ok, record}
          end
        end

      error ->
        error
    end
  end

  defp execute(record, path, operation, module, context) do
    cond do
      record["result"]["status"] == "completed" ->
        {:ok, record["result"]}

      record["execution"] != nil ->
        with {:ok, result} <- module.lookup(context, record["request"], record["execution"]),
             true <- result["execution"] == record["execution"] do
          persist(path, Map.put(record, "result", result))
          {:ok, result}
        end

      operation == "lookup" ->
        {:error, :indeterminate_pass}

      true ->
        # The receiver recovers accept by this id, including after a crash here.
        with {:ok, result} <- module.accept(context, record["request"]),
             true <- is_binary(result["execution"]) do
          persist(
            path,
            Map.merge(record, %{"execution" => result["execution"], "result" => result})
          )

          {:ok, result}
        end
    end
  end

  defp persist(path, record) do
    File.write!(path <> ".tmp", JSON.encode!(record))
    File.rename!(path <> ".tmp", path)
  end
end

defmodule AtlasRuntime.FlowPasses.Native do
  @moduledoc false
  alias AtlasRuntime.{CommandAdmissions, Service, Workspaces}

  def validate(dir, r) do
    q = r["request"]

    with true <- q["mode"] == "start" and is_binary(q["assignment"]) and q["assignment"] != "",
         true <- q["backend"] in ["codex", "claude"] and q["backend"] in q["vendors"],
         true <- q["permissions"] in ["read-only", "workspace-write", "review-packet"],
         true <- is_binary(q["cwd"]) do
      if q["permissions"] == "review-packet" do
        if q["packet_contract"] != 1 or not is_map(q["packet"]),
          do: raise(ArgumentError, "unsupported packet contract")

        if is_binary(q["packet"]["revision"]) and q["packet"]["revision"] != "" do
          scope = Workspaces.packet_scope(q["cwd"], dir)

          if Map.put(Map.take(scope, ~w(packet_id fingerprint)), "revision", revision(scope)) ==
               q["packet"],
             do: :ok,
             else: {:error, :packet_mismatch}
        else
          {:error, :packet_mismatch}
        end
      else
        :ok
      end
    else
      _ -> {:error, :unsupported_pass_contract}
    end
  end

  # The revision the packet records it is for (`snapshot freeze --revision`), from its
  # packet.json, which `packet_scope` has just verified against the packet's record; none
  # when it was frozen without one, which no review of a revision takes.
  defp revision(scope),
    do: JSON.decode!(File.read!(Path.join(scope["packet"], "packet.json")))["revision"]

  def accept(dir, r) do
    # A reservation whose delivery is unknown is never delivered again by Service.
    case CommandAdmissions.load(dir, r["id"]) do
      nil ->
        with :ok <- validate(dir, r) do
          {reply, false} = GenServer.call(Service, start_command(r), 30_000)
          admitted(reply)
        end

      record ->
        admitted(CommandAdmissions.public(record))
    end
  end

  # The Service start command of frozen request `r`: exactly its assignment, folder, backend
  # and permissions, under the request's own id and worker; nothing is chosen here.
  defp start_command(r) do
    q = r["request"]

    command = %{
      "command" => "start",
      "request_id" => r["id"],
      "worker_id" => worker(r),
      "assignment" => q["assignment"],
      "cwd" => q["cwd"],
      "backend" => q["backend"]
    }

    if q["permissions"] == "review-packet",
      do: Map.put(command, "permissions", "review-packet"),
      else: Map.put(command, "sandbox", q["permissions"])
  end

  defp admitted(%{"admission" => "accepted", "turn_id" => turn}),
    do: {:ok, %{"execution" => turn, "status" => "running"}}

  defp admitted(_), do: {:error, :execution_requires_reconciliation}

  def lookup(dir, r, execution) do
    with :ok <- validate(dir, r),
         %{"admission" => "accepted", "turn_id" => ^execution} <-
           CommandAdmissions.load(dir, r["id"]),
         %{"turn" => turn} <- GenServer.call(Service, {:read, "turn", %{"turn_id" => execution}}),
         true <- turn["worker_id"] == worker(r) and turn["turn_id"] == execution do
      review? = r["request"]["permissions"] == "review-packet"

      case turn["state"] do
        "running" ->
          {:ok, %{"execution" => execution, "status" => "running"}}

        ended when review? and ended in ~w(finished stopped killed) ->
          reviewed(dir, r, execution, turn)

        "finished" ->
          {:ok,
           %{
             "execution" => execution,
             "status" => "completed",
             "outcome" => "finished",
             "evidence" => turn
           }}

        _ ->
          {:error, :execution_requires_reconciliation}
      end
    else
      _ -> {:error, :execution_mismatch}
    end
  end

  # A review pass's outcome is the verdict its findings give, as Runtime records them for
  # the packet (`Workspaces.findings/3`), with that record as its evidence. Findings it
  # refuses (missing or invalid) end it as failed; anything else is for reconciliation.
  @verdicts ~w(pass changes_required uncertain)

  defp reviewed(dir, r, execution, turn),
    do:
      review_result(
        Workspaces.findings(Path.dirname(r["request"]["cwd"]), execution, dir),
        r,
        execution,
        turn
      )

  @doc false
  # What the findings Runtime recorded (or refused) for review `execution` of request `r`
  # make of the pass: its outcome and evidence, or reconciliation.
  def review_result({:ok, %{"findings" => %{"verdict" => verdict}} = record}, r, execution, turn) do
    if verdict in @verdicts and record["review_turn"] == execution and
         Map.take(record, ~w(packet_id fingerprint)) ==
           Map.take(r["request"]["packet"], ~w(packet_id fingerprint)),
       do:
         {:ok,
          %{
            "execution" => execution,
            "status" => "completed",
            "outcome" => verdict,
            "evidence" => %{"turn" => turn, "findings" => Map.drop(record, ~w(state record))}
          }},
       else: {:error, :execution_requires_reconciliation}
  end

  def review_result({:refused, code}, _r, execution, turn)
      when code in ~w(findings_missing findings_invalid),
      do:
        {:ok,
         %{
           "execution" => execution,
           "status" => "completed",
           "outcome" => "failed",
           "evidence" => %{"turn" => turn, "refused" => code}
         }}

  def review_result(_, _r, _execution, _turn), do: {:error, :execution_requires_reconciliation}

  defp worker(r), do: "pass-" <> String.slice(r["id"], 0, 59)
end
