defmodule AtlasGates.Endpoint do
  @moduledoc "Bus request/reply endpoint: prepare a snapshot, then evaluate that exact snapshot."
  use GenServer
  alias AtlasBus.{Digest, Envelope, SubjectFingerprint}
  alias AtlasGates.{Decider, Definitions, Request}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(Keyword.get(opts, :endpoint, "gates"))
    {:ok, opts}
  end

  @impl true
  def handle_info(
        {:atlas_bus, %Envelope{class: "request", kind: "gate_activity"} = e, body},
        opts
      ) do
    facts = Keyword.get(opts, :facts, {AtlasGates.Facts.Bus, %{wait: 2_000}})

    answer =
      if e.sender == "flow",
        do: handle(body, facts, opts),
        else: %{"error" => "unauthorized sender"}

    AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, opts}
  end

  def handle_info(_, opts), do: {:noreply, opts}

  def handle(body, facts, opts \\ [])

  def handle(body, {module, state} = facts, opts) when is_map(body) do
    identity = Map.take(body, ~w(version id run entry gate gate_version subject))

    result =
      with 1 <- body["version"],
           true <- Enum.all?(~w(id run gate subject), &is_binary(body[&1])),
           true <- is_integer(body["entry"]) and body["entry"] > 0,
           gates = Keyword.get_lazy(opts, :gates, &Definitions.gates/0),
           {:ok, gate} <- Definitions.fetch(body["gate"], gates),
           true <- gate["version"] == body["gate_version"] do
        case body["operation"] do
          "prepare" ->
            with {:ok, request} <-
                   Decider.request(
                     body["gate"],
                     body["subject"],
                     facts,
                     Keyword.merge(opts, gates: gates, flow: body["flow"] || %{})
                   ) do
              {:ok,
               %{
                 "request" =>
                   Map.put(wire(request), "fingerprint_definition", gate["fingerprint"])
               }}
            end

          "decide" ->
            attrs = body["request"]

            with true <- is_map(attrs) and attrs["subject"] == body["subject"],
                 true <- Digest.of_term(attrs["evidence"]) == attrs["evidence_digest"],
                 {:ok, subject} when is_map(subject) <- module.fetch(state, nil, body["subject"]),
                 true <-
                   SubjectFingerprint.of(subject, gate["fingerprint"]) == attrs["fingerprint"],
                 digest = Digest.of_term(Map.drop(body, ["operation"])),
                 {:ok, existing} <- binding(facts, body["id"], digest, opts),
                 {:ok, request} <-
                   Request.new(
                     body["gate"],
                     Map.merge(attrs, %{"activity_id" => body["id"], "activity_digest" => digest}),
                     gates
                   ),
                 {:ok, verdict} <- recorded_or_decide(existing, request, facts, opts) do
              {:ok,
               %{
                 "outcome" => verdict.outcome,
                 "recorded" => verdict.recorded,
                 "fingerprint" => request.fingerprint,
                 "evidence_digest" => request.evidence_digest
               }}
            end

          _ ->
            {:error, :unknown_operation}
        end
      end

    case result do
      {:ok, answer} -> Map.merge(identity, answer)
      other -> Map.put(identity, "error", inspect(other))
    end
  end

  def handle(_, _, _), do: %{"version" => 1, "error" => "invalid gate activity request"}

  defp binding({module, state}, id, digest, opts) do
    with {:ok, records} <-
           module.fetch(state, Keyword.get_lazy(opts, :kind, &AtlasGates.Record.kind/0), nil) do
      matching = Enum.filter(records, &(&1["values"]["activity_id"] == id))

      cond do
        Enum.any?(matching, &(&1["values"]["activity_digest"] != digest)) ->
          {:error, :activity_conflict}

        length(matching) > 1 ->
          {:error, :ambiguous_activity}

        true ->
          {:ok, List.first(matching)}
      end
    end
  end

  defp recorded_or_decide(nil, request, facts, opts), do: AtlasGates.decide(request, facts, opts)

  defp recorded_or_decide(existing, request, {module, state}, opts) do
    kind = Keyword.get_lazy(opts, :kind, &AtlasGates.Record.kind/0)

    repaired =
      if function_exported?(module, :ensure_links, 5),
        do: module.ensure_links(state, kind, request.id, existing["key"], request.links),
        else: {:ok, existing["key"]}

    with {:ok, key} <- repaired,
         do: {:ok, %{recorded: key, outcome: existing["values"]["verdict"]}}
  end

  defp wire(r),
    do: %{
      "subject" => r.subject,
      "gate_version" => r.gate_version,
      "fingerprint" => r.fingerprint,
      "evidence" => r.evidence,
      "evidence_digest" => r.evidence_digest,
      "allowed_outcomes" => r.allowed_outcomes,
      "links" => r.links
    }
end
