defmodule AtlasControl.BlockGallery do
  @moduledoc "Read-only examples derived from the shared block contract."
  require AtlasControl.Blocks, as: Blocks

  @schema AtlasBFFContract.Contract.__schema__()
  @models Map.new(@schema.models, &{&1.name, &1.fields})
  @entries AtlasBFF.Targets.FixtureVariants.entries(@schema.blocks, @models)

  def render(:block_gallery) do
    rows =
      for entry <- @entries, entry["name"] != "console_action", variant <- ~w(required full) do
        name = entry["name"]

        Blocks.row(
          label: "#{name} — #{variant}",
          to: Blocks.path(:block_gallery_sample, name: name, variant: variant)
        )
      end

    page("Shared blocks", nil, [
      {"intro",
       Blocks.text(
         text:
           "Schema-derived examples; actions are illustrative and cannot submit changes. Console actions are protocol metadata, not visual content."
       )},
      {"samples", Blocks.list(title: "Examples", rows: rows)}
    ])
  end

  def render({:block_gallery_sample, name, variant}) do
    with true <- name != "console_action" and variant in ~w(required full),
         %{} = entry <- Enum.find(@entries, &(&1["name"] == name)),
         %{} = sample <- Enum.find(entry["variants"], &(&1["case"] == variant)) do
      {props, _} = safe(sample["props"], 0)
      block = %{"type" => name, "props" => props}
      page("#{name} — #{variant}", "/_blocks", [{"sample", block}])
    else
      _ ->
        page("Unknown example", "/_blocks", [
          {"error", Blocks.text(text: "No such block example.")}
        ])
    end
  end

  # Fixture actions must never lead to a product operation or an external URL.
  defp safe(value, n) when is_list(value), do: Enum.map_reduce(value, n, &safe/2)

  defp safe(value, n) when is_map(value) do
    {pairs, n} =
      Enum.map_reduce(value, n, fn
        {"key", _}, n ->
          {{"key", Integer.to_string(n)}, n + 1}

        {"to", _}, n ->
          {{"to", "/_blocks"}, n}

        {"url", _}, n ->
          {{"url", "https://example.invalid"}, n}

        {key, nested}, n ->
          {nested, n} = safe(nested, n)
          {{key, nested}, n}
      end)

    {Map.new(pairs), n}
  end

  defp safe(value, n), do: {value, n}

  defp page(title, back, blocks),
    do: Map.merge(%{title: title, back: back}, Blocks.view_model(blocks, []))
end
