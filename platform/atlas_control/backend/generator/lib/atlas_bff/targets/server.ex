defmodule AtlasBFF.Targets.Server do
  @moduledoc """
  A compile-time target: builders for the view model a server sends, made from a
  contract's `__schema__/0` when the module that uses it compiles. No file is written.

      defmodule MyServer.Blocks do
        use AtlasBFF.Targets.Server, contract: MyContract
      end

  It defines in that module:

  - a builder macro per block and model, `Blocks.list(rows: [...])`, and per kind of
    markup, `Blocks.section(first_id, last_id, title: "...")` (with `group:` for one piece
    of split markup). With a literal keyword list, an unknown or missing required prop
    fails at compile time; a wrong value, or a required prop that is `nil`, raises when
    the block is built. Callers `require` the module.
  - `view_model(content, markup \\\\ [])`: `content` as `[{id, block}]` in order. Gives each
    block its id, and raises when an id is used twice or the markup does not nest
    (`AtlasBFF.Markup.check/2`).
  - `version/0`: the contract's version.
  - `pages/0`, `match/1` and `path/2`: the pages the contract lists, the page a path is,
    and the path of a page (`AtlasBFF.Paths`). A server serves exactly these.

  A block is `%{"type" => name, "props" => props}`, a model a plain map, a markup entry
  `%{"kind" => name, "start" => id, "end" => id, "props" => props}`. An optional prop
  without a value is left out.
  """

  alias AtlasBFF.Names

  @markup Names.markup()

  defmacro __using__(opts) do
    schema = Macro.expand(opts[:contract], __CALLER__).__schema__()
    fields = Macro.escape(table(schema))

    builders =
      for entry <- schema.models ++ schema.blocks do
        kind = if entry in schema.blocks, do: "block", else: "model"
        name = Atom.to_string(entry.name)

        quote do
          @doc unquote("Build a `#{name}` #{kind}. Fields: #{field_list(entry)}.")
          defmacro unquote(entry.name)(props),
            do:
              AtlasBFF.Targets.Server.call(
                @fields,
                unquote(kind),
                unquote(name),
                props,
                __CALLER__,
                [],
                __MODULE__
              )
        end
      end

    markup =
      for entry <- schema.markup do
        name = Atom.to_string(entry.name)

        quote do
          @doc unquote(
                 "#{String.capitalize(@markup)}: `#{name}` from block id `first` to `last`. " <>
                   "Fields: #{field_list(entry)}; `group` for one piece of split #{@markup}."
               )
          defmacro unquote(entry.name)(first, last, props \\ []),
            do:
              AtlasBFF.Targets.Server.call(
                @fields,
                unquote(@markup),
                unquote(name),
                props,
                __CALLER__,
                [first, last],
                __MODULE__
              )
        end
      end

    quote do
      @fields unquote(fields)

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

      unquote_splicing(builders ++ markup)

      @doc false
      def __build__(kind, name, props, range),
        do: AtlasBFF.Targets.Server.build(@fields, kind, name, props, range)

      @doc """
      The #{unquote(Names.view_model())}: `content` as `[{id, block}]` in order, and its
      #{unquote(@markup)}. Raises when an id is used twice or the #{unquote(@markup)} does
      not nest (`AtlasBFF.Markup.check/2`).
      """
      def unquote(Names.view_model_fun())(content, markup \\ []),
        do: AtlasBFF.Targets.Server.view_model(content, markup)
    end
  end

  # The fields of every entry: `%{name => [{field, type, required}]}`, all as strings.
  defp table(schema) do
    Map.new(schema.models ++ schema.blocks ++ schema.markup, fn entry ->
      {Atom.to_string(entry.name),
       Enum.map(entry.fields, &{Atom.to_string(&1.name), type_name(&1.type), &1.required})}
    end)
  end

  defp type_name({:list, inner}), do: {:list, type_name(inner)}
  defp type_name({:map, inner}), do: {:map, type_name(inner)}
  defp type_name(type), do: Atom.to_string(type)

  defp field_list(entry) do
    Enum.map_join(entry.fields, ", ", fn f ->
      "`#{f.name}`#{if f.required, do: " (required)", else: ""}"
    end)
  end

  @doc false
  # At compile time: a literal keyword list names only known props and every required
  # one. Anything else is checked when the block is built.
  def call(fields, kind, name, props, caller, range, module) do
    if is_list(props) and Keyword.keyword?(props) do
      fields = Map.fetch!(fields, name)
      given = Enum.map(Keyword.keys(props), &Atom.to_string/1)
      given = if kind == @markup, do: given -- ["group"], else: given
      fail = &raise(CompileError, file: caller.file, line: caller.line, description: &1)

      case given -- Enum.map(fields, &elem(&1, 0)) do
        [] -> :ok
        unknown -> fail.("#{name} has no field(s) #{inspect(unknown)}")
      end

      for {field, _type, true} <- fields,
          field not in given,
          do: fail.("#{name}.#{field} is required")
    end

    quote do
      unquote(module).__build__(unquote(kind), unquote(name), unquote(props), unquote(range))
    end
  end

  @doc false
  def build(fields, kind, name, props, []), do: build(fields, kind, name, props)

  def build(fields, @markup, name, props, [first, last]) do
    {group, props} = props |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.pop("group")

    entry = %{
      "kind" => name,
      "start" => first,
      "end" => last,
      "props" => build(fields, "model", name, props)
    }

    if group, do: Map.put(entry, "group", group), else: entry
  end

  defp build(fields, kind, name, props) do
    own = Map.fetch!(fields, name)
    props = Map.new(props, fn {k, v} -> {to_string(k), v} end)

    case Map.keys(props) -- Enum.map(own, &elem(&1, 0)) do
      [] -> :ok
      unknown -> raise ArgumentError, "#{name} has no field(s) #{inspect(unknown)}"
    end

    checked =
      for {field, type, required} <- own, reduce: %{} do
        acc ->
          case Map.get(props, field) do
            nil when required -> raise ArgumentError, "#{name}.#{field} is required"
            nil -> acc
            value -> Map.put(acc, field, check!(fields, type, value, "#{name}.#{field}"))
          end
      end

    if kind == "block", do: %{"type" => name, "props" => checked}, else: checked
  end

  defp check!(_fields, "string", value, _at) when is_binary(value), do: value
  defp check!(_fields, "integer", value, _at) when is_integer(value), do: value
  defp check!(_fields, "boolean", value, _at) when is_boolean(value), do: value

  defp check!(fields, {:list, type}, values, at) when is_list(values),
    do: Enum.map(values, &check!(fields, type, &1, at))

  defp check!(fields, {:map, type}, values, at) when is_map(values),
    do: Map.new(values, fn {k, v} -> {to_string(k), check!(fields, type, v, "#{at}.#{k}")} end)

  defp check!(fields, model, value, _at)
       when is_map_key(fields, model) and (is_map(value) or is_list(value)),
       do: build(fields, "model", model, value)

  defp check!(_fields, type, value, at),
    do: raise(ArgumentError, "#{at} must be #{inspect(type)}, got: #{inspect(value)}")

  @doc false
  def view_model(content, markup) do
    ids = Enum.map(content, &elem(&1, 0))

    case AtlasBFF.Markup.check(ids, markup) do
      :ok ->
        %{
          :blocks => Enum.map(content, fn {id, block} -> Map.put(block, "id", id) end),
          String.to_atom(@markup) => markup
        }

      {:error, why} ->
        raise ArgumentError, why
    end
  end
end
