defmodule AtlasFlow.Activities.Pass do
  @moduledoc """
  Frozen pass requests and asynchronous, owner-specific Runtime delivery.

  A spec is data from the compiled subflow: `contract`, `name`, `routing` (the owner's
  field naming its machine), `fingerprint` (the subject's deciding fields and relations)
  and `request` (assignment, mode, permissions, backend, vendors, and `cwd` unless the
  request works on a packet). Two forms of request:

    * a fixed folder (`cwd`, permissions `read-only` or `workspace-write`);
    * a frozen review packet (permissions `review-packet`, `packet_contract: 1`): its
      folder, identity and revision are the subject's, named by `packet_from` (`cwd`,
      `packet_id`, `fingerprint`, `revision`, each a field of the subject, each in the
      fingerprint), so a pass is frozen on the packet the subject names when it is frozen,
      and a changed one fences it. Runtime takes the packet only if it was frozen for that
      `revision` (it records the one it is for), so a pass never reviews another revision's.

  A shared pass (`with_person: true`, `writes: "none"`) leaves its state to the ones it
  waits for (`wait_for`) and to its timers as well: an owner the routing field names no
  machine of answers by hand, and nothing is frozen for them. Its `answer` (optional)
  says how a completed pass becomes the owner's own answer: the subject's `field` set to
  the value its outcome maps to (`outcomes`), `by` (a relation) naming the owner, taken
  as the input of `role` (`answer/3`). An outcome it does not map, or a reply Runtime
  marks for reconciliation, answers nothing: it is kept as the pass's result, the run stays active for
  the answer by hand and the timers, and that binding is not asked again; a changed binding
  leaves it (kept with the run's passes) and freezes another.
  """
  alias AtlasBus.{Digest, SubjectFingerprint}

  def valid?(spec) do
    is_map(spec) and spec["contract"] == 1 and text?(spec["name"]) and
      is_map(spec["routing"]) and text?(spec["routing"]["machine_field"]) and
      is_map(spec["fingerprint"]) and
      is_list(spec["fingerprint"]["fields"]) and is_list(spec["fingerprint"]["relations"]) and
      valid_request?(spec["request"], spec) and valid_sharing?(spec)
  end

  defp valid_request?(r, spec) when is_map(r) do
    text?(r["assignment"]) and r["mode"] == "start" and
      r["backend"] in ["codex", "claude"] and is_list(r["vendors"]) and
      r["backend"] in r["vendors"] and
      case r["permissions"] do
        "review-packet" ->
          from = spec["packet_from"]

          r["packet_contract"] == 1 and not Map.has_key?(r, "cwd") and
            not Map.has_key?(r, "packet") and is_map(from) and
            Enum.sort(Map.keys(from)) == ~w(cwd fingerprint packet_id revision) and
            Enum.all?(Map.values(from), &(text?(&1) and &1 in spec["fingerprint"]["fields"]))

        permissions when permissions in ["read-only", "workspace-write"] ->
          text?(r["cwd"]) and Path.type(r["cwd"]) == :absolute and
            not Map.has_key?(spec, "packet_from")

        _ ->
          false
      end
  end

  defp valid_request?(_, _), do: false

  # A pass that writes no result field is a shared one; only it may answer for its owner,
  # with a value for each outcome it maps.
  defp valid_sharing?(spec) do
    case {spec["writes"], spec["answer"]} do
      {nil, nil} ->
        spec["with_person"] in [nil, false]

      {"none", nil} ->
        spec["with_person"] == true

      {"none", %{} = a} ->
        spec["with_person"] == true and Enum.sort(Map.keys(a)) == ~w(by field outcomes role) and
          text?(a["field"]) and text?(a["by"]) and text?(a["role"]) and
          is_map(a["outcomes"]) and a["outcomes"] != %{} and
          Enum.all?(a["outcomes"], fn {k, v} -> text?(k) and text?(v) end)

      _ ->
        false
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  @doc "Whether the pass is shared: its state's inputs, branches and timers go on beside it."
  def with_person?(spec), do: is_map(spec) and spec["with_person"] == true

  def freeze(run, spec, subject, assignment, owner) do
    machine = owner["values"][spec["routing"]["machine_field"]]

    with true <- valid?(spec) and text?(machine) and text?(owner["key"]),
         {:ok, request} <- bind(spec, subject) do
      fingerprint = SubjectFingerprint.of(subject, spec["fingerprint"])

      request = %{
        "version" => 1,
        "run" => run["key"],
        "entry" => run["entry"],
        "name" => spec["name"],
        "subject" => subject["key"],
        "owner" => owner["key"],
        "machine" => machine,
        "machine_field" => spec["routing"]["machine_field"],
        "assignment" => assignment,
        "fingerprint_definition" => spec["fingerprint"],
        "fingerprint" => fingerprint,
        "request" => request
      }

      # Hash the complete frozen binding, including the assignment current?/4 compares.
      # Only new intents come here; stored intents retain their authoritative ids.
      id = String.replace_prefix(Digest.of_term(request), "sha256:", "")
      request = Map.put(request, "id", id)

      {:ok, %{"request" => request, "digest" => Digest.of_term(request)}}
    else
      _ -> {:error, :invalid_pass_binding}
    end
  end

  # The request as the subject gives it now: a packet's folder, identity and the revision it
  # must be of, from its fields.
  defp bind(%{"packet_from" => from, "request" => r}, subject) do
    values = subject["values"] || %{}

    [cwd, id, fingerprint, revision] =
      Enum.map(~w(cwd packet_id fingerprint revision), &values[from[&1]])

    if text?(cwd) and Path.type(cwd) == :absolute and text?(id) and text?(fingerprint) and
         text?(revision),
       do:
         {:ok,
          Map.merge(r, %{
            "cwd" => cwd,
            "packet" => %{"packet_id" => id, "fingerprint" => fingerprint, "revision" => revision}
          })},
       else: {:error, :no_packet}
  end

  defp bind(%{"request" => r}, _subject), do: {:ok, r}

  @doc """
  What a completed pass of `intent` answers for its owner, by `spec`'s `answer`:
  `{:answer, field, value, by, owner, role}` when its outcome maps to a value, `:none`
  when it does not (the state waits on for its answer by hand) or the pass answers nothing.
  """
  def answer(spec, intent, result) do
    with %{"outcomes" => outcomes} = a <- spec["answer"],
         value when is_binary(value) <- outcomes[result["outcome"]] do
      {:answer, a["field"], value, a["by"], intent["request"]["owner"], a["role"]}
    else
      _ -> :none
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
        {:error, {:pass_requires_reconciliation, reply["error"]}}

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
