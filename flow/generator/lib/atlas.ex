defmodule AtlasFlowGenerator.Atlas do
  @moduledoc """
  Writes `flows.json`: what Atlas needs to run the subflows that Rela's `flows.yaml`
  cannot say. It holds

    * `format` (this file's format, `2`) and `writer` (`system:atlas-flow`);
    * `rela_flows_sha256`: the SHA-256 of the `flows.yaml` generated in the same run,
      byte for byte, so a runner can refuse a `flows.yaml` from another run;
    * `gates`: every gate given, by name, as data (version, flavor, purpose,
      evidence, advice or rule, verdicts, person, decide, policy), whether or not a
      subflow names it;
    * `flows`: each subflow by name, with its subject, owner (`via`, `relation`, and
      `default` as `{kind, key}`), channel, initial state, and `states`: each state
      with its label, whether it is final, its own `owner` when it has one (as the
      subflow's is written), its mechanism as `kind` and `spec`, and
      `present`: what its owner sees, as `expected`, `why` and `todo` (`instructions`,
      `section` as `{field, heading}`, `answers` as `[{key, label, set | remove}]`);
    * executable start, run identity policy, state status, waiting roles, awaited
      fields, ordered branches, entry sets, creates and timers. Empty execution lists
      are explicit. Composition is deliberately not emitted yet.

  The writer reads only the data of `__flows__/0` and `__gates__/0`. Every object's
  keys are written sorted, two spaces deep, one key per line; a list of plain values
  stays on one line. The bytes therefore depend only on the data, never on the
  order in which a map happens to be laid out, so two builds give the same file.
  Keyword lists become objects and tuples become lists; keys with no value are left
  out.
  """

  @format 2
  @writer "system:atlas-flow"

  @doc """
  The JSON text of `flows` and `gates`, bound to the `flows.yaml` whose SHA-256 (lower
  case hex) is `rela_flows_sha256`. Raises when a state names a gate, or a gate
  version, that `gates` does not hold.
  """
  def flows_json(flows, gates, rela_flows_sha256) do
    check_gates!(flows, gates)

    %{
      format: @format,
      writer: @writer,
      rela_flows_sha256: rela_flows_sha256,
      gates: Map.new(gates, &{&1.name, gate(&1)}),
      flows: Map.new(flows, &{&1.name, flow(&1)})
    }
    |> encode()
  end

  @doc "SHA-256 of `bytes`, lower case hex, as `rela_flows_sha256` holds it."
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # decide and policy are mappings, so objects even when empty.
  defp gate(g) do
    g
    |> Map.update!(:decide, &Map.new/1)
    |> Map.update!(:policy, &Map.new/1)
    |> Map.take([
      :fixed,
      :fixed_rules,
      :answer_within,
      :fingerprint,
      :version,
      :flavor,
      :purpose,
      :evidence,
      :advice,
      :rule,
      :verdicts,
      :person,
      :decide,
      :policy
    ])
  end

  defp flow(f) do
    %{
      label: f.label,
      subject: f.subject,
      run_as: f.run_as,
      per_subject: f.per_subject,
      start: f.start,
      owner: f.owner,
      channel: f.channel,
      initial: f.initial,
      states: Map.new(f.states, &{&1.name, state(&1)})
    }
  end

  defp state(s) do
    mechanism =
      case s.mechanism do
        nil -> %{}
        {kind, spec} -> %{kind: kind, spec: spec}
      end

    Map.merge(
      %{
        label: s.label,
        final: s.final,
        status: s.status,
        waiting_for: s.waiting_for,
        awaits: s.awaits,
        set: Enum.map(s.set, fn {field, value} -> %{field: field, value: value} end),
        creates: s.creates,
        branches: s.branches,
        timers: s.timers,
        present: present(s.present),
        owner: s.owner
      },
      mechanism
    )
  end

  # What the owner sees, in the shape the description's flows have always given it:
  # `expected` and `why`, and `todo` with the instructions, the section and the answers.
  defp present(nil), do: nil

  defp present(p) do
    todo =
      %{instructions: p.instructions, section: p.section, answers: nonempty(p.answers)}
      |> Map.reject(fn {_, v} -> v == nil end)

    %{expected: p.expected, why: p.why, todo: if(todo != %{}, do: todo)}
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp check_gates!(flows, gates) do
    names = Enum.map(gates, & &1.name)
    if names != Enum.uniq(names), do: raise(ArgumentError, "a gate is given twice")
    versions = Map.new(gates, &{&1.name, &1.version})

    for f <- flows, %{mechanism: {:gate, %{gate: g, version: v}}} = s <- f.states do
      if versions[g] != v do
        raise ArgumentError,
              "subflow #{f.name}, state #{s.name}: names gate #{g} version #{v}, " <>
                "which the gates do not hold"
      end
    end
  end

  # -- JSON, keys sorted --

  defp encode(term), do: IO.iodata_to_binary([value(term, ""), "\n"])

  defp value(map, indent) when is_map(map) do
    pairs = for {k, v} <- map, v != nil, do: {key(k), v}
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys != Enum.uniq(keys),
      do: raise(ArgumentError, "a key is given twice in #{inspect(map)}")

    object(Enum.sort_by(pairs, &elem(&1, 0)), indent)
  end

  defp value([{k, _} | _] = list, indent) when is_atom(k) do
    if Keyword.keyword?(list), do: value(Map.new(list), indent), else: array(list, indent)
  end

  defp value(list, indent) when is_list(list), do: array(list, indent)
  defp value(tuple, indent) when is_tuple(tuple), do: array(Tuple.to_list(tuple), indent)
  defp value(scalar, _indent), do: scalar(scalar)

  defp object([], _indent), do: "{}"

  defp object(pairs, indent) do
    inner = indent <> "  "
    lines = for {k, v} <- pairs, do: [inner, JSON.encode!(k), ": ", value(v, inner)]
    ["{\n", Enum.intersperse(lines, ",\n"), "\n", indent, "}"]
  end

  defp array([], _indent), do: "[]"

  defp array(list, indent) do
    if Enum.all?(list, &plain?/1) do
      ["[", Enum.map_intersperse(list, ", ", &scalar/1), "]"]
    else
      inner = indent <> "  "
      lines = for v <- list, do: [inner, value(v, inner)]
      ["[\n", Enum.intersperse(lines, ",\n"), "\n", indent, "]"]
    end
  end

  defp plain?(v), do: is_binary(v) or is_number(v) or is_atom(v)

  defp scalar(v) when is_boolean(v) or is_nil(v) or is_number(v) or is_binary(v),
    do: JSON.encode!(v)

  defp scalar(v) when is_atom(v), do: JSON.encode!(Atom.to_string(v))
  defp scalar(v), do: raise(ArgumentError, "#{inspect(v)} has no JSON form")

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_binary(k), do: k
  defp key(k), do: raise(ArgumentError, "#{inspect(k)} is not a key")
end
