defmodule AtlasControl.Freshness.RowKeyTest do
  use ExUnit.Case, async: true

  alias AtlasControl.Freshness.RowKey

  test "a row that opens a fact gets that fact's key, from its path" do
    for {to, key} <- [
          {"/k/widget/W-1", "W-1"},
          {"/k/_/W-2", "W-2"},
          {"/k/widget", nil},
          {"/k/widget/W-1/edit", nil},
          {"/k/part/new/of_widget/W-1", nil},
          {"/", nil},
          {"/no/such/page", nil},
          {nil, nil}
        ],
        do: assert(RowKey.of(to) == key, "#{inspect(to)}")
  end

  test "every list's rows are keyed; other blocks and props stay as they are" do
    blocks = [
      %{"id" => "a", "type" => "item", "props" => %{"title" => "W-1"}},
      %{
        "id" => "b",
        "type" => "list",
        "props" => %{
          "title" => "Parts",
          "rows" => [
            %{"label" => "One", "to" => "/k/part/P-1", "pending" => true},
            %{"label" => "Parts", "to" => "/k/part"}
          ]
        }
      }
    ]

    assert [item, %{"props" => %{"title" => "Parts", "rows" => rows}}] = RowKey.put(blocks)
    assert item == hd(blocks)

    assert rows == [
             %{"label" => "One", "to" => "/k/part/P-1", "key" => "P-1", "pending" => true},
             %{"label" => "Parts", "to" => "/k/part"}
           ]
  end
end
