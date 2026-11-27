defmodule AtlasBFFContract.TextFormatTest.Server do
  use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract
end

defmodule AtlasBFFContract.TextFormatTest do
  use ExUnit.Case, async: true
  require AtlasBFFContract.TextFormatTest.Server, as: Server

  test "text format is optional and passed through without changing text" do
    text = "# Heading\n\n```\ncode\n```"

    assert %{"type" => "text", "props" => %{"text" => ^text}} = Server.text(text: text)
    refute Map.has_key?(Server.text(text: text)["props"], "format")

    for format <- ["markdown", "future-format"] do
      assert %{"props" => %{"text" => ^text, "format" => ^format}} =
               Server.text(text: text, format: format)
    end
  end

  test "a formatted pair retains its labelled value for older clients" do
    text = "# Heading"

    assert %{"label" => "Description", "value" => ^text, "format" => "markdown"} =
             Server.pair(label: "Description", value: text, format: "markdown")

    refute Map.has_key?(Server.pair(label: "Description", value: text), "format")
  end
end
