defmodule AtlasRuntimeModel.Generator.SchemaTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.Example

  # The model schema shape (design §1.7, D36): the boundary generator reads it too.
  describe "the model schema shape" do
    test "is exactly %{version, entities: [%{name, fields, persistence}]}" do
      {{:module, module, _, _}, _} =
        Code.eval_string("""
        defmodule AtlasRuntimeModel.Generator.SchemaTest.Shape do
          use AtlasRuntimeModel.Generator.Schema
          version "3.0.0"
          type :colour, values: [:red, :blue]
          defmodel :a do
            field :x, :string, required: true
          end
          defmodel :b do
            field :colour, :colour
          end
          defrecord :r, persist: [form: :json_file, path: "rs/{id}.json", format_version: 4] do
            field :id, :string, required: true
            field :at, :datetime
            field :one, {:one_of, [:a, :b]}, required: true
            field :many, {:list, :a}, required: true
            field :colours, {:list, :colour}
            field :size, {:enum, [:s, :m]}
            field :n, :integer
            field :ok, :boolean, required: true
          end
          defrecord :all, persist: [form: :json_file, path: "rs/all.json", format_version: 1] do
            field :id, :string, required: true
          end
        end
        """)

      assert module.__schema__() == %{
               version: "3.0.0",
               entities: [
                 %{
                   name: :a,
                   fields: [%{name: :x, type: :string, required: true}],
                   persistence: nil
                 },
                 %{
                   name: :b,
                   fields: [%{name: :colour, type: {:enum, [:red, :blue]}, required: false}],
                   persistence: nil
                 },
                 %{
                   name: :r,
                   fields: [
                     %{name: :id, type: :string, required: true},
                     %{name: :at, type: :datetime, required: false},
                     %{name: :one, type: {:one_of, [:a, :b]}, required: true},
                     %{name: :many, type: {:list, :a}, required: true},
                     %{name: :colours, type: {:list, {:enum, [:red, :blue]}}, required: false},
                     %{name: :size, type: {:enum, [:s, :m]}, required: false},
                     %{name: :n, type: :integer, required: false},
                     %{name: :ok, type: :boolean, required: true}
                   ],
                   persistence: %{form: :json_file, path: "rs/{id}.json", format_version: 4}
                 },
                 %{
                   name: :all,
                   fields: [%{name: :id, type: :string, required: true}],
                   persistence: %{form: :json_file, path: "rs/all.json", format_version: 1}
                 }
               ]
             }
    end

    test "the example conforms: only the documented keys and types" do
      assert conforms?(Example.__schema__())

      assert Enum.map(Example.__schema__().entities, & &1.name) ==
               [:author, :paper, :ebook, :review, :book, :loan_entry]
    end
  end

  @doc false
  # The documented shape, checked key by key and type by type.
  def conforms?(%{version: version, entities: entities} = schema)
      when map_size(schema) == 2 and is_binary(version) and is_list(entities) do
    names = Enum.map(entities, & &1.name)

    Enum.all?(entities, fn
      %{name: name, fields: fields, persistence: persistence} = entity
      when map_size(entity) == 3 and is_atom(name) and is_list(fields) ->
        persistence?(persistence) and
          Enum.all?(fields, fn
            %{name: n, type: t, required: r} = f when map_size(f) == 3 ->
              is_atom(n) and is_boolean(r) and type?(t, names)

            _ ->
              false
          end)

      _ ->
        false
    end)
  end

  def conforms?(_), do: false

  defp persistence?(nil), do: true

  defp persistence?(%{form: :json_file, path: path, format_version: v} = p),
    do: map_size(p) == 3 and is_binary(path) and is_integer(v) and v > 0

  defp persistence?(_), do: false

  defp type?(t, _names) when t in [:string, :integer, :boolean, :datetime], do: true
  defp type?({:enum, values}, _names), do: Enum.all?(values, &is_atom/1)
  defp type?({:one_of, variants}, names), do: Enum.all?(variants, &(&1 in names))
  defp type?({:list, inner}, names), do: type?(inner, names)
  defp type?(t, names), do: t in names

  test "the generator depends on nothing (no Control, no other generator)" do
    assert Mix.Project.config()[:deps] == []
  end

  defp compile(body) do
    Code.compile_string("""
    defmodule AtlasRuntimeModel.Generator.SchemaTest.M#{System.unique_integer([:positive])} do
      use AtlasRuntimeModel.Generator.Schema
      #{if body =~ ~r/(^|\n)\s*(# )?version /, do: "", else: ~s(version "1")}
      #{body}
    end
    """)
  end

  @persist ~s(persist: [form: :json_file, path: "x/{id}.json", format_version: 1])

  for {what, body, message} <- [
        {"an unknown type", "defmodel :a do\n field :b, :colour\n end",
         "a.b has unknown type :colour"},
        {"a record as a field's type",
         "defrecord :r, #{@persist} do\n field :id, :string, required: true\n end\n" <>
           "defmodel :a do\n field :r, :r\n end",
         "holds record :r; a record is stored on its own"},
        {"a duplicate name", "defmodel :a do\n end\n type :a, values: [:x]",
         ":a is defined twice"},
        {"a primitive's name", "defmodel :datetime do\n end", "clashes with a primitive"},
        {"a field twice", "defmodel :a do\n field :b, :string\n field :b, :integer\n end",
         "has field :b twice"},
        {"an unknown option", "defmodel :a do\n field :b, :string, default: 1\n end",
         "the only option is required"},
        {"a field outside", "field :b, :string", "outside a model or record"},
        {"a nested declaration", "defmodel :a do\n defmodel :b do\n end\n end", "inside :a"},
        {"an empty enum", "type :e, values: []", "nonempty list of snake_case atoms"},
        {"an enum value twice", "type :e, values: [:x, :x]", "listed twice"},
        {"nil as an enum value", "type :e, values: [nil]", "no enum values"},
        {"a one_of of one model",
         "defmodel :a do\n end\n defmodel :b do\n field :c, {:one_of, [:a]}\n end",
         "two or more distinct models"},
        {"a one_of naming an enum",
         "type :e, values: [:x]\n defmodel :a do\n end\n defmodel :b do\n field :c, {:one_of, [:a, :e]}\n end",
         "variant :e is no model"},
        {"a one_of model with a kind field",
         "defmodel :a do\n field :kind, :string\n end\n defmodel :z do\n end\n" <>
           "defmodel :b do\n field :c, {:one_of, [:a, :z]}\n end",
         "a.kind: a model in a one_of has no field kind"},
        {"a record without persist", "defrecord :r, [] do\n end", "needs persist:"},
        {"another form",
         ~s(defrecord :r, persist: [form: :ecto, path: "x.json", format_version: 1] do\n end),
         "json_file is the only form"},
        {"an absolute path",
         ~s(defrecord :r, persist: [form: :json_file, path: "/x.json", format_version: 1] do\n end),
         "a relative path"},
        {"a path leaving home",
         ~s(defrecord :r, persist: [form: :json_file, path: "../x.json", format_version: 1] do\n end),
         "a relative path"},
        {"no format version",
         ~s(defrecord :r, persist: [form: :json_file, path: "x.json"] do\n end),
         "format_version: a positive integer"},
        {"a path naming no required string field",
         "defrecord :r, #{@persist} do\n field :id, :integer, required: true\n end",
         "{id} is no required string field"},
        {"no version", "# version omitted\n defmodel :a do\n end", "needs a version"},
        {"a version twice", ~s(version "1"\n version "2"), "version is given twice"},
        {"a version that is no string", "version 1", "version: a nonempty string"},
        {"a map type, outside the schema shape",
         "defmodel :a do\n field :b, {:map, :string}\n end",
         "a.b has unknown type {:map, :string}"},
        {"a layout option",
         ~s(defrecord :r, persist: [form: :json_file, path: "x.json", format_version: 1, layout: :collection] do\n end),
         "needs persist: [form:, path:, format_version:]"},
        {"a format_version field",
         "defrecord :r, #{@persist} do\n field :id, :string, required: true\n field :format_version, :integer\n end",
         "format_version is reserved"}
      ] do
    test "refuses #{what} at compile time" do
      error = assert_raise CompileError, fn -> compile(unquote(body)) end
      assert Exception.message(error) =~ unquote(message)
    end
  end
end
