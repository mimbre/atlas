defmodule AtlasFlow.EffectReceiver do
  @moduledoc """
  A private, neutral effect receiver for Flow's tests: it keeps artifacts in a journal
  directory, so it survives its own restart. It proves Flow's side of the effect
  contract only; it says nothing about any real service's idempotency.

  Faults, each for the next submit only: `lose/1` performs and journals the operation
  but sends no answer; `uncertain/1` journals an unknown outcome, as when the receiver's
  own downstream call timed out.
  """
  use GenServer
  alias AtlasBus.{Digest, Envelope}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def request(pid, body), do: GenServer.call(pid, {:request, body})
  def lose(pid), do: GenServer.call(pid, {:fault, :lose})
  def uncertain(pid), do: GenServer.call(pid, {:fault, :uncertain})

  @doc "Every operation performed, oldest first, as `{id, operation, reference}`."
  def operations(dir) do
    case File.read(Path.join(dir, "operations.log")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            do: List.to_tuple(String.split(line, " "))

      {:error, :enoent} ->
        []
    end
  end

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(Path.join(dir, "journal"))
    File.mkdir_p!(Path.join(dir, "artifacts"))
    :ok = AtlasBus.attach(Keyword.fetch!(opts, :address))
    {:ok, %{dir: dir, fault: nil}}
  end

  @impl true
  def handle_call({:request, body}, _, s) do
    {reply, s} = handle(body, s)
    {:reply, reply, s}
  end

  def handle_call({:fault, fault}, _, s), do: {:reply, :ok, %{s | fault: fault}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "flow_effect"} = e, body}, s) do
    {reply, s} =
      if e.sender == "flow/effects",
        do: handle(body, s),
        else: {%{"version" => 1, "error" => "unauthorized sender"}, s}

    if reply != :lost, do: AtlasBus.send(Envelope.reply(e, "answer"), reply)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp handle(%{"request" => %{"id" => id} = r, "digest" => digest} = body, s)
       when is_binary(id) do
    base = %{"version" => 1, "id" => id, "digest" => digest, "fingerprint" => r["fingerprint"]}
    path = Path.join([s.dir, "journal", id <> ".json"])

    cond do
      not Regex.match?(~r/\A[0-9a-f]{64}\z/, id) or r["version"] != 1 ->
        {Map.put(base, "status", "invalid"), s}

      true ->
        case File.read(path) do
          {:ok, bytes} ->
            record = JSON.decode!(bytes)

            # One id names one payload for ever; a different one is never performed.
            if record["digest"] == digest and record["request"] == r,
              do: {Map.merge(base, record["result"]), s},
              else: {Map.put(base, "status", "conflict"), s}

          {:error, :enoent} ->
            cond do
              Digest.of_term(r) != digest -> {Map.put(base, "status", "invalid"), s}
              body["operation"] == "lookup" -> {Map.put(base, "status", "not_found"), s}
              body["operation"] == "submit" -> perform(r, digest, base, path, s)
              true -> {Map.put(base, "status", "invalid"), s}
            end
        end
    end
  end

  defp handle(_, s), do: {%{"version" => 1, "status" => "invalid"}, s}

  defp perform(r, digest, base, path, s) do
    result =
      if s.fault == :uncertain,
        do: %{"status" => "unknown"},
        else: operate(r, s.dir)

    persist(path, %{"request" => r, "digest" => digest, "result" => result})
    reply = if s.fault == :lose, do: :lost, else: Map.merge(base, result)
    {reply, %{s | fault: nil}}
  end

  defp operate(%{"operation" => "create"} = r, dir) do
    n = length(File.ls!(Path.join(dir, "artifacts"))) + 1
    reference = "artifact-#{n}"
    write_artifact(dir, reference, %{"payload" => r["payload"], "revision" => 1})
    log(dir, r, reference)
    done(reference, %{"reference" => reference, "revision" => "1"})
  end

  defp operate(%{"operation" => "update", "target" => target} = r, dir) do
    case read_artifact(dir, target) do
      {:ok, a} ->
        revision = a["revision"] + 1
        write_artifact(dir, target, %{a | "payload" => r["payload"], "revision" => revision})
        log(dir, r, target)
        done(target, %{"reference" => target, "revision" => to_string(revision)})

      :error ->
        %{"status" => "refused", "reason" => "unknown target"}
    end
  end

  defp operate(%{"operation" => "integrate", "target" => target} = r, dir) do
    with {:ok, a} <- read_artifact(dir, target),
         true <- is_binary(r["approved"]) and r["approved"] == r["fingerprint"] do
      write_artifact(dir, target, Map.put(a, "integrated", r["approved"]))
      log(dir, r, target)
      done(target, %{"reference" => target, "revision" => to_string(a["revision"])})
    else
      _ -> %{"status" => "refused", "reason" => "not integrable at the approved fingerprint"}
    end
  end

  defp operate(_, _), do: %{"status" => "refused", "reason" => "unsupported operation"}

  defp done(reference, outputs),
    do: %{"status" => "done", "reference" => reference, "outputs" => outputs}

  defp read_artifact(dir, ref) do
    case File.read(Path.join([dir, "artifacts", ref <> ".json"])) do
      {:ok, bytes} -> {:ok, JSON.decode!(bytes)}
      _ -> :error
    end
  end

  defp write_artifact(dir, ref, a), do: persist(Path.join([dir, "artifacts", ref <> ".json"]), a)

  defp log(dir, r, reference),
    do:
      File.write!(
        Path.join(dir, "operations.log"),
        "#{r["id"]} #{r["operation"]} #{reference}\n",
        [:append]
      )

  defp persist(path, term) do
    File.write!(path <> ".tmp", JSON.encode!(term))
    File.rename!(path <> ".tmp", path)
  end
end

defmodule AtlasFlow.EffectReceiverContract do
  @moduledoc """
  What a receiver must show before Flow enables an effect operation for it
  (`config :atlas_flow, :effect_receivers`). `call` sends one body
  (`%{"operation" => "submit" | "lookup", "request" => r, "digest" => d}`) and returns the
  receiver's reply; `requests` holds one fresh, frozen request for each operation to be
  enabled, built the way `AtlasFlow.Activities.Effect.freeze/4` builds it.
  """
  import ExUnit.Assertions
  alias AtlasBus.Digest

  def check!(call, requests) do
    for r <- requests do
      d = Digest.of_term(r)
      first = call.(%{"operation" => "submit", "request" => r, "digest" => d})
      assert first["id"] == r["id"] and first["digest"] == d, "reply names the request"
      assert first["fingerprint"] == r["fingerprint"], "reply echoes the fingerprint"
      assert first["status"] in ["done", "refused"], "a fresh request is answered"

      if first["status"] == "done",
        do: assert(is_binary(first["reference"]) and is_map(first["outputs"]))

      # Repeated id: the original result, not a second operation.
      assert call.(%{"operation" => "submit", "request" => r, "digest" => d}) == first
      # A lost answer is recovered by lookup.
      assert call.(%{"operation" => "lookup", "request" => r, "digest" => d}) == first

      # A changed payload under that id is rejected and changes nothing.
      changed = Map.put(r, "payload", Map.put(r["payload"], "changed", "yes"))
      cd = Digest.of_term(changed)

      for op <- ["submit", "lookup"],
          do:
            assert(
              call.(%{"operation" => op, "request" => changed, "digest" => cd})["status"] ==
                "conflict"
            )

      # A digest that does not match its request is never performed.
      refute call.(%{"operation" => "submit", "request" => r, "digest" => "forged"})["status"] in [
               "done",
               "refused"
             ]

      assert call.(%{"operation" => "lookup", "request" => r, "digest" => d}) == first
    end

    unknown = Map.put(hd(requests), "id", String.duplicate("0", 64))

    assert call.(%{
             "operation" => "lookup",
             "request" => unknown,
             "digest" => Digest.of_term(unknown)
           })["status"] == "not_found"

    :ok
  end
end
