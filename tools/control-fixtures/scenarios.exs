defmodule ControlFixtures.Scenarios do
  @moduledoc false

  def tabs do
    [
      {"decision", "Decisions", "/k/decision"},
      {"scene", "Scenes", "/k/scene"},
      {"todo", "To-Dos", "/k/to_do"},
      {"lists", "Open work", "/_open"},
      {"empty", "Issues", "/k/issue"}
    ]
    |> Enum.map(fn {id, label, to} ->
      %{"id" => id, "label" => label, "to" => to, "section" => "work"}
    end)
  end

  def initial("decision"), do: "/k/decision/D-7"
  def initial("scene"), do: "/k/scene/SC-1"
  def initial("todo"), do: "/k/to_do/TD-12"
  def initial("lists"), do: "/_open"
  def initial("empty"), do: "/k/issue"

  def tab_for(path) do
    Enum.find(tabs(), fn tab ->
      path == tab["to"] or
        (String.starts_with?(tab["to"], "/k/") and String.starts_with?(path, tab["to"] <> "/"))
    end)
  end

  def page(path), do: :persistent_term.get({__MODULE__, :pages})[path]
end
