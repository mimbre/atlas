defmodule AtlasBFFContract.TextFormatTest do
  use ExUnit.Case, async: true

  defmodule Server do
    use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract
  end

  require Server

  test "text format is optional and passed through without changing text" do
    text = "# Heading\n\n```\ncode\n```"

    assert %{"type" => "text", "props" => %{"text" => ^text}} = Server.text(text: text)
    refute Map.has_key?(Server.text(text: text)["props"], "format")

    for format <- ["markdown", "future-format"] do
      assert %{"props" => %{"text" => ^text, "format" => ^format}} =
               Server.text(text: text, format: format)
    end
  end
end
