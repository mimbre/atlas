defmodule AtlasFacts.Description do
  @moduledoc """
  Reads rela's description (`GET /_schema`) generically: which kinds exist, their
  properties, and the relations that point at them. Knows no kind by name.
  """

  @doc "The description of `kind`, or nil when rela does not describe it."
  def kind(description, kind), do: get_in(description, ["entities", kind])

  @doc "The relations whose facts point at a fact of `kind`: `[{relation, from_kind}]`."
  def incoming(description, kind) do
    for {relation, spec} <- description["relations"] || %{},
        kind in (spec["to"] || []),
        from <- spec["from"] || [],
        do: {relation, from}
  end

  @doc """
  The links a new fact of `kind` asks for (`%{relation => [keys]}`), checked against the
  description and resolved to `%{relation => {target kind, keys}}` for rela. A relation
  that points at several kinds gives the list of them (`{[kind], keys}`); which one each
  key is, Facts finds out (`AtlasFacts.Server`).
  """
  def targets(description, kind, links) when is_map(links) do
    relations = description["relations"] || %{}

    Enum.reduce(links, {:ok, %{}}, fn {relation, keys}, acc ->
      spec = relations[relation]

      problem =
        cond do
          spec == nil ->
            "#{relation} is not described"

          kind not in (spec["from"] || []) ->
            "#{relation} does not start at #{kind}"

          not (is_list(keys) and Enum.all?(keys, &(is_binary(&1) and &1 != ""))) ->
            "#{relation} needs a list of keys"

          (spec["to"] || []) == [] ->
            "#{relation} points at no kind"

          is_integer(spec["max_outgoing"]) and length(keys) > spec["max_outgoing"] ->
            "#{relation} allows at most #{spec["max_outgoing"]}"

          true ->
            nil
        end

      case {acc, problem} do
        {{:ok, targets}, nil} -> {:ok, Map.put(targets, relation, {to(spec["to"]), keys})}
        {{:ok, _}, problem} -> {:error, [problem]}
        {{:error, problems}, nil} -> {:error, problems}
        {{:error, problems}, problem} -> {:error, problems ++ [problem]}
      end
    end)
  end

  def targets(_description, _kind, _links), do: {:error, ["links must be a map"]}

  defp to([kind]), do: kind
  defp to(kinds), do: kinds

  @doc """
  Check `values` against the description of `kind` before rela sees them, because the
  current rela stores invalid values and only warns. `mode` is `:create` or `:change`.
  `nil` clears an optional value.
  """
  def check(spec, values, mode) do
    properties = spec["properties"] || %{}

    problems =
      Enum.flat_map(values, fn {name, value} -> check_value(properties[name], name, value) end) ++
        missing(properties, values, mode)

    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc "A key that fits the kind's id prefix, if it has one."
  def check_key(spec, key) do
    prefixes = spec["id_prefixes"] || List.wrap(spec["id_prefix"])

    cond do
      not is_binary(key) or String.trim(key) == "" ->
        {:error, ["id is missing"]}

      prefixes != [] and not Enum.any?(prefixes, &String.starts_with?(key, &1)) ->
        {:error, ["id must start with #{Enum.join(prefixes, " or ")}"]}

      true ->
        :ok
    end
  end

  defp missing(properties, values, mode) do
    for {name, %{"required" => true}} <- properties,
        mode == :create or Map.has_key?(values, name),
        blank?(values[name]),
        do: "#{name} is required"
  end

  defp check_value(nil, name, _value), do: ["#{name} is not described"]
  defp check_value(_spec, _name, nil), do: []

  defp check_value(%{"values" => allowed}, name, value) when is_list(allowed) do
    if value in allowed, do: [], else: ["#{name} must be one of #{Enum.join(allowed, ", ")}"]
  end

  defp check_value(%{"type" => "boolean"}, name, value),
    do: if(is_boolean(value), do: [], else: ["#{name} must be true or false"])

  defp check_value(%{"type" => "integer"}, name, value),
    do: if(is_integer(value), do: [], else: ["#{name} must be a whole number"])

  # rela stores a datetime that is none with a warning only; empty clears it.
  defp check_value(%{"type" => "datetime"}, name, value) do
    case is_binary(value) and (value == "" or match?({:ok, _, _}, DateTime.from_iso8601(value))) do
      true -> []
      false -> ["#{name} must be a date and time, e.g. 2026-11-04T17:00:00Z"]
    end
  end

  defp check_value(_spec, name, value),
    do: if(is_binary(value), do: [], else: ["#{name} must be text"])

  defp blank?(value), do: value in [nil, ""]
end
