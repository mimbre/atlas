defmodule AtlasBFF.Samples do
  @moduledoc """
  Deterministic structural samples of contract fields. The schema gives types, not
  domain semantics; these values are for exercising decoders, not business examples.
  """

  @depth 3

  def context(schema) do
    %{
      models: Map.new(schema.models, &{&1.name, &1.fields}),
      blocks: schema.blocks,
      markup: schema.markup
    }
  end

  def block(block, ctx, which),
    do: %{"id" => "b1", "type" => to_string(block.name), "props" => fields(block.fields, ctx, which, 0)}

  def markup(kind, ctx, which),
    do: %{"kind" => to_string(kind.name), "start" => "b1", "end" => "b1", "props" => fields(kind.fields, ctx, which, 0)}

  def message(message, ctx) do
    message.fields
    |> Enum.map(&{&1.name, sample(&1.type, &1.name, ctx, :full, 0)})
    |> Map.new()
    |> Map.merge(Map.new(message.literals))
  end

  def fields(fields, ctx, which, depth) do
    for f <- fields, f.required or (which == :full and depth < @depth), into: %{} do
      {to_string(f.name), sample(f.type, f.name, ctx, which, depth + 1)}
    end
  end

  def sample(:string, name, _ctx, _which, _depth), do: "#{name} 1"
  def sample(:integer, _name, _ctx, _which, _depth), do: 7
  def sample(:boolean, _name, _ctx, _which, _depth), do: true
  def sample(:map, _name, _ctx, _which, _depth), do: %{}
  def sample(:list, _name, _ctx, _which, _depth), do: []
  def sample({:map, inner}, name, ctx, which, depth), do: %{"k" => sample(inner, name, ctx, which, depth)}
  def sample({:list, inner}, name, ctx, which, depth), do: if(depth > @depth, do: [], else: [sample(inner, name, ctx, which, depth)])
  def sample(:"$block", _name, %{blocks: [block | _]} = ctx, _which, _depth), do: block(block, ctx, :required)
  def sample(:"$markup", _name, %{markup: [kind | _]} = ctx, _which, _depth), do: markup(kind, ctx, :required)
  def sample(model, _name, ctx, which, depth) when is_atom(model), do: fields(Map.fetch!(ctx.models, model), ctx, which, depth)
end
