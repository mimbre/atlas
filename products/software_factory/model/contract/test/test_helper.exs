# Tests tagged :rela run the pinned rela; they run only when ATLAS_RELA_BIN names its folder.
# A bare assert_receive waits up to 30 s for its message (bin/lib/test_waits.rb), not 100 ms.
ExUnit.start(
  assert_receive_timeout: 30_000,
  exclude: if(System.get_env("ATLAS_RELA_BIN") in [nil, ""], do: [:rela], else: [])
)

# Gates and Flow run the model they are wired to: here, the one under test.
Application.put_env(:atlas, :model, Model.AtlasEyra)

# Flow told of Code's receiver of integrate effects, as the core's runtime.exs tells it.
Application.put_env(:atlas_flow, :effect_receivers, %{
  "code" => %{
    "contract" => 1,
    "address" => "code/effects",
    "operations" => ["integrate", "publish"]
  }
})

defmodule Model.Offered do
  @moduledoc """
  What a page Control serves offers: every action and answer in its blocks (a map with a
  `label` and a `to`, under `actions`, `answers` or an option's `answer`).
  """
  def all(%{} = map) do
    own = if is_binary(map["label"]) and is_binary(map["to"]), do: [map], else: []

    own ++
      Enum.flat_map(map, fn
        {k, v} when k in ["actions", "answers", "answer", "props"] -> all(v)
        _ -> []
      end)
  end

  def all(list) when is_list(list), do: Enum.flat_map(list, &all/1)
  def all(_), do: []

  @doc """
  The ones that do not explain themselves: no `help`, or only their label again (the
  model words its own, Control the rest).
  """
  def unexplained(blocks),
    do:
      for(
        o <- all(blocks),
        not is_binary(o["help"]) or String.trim(o["help"]) in ["", o["label"]],
        do: o
      )
end
