defmodule AtlasFlow.Activities.Pass do
  @moduledoc "Frozen pass requests and asynchronous, owner-specific Runtime delivery."
  alias AtlasBus.{Digest, SubjectFingerprint}

  def valid?(spec) do
    is_map(spec) and spec["contract"] == 1 and text?(spec["name"]) and
      is_map(spec["routing"]) and text?(spec["routing"]["machine_field"]) and
      is_map(spec["fingerprint"]) and
      is_list(spec["fingerprint"]["fields"]) and is_list(spec["fingerprint"]["relations"]) and
      valid_request?(spec["request"])
  end

  defp valid_request?(r) when is_map(r) do
    text?(r["assignment"]) and r["mode"] == "start" and text?(r["cwd"]) and
      Path.type(r["cwd"]) == :absolute and
      r["permissions"] in ["read-only", "workspace-write", "review-packet"] and
      r["backend"] in ["codex", "claude"] and is_list(r["vendors"]) and
      r["backend"] in r["vendors"] and
      (r["permissions"] != "review-packet" or
         (r["packet_contract"] == 1 and is_map(r["packet"]) and
            text?(r["packet"]["packet_id"]) and text?(r["packet"]["fingerprint"])))
  end

  defp valid_request?(_), do: false
  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  def freeze(run, spec, subject, assignment, owner) do
    machine = owner["values"][spec["routing"]["machine_field"]]

    if valid?(spec) and text?(machine) and text?(owner["key"]) do
      request = %{
        "version" => 1,
        "id" =>
          String.replace_prefix(
            Digest.of_term([run["key"], run["entry"], spec["name"]]),
            "sha256:",
            ""
          ),
        "run" => run["key"],
        "entry" => run["entry"],
        "name" => spec["name"],
        "subject" => subject["key"],
        "owner" => owner["key"],
        "machine" => machine,
        "machine_field" => spec["routing"]["machine_field"],
        "assignment" => assignment,
        "fingerprint_definition" => spec["fingerprint"],
        "fingerprint" => SubjectFingerprint.of(subject, spec["fingerprint"]),
        "request" => spec["request"]
      }

      {:ok, %{"request" => request, "digest" => Digest.of_term(request)}}
    else
      {:error, :invalid_pass_binding}
    end
  end

  def current?(intent, subject, assignment, owner) do
    r = intent["request"]

    r["owner"] == owner["key"] and r["machine"] == owner["values"][r["machine_field"]] and
      r["assignment"] == assignment and
      SubjectFingerprint.of(subject, r["fingerprint_definition"]) == r["fingerprint"]
  end

  def endpoint(intent), do: "runtime@" <> intent["request"]["machine"] <> "/passes"

  # No receive timeout: reconciliation/its injected clock drives retransmission.
  def poll(intent, now) do
    case GenServer.call(__MODULE__.Inbox, {:poll, intent, now}) do
      {:reply, reply} -> validate_reply(intent, reply)
      waiting -> waiting
    end
  end

  def validate_reply(intent, reply) when is_map(reply) do
    r = intent["request"]
    execution = reply["execution"]

    fenced =
      reply["version"] == 1 and reply["id"] == r["id"] and reply["digest"] == intent["digest"] and
        reply["fingerprint"] == r["fingerprint"] and reply["packet"] == r["request"]["packet"]

    cond do
      fenced and text?(reply["error"]) and reply["requires_reconciliation"] == true ->
        {:error, :pass_requires_reconciliation}

      fenced and
        text?(execution) and (intent["execution"] == nil or intent["execution"] == execution) and
        reply["status"] in ["running", "completed"] and reply["error"] == nil and
          (reply["status"] != "completed" or text?(reply["outcome"])) ->
        {:ok, reply}

      true ->
        {:error, :invalid_pass_evidence}
    end
  end

  def validate_reply(_, _), do: {:error, :invalid_pass_evidence}
end

defmodule AtlasFlow.Activities.Pass.Inbox do
  @moduledoc false
  use GenServer
  alias AtlasBus.Envelope
  alias AtlasFlow.Activities.Pass
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(_) do
    :ok = AtlasBus.attach("flow/passes")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:poll, intent, now}, _, state) do
    key = {intent["request"]["id"], Pass.endpoint(intent)}

    case Map.pop(state, key) do
      {%{} = reply, rest} ->
        {:reply, {:reply, reply}, rest}

      {_, rest} ->
        if intent["retry_at"] == nil or
             DateTime.compare(now, AtlasFlow.Runs.Run.parse!(intent["retry_at"])) != :lt do
          {id, endpoint} = key
          e = %{Envelope.new("request", "flow_pass", id: id) | address: endpoint}
          operation = if intent["execution"], do: "lookup", else: "accept"

          :ok =
            AtlasBus.send(e, %{
              "operation" => operation,
              "request" => intent["request"],
              "digest" => intent["digest"]
            })

          updated =
            Map.put(
              intent,
              "retry_at",
              DateTime.add(now, 1000, :millisecond) |> DateTime.to_iso8601()
            )

          # This cache is disposable; Facts retains every request needed to rebuild it.
          rest = if map_size(rest) >= 1024, do: %{}, else: rest
          {:reply, {:waiting, updated}, Map.put(rest, key, :awaiting)}
        else
          {:reply, {:waiting, intent}, state}
        end
    end
  end

  @impl true
  def handle_info(
        {:atlas_bus, %Envelope{class: "answer", kind: "flow_pass", id: id, sender: sender},
         reply},
        state
      ) do
    key = {id, sender}
    {:noreply, if(Map.has_key?(state, key), do: Map.put(state, key, reply), else: state)}
  end

  def handle_info(_, state), do: {:noreply, state}
end
