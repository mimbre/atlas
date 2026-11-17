defmodule AtlasFlowBoundary.Generator.Targets.Boundary.Values do
  @moduledoc """
  What the structs and the facade of `AtlasFlowBoundary.Generator.Targets.Boundary`
  call at run time: building, checking and dumping values against a struct's fields, and
  a facade's call. Every struct module has `__fields__/0`: `[{name, type, required}]`,
  with a type of `:string`, `:integer`, `{:integer, min, max}` (a `range:` field),
  `:boolean`, `:datetime`, `{:enum, [atom]}`,
  `{:model, module}`, `{:one_of, [{name, module}], tag}`, `{:list, type}`,
  `{:map, type}` or `:stream`.

  A `:stream` value is anything that implements `Enumerable` (a list, a `Stream`, a
  `File.Stream`, a function of arity 2), except a plain map. It is checked without being
  enumerated, and passed on as it is. `dump/1` refuses to dump a struct with a stream in
  it: a stream is sent as bytes, never as JSON.
  """

  alias AtlasFlowBoundary.Generator.{ContractError, InvalidInput, NotPermitted}

  @doc false
  # `input` is nil for a capability without input, else `{module, given, invalid}`, where
  # `invalid` is `{outcome module, set, detail field, detail right}` or nil (see
  # `Targets.Boundary`).
  def call(facade, implementation, capability, right, client, input, outcomes) do
    at = "#{inspect(facade)}.#{capability}"

    rights =
      case client do
        {_id, rights} when is_list(rights) or is_struct(rights, MapSet) -> rights
        other -> raise ContractError, "#{at}: a client is {id, rights}, got #{inspect(other)}"
      end

    cond do
      not Enum.member?(rights, right) ->
        %NotPermitted{capability: capability, right: right}

      is_nil(input) ->
        answer(at, implementation, capability, [client], outcomes)

      true ->
        {module, given, invalid} = input

        case input(module, given) do
          {:ok, built} -> answer(at, implementation, capability, [client, built], outcomes)
          {:error, reasons} -> invalid(capability, invalid, reasons, rights)
        end
    end
  end

  # The input struct, from a built one (checked strictly) or a map or keyword list (through
  # new/1, JSON forms accepted).
  defp input(module, %module{} = given) do
    case validate(module, "input", given) do
      :ok -> {:ok, given}
      error -> error
    end
  end

  defp input(module, %other{}),
    do: {:error, ["input must be a #{inspect(module)}, got a #{inspect(other)}"]}

  defp input(module, given), do: new(module, "input", given)

  defp invalid(capability, nil, reasons, _rights),
    do: %InvalidInput{capability: capability, reasons: reasons}

  # With a detail right, only a client holding it gets the reasons as text.
  defp invalid(_capability, {module, set, detail, detail_right}, reasons, rights) do
    told = detail != nil and (detail_right == nil or Enum.member?(rights, detail_right))
    fields = if told, do: [{detail, Enum.join(reasons, "; ")} | set], else: set
    struct!(module, fields)
  end

  defp answer(at, implementation, capability, args, outcomes) do
    outcome = apply(implementation, capability, args)

    unless is_struct(outcome) and outcome.__struct__ in outcomes,
      do:
        raise(
          ContractError,
          "#{at}: #{inspect(implementation)} returned #{inspect(outcome)}, " <>
            "which is none of the declared outcomes #{Enum.map_join(outcomes, ", ", &inspect/1)}"
        )

    with {:error, reasons} <- validate(outcome.__struct__, "outcome", outcome),
         do: raise(ContractError, "#{at}: invalid outcome: #{Enum.join(reasons, "; ")}")

    outcome
  end

  @doc false
  def new(module, name, params) do
    case build(module, params, name, :cast) do
      {:ok, value} -> {:ok, value}
      {:error, reasons} -> {:error, reasons}
    end
  end

  @doc false
  def new!(module, name, params) do
    case new(module, name, params) do
      {:ok, value} -> value
      {:error, reasons} -> raise ArgumentError, Enum.join(reasons, "; ")
    end
  end

  @doc false
  def validate(module, name, value) do
    case build(module, value, name, :check) do
      {:ok, _value} -> :ok
      {:error, reasons} -> {:error, reasons}
    end
  end

  @doc false
  def dump(%module{} = value) do
    for {field, type, _required} <- module.__fields__(),
        (item = Map.fetch!(value, field)) != nil,
        into: %{},
        do: {Atom.to_string(field), dump(type, item, module, field)}
  end

  defp dump(:stream, _value, module, field),
    do:
      raise(
        ContractError,
        "#{inspect(module)}.#{field} is a :stream; a stream is sent as bytes, never dumped as JSON"
      )

  defp dump(type, value, _module, _field), do: dump(type, value)

  defp dump(:datetime, value), do: DateTime.to_iso8601(value)
  defp dump({:enum, _values}, value), do: Atom.to_string(value)
  defp dump({:model, _module}, value), do: dump(value)

  defp dump({:one_of, members, tag}, %module{} = value) do
    {name, _module} = List.keyfind(members, module, 1)
    Map.put(dump(value), Atom.to_string(tag), name)
  end

  defp dump({:list, inner}, values), do: Enum.map(values, &dump(inner, &1))
  defp dump({:map, inner}, values), do: Map.new(values, fn {k, v} -> {k, dump(inner, v)} end)
  defp dump(_primitive, value), do: value

  # `:cast` takes the JSON forms too; `:check` takes only built values.
  defp build(module, %module{} = value, at, mode) do
    fields = module.__fields__()

    errors =
      for {field, type, required} <- fields,
          reason <- field_errors(type, Map.get(value, field), required, "#{at}.#{field}", mode),
          do: reason

    if errors == [], do: {:ok, value}, else: {:error, errors}
  end

  defp build(module, params, at, :cast) when is_map(params) and not is_struct(params) do
    fields = module.__fields__()
    by_text = Map.new(fields, fn {field, _type, _required} -> {Atom.to_string(field), field} end)

    {given, unknown} =
      Enum.reduce(params, {%{}, []}, fn {key, value}, {given, unknown} ->
        field =
          cond do
            is_atom(key) -> by_text[Atom.to_string(key)]
            is_binary(key) -> by_text[key]
            true -> nil
          end

        cond do
          # The key is request data: named generically, never repeated (D44).
          is_nil(field) -> {given, ["#{at} has an unknown field" | unknown]}
          Map.has_key?(given, field) -> {given, ["#{at}.#{field} is given twice" | unknown]}
          true -> {Map.put(given, field, value), unknown}
        end
      end)

    # One text per object, however many unknown keys it has.
    unknown = unknown |> Enum.sort() |> Enum.uniq()

    {values, errors} =
      Enum.map_reduce(fields, unknown, fn {field, type, required}, errors ->
        case cast(type, Map.get(given, field), required, "#{at}.#{field}") do
          {:ok, value} -> {{field, value}, errors}
          {:error, reasons} -> {{field, nil}, errors ++ reasons}
        end
      end)

    if errors == [], do: {:ok, struct(module, values)}, else: {:error, errors}
  end

  defp build(module, params, at, :cast) when is_list(params) do
    if Keyword.keyword?(params),
      do: build(module, Map.new(params), at, :cast),
      else: {:error, ["#{at} must be a map, got #{kind(params)}"]}
  end

  defp build(_module, params, at, _mode),
    do: {:error, ["#{at} must be a map, got #{kind(params)}"]}

  defp field_errors(type, value, required, at, mode) do
    result =
      if mode == :cast,
        do: cast(type, value, required, at),
        else: check(type, value, required, at)

    case result do
      {:ok, _value} -> []
      {:error, reasons} -> reasons
    end
  end

  defp check(_type, nil, true, at), do: {:error, ["#{at} is required"]}
  defp check(_type, nil, false, _at), do: {:ok, nil}
  defp check(type, value, _required, at), do: value(type, value, at, :check)

  defp cast(_type, nil, true, at), do: {:error, ["#{at} is required"]}
  defp cast(_type, nil, false, _at), do: {:ok, nil}
  defp cast(type, value, _required, at), do: value(type, value, at, :cast)

  defp value(:string, value, _at, _mode) when is_binary(value), do: {:ok, value}
  defp value(:integer, value, _at, _mode) when is_integer(value), do: {:ok, value}

  # Out of range is refused, never clamped.
  defp value({:integer, min, max}, value, at, _mode) when is_integer(value) do
    if value >= min and value <= max,
      do: {:ok, value},
      else: {:error, ["#{at} must be in #{min}..#{max}, got #{value}"]}
  end

  defp value(:boolean, value, _at, _mode) when is_boolean(value), do: {:ok, value}
  defp value(:datetime, %DateTime{} = value, _at, _mode), do: {:ok, value}

  defp value(:datetime, value, at, :cast) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, ["#{at} must be an ISO-8601 datetime"]}
    end
  end

  # Never enumerated: only its type is looked at.
  defp value(:stream, value, at, _mode) do
    cond do
      is_map(value) and not is_struct(value) ->
        {:error, ["#{at} must be a stream (an Enumerable), got a map"]}

      is_function(value) and not is_function(value, 2) ->
        {:error, ["#{at} must be a stream (an Enumerable), got a function of another arity"]}

      Enumerable.impl_for(value) != nil ->
        {:ok, value}

      true ->
        {:error, ["#{at} must be a stream (an Enumerable), got #{kind(value)}"]}
    end
  end

  defp value({:enum, values}, value, at, mode) do
    found =
      cond do
        is_atom(value) and value in values -> value
        mode == :cast and is_binary(value) -> Enum.find(values, &(Atom.to_string(&1) == value))
        true -> nil
      end

    if found,
      do: {:ok, found},
      else:
        {:error,
         [
           "#{at} must be one of #{Enum.map_join(values, ", ", &Atom.to_string/1)}" <>
             got(value, mode)
         ]}
  end

  defp value({:model, module}, value, at, mode) do
    cond do
      is_struct(value, module) -> build(module, value, at, mode)
      mode == :cast and (is_map(value) or is_list(value)) -> build(module, value, at, :cast)
      true -> {:error, ["#{at} must be a #{inspect(module)}, got #{kind(value)}"]}
    end
  end

  defp value({:one_of, members, tag}, value, at, mode) do
    names = Enum.map_join(members, ", ", &elem(&1, 0))

    cond do
      is_struct(value) and List.keymember?(members, value.__struct__, 1) ->
        build(value.__struct__, value, at, mode)

      mode == :cast and is_map(value) and not is_struct(value) ->
        tag_text = Atom.to_string(tag)
        given = Map.get(value, tag, Map.get(value, tag_text))
        given = if is_atom(given) and not is_nil(given), do: Atom.to_string(given), else: given
        rest = Map.drop(value, [tag, tag_text])

        case List.keyfind(members, given, 0) do
          {_name, module} -> build(module, rest, at, :cast)
          nil -> {:error, ["#{at}.#{tag} must be one of #{names}" <> got(given, :cast)]}
        end

      true ->
        {:error, ["#{at} must be one of #{names}, got #{kind(value)}"]}
    end
  end

  defp value({:list, inner}, values, at, mode) when is_list(values) do
    {items, errors} =
      values
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {item, index}, errors ->
        case value(inner, item, "#{at}[#{index}]", mode) do
          {:ok, item} -> {item, errors}
          {:error, reasons} -> {item, errors ++ reasons}
        end
      end)

    if errors == [], do: {:ok, items}, else: {:error, errors}
  end

  defp value({:map, inner}, values, at, mode) when is_map(values) and not is_struct(values) do
    {items, errors} =
      Enum.map_reduce(Enum.sort(values), [], fn {key, item}, errors ->
        cond do
          not is_binary(key) ->
            {{key, item}, errors ++ ["#{at} has a key that is no string"]}

          true ->
            # A key is data, so the path names the entry, not the key (D44).
            case value(inner, item, "#{at}.*", mode) do
              {:ok, item} -> {{key, item}, errors}
              {:error, reasons} -> {{key, item}, errors ++ reasons}
            end
        end
      end)

    if errors == [], do: {:ok, Map.new(items)}, else: {:error, errors}
  end

  defp value(type, value, at, _mode),
    do: {:error, ["#{at} must be #{describe(type)}, got #{kind(value)}"]}

  # A refusal names the field and the kind of value it got, never the value: a value can
  # hold a path on the client's or the Runtime's machine (D44). An unknown text in a JSON
  # form is just not one of the values.
  defp got(value, :cast) when is_binary(value), do: ""
  defp got(value, _mode), do: ", got #{kind(value)}"

  defp kind(nil), do: "null"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(value) when is_binary(value), do: "a string"
  defp kind(value) when is_integer(value), do: "an integer"
  defp kind(value) when is_float(value), do: "a float"
  defp kind(value) when is_atom(value), do: "an atom"
  defp kind(value) when is_list(value), do: "a list"
  defp kind(value) when is_struct(value), do: "a struct"
  defp kind(value) when is_map(value), do: "a map"
  defp kind(value) when is_function(value), do: "a function"
  defp kind(_value), do: "another value"

  defp describe({:list, inner}), do: "a list of #{describe(inner)}"
  defp describe({:map, inner}), do: "a map of #{describe(inner)}"
  defp describe(:datetime), do: "a DateTime"
  defp describe(:integer), do: "an integer"
  defp describe({:integer, min, max}), do: "an integer in #{min}..#{max}"
  defp describe(type), do: "a #{type}"
end
