defmodule AtlasFlow.Activities.Effect do
  @moduledoc """
  Effects: one call to an outside service per `(run, entry, activity name)`.

  The request, its subject fingerprint and frozen payload are stored in the run before
  anything is sent. Every attempt carries the same id and digest: the first submits, a
  retry looks the id up, and only a lookup that the receiver answers `not_found` submits
  again. A missing answer is never taken as proof that nothing happened. Replies are
  fenced by id, digest and fingerprint; a reply for another entry or payload is ignored.

  A receiver is enabled per operation (`create`, `update`, `integrate`) by
  `config :atlas_flow, :effect_receivers, %{service => %{"contract" => 1, "address" =>
  bus_endpoint, "operations" => [...]}}`. List an operation only after that receiver
  passes the receiver contract (`AtlasFlow.EffectReceiverContract` in Flow's tests): it
  returns the original result for a repeated id, rejects a changed payload under that
  id, and recovers a lost answer by lookup. A definition naming any other service or
  operation is refused before any write. Nothing is enabled by default.

  An integration is approved by the run's own composition. `approved` names the subject
  field its approvals are about: an identity, such as a revision, that the fingerprint
  covers. `approving` says what approves it: `%{field => [value]}`, a field a link of
  the composition writes and the values of it that approve. It is approved when, for
  every such field, the run applied that field's link, from a child current for the
  value `approved` holds now, and the value the link wrote (its `states` mapping of the
  child's state) is one of those; and every other link the run applied with a current
  child was current for that value too. Flow applies a link only from the child current
  for that identity, so an approval of an earlier one never counts, and a rejection of
  this one is no approval. The frozen request carries `approved`: the fingerprint so
  approved.

  Before its request is frozen, an effect's state takes its plain branches (those of no
  role) like a state without a mechanism (`AtlasFlow.Runs.Run.unfrozen/4`): what is
  decided by hand while nothing has been asked of the service still moves the run. Once
  it is frozen, only the service's answer does.
  """
  alias AtlasBus.{Digest, SubjectFingerprint}

  @operations ~w(create update integrate)
  @endpoint "flow/effects"

  def receivers, do: Application.get_env(:atlas_flow, :effect_receivers, %{})

  def valid?(spec, receivers \\ receivers()) do
    is_map(spec) and spec["contract"] == 1 and text?(spec["name"]) and text?(spec["field"]) and
      spec["operation"] in @operations and enabled?(receivers, spec) and
      is_map(spec["fingerprint"]) and is_list(spec["fingerprint"]["fields"]) and
      is_list(spec["fingerprint"]["relations"]) and texts?(spec["payload"]) and
      mapping?(spec["outputs"] || %{}) and valid_records?(spec["records"]) and
      (spec["operation"] == "create" or text?(spec["target"])) and
      (spec["operation"] != "integrate" or
         (text?(spec["approved"]) and spec["approved"] in spec["fingerprint"]["fields"] and
            approving?(spec["approving"])))
  end

  defp approving?(a),
    do:
      is_map(a) and a != %{} and
        Enum.all?(a, fn {f, vs} -> text?(f) and vs != [] and texts?(vs) end)

  defp enabled?(receivers, spec) do
    case receivers[spec["service"]] do
      %{"contract" => 1, "address" => address, "operations" => ops} when is_list(ops) ->
        text?(address) and spec["operation"] in ops

      _ ->
        false
    end
  end

  defp valid_records?(nil), do: true

  defp valid_records?(r),
    do: is_map(r) and text?(r["kind"]) and text?(r["relation"]) and mapping?(r["outputs"])

  defp mapping?(m), do: is_map(m) and Enum.all?(m, fn {k, v} -> text?(k) and text?(v) end)
  defp texts?(l), do: is_list(l) and Enum.all?(l, &text?/1)
  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  @doc """
  The frozen intent, or `{:error, :not_ready}` while the subject lacks what the request
  needs: an update's or integration's target, or for an integration the run's approval of
  the identity the subject holds now (see the module's documentation). `links` are the
  composition's links of the run's subject kind: what each applied source wrote.
  """
  def freeze(run, spec, subject, receivers \\ receivers(), links \\ []) do
    values = subject["values"] || %{}
    fingerprint = SubjectFingerprint.of(subject, spec["fingerprint"])
    target = spec["target"] && values[spec["target"]]

    cond do
      not valid?(spec, receivers) ->
        {:error, :invalid_effect_binding}

      spec["operation"] != "create" and not text?(target) ->
        {:error, :not_ready}

      spec["operation"] == "integrate" and
          not approved?(run, spec["approving"], values[spec["approved"]], links) ->
        {:error, :not_ready}

      true ->
        request =
          %{
            "version" => 1,
            "id" => id(run, spec),
            "run" => run["key"],
            "entry" => run["entry"],
            "name" => spec["name"],
            "subject" => subject["key"],
            "service" => spec["service"],
            "operation" => spec["operation"],
            "fingerprint_definition" => spec["fingerprint"],
            "fingerprint" => fingerprint,
            "payload" => Map.new(spec["payload"], &{&1, values[&1]})
          }
          |> then(&if(target, do: Map.put(&1, "target", target), else: &1))
          |> then(&if(spec["approved"], do: Map.put(&1, "approved", fingerprint), else: &1))

        {:ok,
         %{
           "request" => request,
           "digest" => Digest.of_term(request),
           "address" => receivers[spec["service"]]["address"],
           "attempt" => "submit"
         }}
    end
  end

  # Each approving field's link applied from a child current for `identity`, having
  # written an approving value; every link applied with a current child current for it.
  defp approved?(run, approving, identity, links) do
    applied = get_in(run, ["pending", "composition", "links"]) || %{}
    currents = for {_field, %{"current" => current}} <- applied, current != nil, do: current

    text?(identity) and Enum.all?(currents, &(&1 == identity)) and
      Enum.all?(approving, fn {field, values} ->
        with %{"current" => ^identity, "state" => state} <- applied[field],
             %{"states" => %{} = states} <- Enum.find(links, &(&1["field"] == field)) do
          states[state] in values
        else
          _ -> false
        end
      end)
  end

  def id(run, spec),
    do:
      String.replace_prefix(
        Digest.of_term([run["key"], run["entry"], spec["name"]]),
        "sha256:",
        ""
      )

  @doc "Whether the subject still has the fingerprint the request was frozen for."
  def current?(intent, subject),
    do:
      SubjectFingerprint.of(subject, intent["request"]["fingerprint_definition"]) ==
        intent["request"]["fingerprint"]

  # No receive timeout: reconciliation and its injected clock drive every retry.
  def poll(intent, now) do
    case GenServer.call(__MODULE__.Inbox, {:poll, intent, now}) do
      {:reply, reply} -> validate_reply(intent, reply)
      waiting -> waiting
    end
  end

  @doc """
  `{:ok, reply}` for a fenced `done` or `refused`; `{:retry, intent}` when a lookup found
  no such id, so the same request may be submitted again; `{:error,
  :effect_requires_reconciliation}` for an unknown remote outcome or a conflicting id;
  `{:error, :invalid_effect_evidence}` for anything else, which is ignored.
  """
  def validate_reply(intent, reply) when is_map(reply) do
    r = intent["request"]

    fenced =
      reply["version"] == 1 and reply["id"] == r["id"] and reply["digest"] == intent["digest"] and
        reply["fingerprint"] == r["fingerprint"]

    cond do
      fenced and reply["status"] == "done" and text?(reply["reference"]) and
          is_map(reply["outputs"]) ->
        {:ok, reply}

      fenced and reply["status"] == "refused" and text?(reply["reason"]) ->
        {:ok, reply}

      fenced and reply["status"] == "not_found" ->
        {:retry, Map.merge(intent, %{"attempt" => "submit", "retry_at" => nil})}

      # A conflict answers for the id, whatever digest it carries: someone else's payload
      # is already bound to it, so this request cannot be completed by retrying.
      reply["version"] == 1 and reply["id"] == r["id"] and
          reply["status"] in ["unknown", "conflict"] ->
        {:error, :effect_requires_reconciliation}

      true ->
        {:error, :invalid_effect_evidence}
    end
  end

  def validate_reply(_, _), do: {:error, :invalid_effect_evidence}

  @doc """
  The replayable Facts writes for a fenced `done` or `refused` reply, in order: the
  declared record (created once under a key derived from the activity id), then the
  result field and declared outputs on the subject.
  """
  def writes(intent, spec, run, reply) do
    r = intent["request"]
    outputs = reply["outputs"] || %{}

    record =
      with "done" <- reply["status"], %{} = rec <- spec["records"] do
        key = Digest.of_term([r["id"], "record"]) |> String.replace_prefix("sha256:", "")

        [
          %{
            "id" => key,
            "kind" => rec["kind"],
            "content" => %{
              "op" => "create",
              "key" => key,
              "values" => Map.new(rec["outputs"], fn {field, out} -> {field, outputs[out]} end),
              "links" => %{rec["relation"] => [run["subject_key"]]},
              "by" => "flow"
            }
          }
        ]
      else
        _ -> []
      end

    values =
      if reply["status"] == "done",
        do: Map.new(spec["outputs"] || %{}, fn {out, field} -> {field, outputs[out]} end),
        else: %{}

    subject = %{
      "id" => Digest.of_term([r["id"], "result"]) |> String.replace_prefix("sha256:", ""),
      "kind" => run["subject_kind"],
      "content" => %{
        "op" => "change",
        "key" => run["subject_key"],
        "by" => "flow",
        "values" => Map.put(values, spec["field"], reply["status"])
      }
    }

    record ++ [subject]
  end

  def endpoint, do: @endpoint
end

defmodule AtlasFlow.Activities.Effect.Inbox do
  @moduledoc false
  use GenServer
  alias AtlasBus.Envelope
  alias AtlasFlow.Activities.Effect

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ok = AtlasBus.attach(Effect.endpoint())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:poll, intent, now}, _, state) do
    key = {intent["request"]["id"], intent["address"]}

    case Map.pop(state, key) do
      {%{} = reply, rest} ->
        {:reply, {:reply, reply}, rest}

      {_, rest} ->
        if intent["retry_at"] == nil or
             DateTime.compare(now, AtlasFlow.Runs.Run.parse!(intent["retry_at"])) != :lt do
          {id, address} = key
          attempt = intent["attempt"] || "submit"

          e = %{
            Envelope.new("request", "flow_effect", id: id <> "." <> attempt)
            | address: address
          }

          :ok =
            AtlasBus.send(e, %{
              "operation" => attempt,
              "request" => intent["request"],
              "digest" => intent["digest"]
            })

          # The next attempt, unanswered, recovers this one by lookup.
          updated =
            Map.merge(intent, %{
              "attempt" => "lookup",
              "retry_at" => DateTime.add(now, 1000, :millisecond) |> DateTime.to_iso8601()
            })

          # Disposable: the run in Facts retains every request needed to rebuild it.
          rest = if map_size(rest) >= 1024, do: %{}, else: rest
          {:reply, {:waiting, updated}, Map.put(rest, key, :awaiting)}
        else
          {:reply, {:waiting, intent}, state}
        end
    end
  end

  @impl true
  def handle_info(
        {:atlas_bus, %Envelope{class: "answer", kind: "flow_effect", sender: sender}, reply},
        state
      ) do
    key = {is_map(reply) && reply["id"], sender}
    {:noreply, if(Map.has_key?(state, key), do: Map.put(state, key, reply), else: state)}
  end

  def handle_info(_, state), do: {:noreply, state}
end
