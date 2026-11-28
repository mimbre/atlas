defmodule AtlasBFFContract.TextFormatTest.Server do
  use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract
end

defmodule AtlasBFFContract.TextFormatTest do
  use ExUnit.Case, async: true
  require AtlasBFFContract.TextFormatTest.Server, as: Server

  test "text syntax is optional and passed through without changing text" do
    text = "# Heading\n\n```\ncode\n```"

    assert %{"type" => "text", "props" => %{"text" => ^text}} = Server.text(text: text)
    refute Map.has_key?(Server.text(text: text)["props"], "syntax")

    for syntax <- ["markdown", "future-syntax"] do
      assert %{"props" => %{"text" => ^text, "syntax" => ^syntax}} =
               Server.text(text: text, syntax: syntax)
    end
  end

  test "a syntaxted pair retains its labelled value for older clients" do
    text = "# Heading"

    assert %{"label" => "Description", "value" => ^text, "syntax" => "markdown"} =
             Server.pair(label: "Description", value: text, syntax: "markdown")

    refute Map.has_key?(Server.pair(label: "Description", value: text), "syntax")
  end
end
