ExUnit.start()

defmodule AtlasGates.Fixtures do
  @moduledoc """
  Made-up gates for Gates' tests, written as the generated definitions are: a rule gate
  that dispatches a crate when its seal is intact and it is loaded as packed, one whose rule
  names a field it does not declare, and a smart gate. Their safe verdict is `ask`.
  """

  @decide %{
    "pass" => "ship",
    "changes_required" => "repack",
    "uncertain" => "ask",
    "error" => "ask"
  }

  def gates do
    %{
      "dispatch" => %{
        "version" => 2,
        "flavor" => "rule",
        "purpose" => "flow",
        "evidence" => ["seal", "packed_hash", "loaded_hash"],
        "rule" => %{
          "all" => [["equals", "seal", "intact"], ["same", "packed_hash", "loaded_hash"]]
        },
        "decide" => @decide,
        "verdicts" => ["ship", "repack", "ask"],
        "policy" => %{}
      },
      "careless" => %{
        "version" => 1,
        "flavor" => "rule",
        "purpose" => "decider",
        "evidence" => ["seal"],
        "rule" => %{"all" => [["equals", "seal", "intact"], ["equals", "weight", "light"]]},
        "decide" => @decide,
        "verdicts" => ["ship", "repack", "ask"]
      },
      "taste" => %{
        "version" => 1,
        "flavor" => "smart",
        "purpose" => "flow",
        "evidence" => ["sample"],
        "decide" => @decide,
        "verdicts" => ["ship", "repack", "ask"]
      }
    }
  end

  def gate(name), do: Map.fetch!(gates(), name)

  def evidence(changes \\ %{}),
    do: Map.merge(%{"seal" => "intact", "packed_hash" => "h-1", "loaded_hash" => "h-1"}, changes)

  def digest(evidence), do: AtlasBus.Digest.of_bytes(JSON.encode!(evidence))

  @doc "A request for `gate` on `evidence`, about crate C-7 at fingerprint f-1."
  def request(gate \\ "dispatch", evidence \\ evidence(), attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "subject" => "C-7",
          "fingerprint" => "f-1",
          "evidence" => evidence,
          "evidence_digest" => digest(evidence)
        },
        attrs
      )

    {:ok, request} = AtlasGates.Request.new(gate, attrs, gates())
    request
  end

  def now, do: ~U[2026-11-11 14:05:07.123Z]
end

defmodule AtlasGates.FakeFacts do
  @moduledoc """
  An in-memory Facts for Gates' recording tests (`AtlasGates.Facts`): keeps verdicts as
  Facts would, keys R-1, R-2, …; `fail: :create` refuses every create, `fail: :find`
  cannot read.
  """
  @behaviour AtlasGates.Facts

  def start(opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> %{facts: [], fail: opts[:fail]} end)
    {__MODULE__, pid}
  end

  @impl true
  def fetch(pid, kind, key) do
    Agent.get(pid, fn s ->
      facts =
        Enum.map(s.facts, fn f ->
          %{
            "key" => f.key,
            "values" => f.values,
            "links" => Map.new(f.links, fn {r, k} -> {r, List.wrap(k)} end),
            "kind" => f.kind
          }
        end)

      if key,
        do: {:ok, Enum.find(facts, &(&1["key"] == key))},
        else: {:ok, Enum.filter(facts, &(&1["kind"] == kind))}
    end)
  end

  def facts({__MODULE__, pid}),
    do: Agent.get(pid, &Enum.reverse(&1.facts))

  @impl true
  def find(pid, kind, identity) do
    Agent.get(pid, fn
      %{fail: :find} ->
        {:error, "Facts could not read #{kind}"}

      s ->
        found =
          Enum.find(s.facts, fn f ->
            f.kind == kind and
              Enum.all?(
                identity,
                &(&1 in Enum.map(Map.values(f.values), fn v -> to_string(v) end))
              )
          end)

        {:ok, found && found.key}
    end)
  end

  @impl true
  def create(pid, kind, request_id, values, links) do
    Agent.get_and_update(pid, fn
      %{fail: :create} = s ->
        {{:error, "Facts refused it: a test refusal"}, s}

      s ->
        key = "R-#{length(s.facts) + 1}"
        fact = %{key: key, kind: kind, request: request_id, values: values, links: links}
        {{:ok, key}, %{s | facts: [fact | s.facts]}}
    end)
  end
end
