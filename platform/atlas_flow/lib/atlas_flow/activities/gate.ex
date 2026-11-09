defmodule AtlasFlow.Activities.Gate do
  @moduledoc "Versioned gate activity protocol. Only a recorded, fenced reply can advance an entry."
  alias AtlasBus.Digest

  def intent(run, spec) do
    %{
      "version" => 1,
      "id" => Digest.of_term([run["key"], run["entry"], "gate"]),
      "run" => run["key"],
      "entry" => run["entry"],
      "gate" => spec["gate"],
      "gate_version" => spec["version"],
      "subject" => run["subject_key"],
      "flow" => %{
        "timed_out" => is_binary(run["last_input"]["due"]),
        "waited_from" => run["last_input"]["waited_from"],
        "due" => run["last_input"]["due"]
      }
    }
  end

  def freeze(intent, reply) when is_map(intent) and is_map(reply) do
    with :ok <- fence(intent, reply),
         %{"fingerprint" => fp, "evidence" => evidence, "evidence_digest" => digest} <-
           reply["request"],
         true <-
           is_binary(fp) and fp != "" and is_map(evidence) and Digest.of_term(evidence) == digest,
         request = reply["request"],
         true <-
           request["subject"] == intent["subject"] and
             request["gate_version"] in [
               intent["gate_version"],
               to_string(intent["gate_version"])
             ],
         true <- is_map(request["fingerprint_definition"]),
         true <- is_list(request["allowed_outcomes"]) and request["allowed_outcomes"] != [] do
      {:ok, Map.put(intent, "request", reply["request"])}
    else
      _ -> {:error, :invalid_gate_snapshot}
    end
  end

  def freeze(_, _), do: {:error, :invalid_gate_snapshot}

  def result(intent, reply) when is_map(intent) and is_map(reply) do
    with :ok <- fence(intent, reply),
         true <- reply["fingerprint"] == intent["request"]["fingerprint"],
         true <- reply["evidence_digest"] == intent["request"]["evidence_digest"],
         true <- is_binary(reply["recorded"]) and reply["recorded"] != "",
         allowed when is_list(allowed) <- intent["request"]["allowed_outcomes"],
         true <- reply["outcome"] in allowed do
      {:ok, Map.put(reply, "fingerprint_definition", intent["request"]["fingerprint_definition"])}
    else
      _ -> {:error, :invalid_gate_result}
    end
  end

  def result(_, _), do: {:error, :invalid_gate_result}

  defp fence(intent, reply) do
    if reply["version"] == 1 and reply["error"] == nil and
         Enum.all?(~w(id run entry gate gate_version subject), &(reply[&1] == intent[&1])),
       do: :ok,
       else: {:error, :gate_reply_mismatch}
  end
end
