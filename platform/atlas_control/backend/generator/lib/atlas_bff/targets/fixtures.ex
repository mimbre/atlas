defmodule AtlasBFF.Targets.Fixtures do
  @moduledoc """
  Deterministic, bounded structural specimens derived from the contract. Values
  exercise decoding; the schema cannot infer application semantics or state.
  """

  alias AtlasBFF.Samples
  alias AtlasBFF.Targets.FixtureVariants
  alias AtlasBFF.Targets.Swift

  def files(schema, _opts \\ []) do
    ctx = Samples.context(schema)

    models = Map.new(schema.models, &{&1.name, &1.fields})
    blocks = FixtureVariants.entries(schema.blocks, models) |> wrap("block")
    markup = FixtureVariants.entries(schema.markup, models) |> wrap("markup")
    model_examples = FixtureVariants.entries(schema.models, models)

    channels =
      for channel <- Swift.messages(schema) do
        %{
          "channel" => to_string(channel.channel),
          "requests" => Enum.map(channel.requests, &wire(&1, ctx)),
          "messages" => Enum.map(channel.messages, &wire(&1, ctx))
        }
      end

    body = %{
      "version" => schema.version,
      "blocks" => blocks,
      "markup" => markup,
      "models" => model_examples,
      "channels" => channels
    }

    [{"fixtures.json", AtlasBFF.Targets.Json.pretty(%{"fixtures" => body})}]
  end

  defp wrap(entries, type) do
    Enum.map(entries, fn entry ->
      variants =
        Enum.map(entry["variants"], fn variant ->
          sample =
            case type do
              "block" ->
                %{"id" => "b1", "type" => entry["name"], "props" => variant["props"]}

              "markup" ->
                %{
                  "kind" => entry["name"],
                  "start" => "b1",
                  "end" => "b1",
                  "props" => variant["props"]
                }
            end

          variant |> Map.delete("props") |> Map.put("sample", sample)
        end)

      Map.put(entry, "variants", variants)
    end)
  end

  defp wire(message, ctx),
    do: %{"name" => message.case, "sample" => Samples.message(message, ctx)}
end
