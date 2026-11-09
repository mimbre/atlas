defmodule AtlasBFF.Schema do
  @moduledoc """
  The schema of Control's spec, written as a DSL. Inspired by mica-bff's spec format
  (inspiration only, d-0009: nothing is shared with it).

      defmodule MyBlocks do
        use AtlasBFF.Schema

        version "0.1.0"

        defmodel :action do
          field :label, :string, required: true
        end

        defblock :list do
          field :title, :string, required: true
          field :actions, {:list, :action}
        end

        defmarkup :section do
          field :title, :string, required: true
        end

        defpage :item, "/k/:kind/:key"

        defendpoint :update, "/k/:kind/:key/edit",
          call: :submit,
          takes: :values,
          replies: [stored: :view_model, refused: :view_model]
      end

  - `defblock`: a block Control sends and clients render. A page is a flat, ordered list
    of blocks; a block never holds another block.
  - `defmodel`: a value a block field holds (an action, a row, an input).
  - `defmarkup`: a kind of markup. A view model sends content (its blocks, each with an
    id) and markup: entries of a kind that cover the blocks from one id to another, with
    the kind's fields as props. All markup nests (`AtlasBFF.Markup` has the rules).
  - `field`: a snake_case name, a type and `required: true | false` (default `false`).
    Types: `:string`, `:integer`, `:boolean`, a model, `{:list, type}`, or
    `{:map, primitive}` (an object of names to such values).
  - `defpage`: a page the server serves, by name and path. A segment `:name` is a
    parameter (a string); the others are literal. A page always returns a view model; it
    is fetched, never sent to. Where two pages could match one path, the one with a
    literal segment first wins (`/k/:kind/new` over `/k/:kind/:key`), so the order they are
    written in does not matter (`AtlasBFF.Paths`). Each page is also an endpoint: the call
    that fetches it, so a client has one list of what it can call.
  - `defoperation`: a named wire descriptor with explicit channel, direction, envelopes
    and reply selectors as plain data (`AtlasBFF.Wire`). When present, every endpoint
    must name its `wire:` descriptor; pages use `:open`.
  - `protocol_from`: import wire descriptors from a compiled contract, in order.
  - `defendpoint`: any other call, by name, an optional path and options: `call:` (the
    message it travels in, such as `:submit`; required), `takes:` (what it is sent: a
    model, or `:values`, a form's inputs by name) and `replies:` (`[reply: what it
    returns]`: a model, a block or `:view_model`). Names and paths are unique per call;
    `:open` is the pages' own. Without a path an endpoint is a message of its own (a
    session's hello), matched by its call alone.

  A mistake fails at compile time and points at its line.

  ## The schema as data

  A contract compiles to one function, `__schema__/0`, and the targets read only that,
  never this module's internals (a test checks it):

      %{
        version: "1.0.0",
        file: "/abs/path/to/the/contract.ex",
        models: [entry],
        blocks: [entry],
        markup: [entry],
        pages: [%{name: atom, path: "/k/:kind/:key", params: [:kind, :key]}],
        protocol: [wire_descriptor],
        endpoints: [%{wire: atom | nil, name: atom, call: atom, page: atom | nil, path: path, params: [atom],
                      takes: atom | nil, replies: [%{name: atom, returns: atom}]}]
      }

  where an entry is `%{name: atom, fields: [%{name: atom, type: type, required: boolean}]}`
  in the order written, and a type is `:string`, `:integer`, `:boolean`, a model's name,
  or `{:list, type}`. Pages and endpoints are in the order written: first the pages' own
  (call `:open`, the fetch of the page it names, replying a view model), then those of
  `defendpoint`.
  """

  @primitives [:string, :integer, :boolean]

  defmacro __using__(_opts) do
    quote do
      import AtlasBFF.Schema,
        only: [
          version: 1,
          defoperation: 2,
          protocol_from: 1,
          models_from: 1,
          defblock: 2,
          defmodel: 2,
          defmarkup: 2,
          defpage: 2,
          defendpoint: 2,
          defendpoint: 3,
          field: 2,
          field: 3
        ]

      Module.register_attribute(__MODULE__, :spec_entries, accumulate: true)
      Module.register_attribute(__MODULE__, :spec_protocol, accumulate: true)
      @before_compile AtlasBFF.Schema
    end
  end

  defmacro version(version) do
    quote do: @spec_version(unquote(version))
  end

  @doc "Declare a named wire descriptor as plain data; see `AtlasBFF.Wire`."
  defmacro defoperation(name, descriptor) do
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      @spec_protocol %{
        descriptor:
          AtlasBFF.Schema.__operation__(
            unquote(name),
            unquote(descriptor),
            unquote(file),
            unquote(line)
          ),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  @doc false
  def __operation__(name, descriptor, _file, _line) when is_map(descriptor),
    do: Map.put(descriptor, :name, name)

  def __operation__(_name, _descriptor, file, line),
    do: __fail__(file, line, "wire descriptor must be a map")

  @doc "Import wire descriptors from a compiled contract; duplicates remain compile errors."
  defmacro protocol_from(contract) do
    contract = Macro.expand(contract, __CALLER__)
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      Code.ensure_compiled!(unquote(contract))

      for descriptor <- unquote(contract).__schema__().protocol do
        @spec_protocol %{
          descriptor: descriptor,
          file: unquote(file),
          line: unquote(line)
        }
      end
    end
  end

  @doc "Reuse models from another compiled data contract; duplicates remain compile errors."
  defmacro models_from(contract) do
    contract = Macro.expand(contract, __CALLER__)
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      Code.ensure_compiled!(unquote(contract))

      for model <- unquote(contract).__schema__().models do
        @spec_entries %{
          type: :model,
          name: model.name,
          file: unquote(file),
          line: unquote(line),
          fields:
            Enum.map(model.fields, &Map.merge(&1, %{file: unquote(file), line: unquote(line)}))
        }
      end
    end
  end

  defmacro defblock(name, do: body), do: entry(:block, name, body, __CALLER__)
  defmacro defmodel(name, do: body), do: entry(:model, name, body, __CALLER__)
  defmacro defmarkup(name, do: body), do: entry(:markup, name, body, __CALLER__)

  defmacro defpage(name, path) do
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
          unquote(file),
          unquote(line),
          "page #{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      @spec_entries %{
        type: :page,
        name: unquote(name),
        path: unquote(path),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  defmacro defendpoint(name, opts) when is_list(opts),
    do: endpoint_entry(name, nil, opts, __CALLER__)

  defmacro defendpoint(name, path, opts), do: endpoint_entry(name, path, opts, __CALLER__)

  defp endpoint_entry(name, path, opts, %{file: file, line: line}) do
    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
          unquote(file),
          unquote(line),
          "endpoint #{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      @spec_entries %{
        type: :endpoint,
        name: unquote(name),
        path: unquote(path),
        opts: unquote(opts),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  defp entry(type, name, body, %{file: file, line: line}) do
    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
          unquote(file),
          unquote(line),
          "#{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      Module.put_attribute(__MODULE__, :spec_open, unquote(name))
      Module.register_attribute(__MODULE__, :spec_fields, accumulate: true)
      unquote(body)

      @spec_entries %{
        type: unquote(type),
        name: unquote(name),
        file: unquote(file),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :spec_fields))
      }

      Module.delete_attribute(__MODULE__, :spec_fields)
      Module.delete_attribute(__MODULE__, :spec_open)
    end
  end

  defmacro field(name, type, opts \\ []) do
    file = __CALLER__.file
    line = __CALLER__.line

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:required] == [] and
             is_boolean(Keyword.get(opts, :required, false)) do
      __fail__(
        __CALLER__.file,
        line,
        "field #{inspect(name)}: the only option is required: true | false"
      )
    end

    quote do
      unless Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
          unquote(file),
          unquote(line),
          "field #{inspect(unquote(name))} outside a block, model or markup"
        )
      end

      @spec_fields %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(Keyword.get(opts, :required, false)),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:spec_entries) |> Enum.reverse()

    version =
      Module.get_attribute(env.module, :spec_version) ||
        __fail__(env.file, 1, "the spec needs a version")

    {pages, entries} = Enum.split_with(entries, &(&1.type == :page))
    {endpoints, entries} = Enum.split_with(entries, &(&1.type == :endpoint))

    page_sources = Map.new(pages, &{{&1.name, :open}, {&1.file, &1.line}})
    validate!(entries)
    pages = validate_pages!(pages)

    known = %{
      takes: [:values | for(%{type: :model, name: n} <- entries, do: n)],
      returns: [:view_model | for(%{type: t, name: n} <- entries, t in [:model, :block], do: n)]
    }

    validated_endpoints = validate_endpoints!(endpoints, known)

    endpoint_sources =
      Map.merge(
        page_sources,
        Map.new(endpoints, &{{&1.name, &1.opts[:call]}, {&1.file, &1.line}})
      )

    strip = fn entry ->
      %{name: entry.name, fields: Enum.map(entry.fields, &Map.drop(&1, [:file, :line]))}
    end

    operations = env.module |> Module.get_attribute(:spec_protocol) |> Enum.reverse()

    wire_sources =
      Enum.reduce(operations, %{}, fn operation, sources ->
        wire = operation.descriptor
        fail = &__fail__(operation.file, operation.line, &1)

        unless is_map(wire) and Map.has_key?(wire, :name),
          do: fail.("wire descriptor must be a map with a name")

        if Map.has_key?(sources, wire.name), do: fail.("duplicate wire descriptor")
        Map.put(sources, wire.name, {operation.file, operation.line})
      end)

    wires = Enum.map(operations, & &1.descriptor)

    spec = %{
      version: version,
      protocol: wires,
      file: env.file,
      models: for(%{type: :model} = e <- entries, do: strip.(e)),
      blocks: for(%{type: :block} = e <- entries, do: strip.(e)),
      markup: for(%{type: :markup} = e <- entries, do: strip.(e)),
      pages: pages,
      endpoints:
        for(
          page <- pages,
          do: %{
            name: page.name,
            call: :open,
            page: page.name,
            path: page.path,
            params: page.params,
            takes: nil,
            wire: :open,
            replies: [%{name: :page, returns: :view_model}]
          }
        ) ++ validated_endpoints
    }

    AtlasBFF.Wire.validate!(spec, %{wires: wire_sources, endpoints: endpoint_sources})

    quote do
      @doc "The schema as plain data, for the targets (see `AtlasBFF.Schema`)."
      def __schema__, do: unquote(Macro.escape(spec))
    end
  end

  defp validate!(entries) do
    names = fn type -> for %{type: ^type, name: name} <- entries, do: name end
    kinds = {names.(:model), names.(:block), names.(:markup)}

    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      fail = &__fail__(entry.file, entry.line, &1)
      unless snake?(entry.name), do: fail.("#{inspect(entry.name)} is not a snake_case atom")
      if entry.name in seen, do: fail.("#{inspect(entry.name)} is defined twice")

      if entry.name in @primitives,
        do: fail.("#{inspect(entry.name)} clashes with a primitive type")

      Enum.reduce(entry.fields, MapSet.new(), fn field, names ->
        fail = &__fail__(field.file, field.line, &1)

        unless snake?(field.name),
          do: fail.("field #{inspect(field.name)} is not a snake_case atom")

        if field.name in names,
          do: fail.("#{inspect(entry.name)} has field #{inspect(field.name)} twice")

        check_type!(field.type, kinds, "#{entry.name}.#{field.name}", fail)
        MapSet.put(names, field.name)
      end)

      MapSet.put(seen, entry.name)
    end)
  end

  # Endpoints are unique per call, by name and by the paths they match; `:open` is the
  # pages' call.
  defp validate_endpoints!(endpoints, known) do
    {endpoints, _seen} =
      Enum.map_reduce(endpoints, %{}, fn endpoint, seen ->
        fail = &__fail__(endpoint.file, endpoint.line, &1)
        opts = endpoint.opts
        name = endpoint.name

        unless snake?(name), do: fail.("endpoint #{inspect(name)} is not a snake_case atom")

        unless Keyword.keyword?(opts) and
                 Keyword.keys(opts) -- [:call, :takes, :replies, :wire] == [],
               do:
                 fail.(
                   "endpoint #{inspect(name)}: the options are call:, takes:, replies: and wire:"
                 )

        call = opts[:call]

        cond do
          is_nil(call) or not snake?(call) ->
            fail.("endpoint #{inspect(name)} needs call: <a snake_case atom>")

          call == :open ->
            fail.("endpoint #{inspect(name)}: call :open is for pages; use defpage")

          true ->
            :ok
        end

        unless is_nil(opts[:takes]) or opts[:takes] in known.takes,
          do:
            fail.(
              "endpoint #{inspect(name)} takes #{inspect(opts[:takes])}, " <>
                "which is no model and not :values"
            )

        replies = opts[:replies] || []

        unless Keyword.keyword?(replies) and replies != [] and
                 Enum.all?(replies, fn {reply, _returns} -> snake?(reply) end),
               do: fail.("endpoint #{inspect(name)} needs replies: [reply: what it returns]")

        for {reply, returns} <- replies, returns not in known.returns do
          fail.(
            "endpoint #{inspect(name)} replies #{reply} with #{inspect(returns)}, " <>
              "which is no model, no block and not :view_model"
          )
        end

        segments =
          case endpoint.path && AtlasBFF.Paths.parse(endpoint.path) do
            nil -> []
            {:ok, segments} -> segments
            {:error, why} -> fail.("endpoint #{inspect(name)}: #{why}")
          end

        # Endpoints without a path never clash by their paths; their names keep them apart.
        shape = {call, if(endpoint.path, do: AtlasBFF.Paths.shape(segments), else: name)}

        cond do
          Map.has_key?(seen, {call, name}) ->
            fail.("endpoint #{inspect(name)} (#{call}) is defined twice")

          other = Enum.find_value(seen, fn {key, s} -> s == shape && key end) ->
            fail.(
              "endpoints #{inspect(elem(other, 1))} and #{inspect(name)} match the same paths"
            )

          true ->
            :ok
        end

        entry = %{
          name: name,
          call: call,
          page: nil,
          path: endpoint.path,
          params: for({:param, p} <- segments, do: p),
          takes: opts[:takes],
          wire: opts[:wire],
          replies: for({reply, returns} <- replies, do: %{name: reply, returns: returns})
        }

        {entry, Map.put(seen, {call, name}, shape)}
      end)

    endpoints
  end

  # Pages are a namespace of their own: a page may share its name with a block.
  defp validate_pages!(pages) do
    {pages, _seen} =
      Enum.map_reduce(pages, %{}, fn page, seen ->
        fail = &__fail__(page.file, page.line, &1)
        unless snake?(page.name), do: fail.("page #{inspect(page.name)} is not a snake_case atom")
        if Map.has_key?(seen, page.name), do: fail.("page #{inspect(page.name)} is defined twice")

        segments =
          case AtlasBFF.Paths.parse(page.path) do
            {:ok, segments} -> segments
            {:error, why} -> fail.("page #{inspect(page.name)}: #{why}")
          end

        shape = AtlasBFF.Paths.shape(segments)

        case Enum.find(seen, fn {_name, other} -> other == shape end) do
          {other, _} ->
            fail.("pages #{inspect(other)} and #{inspect(page.name)} match the same paths")

          nil ->
            :ok
        end

        params = for {:param, name} <- segments, do: name
        {%{name: page.name, path: page.path, params: params}, Map.put(seen, page.name, shape)}
      end)

    pages
  end

  defp check_type!({:list, inner}, kinds, at, fail), do: check_type!(inner, kinds, at, fail)

  defp check_type!({:map, inner}, _kinds, at, fail) do
    unless inner in @primitives,
      do: fail.("#{at} is a map of #{inspect(inner)}; a map holds a primitive type")

    :ok
  end

  defp check_type!(type, _kinds, _at, _fail) when type in @primitives, do: :ok

  defp check_type!(type, {models, blocks, markup}, at, fail) do
    cond do
      type in models -> :ok
      type in blocks -> fail.("#{at} holds block #{inspect(type)}; blocks have no children")
      type in markup -> fail.("#{at} holds markup #{inspect(type)}; markup covers blocks")
      true -> fail.("#{at} has unknown type #{inspect(type)}")
    end
  end

  defp snake?(name),
    do: is_atom(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end
