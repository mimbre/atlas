defmodule AtlasFlowBoundary.Generator.Targets.BoundaryRangeTest do
  @moduledoc """
  `range: min..max` on an integer field (design §1.3, S2): `new/1` and `validate/1` refuse
  a value outside it, the facade answers that as an invalid input without calling the
  implementation, nothing is clamped, and the JSON target names the range.
  """
  use ExUnit.Case, async: true

  alias AtlasFlowBoundary.Generator.{InvalidInput, Targets.Json}

  Code.compile_string("""
  defmodule AtlasFlowBoundary.Generator.RangeExample do
    use AtlasFlowBoundary.Generator.Schema
    version "1.0.0"

    defmodel :page_input do
      field :limit, :integer, range: 1..100
      field :offset, :integer
    end

    defmodel :page do
      field :size, :integer, required: true
    end

    defcapability :page, input: :page_input, outcomes: [page: :page], right: :read
  end

  defmodule AtlasFlowBoundary.Generator.RangeExample.Facade do
    use AtlasFlowBoundary.Generator.Targets.Boundary,
      contract: AtlasFlowBoundary.Generator.RangeExample,
      implementation: AtlasFlowBoundary.Generator.RangeExample.Implementation
  end

  defmodule AtlasFlowBoundary.Generator.RangeExample.Implementation do
    use AtlasFlowBoundary.Generator.RangeExample.Facade.Implementation
    alias AtlasFlowBoundary.Generator.RangeExample.Facade, as: F

    def page(_client, %F.PageInput{} = input) do
      send(self(), {:implementation, input})
      %F.Outcome.Page{size: input.limit || 0}
    end
  end
  """)

  alias AtlasFlowBoundary.Generator.RangeExample, as: Contract
  alias AtlasFlowBoundary.Generator.RangeExample.Facade, as: F

  @client {"c", [:read]}

  test "new/1 takes the bounds and anything between, and refuses a value outside" do
    for limit <- [1, 50, 100, nil],
        do: assert({:ok, %F.PageInput{limit: ^limit}} = F.PageInput.new(%{"limit" => limit}))

    for limit <- [0, 101, -1] do
      assert {:error, [reason]} = F.PageInput.new(%{"limit" => limit})
      assert reason == "page_input.limit must be in 1..100, got #{limit}"
    end

    assert {:error, [reason]} = F.PageInput.new(%{"limit" => "ten"})
    assert reason =~ "must be an integer in 1..100"
    # A field without range: is unbounded.
    assert {:ok, %F.PageInput{offset: 1_000_000}} = F.PageInput.new(%{"offset" => 1_000_000})
  end

  test "validate/1 refuses a built struct out of range" do
    assert F.PageInput.validate(%F.PageInput{limit: 100}) == :ok
    assert {:error, [_]} = F.PageInput.validate(%F.PageInput{limit: 101})
  end

  test "the facade refuses out of range without calling the implementation; nothing is clamped" do
    for input <- [%{"limit" => 0}, %{"limit" => 101}, %F.PageInput{limit: 101}] do
      assert %InvalidInput{capability: :page, reasons: [reason]} = F.page(@client, input)
      assert reason =~ "must be in 1..100"
      refute_received {:implementation, _}
    end

    assert %F.Outcome.Page{size: 100} = F.page(@client, %{"limit" => 100})
    assert_received {:implementation, %F.PageInput{limit: 100}}
  end

  test "the JSON target names the range" do
    [{_, body}] = Json.files(Contract.__schema__(), name: "range")

    input =
      body |> JSON.decode!() |> Map.fetch!("models") |> Enum.find(&(&1["name"] == "page_input"))

    fields = Map.new(input["fields"], &{&1["name"], &1})

    assert fields["limit"] == %{
             "name" => "limit",
             "type" => "integer",
             "required" => false,
             "range" => %{"min" => 1, "max" => 100}
           }

    refute Map.has_key?(fields["offset"], "range")
  end
end
