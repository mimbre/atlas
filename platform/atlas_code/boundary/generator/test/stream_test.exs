defmodule AtlasCodeBoundary.Generator.StreamTest do
  use ExUnit.Case, async: true

  alias AtlasCodeBoundary.Generator.{ContractError, ReadingRoom, Targets.Json}
  alias AtlasCodeBoundary.Generator.FixtureModel, as: M
  alias AtlasCodeBoundary.Generator.ReadingRoom.Boundary, as: R

  @rule "a :stream is allowed only as a direct field of an outcome model"

  describe "the schema" do
    test "keeps :stream as a field's type" do
      reading = Enum.find(ReadingRoom.__schema__().models, &(&1.name == :reading))
      assert %{name: :pages, type: :stream, required: true} in reading.fields
    end

    test "refuses a stream anywhere but as a direct field of an outcome model, at its line" do
      scan = "defmodel :scan do\nfield :content, :stream, required: true\nend\n"

      for {body, message} <- [
            {scan <> "defcapability :up, input: :scan, outcomes: [ok: nil], right: :r",
             "scan.content: #{@rule}; :scan is the input of capability :up"},
            {scan <>
               "defmodel :up_input do field :scan, :scan end\n" <>
               "defcapability :get, outcomes: [got: :scan], right: :r\n" <>
               "defcapability :up, input: :up_input, outcomes: [ok: nil], right: :r",
             "scan.content: #{@rule}; :scan is held by up_input.scan"},
            {scan <>
               "defmodel :c do field :z, {:list, :scan} end\n" <>
               "defcapability :get, outcomes: [got: :c], right: :r",
             "scan.content: #{@rule}; :scan is held by c.z"},
            {scan <>
               "defmodel :other do field :y, :string end\n" <>
               "defmodel :c do field :z, {:one_of, [:scan, :other], tag: :kind} end\n" <>
               "defcapability :get, outcomes: [got: :scan, c: :c], right: :r",
             "scan.content: #{@rule}; :scan is held by c.z"},
            {scan, "scan.content: #{@rule}; no outcome carries :scan"},
            {"defmodel :a do field :x, {:list, :stream} end",
             "a.x is a list of :stream; #{@rule}"},
            {"defmodel :a do field :x, {:map, :stream} end",
             "a.x is a map of :stream; a map holds a primitive type"},
            {"defmodel :stream do field :x, :string end",
             ":stream clashes with a primitive type"},
            {"""
             defmodel :no do field :why, :stream, required: true end
             defcapability :go, outcomes: [no: :no], right: :r
             invalid_input :no, set: [why: "bytes"]
             """, ~s(no.why cannot be "bytes")}
          ] do
        error = assert_raise CompileError, ~r/#{Regex.escape(message)}/, fn -> spec(body) end
        if String.starts_with?(body, scan), do: assert(error.line == 5, inspect(error))
      end
    end
  end

  describe "the facade" do
    test "passes the implementation's stream through unread" do
      assert %R.Outcome.Opened{title: "Dune", pages: pages} = R.read(client(), %{title: "Dune"})

      # Checking the outcome read nothing; the receiver's enumeration is the first read.
      refute_received {:page_read, _}
      refute is_list(pages) or is_binary(pages)
      assert Enum.take(pages, 1) == ["page 1\n"]
      assert_received {:page_read, 1}
      refute_received {:page_read, 2}
      assert Enum.to_list(pages) == ["page 1\n", "page 2\n", "page 3\n"]
    end

    test "refuses as outcome a binary, a plain map, a function of another arity, no Enumerable" do
      for {title, got} <- [
            {"text", ~s(got "not a stream")},
            {"map", "got a map"},
            {"number", "got 42"},
            {"one-arity", "got a function of another arity"}
          ] do
        assert_raise ContractError,
                     ~r/invalid outcome: outcome.pages must be a stream \(an Enumerable\), #{Regex.escape(got)}/,
                     fn -> R.read(client(), %{title: title}) end
      end
    end
  end

  describe "struct functions" do
    test "new/1 and validate/1 take any Enumerable but a map, and never enumerate it" do
      lazy = Stream.map(["a", "b"], fn chunk -> send(self(), :enumerated) && chunk end)
      file = File.stream!(__ENV__.file, 64)

      for pages <- [lazy, file, ["a"], [], fn _acc, _fun -> {:done, nil} end] do
        assert {:ok, %R.Reading{pages: ^pages} = reading} =
                 R.Reading.new(title: "x", pages: pages)

        assert R.Reading.validate(reading) == :ok
      end

      refute_received :enumerated

      for {pages, got} <- [{%{}, "got a map"}, {"bytes", ~s(got "bytes")}, {:x, "got :x"}] do
        assert {:error, ["reading.pages must be a stream (an Enumerable), " <> ^got]} =
                 R.Reading.new(title: "x", pages: pages)
      end

      assert {:error, ["reading.pages is required"]} = R.Reading.new(title: "x")
    end

    test "dump/1 refuses a stream: it is sent as bytes, never as JSON" do
      reading = R.Reading.new!(title: "x", pages: Stream.cycle(["endless"]))

      assert_raise ContractError,
                   ~r/Reading.pages is a :stream; a stream is sent as bytes, never dumped as JSON/,
                   fn -> R.Reading.dump(reading) end
    end
  end

  # As in the Runtime's generator: no model type is a stream, so a mapping supplies it.
  describe "a mapping onto a stream field" do
    test "supplies it, and from_model passes it on unconsumed" do
      facade = stream_facade("supply: [:content]")
      lazy = Stream.map(["a"], fn chunk -> send(self(), :enumerated) && chunk end)
      scan = Module.concat(facade, Scan)

      assert {:ok, %{__struct__: ^scan, row: 4, content: ^lazy}} =
               facade.from_model(M.ShelfSpot.new!(row: 4), supply: [content: lazy])

      refute_received :enumerated
    end

    test "maps no model field onto it" do
      assert_raise CompileError,
                   ~r/shelf_spot.row -> scan.content: a boundary :stream takes no model field; supply it/,
                   fn -> stream_facade("rename: [row: :content], supply: [:row]") end
    end
  end

  test "the JSON target describes a stream only as a byte stream" do
    [{"reading_room.json", body}] = Json.files(ReadingRoom.__schema__(), name: "reading_room")
    models = Map.new(JSON.decode!(body)["models"], &{&1["name"], &1["fields"]})

    assert %{
             "name" => "pages",
             "type" => "stream",
             "description" => "byte stream",
             "required" => true
           } in models["reading"]
  end

  defp client, do: {self(), [:read]}

  defp stream_facade(options) do
    n = System.unique_integer([:positive])

    Code.compile_string("""
    defmodule StreamContract#{n} do
      use AtlasCodeBoundary.Generator.Schema
      version "0"
      defmodel :scan do
        field :row, :integer, required: true
        field :content, :stream, required: true
      end
      defcapability :get, outcomes: [got: :scan], right: :r
    end

    defmodule StreamMappings#{n} do
      use AtlasCodeBoundary.Generator.Mappings
      defmapping :shelf_spot, :scan, direction: :from_model, #{options}
    end

    defmodule StreamFacade#{n} do
      use AtlasCodeBoundary.Generator.Targets.Boundary,
        contract: StreamContract#{n},
        implementation: StreamDesk#{n},
        mappings: StreamMappings#{n},
        model: AtlasCodeBoundary.Generator.FixtureModel
    end

    defmodule StreamDesk#{n} do
      use StreamFacade#{n}.Implementation
      @impl true
      def get(_client), do: %StreamFacade#{n}.Outcome.Got{row: 1, content: []}
    end
    """)

    Module.concat([:"StreamFacade#{n}"])
  end

  defp spec(body) do
    module = :"Elixir.StreamSpec#{System.unique_integer([:positive])}"

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
