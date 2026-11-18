defmodule AtlasCodeBoundary.Generator.SchemaTest do
  use ExUnit.Case, async: true

  alias AtlasCodeBoundary.Generator.Example

  test "a contract compiles to plain data, in the order written" do
    schema = Example.__schema__()
    assert %{version: "1.0.0", file: file} = schema
    assert String.ends_with?(file, "test/support/example.ex")

    assert Map.keys(schema) |> Enum.sort() ==
             [:capabilities, :file, :invalid_input, :models, :version]

    assert Enum.map(schema.models, & &1.name) ==
             [:shelf, :branch, :book, :lend_input, :shortage, :refusal, :find_input, :tally]

    book = Enum.find(schema.models, &(&1.name == :book))

    assert book.fields == [
             %{name: :title, type: :string, required: true},
             %{name: :condition, type: {:enum, [:new, :worn, :"badly-worn"]}, required: true},
             %{name: :place, type: {:one_of, [:shelf, :branch], tag: :kind}, required: true},
             %{name: :due_at, type: :datetime, required: false},
             %{name: :labels, type: {:list, {:enum, [:large_print, :audio]}}, required: false},
             %{name: :notes, type: {:map, :string}, required: false}
           ]
  end

  test "capabilities: input, right and outcomes in the order written" do
    assert Example.__schema__().capabilities == [
             %{
               name: :lend,
               input: :lend_input,
               right: :lend,
               outcomes: [
                 %{name: :lent, model: :book},
                 %{name: :short, model: :shortage},
                 %{name: :declined, model: :refusal},
                 %{name: :missing, model: nil}
               ]
             },
             %{
               name: :count,
               input: nil,
               right: :browse,
               outcomes: [%{name: :counted, model: :tally}]
             },
             %{
               name: :find,
               input: :find_input,
               right: :browse,
               outcomes: [%{name: :lent, model: :book}, %{name: :missing, model: nil}]
             }
           ]
  end

  test "invalid_input: the outcome, its fixed values and its detail field, else nil" do
    assert Example.__schema__().invalid_input ==
             %{outcome: :declined, set: [why: :unreadable], detail: :note}

    assert spec("defcapability :a, outcomes: [ok: nil], right: :r").__schema__().invalid_input ==
             nil
  end

  test "a datetime may be listed and mapped, an enum and a one_of listed" do
    schema =
      spec("""
      defmodel :a do field :x, :integer end
      defmodel :b do field :y, :integer end
      defmodel :c do
        field :at, {:list, :datetime}
        field :by, {:map, :datetime}
        field :ab, {:list, {:one_of, [:a, :b], tag: :kind}}
      end
      """).__schema__()

    assert [
             _,
             _,
             %{
               fields: [
                 %{type: {:list, :datetime}},
                 %{type: {:map, :datetime}},
                 %{type: {:list, {:one_of, [:a, :b], tag: :kind}}}
               ]
             }
           ] =
             schema.models
  end

  test "a capability without input: input: nil and no input: are the same" do
    schema =
      spec("""
      defcapability :a, input: nil, outcomes: [ok: nil], right: :r
      defcapability :b, outcomes: [ok: nil], right: :r
      """).__schema__()

    assert [%{name: :a, input: nil}, %{name: :b, input: nil}] = schema.capabilities
  end

  describe "a mistake fails at compile time" do
    test "an unknown type" do
      assert_raise CompileError, ~r/a.x has unknown type :strnig/, fn ->
        spec("defmodel :a do field :x, {:list, :strnig} end")
      end
    end

    test "a name or a field defined twice" do
      assert_raise CompileError, ~r/:a is defined twice/, fn ->
        spec("defmodel :a do field :x, :string end\ndefmodel :a do field :y, :string end")
      end

      assert_raise CompileError, ~r/:a has field :x twice/, fn ->
        spec("defmodel :a do field :x, :string\nfield :x, :integer end")
      end
    end

    test "a model named like a primitive" do
      assert_raise CompileError, ~r/:datetime clashes with a primitive type/, fn ->
        spec("defmodel :datetime do field :x, :string end")
      end
    end

    test "a field option other than required:, and a field outside a model" do
      assert_raise CompileError, ~r/the only option is required/, fn ->
        spec("defmodel :a do field :x, :string, default: 1 end")
      end

      assert_raise CompileError, ~r/field :x outside a model/, fn -> spec("field :x, :string") end
    end

    test "an empty enum, a value listed twice, a non-atom value" do
      assert_raise CompileError, ~r/a.x: an enum is \{:enum, \[atom\]\}/, fn ->
        spec("defmodel :a do field :x, {:enum, []} end")
      end

      assert_raise CompileError, ~r/a.x: an enum lists a value twice/, fn ->
        spec("defmodel :a do field :x, {:enum, [:p, :p]} end")
      end

      assert_raise CompileError, ~r/an enum is/, fn ->
        spec(~s(defmodel :a do field :x, {:enum, ["p"]} end))
      end
    end

    test "a one_of without a tag, with one model, an unknown model, or a model twice" do
      models = "defmodel :p do field :x, :string end\ndefmodel :q do field :y, :string end\n"

      assert_raise CompileError, ~r/c.z: a one_of is \{:one_of, \[model\], tag: atom\}/, fn ->
        spec(models <> "defmodel :c do field :z, {:one_of, [:p, :q]} end")
      end

      assert_raise CompileError, ~r/c.z: a one_of lists at least two models/, fn ->
        spec(models <> "defmodel :c do field :z, {:one_of, [:p], tag: :kind} end")
      end

      assert_raise CompileError, ~r/c.z: one_of member :r is no model/, fn ->
        spec(models <> "defmodel :c do field :z, {:one_of, [:p, :r], tag: :kind} end")
      end

      assert_raise CompileError, ~r/c.z: a one_of lists a model twice/, fn ->
        spec(models <> "defmodel :c do field :z, {:one_of, [:p, :p], tag: :kind} end")
      end
    end

    test "a one_of whose tag is a field of a member, pointing at the field's line" do
      error =
        assert_raise CompileError, ~r/c.z: tag :x is also a field of :p/, fn ->
          spec("""
          defmodel :p do field :x, :string end
          defmodel :q do field :y, :string end
          defmodel :c do
            field :z, {:one_of, [:p, :q], tag: :x}
          end
          """)
        end

      assert error.line == 7
    end

    test "a map of anything but a primitive" do
      assert_raise CompileError,
                   ~r/a.x is a map of \{:enum, \[:p\]\}; a map holds a primitive/,
                   fn ->
                     spec("defmodel :a do field :x, {:map, {:enum, [:p]}} end")
                   end
    end

    test "a capability with an unknown input or outcome model" do
      assert_raise CompileError, ~r/capability :go takes :nope, which is no model/, fn ->
        spec("defcapability :go, input: :nope, outcomes: [ok: nil], right: :r")
      end

      assert_raise CompileError,
                   ~r/capability :go: outcome ok carries :nope, which is no model/,
                   fn ->
                     spec("defcapability :go, outcomes: [ok: :nope], right: :r")
                   end
    end

    test "a capability without outcomes, without a right, or with another option" do
      assert_raise CompileError, ~r/capability :go needs outcomes:/, fn ->
        spec("defcapability :go, outcomes: [], right: :r")
      end

      assert_raise CompileError, ~r/capability :go needs right:/, fn ->
        spec("defcapability :go, outcomes: [ok: nil]")
      end

      assert_raise CompileError, ~r/the options are input:, outcomes: and right:/, fn ->
        spec("defcapability :go, outcomes: [ok: nil], right: :r, path: \"/go\"")
      end
    end

    test "a capability or an outcome defined twice" do
      assert_raise CompileError, ~r/capability :go is defined twice/, fn ->
        spec(
          "defcapability :go, outcomes: [ok: nil], right: :r\ndefcapability :go, outcomes: [ok: nil], right: :r"
        )
      end

      assert_raise CompileError, ~r/capability :go has outcome :ok twice/, fn ->
        spec("defcapability :go, outcomes: [ok: nil, ok: nil], right: :r")
      end
    end

    test "an outcome name that carries another model in another capability" do
      error =
        assert_raise CompileError,
                     ~r/outcome :ok carries :a here and nil elsewhere; an outcome means the same/,
                     fn ->
                       spec("""
                       defmodel :a do field :x, :string end
                       defcapability :go, outcomes: [ok: nil], right: :r
                       defcapability :stay, outcomes: [ok: :a], right: :r
                       """)
                     end

      assert error.line == 6
    end

    test "an invalid_input that does not fit its outcome" do
      model = """
      defmodel :no do
        field :why, {:enum, [:bad, :unknown]}, required: true
        field :text, :string
        field :count, :integer
      end
      defcapability :go, input: :no, outcomes: [no: :no, gone: nil], right: :r
      """

      for {declaration, message} <- [
            {"invalid_input :nope, set: [why: :bad]", ":nope is no capability's outcome"},
            {"invalid_input :gone", "outcome :gone carries no model"},
            {"invalid_input :no, set: [why: :worse]", "no.why cannot be :worse"},
            {"invalid_input :no, set: [whom: :bad]", ":no has no field :whom"},
            {"invalid_input :no, set: [why: :bad], detail: :count",
             "detail: :count is no string field of :no"},
            {"invalid_input :no, set: [why: :bad, text: \"x\"], detail: :text",
             ":text is both set and detail"},
            {"invalid_input :no, detail: :text",
             "required field no.why is neither set nor detail"},
            {"invalid_input :no, set: [why: :bad], then: :x", "the options are set: and detail:"},
            {"invalid_input :no, set: [why: :bad]\ninvalid_input :no, set: [why: :bad]",
             "invalid_input is declared twice"}
          ] do
        assert_raise CompileError, ~r/#{Regex.escape(message)}/, fn ->
          spec(model <> declaration)
        end
      end

      assert spec(model <> "invalid_input :no, set: [why: :bad, count: 0]").__schema__().invalid_input ==
               %{outcome: :no, set: [why: :bad, count: 0], detail: nil}
    end

    test "a capability inside a model, and a contract without a version" do
      assert_raise CompileError, ~r/capability :go inside :a/, fn ->
        spec("defmodel :a do\ndefcapability :go, outcomes: [ok: nil], right: :r\nend")
      end

      assert_raise CompileError, ~r/the contract needs a version/, fn ->
        Code.compile_string("""
        defmodule NoVersion#{System.unique_integer([:positive])} do
          use AtlasCodeBoundary.Generator.Schema
        end
        """)
      end
    end
  end

  defp spec(body) do
    module = :"Elixir.Spec#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use AtlasCodeBoundary.Generator.Schema
      version "0"
      #{body}
    end
    """)

    module
  end
end
