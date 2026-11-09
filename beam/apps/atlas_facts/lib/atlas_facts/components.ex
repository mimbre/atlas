defmodule AtlasFacts.Components do
  @moduledoc """
  The facts made and deleted with a fact (d-0022: every assignable thing has an
  Assignment). A relation marked `component` in the description (`rela/atlas.json`) points
  from a fact at one fact of its own, which Facts creates in the same write, before the
  fact, and deletes with it: `"component": {"key": "AS-{key}", "values": {"of": "{key}"}}`,
  where `{key}` is the fact's key. Knows no kind by name.
  """

  @doc """
  The components of a fact of `kind` with `key`: `[{relation, kind, key, values}]`, one per
  marked relation that starts at `kind`.
  """
  def of(description, kind, key) do
    for {relation, %{"component" => %{"key" => template} = component} = spec} <-
          Enum.sort((description || %{})["relations"] || %{}),
        kind in (spec["from"] || []),
        [to] <- [spec["to"]] do
      values = Map.new(component["values"] || %{}, fn {name, text} -> {name, fill(text, key)} end)
      {relation, to, fill(template, key), values}
    end
  end

  @doc """
  The fact a component of `kind` with `key` belongs to, as `{relation, owner kinds}` per
  marked relation that points at `kind`. Empty when `kind` is no component.
  """
  def owners(description, kind) do
    for {relation, %{"component" => %{}, "to" => [^kind]} = spec} <-
          Enum.sort((description || %{})["relations"] || %{}),
        do: {relation, spec["from"] || []}
  end

  @doc "The relations marked `component`."
  def relations(description) do
    for {relation, %{"component" => %{}}} <- (description || %{})["relations"] || %{},
        do: relation
  end

  defp fill(text, key) when is_binary(text), do: String.replace(text, "{key}", key)
  defp fill(value, _key), do: value
end
