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
  - `decode/1`: one block from its JSON map. It reads tolerantly (D-0105): `required`
    binds Control, which must send it, never a client, so every field is optional here;
    one that is missing or of another type is left out (nil), and so is an entry of a
    list or map that does not decode. A page of a newer server, or an older one, always
    decodes. An unknown block becomes a `Fallback` with its title and texts in plain
    words (`plain/1`), and the rest of the page still renders. Unknown keys are ignored.
  - `view_model/1`: a page's `{blocks, ids, markup}`. Each markup entry keeps its wire
    form and gets its props decoded as `"value"`, as tolerantly. Markup of an unknown kind
    is left out; when the rest does not nest (`AtlasBFF.Markup.check/2`) all
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
          Enum.map(entry.fields, &{&1.name, type(&1.type, names)})}}
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
        # `title` and `lines`: what the block says, in plain words (`plain/1`).
        defstruct [:type, :reason, :title, lines: []]
      end

      unquote_splicing(structs)

      @doc "Decode one block from its JSON map; a `Fallback` when it cannot be shown."
      def decode(block),
        do: AtlasBFF.Targets.Client.decode(@table, @blocks, __MODULE__.Fallback, block)

      @doc "What a block's props say, in plain words: `{title, lines}`."
      def plain(props), do: AtlasBFF.Targets.Client.plain(props)

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
          do: Map.put(entry, "value", decode_model(table, kind, Map.get(entry, "props")))

    markup = if AtlasBFF.Markup.check(ids, markup) == :ok, do: markup, else: []
    {Enum.map(raw, &decode(table, blocks, fallback, &1)), ids, markup}
  end

  defp block_id(%{"id" => id}, _i) when is_binary(id), do: id
  defp block_id(_block, i), do: "##{i}"

  @doc false
  def decode(table, blocks, fallback, %{"type" => type} = block) do
    props = Map.get(block, "props")

    cond do
      not is_map(props) and props != nil ->
        struct(fallback, type: type, reason: "props are not an object")

      type in blocks ->
        decode_model(table, type, props || %{})

      true ->
        {title, lines} = plain(props || %{})
        struct(fallback, type: type, reason: "unknown block", title: title, lines: lines)
    end
  end

  def decode(_table, _blocks, fallback, _other),
    do: struct(fallback, type: nil, reason: "not a block")

  @title ~w(title label heading name)
  # What only says where something goes or how it looks; never words for a reader.
  @structural ~w(id to path key kind type tone role style icon endpoint params scope operation keys at)
  @first ~w(text description body summary value)

  @doc """
  What a block of a kind this client does not know says, in plain words (D-0105):
  `{title, lines}`, its title or label (nil for none) and its other texts in order, a
  text field first; an entry of a list with a label and a value as `label: value`.
  """
  def plain(props) when is_map(props) do
    title = Enum.find_value(@title, &text(props[&1]))
    title_key = Enum.find(@title, &text(props[&1]))

    keys =
      props
      |> Map.keys()
      |> Enum.reject(&(&1 == title_key or &1 in @structural or String.ends_with?(&1, "_to")))
      |> Enum.sort_by(&{Enum.find_index(@first, fn k -> k == &1 end) || length(@first), &1})

    {title, Enum.flat_map(keys, &lines(props[&1]))}
  end

  def plain(_props), do: {nil, []}

  defp lines(value) when is_binary(value),
    do: if(text(value), do: [String.trim(value)], else: [])

  defp lines(values) when is_list(values), do: Enum.flat_map(values, &lines/1)

  defp lines(value) when is_map(value) do
    case plain(value) do
      {nil, lines} -> lines
      {title, [line | rest]} -> ["#{title}: #{line}" | rest]
      {title, []} -> [title]
    end
  end

  defp lines(_value), do: []

  defp text(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp text(_value), do: nil

  # Every field is read on its own: one that is missing or does not decode is left out.
  defp decode_model(table, name, props) do
    {module, fields} = Map.fetch!(table, name)
    props = if is_map(props), do: props, else: %{}

    Enum.reduce(fields, struct(module), fn {field, type}, acc ->
      case decode_value(table, type, Map.get(props, Atom.to_string(field))) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp decode_value(_table, :string, v) when is_binary(v), do: {:ok, v}
  defp decode_value(_table, :integer, v) when is_integer(v), do: {:ok, v}
  defp decode_value(_table, :boolean, v) when is_boolean(v), do: {:ok, v}

  defp decode_value(table, {:list, type}, values) when is_list(values) do
    {:ok, for(value <- values, {:ok, value} <- [decode_value(table, type, value)], do: value)}
  end

  defp decode_value(table, {:map, type}, values) when is_map(values) do
    {:ok,
     for(
       {k, v} <- values,
       {:ok, value} <- [decode_value(table, type, v)],
       into: %{},
       do: {k, value}
     )}
  end

  defp decode_value(table, model, value) when is_binary(model) and is_map(value),
    do: {:ok, decode_model(table, model, value)}

  defp decode_value(_table, type, value) when type in [:map, :list, :any] and value != nil,
    do: {:ok, value}

  defp decode_value(_table, _type, _value), do: :error
end
