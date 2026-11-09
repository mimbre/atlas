defmodule AtlasRuntimeBoundary.Generator.FixtureModel do
  @moduledoc false
  # A stand-in for a model target, over test/fixtures/model_schema.exs: what the Boundary
  # target's model: option relies on, and nothing more. It has __schema__/0 (the model
  # schema shape) and, per entity, a struct module named after it with @type t and new/1
  # (atom keys; a nested entity as its struct or a map; a one_of as a struct or a map with
  # kind:). new/1 answers {:error, {:missing_field | :unknown_field | :invalid, at}}.

  @fixture Path.expand("../fixtures/model_schema.exs", __DIR__)
  @external_resource @fixture
  {schema, _binding} = Code.eval_file(@fixture)
  @schema schema

  def __schema__, do: @schema

  @doc false
  def build(name, input, at) do
    entity = Enum.find(@schema.entities, &(&1.name == name))
    module = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(name)))
    input = if is_struct(input), do: Map.from_struct(input), else: Map.new(input)
    names = Enum.map(entity.fields, & &1.name)

    case Enum.find(Map.keys(input), &(&1 not in names)) do
      nil -> :ok
      unknown -> throw({:unknown_field, "#{at}.#{unknown}"})
    end

    values =
      for %{name: field, type: type, required: required} <- entity.fields do
        case Map.get(input, field) do
          nil when required -> throw({:missing_field, "#{at}.#{field}"})
          nil -> {field, nil}
          value -> {field, value(type, value, "#{at}.#{field}")}
        end
      end

    struct!(module, values)
  end

  defp value(:string, v, _at) when is_binary(v), do: v
  defp value(:integer, v, _at) when is_integer(v), do: v
  defp value(:boolean, v, _at) when is_boolean(v), do: v
  defp value(:datetime, %DateTime{} = v, _at), do: v
  defp value({:enum, values}, v, at), do: if(v in values, do: v, else: throw({:invalid, at}))
  defp value({:list, inner}, v, at) when is_list(v), do: Enum.map(v, &value(inner, &1, at))

  defp value({:one_of, members}, v, at) do
    kind =
      Enum.find(members, &is_struct(v, Module.concat(__MODULE__, Macro.camelize("#{&1}")))) ||
        (is_map(v) and Map.get(v, :kind) in members and v.kind) || throw({:invalid, at})

    build(kind, if(is_struct(v), do: v, else: Map.delete(v, :kind)), at)
  end

  defp value(name, v, at) when is_atom(name) and is_map(v), do: build(name, v, at)
  defp value(_type, _v, at), do: throw({:invalid, at})

  for entity <- schema.entities do
    module = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(entity.name)))

    defmodule module do
      @moduledoc false
      @enforce_keys for f <- entity.fields, f.required, do: f.name
      defstruct Enum.map(entity.fields, & &1.name)
      @type t :: %__MODULE__{}
      @name entity.name

      def new(fields) do
        {:ok, AtlasRuntimeBoundary.Generator.FixtureModel.build(@name, fields, "#{@name}")}
      catch
        error -> {:error, error}
      end

      def new!(fields) do
        {:ok, entity} = new(fields)
        entity
      end
    end
  end
end
