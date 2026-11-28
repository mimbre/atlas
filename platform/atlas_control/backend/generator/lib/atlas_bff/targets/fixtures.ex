defmodule AtlasBFF.Targets.Fixtures do
  @moduledoc """
  Structural specimens derived only from the contract: required and full blocks and
  markup, plus typed wire request and reply examples (including boot/page when declared).
  Values exercise decoding; the schema cannot infer application semantics or state.
  """

  alias AtlasBFF.Samples
  alias AtlasBFF.Targets.Swift

  def files(schema, _opts \\ []) do
    ctx = Samples.context(schema)

    blocks = for block <- schema.blocks do
      %{"name" => to_string(block.name), "required" => Samples.block(block, ctx, :required), "full" => Samples.block(block, ctx, :full)}
    end

    markup = for kind <- schema.markup do
      %{"name" => to_string(kind.name), "required" => Samples.markup(kind, ctx, :required), "full" => Samples.markup(kind, ctx, :full)}
    end

    channels = for channel <- Swift.messages(schema) do
      %{
        "channel" => to_string(channel.channel),
        "requests" => Enum.map(channel.requests, &wire(&1, ctx)),
        "messages" => Enum.map(channel.messages, &wire(&1, ctx))
      }
    end

    body = %{"version" => schema.version, "blocks" => blocks, "markup" => markup, "channels" => channels}
    [{"fixtures.json", "{\n  \"fixtures\": " <> JSON.encode!(body) <> "\n}\n"}]
  end

  defp wire(message, ctx), do: %{"name" => message.case, "sample" => Samples.message(message, ctx)}
end
