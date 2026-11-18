defmodule AtlasBFF.Targets.Client do
  @moduledoc """
  A compile-time target: an Elixir client's decoder, made from a contract's
  `__schema__/0` when the module that uses it compiles. No file is written.

      defmodule MyClient.Blocks do
        use AtlasBFF.Targets.Client, contract: MyContract
      end

  It defines in that module:

  - a struct per block, model and kind of markup, named after it (`MyClient.Blocks.List`,
    `MyClient.Blocks.Section`), and `MyClient.Blocks.Fallback` for a block it cannot show;
  - `decode/1`: one block from its JSON map. An unknown block, or one that fails to
    decode, becomes a `Fallback`, and the rest of the page still renders. Unknown keys
    are ignored.
  - `view_model/1`: a page's `{blocks, ids, markup}`. Each markup entry keeps its wire
    form and gets its props decoded as `"value"`. Markup of an unknown kind, or that fails
    to decode, is left out; when the rest does not nest (`AtlasBFF.Markup.check/2`) all
    of it is left out. The blocks always render.
  - `version/0`: the contract's version.
  """

  alias AtlasBFF.Names

  defmacro __using__(opts) do
    schema = Macro.expand(opts[:contract], __CALLER__).__schema__()
    module = __CALLER__.module
    entries = schema.models ++ schema.blocks ++ schema.markup
    names = Enum.map(schema.models ++ schema.blocks, & &1.name)

    table =
      Map.new(entries, fn entry ->
        {Atom.to_string(entry.name),
         {struct_module(module, entry.name),
          Enum.map(entry.fields, &{&1.name, type(&1.type, names), &1.required})}}
      end)

    structs =
      for entry <- entries do
        quote do
          defmodule unquote(struct_module(module, entry.name)) do
            @moduledoc false
            defstruct unquote(Enum.map(entry.fields, & &1.name))
          end
        end
      end

    quote do
      @table unquote(Macro.escape(table))
      @blocks unquote(Enum.map(schema.blocks, &Atom.to_string(&1.name)))
      @markup_kinds unquote(Enum.map(schema.markup, &Atom.to_string(&1.name)))

      @doc "The contract's version."
      def version, do: unquote(schema.version)

      @pages unquote(Macro.escape(schema.pages))

      @doc "The pages the contract lists: `[%{name, path, params}]`, as `__schema__/0` has them."
      def pages, do: @pages

      @doc """
      The page the contract has for `path`: `{:ok, name, %{param => value}}`, or `:error`
      for a path that is no page (`AtlasBFF.Paths.match/2`).
      """
      def match(path), do: AtlasBFF.Paths.match(@pages, path)

      @doc "The path of page `name` with `params` (`AtlasBFF.Paths.build/3`)."
      def path(name, params \\ %{}), do: AtlasBFF.Paths.build(@pages, name, params)

      @endpoints unquote(Macro.escape(schema.endpoints))

      @doc """
      The calls the contract lists, pages' fetches (`call: :open`) included:
      `[%{name, call, page, path, params, takes, replies}]`, as `__schema__/0` has them.
      """
      def endpoints, do: @endpoints

      @doc """
      The endpoint of `call` (such as `:submit`) that `path` is: `{:ok, name, params}`, or
      `:error` for a path that is no such endpoint (`AtlasBFF.Paths.match/2`).
      """
      def endpoint(call, path),
        do: AtlasBFF.Paths.match(Enum.filter(@endpoints, &(&1.call == call and &1.path)), path)

      @doc """
      The path of endpoint `name` of `call` with `params`; nil for an endpoint without a
      path, and raises when it does not exist or a parameter is missing.
      """
      def endpoint_path(call, name, params \\ %{}) do
        case Enum.find(@endpoints, &(&1.call == call and &1.name == name)) do
          nil -> raise ArgumentError, "no endpoint #{inspect(name)} (#{call})"
          %{path: nil} -> nil
          endpoint -> AtlasBFF.Paths.build([endpoint], name, params)
        end
      end

      defmodule Fallback do
        @moduledoc false
        defstruct [:type, :reason]
      end

      unquote_splicing(structs)

      @doc "Decode one block from its JSON map; a `Fallback` when it cannot be shown."
      def decode(block),
        do: AtlasBFF.Targets.Client.decode(@table, @blocks, __MODULE__.Fallback, block)

      @doc "A page's #{unquote(Names.view_model())}: `{blocks, ids, #{unquote(Names.markup())}}`."
      def unquote(Names.view_model_fun())(page),
        do:
          AtlasBFF.Targets.Client.view_model(
            @table,
            @blocks,
            @markup_kinds,
            __MODULE__.Fallback,
            page
          )
    end
  end

  defp struct_module(module, name),
    do: Module.concat(module, Macro.camelize(Atom.to_string(name)))

  defp type({:list, inner}, names), do: {:list, type(inner, names)}
  defp type({:map, inner}, names), do: {:map, type(inner, names)}
  defp type(type, names), do: if(type in names, do: Atom.to_string(type), else: type)

  @doc false
  def view_model(table, blocks, kinds, fallback, page) do
    raw = page["blocks"] || []
    ids = raw |> Enum.with_index() |> Enum.map(fn {block, i} -> block_id(block, i) end)

    markup =
      for %{"kind" => kind} = entry <- page[Names.markup()] || [],
          kind in kinds,
          {:ok, value} <- [decode_model(table, kind, Map.get(entry, "props") || %{})],
          do: Map.put(entry, "value", value)

    markup = if AtlasBFF.Markup.check(ids, markup) == :ok, do: markup, else: []
    {Enum.map(raw, &decode(table, blocks, fallback, &1)), ids, markup}
  end

  defp block_id(%{"id" => id}, _i) when is_binary(id), do: id
  defp block_id(_block, i), do: "##{i}"

  @doc false
  def decode(table, blocks, fallback, %{"type" => type} = block) do
    if type in blocks do
      case decode_model(table, type, Map.get(block, "props") || %{}) do
        {:ok, struct} -> struct
        {:error, reason} -> struct(fallback, type: type, reason: reason)
      end
    else
      struct(fallback, type: type, reason: "unknown block")
    end
  end

  def decode(_table, _blocks, fallback, _other),
    do: struct(fallback, type: nil, reason: "not a block")

  defp decode_model(table, name, props) when is_map(props) do
    {module, fields} = Map.fetch!(table, name)

    Enum.reduce_while(fields, {:ok, struct(module)}, fn {field, type, required}, {:ok, acc} ->
      case {Map.get(props, Atom.to_string(field)), required} do
        {nil, true} ->
          {:halt, {:error, "#{name}.#{field} is missing"}}

        {nil, false} ->
          {:cont, {:ok, acc}}

        {value, _} ->
          case decode_value(table, type, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
            :error -> {:halt, {:error, "#{name}.#{field} has the wrong type"}}
          end
      end
    end)
  end

  defp decode_model(_table, name, _props), do: {:error, "#{name} is not an object"}

  defp decode_value(_table, :string, v) when is_binary(v), do: {:ok, v}
  defp decode_value(_table, :integer, v) when is_integer(v), do: {:ok, v}
  defp decode_value(_table, :boolean, v) when is_boolean(v), do: {:ok, v}

  defp decode_value(table, {:list, type}, values) when is_list(values) do
    Enum.reduce_while(Enum.reverse(values), {:ok, []}, fn value, {:ok, acc} ->
      case decode_value(table, type, value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_value(table, {:map, type}, values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case decode_value(table, type, v) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, k, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_value(table, model, value) when is_binary(model) do
    case decode_model(table, model, value) do
      {:ok, struct} -> {:ok, struct}
      {:error, _} -> :error
    end
  end

  defp decode_value(_table, _type, _value), do: :error
end
