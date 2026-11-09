defmodule AtlasFacts.TestModel do
  @moduledoc """
  A neutral model for Facts' tests, compiled by the Rela DSL's store generator
  (`RelaDSL.Facts.Model`, as a composition compiles it) from the description a test
  gives: rela's part of it (kinds, their fields, relations, types) and the model's
  additions (every other key: rules, progress, components, connectors, guidance, the
  turn, the run mapping under `flow_runtime`), split as `split/1` says.

      defmodule Ruled do
        use AtlasFacts.TestModel, description: %{"entities" => ..., "relations" => ...}
      end

  A test's store serves `rela_schema/0`, so Facts starts on it: what rela serves for
  rela's part, never a hand-written stand-in of it.
  """

  # What rela's schema holds; everything else is the model's.
  @entity ~w(label plural description id_type id_prefix id_prefixes aliases properties primary)
  @property ~w(type required unique default description values labels)
  @relation ~w(label description from to max_outgoing inverse)

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AtlasFacts.Model
      @test_description Keyword.fetch!(opts, :description)
      @before_compile AtlasFacts.TestModel
    end
  end

  defmacro __before_compile__(env) do
    description = Module.get_attribute(env.module, :test_description)
    {schema, extension} = split(description)

    flow_runtime =
      if description["flow_runtime"], do: %{"flow_runtime" => description["flow_runtime"]}

    quote do
      unquote(RelaDSL.Facts.Model.body(schema, extension, flow_runtime))

      def guidance, do: unquote(Macro.escape(extension["guidance"]))
      def turn, do: unquote(Macro.escape(get_in(extension, ["runtime", "turn"])))
    end
  end

  @doc "A description split into rela's schema and the model's additions: `{schema, additions}`."
  def split(description) do
    entities = description["entities"] || %{}
    relations = description["relations"] || %{}

    schema = %{
      "entities" =>
        Map.new(entities, fn {kind, spec} ->
          spec = Map.take(spec, @entity)

          {kind,
           Map.update(spec, "properties", %{}, fn props ->
             Map.new(props, fn {name, p} -> {name, Map.take(p, @property)} end)
           end)}
        end),
      "relations" => Map.new(relations, fn {name, spec} -> {name, Map.take(spec, @relation)} end),
      "types" => description["types"] || %{}
    }

    entity_additions =
      for {kind, spec} <- entities,
          rest = Map.drop(spec, @entity),
          props = property_additions(spec["properties"] || %{}),
          rest = if(props == %{}, do: rest, else: Map.put(rest, "properties", props)),
          rest != %{},
          into: %{},
          do: {kind, rest}

    relation_additions =
      for {name, spec} <- relations,
          rest = Map.drop(spec, @relation),
          rest != %{},
          into: %{},
          do: {name, rest}

    additions = %{"entities" => entity_additions, "relations" => relation_additions}

    {schema,
     Map.merge(Map.drop(description, ~w(entities relations types flow_runtime)), additions)}
  end

  defp property_additions(properties) do
    for {name, p} <- properties,
        more = Map.drop(p, @property),
        more != %{},
        into: %{},
        do: {name, more}
  end
end

defmodule AtlasFacts.Workshop.Description do
  @moduledoc """
  The description of the neutral workshop: widgets, the parts of a widget and their
  makers, with no rules. Its kinds are made up on purpose: Facts must not care.
  """

  def base,
    do: %{
      "entities" => %{
        "widget" => %{
          "plural" => "widgets",
          "primary" => "title",
          "id_type" => "manual",
          "id_prefixes" => ["W-"],
          "properties" => %{
            "title" => %{"type" => "string", "required" => true},
            "shade" => %{"type" => "shade", "values" => ["light", "dark"]},
            "done" => %{"type" => "boolean"}
          }
        },
        "part" => %{"plural" => "parts", "properties" => %{"title" => %{"type" => "string"}}},
        "maker" => %{"plural" => "makers", "properties" => %{"title" => %{"type" => "string"}}}
      },
      "relations" => %{
        "of_widget" => %{"from" => ["part"], "to" => ["widget"], "max_outgoing" => 1},
        "made_by" => %{"from" => ["widget", "part"], "to" => ["maker"], "max_outgoing" => 1}
      }
    }

  @doc "The workshop's description with `more` merged in, key by key: a test model's."
  def with(more), do: merge(base(), more)

  defp merge(left, right),
    do:
      Map.merge(left, right, fn _key, l, r ->
        if is_map(l) and is_map(r), do: merge(l, r), else: r
      end)
end

defmodule AtlasFacts.Workshop do
  @moduledoc "The neutral model most of Facts' tests run on (`AtlasFacts.Workshop.Description`)."
  use AtlasFacts.TestModel, description: AtlasFacts.Workshop.Description.base()
end
