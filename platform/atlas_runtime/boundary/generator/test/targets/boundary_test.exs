defmodule AtlasRuntimeBoundary.Generator.Targets.BoundaryTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.{ContractError, InvalidInput, NotPermitted}
  alias AtlasRuntimeBoundary.Generator.Example.Boundary, as: B
  alias AtlasRuntimeBoundary.Generator.Example.Guarded, as: G

  @member {"ann", [:lend, :browse]}
  @until ~U[2026-03-01 10:00:00Z]

  describe "the facade" do
    test "calls the implementation and returns its declared outcome" do
      input = %B.LendInput{title: "Dune", until: @until}

      assert %B.Outcome.Lent{title: "Dune", place: %B.Shelf{row: 3}, due_at: @until} =
               B.lend(@member, input)

      assert %B.Outcome.Missing{} = B.lend(@member, %{input | title: "missing"})
      assert %B.Outcome.Short{waiting: 2} = B.lend(@member, %{input | title: "short"})
      assert %B.Outcome.Counted{books: [%B.Book{title: "ann"}]} = B.count(@member)
    end

    test "returns NotPermitted without the right, and never calls the implementation" do
      # "undeclared" would raise if the implementation were called.
      input = %B.LendInput{title: "undeclared", until: @until}

      assert %NotPermitted{capability: :lend, right: :lend} = B.lend({"bo", [:browse]}, input)

      assert %NotPermitted{capability: :count, right: :browse} =
               B.count({"bo", MapSet.new([:lend])})

      assert %B.Outcome.Counted{} = B.count({"bo", MapSet.new([:browse])})
    end

    test "raises on a client that is not {id, rights}" do
      assert_raise ContractError, ~r/a client is \{id, rights\}/, fn -> B.count(:anyone) end
    end

    test "takes the input as a plain map too, built through new/1 with the JSON forms" do
      assert %B.Outcome.Lent{title: "Dune", due_at: @until} =
               B.lend(@member, %{"title" => "Dune", "until" => "2026-03-01T11:00:00+01:00"})

      assert %B.Outcome.Missing{} = B.lend(@member, %{title: "missing", until: @until})
      assert %B.Outcome.Missing{} = B.find(@member, %{"title" => "x"})
    end

    test "checks the right before the input, in either form" do
      # "undeclared" would raise if the implementation were called; the inputs are invalid.
      for input <- [
            %B.LendInput{title: "undeclared", until: @until},
            %{"title" => "undeclared", "until" => "2026-03-01T10:00:00Z"},
            %B.LendInput{title: 1, until: nil},
            %{"colour" => "red"},
            :no_map
          ] do
        assert %NotPermitted{capability: :lend, right: :lend} = B.lend({"bo", [:browse]}, input)
      end

      assert %NotPermitted{capability: :find, right: :browse} = B.find({"bo", [:lend]}, %{})
    end

    test "answers the contract's invalid_input outcome on an invalid input, in either form" do
      # A built struct is checked strictly: no JSON forms.
      assert B.lend(@member, %B.LendInput{title: 1, until: "2026-03-01T10:00:00Z"}) ==
               %B.Outcome.Declined{
                 why: :unreadable,
                 note:
                   ~s(input.title must be a string, got 1; ) <>
                     ~s(input.until must be a DateTime, got "2026-03-01T10:00:00Z")
               }

      assert B.lend(@member, %{"title" => "Dune", "colour" => "red"}) ==
               %B.Outcome.Declined{
                 why: :unreadable,
                 note: ~s(input has no field "colour"; input.until is required)
               }

      # Through apply/3: the type checker would refuse the literal calls.
      assert %B.Outcome.Declined{note: "input must be a " <> _} =
               apply(B, :lend, [@member, %B.Shelf{row: 1}])

      assert %B.Outcome.Declined{note: "input must be a map, got \"Dune\""} =
               apply(B, :lend, [@member, "Dune"])
    end

    test "answers InvalidInput for a capability that declares no invalid_input outcome" do
      assert B.find(@member, %{"title" => 1}) ==
               %InvalidInput{capability: :find, reasons: ["input.title must be a string, got 1"]}

      assert %InvalidInput{capability: :find, reasons: ["input.title is required"]} =
               B.find(@member, %B.FindInput{title: nil})
    end

    test "raises when the implementation returns an undeclared or invalid outcome" do
      input = %B.LendInput{title: "undeclared", until: @until}

      assert_raise ContractError,
                   ~r/returned .*Outcome.Counted.*none of the declared outcomes/,
                   fn ->
                     B.lend(@member, input)
                   end

      assert_raise ContractError, ~r/returned \{:ok, :lent\}/, fn ->
        B.lend(@member, %{input | title: "plain"})
      end

      assert_raise ContractError, ~r/invalid outcome: outcome.waiting must be an integer/, fn ->
        B.lend(@member, %{input | title: "invalid"})
      end
    end
  end

  describe "a :stream field" do
    test "reaches the caller unconsumed: the facade checks it without enumerating it" do
      # The client's id is told when the stream is opened (Example.Library.download/2).
      assert %B.Outcome.Downloaded{title: "Dune", content: content} =
               B.download({self(), [:browse]}, %{"title" => "Dune"})

      refute_received {:opened, _}
      assert Enum.join(content) == "page 1\npage 2\n"
      assert_received {:opened, "Dune"}

      assert %B.Outcome.Missing{} = B.download({self(), [:browse]}, %{title: "missing"})
    end

    test "the outcome check refuses a map, a function of another arity, and no Enumerable" do
      for {title, got} <- [
            {"map", "got a map"},
            {"one-arity", "got a function of another arity"},
            {"text", ~s(got "not a stream")}
          ] do
        assert_raise ContractError,
                     ~r/invalid outcome: outcome.content must be a stream \(an Enumerable\), #{Regex.escape(got)}/,
                     fn -> B.download(@member, %{title: title}) end
      end
    end

    test "new/1 and validate/1 take any Enumerable but a map, and never enumerate it" do
      lazy = Stream.map(["a", "b"], fn chunk -> send(self(), :enumerated) && chunk end)
      file = File.stream!(__ENV__.file, 64)

      for content <- [lazy, file, ["a", "b"], [], fn _acc, _fun -> {:done, nil} end] do
        assert {:ok, %B.Scan{content: ^content}} = B.Scan.new(%{title: "t", content: content})
        assert :ok = B.Scan.validate(%B.Scan{title: "t", content: content})

        assert {:ok, %B.Outcome.Downloaded{content: ^content}} =
                 B.Outcome.Downloaded.new(title: "t", content: content)
      end

      refute_received :enumerated

      for {content, got} <- [
            {%{}, "got a map"},
            {%{"a" => 1}, "got a map"},
            {%B.Shelf{row: 1},
             "got %AtlasRuntimeBoundary.Generator.Example.Boundary.Shelf{row: 1}"},
            {42, "got 42"},
            {"bytes", ~s(got "bytes")}
          ] do
        assert {:error, [reason]} = B.Scan.new(%{title: "t", content: content})
        assert reason == "scan.content must be a stream (an Enumerable), " <> got
      end

      assert {:error, ["scan.content is required"]} = B.Scan.new(%{title: "t"})
    end

    test "dump/1 refuses to dump a stream as JSON" do
      assert_raise ContractError, ~r/Scan.content is a :stream; a stream is sent as bytes/, fn ->
        B.Scan.dump(%B.Scan{title: "t", content: ["a"]})
      end
    end

    test "its type is Enumerable.t()" do
      {:ok, types} = Code.Typespec.fetch_types(B.Scan)
      {:type, t} = Enum.find(types, &match?({:type, {:t, _, _}}, &1))
      assert Code.Typespec.type_to_quoted(t) |> Macro.to_string() =~ "content: Enumerable.t()"
    end
  end

  describe "a :stream input field (S5c)" do
    test "the implementation gets the same term, unread, from a map or a built struct" do
      lazy = Stream.map(["a", "b"], fn chunk -> send(self(), :enumerated) && chunk end)
      file = File.stream!(__ENV__.file, 64)

      for pages <- [lazy, file, ["a", "b"], [], fn _acc, _fun -> {:done, nil} end] do
        assert %B.Outcome.Received{} =
                 B.upload({self(), [:lend]}, %{"title" => "Dune", "pages" => pages})

        assert_received {:received, ^pages}

        assert %B.Outcome.Received{} =
                 B.upload({self(), [:lend]}, %B.UploadInput{title: "Dune", pages: pages})

        assert_received {:received, ^pages}

        assert {:ok, %B.UploadInput{pages: ^pages}} =
                 B.UploadInput.new(title: "Dune", pages: pages)
      end

      refute_received :enumerated
    end

    test "a binary, a list of non-binaries or a missing value is refused: invalid" do
      for {pages, reason} <- [
            {"bytes", ~s(input.pages must be a stream (an Enumerable\), got "bytes")},
            {[1, 2], "input.pages must be a stream of binary chunks, got [1, 2]"},
            {["a", :b], ~s(input.pages must be a stream of binary chunks, got ["a", :b])},
            {["a" | "b"], ~s(input.pages must be a stream of binary chunks, got ["a" | "b"])},
            {%{}, "input.pages must be a stream (an Enumerable), got a map"},
            {nil, "input.pages is required"}
          ] do
        assert B.upload({self(), [:lend]}, %{"title" => "Dune", "pages" => pages}) ==
                 %B.Outcome.Declined{why: :unreadable, note: reason}

        assert B.upload({self(), [:lend]}, %B.UploadInput{title: "Dune", pages: pages}) ==
                 %B.Outcome.Declined{why: :unreadable, note: reason}

        assert B.UploadInput.new(%{title: "Dune", pages: pages}) ==
                 {:error, ["upload_" <> reason]}
      end

      assert %B.Outcome.Declined{note: "input.pages is required"} =
               B.upload({self(), [:lend]}, %{"title" => "Dune"})

      refute_received {:received, _}
    end

    test "its type is Enumerable.t(), and dump/1 refuses it" do
      {:ok, types} = Code.Typespec.fetch_types(B.UploadInput)
      {:type, t} = Enum.find(types, &match?({:type, {:t, _, _}}, &1))
      assert Code.Typespec.type_to_quoted(t) |> Macro.to_string() =~ "pages: Enumerable.t()"

      assert_raise ContractError, ~r/UploadInput.pages is a :stream/, fn ->
        B.UploadInput.dump(%B.UploadInput{title: "t", pages: ["a"]})
      end
    end
  end

  describe "invalid_detail_right:" do
    test "the invalid_input detail goes only to a client that holds the right" do
      told = {"ann", [:lend, :browse, :see_reasons]}
      untold = {"bo", MapSet.new([:lend, :browse])}

      for input <- [%{"title" => "Dune", "colour" => "red"}, %G.LendInput{title: 1, until: nil}] do
        assert %G.Outcome.Declined{why: :unreadable, note: "input" <> _} = G.lend(told, input)
        assert G.lend(untold, input) == %G.Outcome.Declined{why: :unreadable, note: nil}
      end

      # A valid input still reaches the implementation, whatever the client holds.
      assert %G.Outcome.Missing{} = G.lend(untold, %{title: "Dune", until: @until})

      # Without the option, every client is told.
      assert %B.Outcome.Declined{note: "input has no field" <> _} =
               B.lend(untold, %{"title" => "Dune", "colour" => "red"})
    end

    test "needs an invalid_input with an optional detail: field, and a right" do
      for {contract, message} <- [
            {"AtlasRuntimeBoundary.Generator.Catalogue",
             "invalid_detail_right: the contract declares no invalid_input with detail:"},
            {required_detail_contract(), "invalid_detail_right: no.text is required"}
          ] do
        assert_raise CompileError, ~r/#{Regex.escape(message)}/, fn ->
          guarded_facade(contract, ":see")
        end
      end

      assert_raise CompileError, ~r/invalid_detail_right: expects a right/, fn ->
        guarded_facade("AtlasRuntimeBoundary.Generator.Example", ~s("see"))
      end
    end
  end

  defp required_detail_contract do
    module = "RequiredDetail#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use AtlasRuntimeBoundary.Generator.Schema
      version "0"
      defmodel :ask do field :q, :string, required: true end
      defmodel :no do
        field :why, {:enum, [:bad]}, required: true
        field :text, :string, required: true
      end
      defcapability :go, input: :ask, outcomes: [no: :no], right: :r
      invalid_input :no, set: [why: :bad], detail: :text
    end
    """)

    module
  end

  defp guarded_facade(contract, right) do
    Code.compile_string("""
    defmodule GuardedFacade#{System.unique_integer([:positive])} do
      use AtlasRuntimeBoundary.Generator.Targets.Boundary,
        contract: #{contract},
        implementation: Nobody,
        invalid_detail_right: #{right}
    end
    """)
  end

  describe "constructors" do
    test "build from decoded JSON: string keys, enum names, ISO-8601, tagged one_of" do
      assert {:ok, book} =
               B.Book.new(%{
                 "title" => "Dune",
                 "condition" => "badly-worn",
                 "place" => %{"kind" => "branch", "city" => "Delft"},
                 "due_at" => "2026-03-01T11:00:00+01:00",
                 "labels" => ["audio"],
                 "notes" => %{"shelf" => "top"}
               })

      assert %B.Book{
               condition: :"badly-worn",
               place: %B.Branch{city: "Delft", open: nil},
               due_at: @until,
               labels: [:audio],
               notes: %{"shelf" => "top"}
             } = book
    end

    test "build from atom keys, keyword lists and built structs" do
      assert {:ok, %B.Shelf{row: 1}} = B.Shelf.new(row: 1)

      assert {:ok, %B.Book{place: %B.Shelf{row: 1}}} =
               B.Book.new(%{title: "t", condition: :new, place: %B.Shelf{row: 1}})

      assert {:ok, %B.Book{place: %B.Shelf{row: 2}}} =
               B.Book.new(%{title: "t", condition: :new, place: %{kind: :shelf, row: 2}})
    end

    test "every error, with the path of the field" do
      assert {:error, reasons} =
               B.Book.new(%{
                 "title" => 1,
                 "colour" => "red",
                 "place" => %{"kind" => "attic"},
                 "due_at" => "tomorrow",
                 "labels" => ["audio", "braille"],
                 "notes" => %{"a" => 1}
               })

      assert reasons == [
               ~s(book has no field "colour"),
               "book.title must be a string, got 1",
               "book.condition is required",
               ~s(book.place.kind must be one of shelf, branch, got "attic"),
               ~s(book.due_at must be an ISO-8601 datetime, got "tomorrow"),
               ~s(book.labels[1] must be one of large_print, audio, got "braille"),
               "book.notes.a must be a string, got 1"
             ]

      assert {:error, ["tally.books[0].place.row is required"]} =
               B.Tally.new(%{
                 "books" => [
                   %{"title" => "t", "condition" => "new", "place" => %{"kind" => "shelf"}}
                 ],
                 "counted_at" => "2026-01-01T00:00:00Z"
               })

      assert {:error, [~s(book.place.kind must be one of shelf, branch, got nil)]} =
               B.Book.new(%{"title" => "t", "condition" => "new", "place" => %{"row" => 1}})

      assert_raise ArgumentError, ~r/shelf.row is required/, fn -> B.Shelf.new!(%{}) end
    end

    test "an outcome without a model has no fields" do
      assert {:ok, %B.Outcome.Missing{}} = B.Outcome.Missing.new(%{})
      assert {:error, [~s(missing has no field "x")]} = B.Outcome.Missing.new(%{"x" => 1})
    end

    test "validate checks built structs strictly" do
      assert :ok = B.Shelf.validate(%B.Shelf{row: 1})

      assert {:error, ["shelf.row must be an integer, got \"1\""]} =
               B.Shelf.validate(%B.Shelf{row: "1"})

      assert {:error, [~s(book.condition must be one of new, worn, badly-worn, got "new")]} =
               B.Book.validate(%B.Book{title: "t", condition: "new", place: %B.Shelf{row: 1}})
    end
  end

  test "dump gives JSON-ready data and new/1 reads it back" do
    book = %B.Book{
      title: "Dune",
      condition: :"badly-worn",
      place: %B.Branch{city: "Delft"},
      due_at: @until,
      labels: [:audio]
    }

    dumped = B.Book.dump(book)

    assert dumped == %{
             "title" => "Dune",
             "condition" => "badly-worn",
             "place" => %{"kind" => "branch", "city" => "Delft"},
             "due_at" => "2026-03-01T10:00:00Z",
             "labels" => ["audio"]
           }

    assert {:ok, ^book} = dumped |> JSON.encode!() |> JSON.decode!() |> B.Book.new()
  end

  describe "types and the behaviour" do
    test "the behaviour has one callback per capability, with its arity" do
      assert Enum.sort(B.Implementation.behaviour_info(:callbacks)) ==
               [count: 1, download: 2, find: 2, lend: 2, upload: 2]
    end

    test "callbacks and specs carry the input struct and the union of outcome structs" do
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(B.Implementation)
      {_, [spec]} = List.keyfind(callbacks, {:lend, 2}, 0)
      text = spec |> then(&Code.Typespec.spec_to_quoted(:lend, &1)) |> Macro.to_string()

      assert text =~ "B.LendInput.t()" or text =~ "Boundary.LendInput.t()"

      for outcome <- ~w(Lent Short Declined Missing),
          do: assert(text =~ "Outcome.#{outcome}.t()", "#{outcome} missing in #{text}")

      refute text =~ "Counted"

      # The facade takes the input struct or a map, and answers NotPermitted too; InvalidInput
      # only where the capability declares no invalid_input outcome.
      {:ok, specs} = Code.Typespec.fetch_specs(B)
      {_, [spec]} = List.keyfind(specs, {:lend, 2}, 0)
      lend = Code.Typespec.spec_to_quoted(:lend, spec) |> Macro.to_string()
      assert lend =~ "LendInput.t() | map()"
      assert lend =~ "NotPermitted.t()"
      refute lend =~ "InvalidInput"

      {_, [spec]} = List.keyfind(specs, {:find, 2}, 0)
      assert Code.Typespec.spec_to_quoted(:find, spec) |> Macro.to_string() =~ "InvalidInput.t()"
    end

    test "enums and one_ofs have named types; structs have t" do
      {:ok, types} = Code.Typespec.fetch_types(B.Book)
      names = for {:type, {name, _, _}} <- types, do: name
      assert Enum.sort(names) == [:condition, :labels, :place, :t]

      {:type, condition} = Enum.find(types, &match?({:type, {:condition, _, _}}, &1))

      assert Code.Typespec.type_to_quoted(condition) |> Macro.to_string() ==
               ~s{condition() :: :new | :worn | :"badly-worn"}
    end

    test "a struct literal with an unknown field, or without a required one, fails compilation" do
      assert_raise KeyError, ~r/key :titel not found/, fn ->
        compile_module("def f, do: %B.Book{titel: \"x\"}")
      end

      assert_raise ArgumentError, ~r/the following keys must also be given.*:row/, fn ->
        compile_module("def f, do: %B.Shelf{}")
      end
    end
  end

  defp compile_module(body) do
    Code.compile_string("""
    defmodule Literal#{System.unique_integer([:positive])} do
      alias AtlasRuntimeBoundary.Generator.Example.Boundary, as: B
      #{body}
    end
    """)
  end

  test "a model named like a module of the target is refused" do
    Code.compile_string("""
    defmodule ReservedContract do
      use AtlasRuntimeBoundary.Generator.Schema
      version "0"
      defmodel :outcome do field :x, :string end
    end
    """)

    assert_raise CompileError, ~r/model :outcome is reserved by the target/, fn ->
      Code.compile_string("""
      defmodule ReservedFacade do
        use AtlasRuntimeBoundary.Generator.Targets.Boundary,
          contract: ReservedContract,
          implementation: Nobody
      end
      """)
    end
  end
end
