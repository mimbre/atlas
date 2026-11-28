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

  test "a pair retains its labelled value and syntax" do
    text = "# Heading"

    assert %{"label" => "Description", "value" => ^text, "syntax" => "markdown"} =
             Server.pair(label: "Description", value: text, syntax: "markdown")

    refute Map.has_key?(Server.pair(label: "Description", value: text), "syntax")
  end

  test "shared spec classifies text and identifies Markdown-capable fields" do
    schema = AtlasBFFContract.Contract.__schema__()
    field = fn entries, entry, name ->
      entries |> Enum.find(&(&1.name == entry)) |> Map.fetch!(:fields) |> Enum.find(&(&1.name == name))
    end

    assert %{intent: :title} = field.(schema.blocks, :header, :title)
    assert %{intent: :label} = field.(schema.models, :pair, :label)
    assert %{intent: :body, syntax: :markdown} = field.(schema.blocks, :text, :text)
    assert %{intent: :body, syntax: :markdown} = field.(schema.models, :pair, :value)
    assert %{intent: :body} = field.(schema.blocks, :list, :empty)
    assert %{intent: :body} = field.(schema.blocks, :header, :detail)
    assert %{intent: :label} = field.(schema.blocks, :form, :submit_label)
    assert %{intent: :body, type: {:list, :string}} = field.(schema.blocks, :form, :errors)
    assert %{intent: :body} = field.(schema.models, :action, :help)
    assert %{intent: :label} = field.(schema.models, :row, :kind)
    assert %{intent: :title} = field.(schema.markup, :section, :title)
    refute Map.has_key?(field.(schema.models, :action, :to), :intent)
    refute Map.has_key?(field.(schema.blocks, :header, :since), :intent)
    refute Map.has_key?(field.(schema.blocks, :text, :syntax), :intent)
  end
end
