defmodule AtlasTui.Legend do
  @moduledoc "Modal legend state over the existing BFF action objects; never owns a key table."
  alias AtlasTui.{Interactions, LegendView}

  def open(%{console: %{legend: nil}} = model) do
    if closer(model) do
      %{
        model
        | console: %{
            model.console
            | legend: %{scroll: 0},
              generation: model.console.generation + 1
          }
      }
    else
      %{model | notice: %{tone: "error", text: "Keys are unavailable for this view."}}
    end
  end

  def open(model), do: model

  def close(%{console: %{legend: nil}} = model), do: model

  def close(model),
    do: %{
      model
      | console: %{model.console | legend: nil, generation: model.console.generation + 1}
    }

  # Recheck against the installed content and restored row/focus, not the old page.
  # Availability/scope may remove the final escape route from a valid projection.
  def reconcile(%{console: %{legend: nil}} = model), do: model
  def reconcile(model), do: if(closer(model), do: model, else: close(model))

  def groups(model) do
    source = Interactions.content_context(model)
    projection = model.console.projection
    active = Interactions.active_for(model, source) ++ Interactions.active_for(model, "legend")
    by_id = Map.new(active, &{&1["id"], &1})

    if projection do
      for group <- projection.groups,
          group["props"]["context"] in [source, "legend"],
          actions =
            for(
              id <- range(projection.ids, group["start"], group["end"]),
              Map.has_key?(by_id, id),
              do: by_id[id]
            ),
          actions != [],
          do: %{markup: group, actions: actions}
    else
      []
    end
  end

  def title(model) do
    case opener(model) do
      nil ->
        case groups(model) do
          [%{markup: group} | _] -> group["props"]["title"]
          [] -> ""
        end

      action ->
        action["props"]["label"]
    end
  end

  def opener(model) do
    Enum.find(Interactions.active_for(model, Interactions.content_context(model)), fn action ->
      action["props"]["available"] && action["props"]["operation"]["name"] == "legend_open"
    end)
  end

  def closer(model) do
    Enum.find(Interactions.active_for(model, "legend"), fn action ->
      action["props"]["available"] && action["props"]["operation"]["name"] == "legend_close"
    end)
  end

  def scroll(model, by) do
    {width, height} = model.console.viewport
    geometry = LegendView.geometry(model, width, max(height - 7, 1))
    offset = (model.console.legend.scroll + by) |> max(0) |> min(geometry.max_scroll)
    %{model | console: %{model.console | legend: %{scroll: offset}}}
  end

  def page(model, direction) do
    {width, height} = model.console.viewport
    geometry = LegendView.geometry(model, width, max(height - 7, 1))
    scroll(model, direction * max(geometry.room - 1, 1))
  end

  def resize(model, width, height) do
    model = %{model | console: %{model.console | viewport: {width, height}}}
    if model.console.legend, do: scroll(model, 0), else: model
  end

  defp range(ids, first, last) do
    with from when is_integer(from) <- Enum.find_index(ids, &(&1 == first)),
         to when is_integer(to) <- Enum.find_index(ids, &(&1 == last)) do
      Enum.slice(ids, from..to)
    else
      _ -> []
    end
  end
end
