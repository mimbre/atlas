defmodule AtlasRuntimeBoundary.Generator.Targets.BoundaryTranslationsTest do
  # The translations of the Boundary target (options mappings: and model:), over the
  # model schema fixture (FixtureModel) and the neutral Catalogue contract.
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.ContractError
  alias AtlasRuntimeBoundary.Generator.Catalogue.Boundary, as: B
  alias AtlasRuntimeBoundary.Generator.Catalogue.Desk
  alias AtlasRuntimeBoundary.Generator.FixtureModel, as: M

  @reader {"ann", [:browse]}

  describe "round trip: model entity -> from_model -> facade outcome" do
    test "gives the declared outcome struct, renamed, with the private fields absent" do
      assert %B.Outcome.Seen{} = seen = B.look(@reader, %{"id" => "c1"})

      assert seen == %B.Outcome.Seen{
               id: "c1",
               title: "Dune",
               condition: :"badly-worn",
               place: %B.Shelf{row: 3},
               due_at: nil,
               labels: [:audio],
               holds: [
                 %B.Hold{member: "bo", reason: :waitlist, placed_at: ~U[2026-01-02 03:04:05Z]}
               ],
               home: %B.Branch{city: "Delft"},
               status: :on_shelf,
               notes: nil
             }

      for private <- [:lent_count, :scan_path, :copy_id, :wear, :location],
          do: refute(Map.has_key?(seen, private), "#{private}")

      refute seen.holds |> hd() |> Map.has_key?(:desk_note)
      dumped = inspect(B.Outcome.Seen.dump(seen))
      refute dumped =~ "scans" or dumped =~ "asked twice" or dumped =~ "lent_count"
    end

    test "through a one-way mapping too" do
      assert B.look(@reader, %{id: "closed-c9"}) ==
               %B.Outcome.Closed{copy_id: "c9", wear: :"badly-worn"}
    end

    test "without as:, the mapped boundary model's struct" do
      assert {:ok, %B.Copy{id: "c2", status: :lent, notes: %{"shelf" => "top"}}} =
               B.from_model(Desk.copy("c2"), supply: [status: :lent, notes: %{"shelf" => "top"}])

      assert {:ok, %B.Shelf{row: 4}} = B.from_model(M.ShelfSpot.new!(row: 4))

      assert {:ok, %B.Branch{city: "Delft", open: nil}} =
               B.from_model(M.BranchSpot.new!(city: "Delft"))
    end
  end

  describe "from_model refuses" do
    test "a result that does not validate, naming where" do
      assert B.from_model(Desk.copy("c1")) == {:error, ["copy.status is required"]}

      copy = Desk.copy("c1")
      copy = %{copy | holds: [%{hd(copy.holds) | reason: "lost"}]}

      assert {:error, ["copy.holds[0].reason must be one of waitlist, reserve"]} =
               B.from_model(copy, supply: [status: :lent])

      entry = M.LedgerEntry.new!(member: "a", copy_id: "c", closed: false)
      assert {:error, ["closing.wear is required"]} = B.from_model(entry)
    end

    test "what the mapping does not declare, as a broken contract" do
      assert_raise ContractError,
                   ~r/supplies \[:status, :notes\], got supply: \[lent_count: 1\]/,
                   fn ->
                     B.from_model(Desk.copy("c1"), supply: [lent_count: 1])
                   end

      assert_raise ContractError,
                   ~r/as: :closed is no outcome carrying :copy \(\[:seen\]\)/,
                   fn ->
                     B.from_model(Desk.copy("c1"), as: :closed)
                   end

      assert_raise ContractError, ~r/the options are supply:, as:/, fn ->
        B.from_model(Desk.copy("c1"), state: :x)
      end

      assert_raise ContractError,
                   ~r/no mapping from %AtlasRuntimeBoundary.Generator.Catalogue.Boundary.Shelf/,
                   fn ->
                     B.from_model(%B.Shelf{row: 1})
                   end
    end
  end

  describe "to_model" do
    test "builds the model entity through the model's new/1" do
      {:ok, copy} = B.from_model(Desk.copy("c2"), supply: [status: :lent])

      # The model's own refusal: lent_count is dropped, so the boundary does not give it.
      assert B.to_model(copy) == {:error, {:missing_field, "copy_record.lent_count"}}

      assert {:ok, %M.CopyRecord{} = record} =
               B.to_model(copy, with: [lent_count: 7, scan_path: "/scans/c2.tiff"])

      # Every field back, renames and values reversed; only the nested private desk_note
      # is gone (a nested entity takes no with:).
      original = Desk.copy("c2")
      assert record == %{original | holds: Enum.map(original.holds, &%{&1 | desk_note: nil})}
      assert %M.ShelfSpot{row: 3} = record.location
      assert [%M.Hold{reason: "waitlist"}] = record.holds
    end

    test "takes a one_of member back by its model's name" do
      {:ok, copy} = B.from_model(Desk.copy("c2"), supply: [status: :lent])
      copy = %{copy | place: %B.Branch{city: "Delft", open: true}}

      assert {:ok, %M.CopyRecord{location: %M.BranchSpot{city: "Delft", open: true}}} =
               B.to_model(copy, with: [lent_count: 0])
    end

    test "refuses what is no mapping both ways, an invalid struct, or a with: it does not drop" do
      assert_raise ContractError,
                   ~r/no mapping both ways for %AtlasRuntimeBoundary.Generator.Catalogue.Boundary.Closing/,
                   fn ->
                     B.to_model(%B.Closing{copy_id: "c", wear: :new})
                   end

      assert_raise ContractError, ~r/invalid value: shelf.row must be an integer/, fn ->
        B.to_model(%B.Shelf{row: "3"})
      end

      assert_raise ContractError, ~r/with: takes the fields shelf does not give \(\[\]\)/, fn ->
        B.to_model(%B.Shelf{row: 3}, with: [row: 4])
      end
    end
  end

  test "a facade without mappings: and model: has no translations" do
    alias AtlasRuntimeBoundary.Generator.Example.Boundary, as: Plain
    Code.ensure_loaded!(Plain)
    refute function_exported?(Plain, :from_model, 1) or function_exported?(Plain, :to_model, 1)
  end

  describe "a mapping that does not fit fails compilation" do
    test "an unknown model entity, at the mapping's line" do
      assert_raise CompileError,
                   ~r/nofile:4: defmapping :shelf_spt -> :shelf: the model has no entity :shelf_spt/,
                   fn ->
                     facade("defmapping :shelf_spot, :shelf\ndefmapping :shelf_spt, :shelf")
                   end
    end

    test "an unknown model field" do
      assert_raise CompileError, ~r/model entity :shelf_spot has no field :rows/, fn ->
        facade("defmapping :shelf_spot, :shelf, drop: [:rows]")
      end

      assert_raise CompileError, ~r/model entity :shelf_spot has no field :rw/, fn ->
        facade("defmapping :shelf_spot, :shelf, rename: [rw: :row]")
      end

      assert_raise CompileError, ~r/model entity :ledger_entry has no field :wear/, fn ->
        facade(
          "defmapping :ledger_entry, :closing, direction: :from_model, rename: [last_wear: :wear], " <>
            "drop: [:member, :closed], values: [wear: [badly_worn: :\"badly-worn\"]]"
        )
      end
    end

    test "an unknown boundary model or field" do
      assert_raise CompileError, ~r/the contract has no model :shelve/, fn ->
        facade("defmapping :shelf_spot, :shelve")
      end

      assert_raise CompileError, ~r/boundary model :shelf has no field :rows/, fn ->
        facade("defmapping :shelf_spot, :shelf, rename: [row: :rows]")
      end

      assert_raise CompileError, ~r/boundary model :branch has no field :hours/, fn ->
        facade("defmapping :branch_spot, :branch, supply: [:hours]")
      end
    end

    test "a model field that is neither kept, renamed nor dropped" do
      assert_raise CompileError,
                   ~r/model field hold.desk_note has no field in :hold: rename it onto one, or drop it/,
                   fn -> facade("defmapping :hold, :hold") end
    end

    test "a boundary field that nothing gives, or that is given and supplied" do
      assert_raise CompileError,
                   ~r/boundary field closing.wear is given by no model field: rename one onto it, or supply it/,
                   fn ->
                     facade(
                       "defmapping :ledger_entry, :closing, direction: :from_model, drop: [:member, :closed, :last_wear]"
                     )
                   end

      assert_raise CompileError, ~r/shelf.row is given by a model field and supplied/, fn ->
        facade("defmapping :shelf_spot, :shelf, supply: [:row]")
      end
    end

    test "two model fields onto one boundary field (one kept, one renamed onto it)" do
      # Without the check, the last one wins at run time: the private scan_path would
      # overwrite the public title.
      assert_raise CompileError,
                   ~r/nofile:3: defmapping :copy_record -> :copy: boundary field copy.title is given by 2 model fields, copy_record.title and copy_record.scan_path/,
                   fn ->
                     facade(
                       "defmapping :copy_record, :copy, " <>
                         "rename: [copy_id: :id, wear: :condition, location: :place, scan_path: :title], " <>
                         "drop: [:lent_count], values: [wear: [badly_worn: :\"badly-worn\"]], " <>
                         "supply: [:status, :notes]" <>
                         "\ndefmapping :shelf_spot, :shelf\ndefmapping :branch_spot, :branch" <>
                         "\ndefmapping :hold, :hold, drop: [:desk_note]"
                     )
                   end
    end

    test "types that renaming cannot fit" do
      assert_raise CompileError,
                   ~r/shelf_spot.row -> closing.copy_id: a model :integer cannot become a boundary :string/,
                   fn ->
                     facade(
                       "defmapping :shelf_spot, :closing, rename: [row: :copy_id], supply: [:wear]"
                     )
                   end

      assert_raise CompileError, ~r/values: :row is no enum field mapped onto an enum/, fn ->
        facade("defmapping :shelf_spot, :shelf, values: [row: [a: :b]]")
      end
    end

    test "enum values the other side does not have" do
      assert_raise CompileError,
                   ~r/ledger_entry.last_wear -> closing.wear: model value :badly_worn is no boundary value; rename it with values:/,
                   fn ->
                     facade(
                       "defmapping :ledger_entry, :closing, direction: :from_model, rename: [last_wear: :wear], drop: [:member, :closed]"
                     )
                   end

      assert_raise CompileError, ~r/values: :mint is no value of/, fn ->
        facade(
          "defmapping :ledger_entry, :closing, direction: :from_model, rename: [last_wear: :wear], " <>
            "drop: [:member, :closed], values: [last_wear: [badly_worn: :\"badly-worn\", mint: :new]]"
        )
      end

      assert_raise CompileError,
                   ~r/boundary value :"badly-worn" is no model value; a mapping both ways needs one for each/,
                   fn ->
                     facade(
                       "defmapping :ledger_entry, :closing, rename: [last_wear: :wear], drop: [:member, :closed], " <>
                         "values: [last_wear: [badly_worn: :worn]]"
                     )
                   end
    end

    test "a held entity without a fitting mapping" do
      assert_raise CompileError,
                   ~r/copy_record.holds -> copy.holds: model entity :hold has no mapping \(defmapping :hold, :hold\)/,
                   fn ->
                     facade(
                       copy_mapping() <>
                         "\ndefmapping :shelf_spot, :shelf\ndefmapping :branch_spot, :branch"
                     )
                   end

      assert_raise CompileError,
                   ~r/copy_record.location -> copy.place: model entity :branch_spot is mapped to :closing, not to :shelf or :branch/,
                   fn ->
                     facade(
                       copy_mapping() <>
                         "\ndefmapping :shelf_spot, :shelf\ndefmapping :hold, :hold, drop: [:desk_note]" <>
                         "\ndefmapping :branch_spot, :closing, rename: [city: :copy_id], drop: [:open], supply: [:wear]"
                     )
                   end

      assert_raise CompileError,
                   ~r/the mapping of :hold is one way \(direction: :from_model\), so this one cannot go both ways/,
                   fn ->
                     facade(
                       copy_mapping() <>
                         "\ndefmapping :shelf_spot, :shelf\ndefmapping :branch_spot, :branch" <>
                         "\ndefmapping :hold, :hold, direction: :from_model, drop: [:desk_note]"
                     )
                   end
    end

    test "a required field supplied in an entity held by another" do
      assert_raise CompileError,
                   ~r/the required field hold.reason is supplied, but copy_record holds hold/,
                   fn ->
                     facade(
                       copy_mapping() <>
                         "\ndefmapping :shelf_spot, :shelf\ndefmapping :branch_spot, :branch" <>
                         "\ndefmapping :hold, :hold, drop: [:reason, :desk_note], supply: [:reason]"
                     )
                   end
    end

    test "options that do not go together, or a model without the schema" do
      assert_raise CompileError, ~r/optionally mappings: and model: together/, fn ->
        Code.compile_string("""
        defmodule HalfFacade do
          use AtlasRuntimeBoundary.Generator.Targets.Boundary,
            contract: AtlasRuntimeBoundary.Generator.Catalogue,
            implementation: Nobody,
            mappings: AtlasRuntimeBoundary.Generator.CatalogueMappings
        end
        """)
      end

      assert_raise CompileError,
                   ~r/model: NoSchemaModel is no compiled model with __schema__\/0/,
                   fn ->
                     Code.compile_string("""
                     defmodule NoSchemaModel do
                     end

                     defmodule NoSchemaFacade do
                       use AtlasRuntimeBoundary.Generator.Targets.Boundary,
                         contract: AtlasRuntimeBoundary.Generator.Catalogue,
                         implementation: Nobody,
                         mappings: AtlasRuntimeBoundary.Generator.CatalogueMappings,
                         model: NoSchemaModel
                     end
                     """)
                   end

      assert_raise CompileError, ~r/mappings: NoMappings is no compiled mappings module/, fn ->
        Code.compile_string("""
        defmodule NoMappingsFacade do
          use AtlasRuntimeBoundary.Generator.Targets.Boundary,
            contract: AtlasRuntimeBoundary.Generator.Catalogue,
            implementation: Nobody,
            mappings: NoMappings,
            model: AtlasRuntimeBoundary.Generator.FixtureModel
        end
        """)
      end
    end
  end

  describe "a :stream field" do
    test "is supplied, and from_model passes it on unconsumed" do
      facade = stream_facade("supply: [:content]")
      lazy = Stream.map(["a"], fn chunk -> send(self(), :enumerated) && chunk end)
      scan = Module.concat(facade, Scan)

      assert {:ok, %{__struct__: ^scan, row: 4, content: ^lazy}} =
               facade.from_model(M.ShelfSpot.new!(row: 4), supply: [content: lazy])

      refute_received :enumerated
    end

    test "takes no model field" do
      assert_raise CompileError,
                   ~r/shelf_spot.row -> scan.content: a boundary :stream takes no model field; supply it/,
                   fn -> stream_facade("rename: [row: :content], supply: [:row]") end
    end
  end

  defp stream_facade(options) do
    n = System.unique_integer([:positive])

    Code.compile_string("""
    defmodule StreamContract#{n} do
      use AtlasRuntimeBoundary.Generator.Schema
      version "0"
      defmodel :scan do
        field :row, :integer, required: true
        field :content, :stream, required: true
      end
      defcapability :get, outcomes: [got: :scan], right: :r
    end

    defmodule StreamMappings#{n} do
      use AtlasRuntimeBoundary.Generator.Mappings
      defmapping :shelf_spot, :scan, direction: :from_model, #{options}
    end

    defmodule StreamFacade#{n} do
      use AtlasRuntimeBoundary.Generator.Targets.Boundary,
        contract: StreamContract#{n},
        implementation: StreamDesk#{n},
        mappings: StreamMappings#{n},
        model: AtlasRuntimeBoundary.Generator.FixtureModel
    end

    defmodule StreamDesk#{n} do
      use StreamFacade#{n}.Implementation
      @impl true
      def get(_client), do: %StreamFacade#{n}.Outcome.Got{row: 1, content: []}
    end
    """)

    Module.concat([:"StreamFacade#{n}"])
  end

  defp copy_mapping,
    do: """
    defmapping :copy_record, :copy,
      rename: [copy_id: :id, wear: :condition, location: :place],
      drop: [:lent_count, :scan_path],
      values: [wear: [badly_worn: :"badly-worn"]],
      supply: [:status, :notes]
    """

  defp facade(mappings) do
    n = System.unique_integer([:positive])

    Code.compile_string("""
    defmodule Mappings#{n} do
      use AtlasRuntimeBoundary.Generator.Mappings
    #{mappings}
    end

    defmodule Facade#{n} do
      use AtlasRuntimeBoundary.Generator.Targets.Boundary,
        contract: AtlasRuntimeBoundary.Generator.Catalogue,
        implementation: Nobody,
        mappings: Mappings#{n},
        model: AtlasRuntimeBoundary.Generator.FixtureModel
    end
    """)
  end
end
