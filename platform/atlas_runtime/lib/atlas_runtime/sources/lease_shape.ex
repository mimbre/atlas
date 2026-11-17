defmodule AtlasRuntime.Sources.LeaseShape do
  @moduledoc """
  Whether a lease from a work source has exactly the `work_source` contract's shape
  (`AtlasRuntimeBoundary.WorkSource`, model `lease`), checked against the contract's own
  `__schema__/0` before anything of it is used (M2 assembly A, the lease security fix).

  The shape is strict, as both contract targets give it:
  - every declared field is present (an optional one as `nil`), and no other field;
  - each value has its declared type: text (valid UTF-8), integer (within a declared range),
    boolean, `DateTime`, an enum's atom, a list, a map with text keys, or a nested model.

  The in-BEAM target's structs are taken as their fields (`DateTime` is a value). Anything
  else (a missing or extra field, a wrong type, not a map at all) is malformed.

  `check/1` answers `{:ok, lease}` with the lease as plain maps, or `{:error, {rule, path}}`.
  `rule` is one of `:not_a_map`, `:missing_field`, `:undeclared_field`, `:required` and
  `:wrong_type`. `path` names only the contract's own fields that lead to the fault. **Never**
  anything the lease carries: no value and no undeclared field's name, so the answer can be
  logged.
  """

  @contract AtlasRuntimeBoundary.WorkSource

  @type rule :: :not_a_map | :missing_field | :undeclared_field | :required | :wrong_type

  @spec check(term()) :: {:ok, map()} | {:error, {rule(), [atom()]}}
  def check(lease) do
    case value({:model, :lease}, lease, []) do
      {:ok, plain} -> {:ok, plain}
      {:error, _} = error -> error
    end
  end

  defp models,
    do: Map.new(@contract.__schema__().models, &{&1.name, &1.fields})

  defp value({:model, _name}, %DateTime{}, path), do: {:error, {:not_a_map, Enum.reverse(path)}}

  defp value({:model, name}, %_{} = struct, path),
    do: value({:model, name}, Map.from_struct(struct), path)

  defp value({:model, name}, map, path) when is_map(map) do
    fields = Map.fetch!(models(), name)
    declared = MapSet.new(fields, & &1.name)

    cond do
      Enum.any?(Map.keys(map), &(not MapSet.member?(declared, &1))) ->
        {:error, {:undeclared_field, Enum.reverse(path)}}

      true ->
        Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
          case field(field, map, [field.name | path]) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, field.name, v)}}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp value({:model, _name}, _other, path), do: {:error, {:not_a_map, Enum.reverse(path)}}

  defp value(type, v, path), do: typed(type, v, path)

  defp field(field, map, path) do
    case Map.fetch(map, field.name) do
      :error -> {:error, {:missing_field, Enum.reverse(path)}}
      {:ok, nil} when field.required -> {:error, {:required, Enum.reverse(path)}}
      {:ok, nil} -> {:ok, nil}
      {:ok, v} -> with {:ok, v} <- value(kind(field.type), v, path), do: in_range(field, v, path)
    end
  end

  # A model's name stands for the model; the rest are the generator's types.
  defp kind(type) when is_atom(type) and type not in [:string, :integer, :boolean, :datetime],
    do: {:model, type}

  defp kind({:list, t}), do: {:list, kind(t)}
  defp kind({:map, t}), do: {:map, kind(t)}
  defp kind(type), do: type

  defp typed(:string, v, path),
    do: if(is_binary(v) and String.valid?(v), do: {:ok, v}, else: wrong(path))

  defp typed(:integer, v, path), do: if(is_integer(v), do: {:ok, v}, else: wrong(path))
  defp typed(:boolean, v, path), do: if(is_boolean(v), do: {:ok, v}, else: wrong(path))
  defp typed(:datetime, %DateTime{} = v, _path), do: {:ok, v}
  defp typed(:datetime, _v, path), do: wrong(path)
  defp typed({:enum, values}, v, path), do: if(v in values, do: {:ok, v}, else: wrong(path))

  defp typed({:list, t}, v, path) when is_list(v) do
    if proper?(v) do
      Enum.reduce_while(Enum.reverse(v), {:ok, []}, fn item, {:ok, acc} ->
        case value(t, item, path) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      wrong(path)
    end
  end

  defp typed({:map, t}, v, path) when is_map(v) and not is_struct(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn
      {k, item}, {:ok, acc} when is_binary(k) ->
        case value(t, item, path) do
          {:ok, item} -> {:cont, {:ok, Map.put(acc, k, item)}}
          {:error, _} = error -> {:halt, error}
        end

      _, _ ->
        {:halt, wrong(path)}
    end)
  end

  defp typed(_type, _v, path), do: wrong(path)

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp in_range(%{range: {min, max}}, v, path) when is_integer(v) and (v < min or v > max),
    do: wrong(path)

  defp in_range(_field, v, _path), do: {:ok, v}

  defp wrong(path), do: {:error, {:wrong_type, Enum.reverse(path)}}
end
