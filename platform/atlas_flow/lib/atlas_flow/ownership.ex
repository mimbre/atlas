defmodule AtlasFlow.Ownership do
  @moduledoc "Preserve an assignee of the declared kind, otherwise use the state default."

  def resolve(current, owners, read) do
    case {current["preserve_kind"], owners} do
      {kind, [key]} when is_binary(kind) ->
        case read.(kind, key) do
          %{"fact" => %{}} -> Map.put(current, "owner", %{"kind" => kind, "key" => key})
          %{"fact" => nil} -> current
          _ -> Map.put(current, "owner_unavailable", true)
        end

      _ ->
        current
    end
  end
end
