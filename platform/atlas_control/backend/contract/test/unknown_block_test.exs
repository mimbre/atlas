defmodule AtlasBFFContract.UnknownBlockTest.Server do
  use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract
end

defmodule AtlasBFFContract.UnknownBlockTest do
  use ExUnit.Case, async: true
  require AtlasBFFContract.UnknownBlockTest.Server, as: Server

  test "unknown is a real block with optional plain content" do
    assert %{"type" => "unknown", "props" => %{}} = Server.unknown([])

    assert %{"type" => "unknown", "props" => %{"title" => "Example", "text" => "First", "lines" => ["Second", "Third"]}} =
             Server.unknown(title: "Example", text: "First", lines: ["Second", "Third"])
  end
end
