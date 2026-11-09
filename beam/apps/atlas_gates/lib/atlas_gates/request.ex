defmodule AtlasGates.Request do
  @moduledoc """
  What a caller asks a gate: which gate and version, about which subject at which exact
  version (its fingerprint), on which evidence (a fixed map of named fields and the digest
  of the immutable snapshot it came from), and which verdicts are allowed. Gates does not
  browse for more: what is not in the evidence is missing.

  Its `id` is made from what identifies the decision (gate, gate version, rule version,
  subject, fingerprint and evidence digest), so asking the same again is the same request
  and is recorded once. `links` (relation to key) go with the recorded verdict, for
  example the fact it is about and the verdict it follows.
  """

  @enforce_keys [:id, :gate, :definition, :gate_version, :rule_version, :subject, :fingerprint]
  defstruct [
    :id,
    :gate,
    :definition,
    :gate_version,
    :rule_version,
    :subject,
    :fingerprint,
    :evidence_digest,
    :activity_id,
    :activity_digest,
    evidence: %{},
    allowed_outcomes: [],
    links: %{}
  ]

  @type t :: %__MODULE__{}

  alias AtlasBus.Digest

  @doc """
  A request for the gate `name` of `gates` (by default the generated definitions), from
  `attrs`: `subject`, `fingerprint`, `evidence` (a map), `evidence_digest`, and optionally
  `gate_version` (must be the definition's), `allowed_outcomes` (default: the gate's
  verdicts; the safe verdict is always allowed) and `links`. `{:ok, request}` or
  `{:error, reason}`: a request that cannot be asked gets no verdict, which a caller treats
  as the safe one.
  """
  def new(name, attrs, gates \\ AtlasGates.Definitions.gates()) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, gate} <- definition(name, gates),
         :ok <- version(gate, attrs["gate_version"]),
         :ok <- text(attrs, "subject"),
         :ok <- text(attrs, "fingerprint"),
         :ok <- digest(attrs["evidence_digest"]),
         :ok <- evidence(attrs["evidence"]),
         {:ok, allowed} <- allowed(gate, attrs["allowed_outcomes"]),
         {:ok, links} <- links(attrs["links"]) do
      request = %__MODULE__{
        id: nil,
        gate: name,
        definition: gate,
        gate_version: to_string(gate["version"]),
        rule_version: rule_version(gate),
        subject: attrs["subject"],
        fingerprint: attrs["fingerprint"],
        evidence: attrs["evidence"],
        evidence_digest: attrs["evidence_digest"],
        activity_id: attrs["activity_id"],
        activity_digest: attrs["activity_digest"],
        allowed_outcomes: allowed,
        links: links
      }

      {:ok, %{request | id: id(request)}}
    end
  end

  @doc "The values that identify the decision; a recorded verdict with all of them is this request's."
  def identity(%__MODULE__{} = r),
    do:
      [r.gate, r.gate_version, r.rule_version, r.subject, r.fingerprint, r.evidence_digest] ++
        if(r.activity_id, do: [r.activity_id, r.activity_digest], else: [])

  @doc "The verdict a gate gives when it cannot decide by itself: its decide map's verdict for an error."
  def safe_verdict(gate), do: get_in(gate, ["decide", "error"])

  defp id(request), do: "GR-" <> (request |> identity() |> Digest.of_term() |> binary_part(7, 32))

  # The exact rule a verdict came from: a digest of the gate's rule, or none for a gate without one.
  defp rule_version(%{"rule" => rule}), do: Digest.of_term(rule) |> binary_part(0, 23)
  defp rule_version(_gate), do: "none"

  defp definition(name, gates) when is_binary(name) and name != "" do
    case AtlasGates.Definitions.fetch(name, gates) do
      {:ok, gate} ->
        if is_binary(safe_verdict(gate)),
          do: {:ok, gate},
          else: {:error, "gate #{name} has no verdict for an error in its decide map"}

      :error ->
        {:error, "no gate is named #{inspect(name)}"}
    end
  end

  defp definition(_name, _gates), do: {:error, "a request names its gate"}

  defp version(_gate, nil), do: :ok

  defp version(gate, asked) do
    if to_string(asked) == to_string(gate["version"]),
      do: :ok,
      else:
        {:error, "gate version #{asked} is asked; the definition is version #{gate["version"]}"}
  end

  defp text(attrs, name) do
    if is_binary(attrs[name]) and String.trim(attrs[name]) != "",
      do: :ok,
      else: {:error, "a request names its #{name}"}
  end

  defp digest("sha256:" <> hex) when byte_size(hex) == 64, do: :ok
  defp digest(_), do: {:error, "a request gives its evidence_digest as sha256:<64 hex>"}

  defp evidence(evidence) when is_map(evidence), do: :ok
  defp evidence(_), do: {:error, "a request gives its evidence as a map of named fields"}

  defp allowed(gate, nil), do: allowed(gate, gate["verdicts"] || [])

  defp allowed(gate, outcomes) when is_list(outcomes) do
    known = gate["verdicts"] || []

    case Enum.reject(outcomes, &(&1 in known)) do
      [] -> {:ok, Enum.uniq(outcomes ++ [safe_verdict(gate)])}
      other -> {:error, "#{Enum.join(other, ", ")} is not a verdict of this gate"}
    end
  end

  defp allowed(_gate, _), do: {:error, "allowed_outcomes is a list"}

  defp links(nil), do: {:ok, %{}}

  defp links(links) when is_map(links) do
    if Enum.all?(links, fn {r, k} -> is_binary(r) and is_binary(k) and k != "" end),
      do: {:ok, links},
      else: {:error, "links map a relation to a key"}
  end

  defp links(_), do: {:error, "links map a relation to a key"}
end
