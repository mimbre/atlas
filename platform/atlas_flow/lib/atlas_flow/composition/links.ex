defmodule AtlasFlow.Composition.Links do
  @moduledoc """
  A link of the model's composition (`AtlasFlow.Model.composition/0`, version 1): when
  the run of a child subflow reaches one of the link's `states`, its value goes to
  `field` on the parent the child relates to by `relation`. Pure: the caller reads the
  parent, its children and their latest runs.

  Which child may write is explicit, never a matter of time:

    * with `current: %{"child" => cf, "parent" => pf}`, a child is current when its `cf`
      equals the parent's `pf` (a revision or fingerprint); a parent without `pf` is not
      ready;
    * without it, every child related to the parent is current.

  More than one current child is ambiguous: nothing is written until only one is. A
  child that is not current (replaced, removed or moved to another parent) writes
  nothing, however late its run completes. Each completion is one source: the child's
  key, its run's key and entry and the identity it was current by; a source the parent
  already applied is not applied again.
  """

  @version 1

  @doc "The composition version these links follow."
  def version, do: @version

  @doc """
  Whether a runner can apply `link`: `:ok`, or `{:error, why}`. `stale: drop` needs
  `current`, since without it nothing says which child is the current one.
  """
  def valid?(%{"stale" => "drop"} = link) when not is_map_key(link, "current"),
    do: {:error, :stale_without_current}

  def valid?(%{"stale" => "drop", "current" => nil}), do: {:error, :stale_without_current}

  def valid?(%{"field" => f, "states" => %{} = states, "relation" => r} = link)
      when is_binary(f) and is_binary(r) and map_size(states) > 0 do
    case link["current"] do
      nil -> :ok
      %{"child" => c, "parent" => p} when is_binary(c) and is_binary(p) -> :ok
      _ -> {:error, :invalid_current}
    end
  end

  def valid?(_link), do: {:error, :invalid_link}

  @doc """
  What `link` writes to `parent` (`%{"key", "values"}`), given its `children` (the facts
  related to it by the link's relation) and `runs` (each child's latest run of the
  link's subflow, by child key; missing when it has none), with `applied` the source the
  parent applied last for this field (or nil):

    * `:none`: no current child;
    * `:waiting`: the parent has no identity to compare yet, or the current child's run
      is not in one of the link's states;
    * `{:refused, :ambiguous, keys}`: more than one current child;
    * `{:applied, source}`: the current child's completion was applied already;
    * `{:write, value, source}`: a new completion of the current child.
  """
  def select(link, parent, children, runs, applied) do
    case current(link, parent, children) do
      :waiting ->
        :waiting

      [] ->
        :none

      [child] ->
        run = runs[child["key"]]
        state = run && run["state"]

        if run != nil and run["flow"] == link["child"] and Map.has_key?(link["states"], state) do
          source = %{
            "child" => child["key"],
            "run" => run["key"],
            "entry" => run["entry"],
            "state" => state,
            "current" => identity(link, child)
          }

          if applied == source,
            do: {:applied, source},
            else: {:write, link["states"][state], source}
        else
          :waiting
        end

      many ->
        {:refused, :ambiguous, Enum.sort(Enum.map(many, & &1["key"]))}
    end
  end

  @doc "The children of `parent` that are current for `link`, or `:waiting`."
  def current(%{"current" => %{"child" => cf, "parent" => pf}}, parent, children) do
    case (parent["values"] || %{})[pf] do
      nil -> :waiting
      "" -> :waiting
      value -> Enum.filter(children, &((&1["values"] || %{})[cf] == value))
    end
  end

  def current(_link, _parent, children), do: children

  defp identity(%{"current" => %{"child" => cf}}, child), do: (child["values"] || %{})[cf]
  defp identity(_link, _child), do: nil
end
