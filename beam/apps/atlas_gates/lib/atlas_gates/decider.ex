defmodule AtlasGates.Decider do
  @moduledoc "Asks who may decide a subject, using evidence and a fingerprint derived from its stored facts."
  alias AtlasBus.{Digest, SubjectFingerprint}
  alias AtlasGates.{Definitions, Evidence, Request}

  def ask(gate, subject_key, facts, opts \\ []) do
    with {:ok, request} <- request(gate, subject_key, facts, opts),
         do: AtlasGates.decide(request, facts, opts)
  end

  def request(name, key, {module, state} = facts, opts \\ []) do
    with {:ok, gate} <-
           Definitions.fetch(name, Keyword.get_lazy(opts, :gates, &Definitions.gates/0)),
         :ok <- decider(gate),
         {:ok, subject} when is_map(subject) <- module.fetch(state, nil, key),
         {:ok, evidence, previous} <- Evidence.build(name, gate, subject, facts, opts) do
      previous = Enum.find(previous, &(get_in(&1, ["values", "subject"]) == key))

      links =
        if previous, do: %{"about" => key, "follows" => previous["key"]}, else: %{"about" => key}

      Request.new(
        name,
        %{
          subject: key,
          fingerprint: SubjectFingerprint.of(subject, gate["fingerprint"]),
          evidence: evidence,
          evidence_digest: Digest.of_term(evidence),
          links: links
        },
        %{name => gate}
      )
    else
      :error -> {:error, "unknown gate #{inspect(name)}"}
      {:ok, nil} -> {:error, "no subject #{key}"}
      {:error, _} = error -> error
    end
  end

  defp decider(%{"purpose" => "decider", "fingerprint" => %{}}), do: :ok
  defp decider(_), do: {:error, "a decider gate needs a subject fingerprint definition"}
end
