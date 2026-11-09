defmodule AtlasRuntimeModel.Generator.Targets.ModelTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.Example.Model
  alias Model.{Author, Book, Ebook, LoanEntry, Paper, Review}

  @at ~U[2026-01-02 03:04:05.123456Z]

  defp book(overrides \\ []) do
    Book.new!(
      Keyword.merge(
        [
          book_id: "b-1",
          title: "A title",
          genre: :poetry,
          authors: [%{name: "Ann", born: 1900}, Author.new!(name: "Bo")],
          edition: %{kind: :paper, pages: 120, hardcover: false},
          reviews: [%{stars: :three, at: @at}],
          tags: ["x"],
          shelved_at: @at
        ],
        overrides
      )
    )
  end

  test "one plain struct per model and record, with required keys enforced" do
    assert Model.records() == [book: Book, loan_entry: LoanEntry]

    assert %Book{genre: :poetry, edition: %Paper{pages: 120}, authors: [%Author{}, %Author{}]} =
             book()

    assert Map.keys(Map.from_struct(book())) |> Enum.sort() ==
             Enum.sort(
               [:book_id, :title, :genre, :authors, :edition, :reviews, :tags] ++
                 [:shelved_at, :archive_note]
             )
  end

  test "a struct literal with an unknown or without a required field does not compile" do
    assert_raise KeyError, ~r/key :nmae not found/, fn ->
      Code.compile_string("%#{inspect(Author)}{nmae: \"x\"}")
    end

    assert_raise ArgumentError, ~r/the following keys must also be given.*:name/, fn ->
      Code.compile_string("%#{inspect(Author)}{born: 1}")
    end
  end

  test "@type t is precise: enums are atom unions, a one_of its models, optional nil" do
    {:ok, types} = Code.Typespec.fetch_types(Book)
    {:type, t} = Enum.find(types, &match?({:type, {:t, _, _}}, &1))

    spec =
      t |> Code.Typespec.type_to_quoted() |> Macro.to_string() |> String.replace(~r"\s+", " ")

    assert spec =~ "genre: :novel | :poetry | :essay"
    assert spec =~ "edition: #{inspect(Paper)}.t() | #{inspect(Ebook)}.t()"
    assert spec =~ "shelved_at: DateTime.t() | nil"
    assert spec =~ "reviews: [#{inspect(Review)}.t()] | nil"
    assert spec =~ "authors: [#{inspect(Author)}.t()]"
  end

  describe "new/1" do
    test "builds nested structs from maps and keyword lists, and checks structs again" do
      assert {:ok, %Book{edition: %Ebook{bytes: 9}}} =
               Book.new(Map.from_struct(%{book() | edition: %Ebook{bytes: 9}}))

      assert {:ok, %Author{name: "Ann", born: nil}} = Author.new(name: "Ann")
    end

    test "refuses unknown and missing fields and wrong values, naming where" do
      fields = Map.from_struct(book())
      assert {:error, {:unknown_field, "book.colour"}} = Book.new(Map.put(fields, :colour, 1))
      assert {:error, {:unknown_field, "book.title"}} = Book.new(%{"title" => "x"})
      assert {:error, {:missing_field, "book.title"}} = Book.new(Map.delete(fields, :title))

      assert {:error, {:invalid, "book.genre", "one of novel, poetry, essay"}} =
               Book.new(%{fields | genre: :jazz})

      assert {:error, {:invalid, "book.genre", _}} = Book.new(%{fields | genre: "poetry"})

      assert {:error, {:missing_field, "book.authors[1].name"}} =
               Book.new(%{fields | authors: [%{name: "A"}, %{born: 1}]})

      assert {:error, {:invalid, "book.edition", _}} =
               Book.new(%{fields | edition: %{kind: :scroll, pages: 1}})

      assert {:error, {:invalid, "book.edition", _}} =
               Book.new(%{fields | edition: %Author{name: "A"}})

      assert {:error, {:invalid, "book.shelved_at", _}} =
               Book.new(%{fields | shelved_at: "2026-01-01"})

      assert {:error, {:invalid, "book.reviews[0].stars", _}} =
               Book.new(%{fields | reviews: [%{stars: :five, at: @at}]})

      assert {:error, {:invalid, "book.tags[0]", "a string"}} = Book.new(%{fields | tags: [1]})
      assert {:error, {:invalid, "book", _}} = Book.new(%Author{name: "A"})
      assert_raise ArgumentError, ~r/refused/, fn -> Author.new!(born: 1) end
    end
  end

  describe "persistence" do
    test "encode → JSON → decode gives the same record" do
      record = book()
      encoded = Book.encode(record)
      assert {:ok, ^record} = encoded |> JSON.encode!() |> JSON.decode!() |> Book.decode()
    end

    test "encode is string-keyed and JSON-ready, with format_version, leaving out empty fields" do
      encoded = Book.encode(book())
      assert encoded["format_version"] == 2
      assert encoded["genre"] == "poetry"
      assert encoded["edition"] == %{"kind" => "paper", "pages" => 120, "hardcover" => false}
      assert encoded["shelved_at"] == "2026-01-02T03:04:05.123456Z"

      assert encoded["reviews"] == [%{"stars" => "three", "at" => "2026-01-02T03:04:05.123456Z"}]

      refute Map.has_key?(encoded, "archive_note")
      assert Enum.all?(Map.keys(encoded), &is_binary/1)
    end

    test "a datetime in another zone is kept in UTC, so the record round-trips" do
      plus_one = %DateTime{
        year: 2026,
        month: 1,
        day: 2,
        hour: 4,
        minute: 4,
        second: 5,
        microsecond: {123_456, 6},
        utc_offset: 3600,
        std_offset: 0,
        zone_abbr: "+01",
        time_zone: "Etc/GMT-1"
      }

      record = book(shelved_at: plus_one)
      assert record.shelved_at == @at
      assert Book.encode(record)["shelved_at"] == "2026-01-02T03:04:05.123456Z"

      assert {:ok, ^record} =
               record |> Book.encode() |> JSON.encode!() |> JSON.decode!() |> Book.decode()

      # Read from disk, an offset is shifted to UTC as well.
      encoded = %{Book.encode(record) | "shelved_at" => "2026-01-02T04:04:05.123456+01:00"}
      assert {:ok, %Book{shelved_at: @at}} = Book.decode(encoded)
    end

    test "encode raises on an invalid struct: it is never written" do
      assert_raise ArgumentError, ~r/book.genre/, fn -> Book.encode(%{book() | genre: :jazz}) end
      assert_raise ArgumentError, ~r/expected a/, fn -> Book.encode(%{book_id: "b"}) end
    end

    test "decode refuses another or no format version: never a silent migration" do
      encoded = Book.encode(book())
      assert {:error, {:format_version, 1}} = Book.decode(%{encoded | "format_version" => 1})
      assert {:error, {:format_version, "2"}} = Book.decode(%{encoded | "format_version" => "2"})
      assert {:error, {:format_version, nil}} = Book.decode(Map.delete(encoded, "format_version"))
    end

    test "decode refuses unknown and missing fields and wrong values" do
      encoded = Book.encode(book())

      assert {:error, {:unknown_field, "book.colour"}} =
               Book.decode(Map.put(encoded, "colour", 1))

      assert {:error, {:unknown_field, "book.authors[0].nick"}} =
               Book.decode(put_in(encoded, ["authors"], [%{"name" => "A", "nick" => "a"}]))

      assert {:error, {:missing_field, "book.title"}} = Book.decode(Map.delete(encoded, "title"))
      assert {:error, {:missing_field, "book.title"}} = Book.decode(%{encoded | "title" => nil})
      assert {:error, {:invalid, "book.genre", _}} = Book.decode(%{encoded | "genre" => "jazz"})

      assert {:error, {:missing_field, "book.edition.kind"}} =
               Book.decode(%{encoded | "edition" => %{"bytes" => 1}})

      assert {:error, {:invalid, "book.edition.kind", _}} =
               Book.decode(%{encoded | "edition" => %{"kind" => "scroll"}})

      assert {:error, {:unknown_field, "book.edition.pages"}} =
               Book.decode(%{
                 encoded
                 | "edition" => %{"kind" => "ebook", "bytes" => 1, "pages" => 2}
               })

      assert {:error, {:invalid, "book.shelved_at", _}} =
               Book.decode(%{encoded | "shelved_at" => "yesterday"})

      assert {:error, {:invalid, "book.title", "a string"}} =
               Book.decode(%{encoded | "title" => 1})

      assert {:error, {:invalid, "book", "an object"}} = Book.decode([])
      assert {:ok, %Book{archive_note: nil}} = Book.decode(Map.put(encoded, "archive_note", nil))
    end

    test "the path is filled from the record, and refuses what is no file name" do
      assert Book.path(book()) == "books/b-1.json"
      assert Book.path(%{book_id: "b-2"}) == "books/b-2.json"
      assert Book.format_version() == 2

      assert Book.persistence() == %{
               form: :json_file,
               path: "books/{book_id}.json",
               format_version: 2
             }

      for bad <- ["../x", "a/b", "", "..", nil] do
        assert_raise ArgumentError, ~r/no file name/, fn -> Book.path(%{book_id: bad}) end
      end
    end

    test "a collection: one file, one format version, the records under entries" do
      entries = [
        LoanEntry.new!(reader: "r", book_id: "b-1", returned: false, genre: :essay),
        LoanEntry.new!(reader: "s", book_id: "b-2", returned: true)
      ]

      file = LoanEntry.encode_file(entries)
      assert LoanEntry.path() == "books/loans.json"
      assert %{"format_version" => 1, "entries" => [first, _]} = file
      refute Map.has_key?(first, "format_version")
      assert {:ok, ^entries} = file |> JSON.encode!() |> JSON.decode!() |> LoanEntry.decode_file()
      assert {:ok, []} = LoanEntry.decode_file(LoanEntry.encode_file([]))

      assert {:error, {:format_version, 2}} =
               LoanEntry.decode_file(%{file | "format_version" => 2})

      assert {:error, {:format_version, nil}} = LoanEntry.decode_file(%{"entries" => []})

      assert {:error, {:unknown_field, "loan_entry.extra"}} =
               LoanEntry.decode_file(Map.put(file, "extra", 1))

      assert {:error, {:missing_field, "loan_entry.entries"}} =
               LoanEntry.decode_file(%{"format_version" => 1})

      assert {:error, {:unknown_field, "loan_entry[1].x"}} =
               LoanEntry.decode_file(%{file | "entries" => [hd(file["entries"]), %{"x" => 1}]})

      # An entry is only ever written inside its file, so it has no encode/decode or path/1.
      refute function_exported?(LoanEntry, :encode, 1)
      refute function_exported?(LoanEntry, :decode, 1)
      refute function_exported?(LoanEntry, :path, 1)
      refute function_exported?(Book, :encode_file, 1)
      refute function_exported?(Book, :path, 0)
    end
  end
end
