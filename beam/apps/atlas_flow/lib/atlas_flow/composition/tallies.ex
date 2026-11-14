defmodule AtlasFlow.Composition.Tallies do
  @moduledoc """
  A tally of the model's composition (`AtlasFlow.Model.composition/0`, version 1): the
  parent's `all`, how many facts relate to it by `relation`, of every kind the relation
  starts at (`from`, as the model's relations give it), whether a subflow runs on them or
  not. Only the runs of its `readers` (the subflows on the parent that read `all`) are
  given it. Pure, and always worked out again from those facts as they are now, so a deleted
  or moved one, or a hint that was lost, is tallied right on the next look.
  """

  @doc "Whether a runner can apply `tally`: `:ok`, or `{:error, why}`."
  def valid?(%{"all" => a, "relation" => r, "from" => [_ | _] = from, "readers" => [_ | _] = rs})
      when is_binary(a) and is_binary(r),
      do: if(Enum.all?(from ++ rs, &is_binary/1), do: :ok, else: {:error, :invalid_tally})

  def valid?(_tally), do: {:error, :invalid_tally}

  @doc """
  `tally` (`%{"parent_subject", "relation", "all", "readers"}`) with the kinds its relation starts
  at in `relations` (the model's), as a runner applies it.
  """
  def resolve(tally, relations),
    do: Map.put(tally, "from", get_in(relations, [tally["relation"], "from"]) || [])

  @doc "The values of `tally` for `facts` (every fact related to the parent): `%{all => n}`."
  def values(tally, facts),
    do: %{tally["all"] => length(Enum.uniq_by(facts, &{&1["kind"], &1["key"]}))}
end
