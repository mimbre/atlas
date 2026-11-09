defmodule AtlasBFFContract.PageFreshnessTest do
  @moduledoc """
  Contract 0.15.0 (docs/design/page-freshness.md §3): a row names the fact it opens
  (`key`) and may be marked `pending`; Control pushes pages for recently viewed paths
  (`hint`) and marker overlays (`pending`).
  """
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Session.Protocol, as: Session

  @page %{
    "op" => "page",
    "path" => "/k/widget",
    "title" => "Widgets",
    "blocks" => [],
    "markup" => [],
    "position" => 7
  }

  test "the contract, its models and its session wire are 0.15.0" do
    assert AtlasBFFContract.Contract.__schema__().version == "0.15.0"
    assert AtlasBFFContract.Models.Presentation.__schema__().version == "0.15.0"
    assert Session.version() == "0.15.0"
  end

  test "a row may carry an opaque key and a pending flag, both optional" do
    row = %{label: "One", to: "/k/widget/W-1"}

    assert Session.model(:row, row) == %{"label" => "One", "to" => "/k/widget/W-1"}

    assert Session.model(:row, Map.merge(row, %{key: "W-1", pending: true})) ==
             %{"label" => "One", "to" => "/k/widget/W-1", "key" => "W-1", "pending" => true}

    assert_raise ArgumentError, fn -> Session.model(:row, Map.put(row, :pending, "yes")) end
    assert_raise ArgumentError, fn -> Session.model(:row, Map.put(row, :key, 1)) end
  end

  test "an unasked page is a hint, whatever path it is for" do
    for path <- ["/k/widget", "/k/widget/W-1"] do
      message = Map.merge(@page, %{"reason" => "hint", "path" => path})
      assert {:ok, :hint, ^message} = Session.decode_event(message)
    end
  end

  test "a marker overlay is a push of its own, which never completes an open" do
    message = Map.put(@page, "reason", "pending")
    assert {:ok, :pending, ^message} = Session.decode_event(message)
    assert {:reply, %{name: :page, effect: :progress}} = Session.classify(:open, message)

    assert {:reply, %{effect: :complete}} =
             Session.classify(:open, Map.put(message, "reason", "open"))
  end

  test "both pushes are endpoints of the contract" do
    endpoints = AtlasBFFContract.Contract.__schema__().endpoints

    for name <- [:hint, :pending] do
      assert %{call: :page, wire: ^name} = Enum.find(endpoints, &(&1.name == name))
    end
  end
end
