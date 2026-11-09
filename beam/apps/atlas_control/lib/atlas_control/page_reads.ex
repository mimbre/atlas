defmodule AtlasControl.PageReads do
  @moduledoc "Collection reads for a page and its assignment count, sharing one Facts snapshot."
  alias AtlasControl.Pages

  def answers(route, m, ask) do
    reads = Pages.reads(route, m)

    batch? =
      case route do
        {:assigned, _} -> true
        {:list, kind} -> Pages.open_work?(m, kind)
        _ -> false
      end

    if batch? and reads != [] do
      kinds = reads |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      # Keep the aggregate wait budget of the separate collection reads.
      case ask.("_page", %{"kinds" => kinds}, length(reads)) do
        %{"answers" => answers} when is_list(answers) and length(answers) == length(kinds) ->
          by_kind = Map.new(Enum.zip(kinds, answers))

          Enum.map(reads, fn {kind, content} ->
            answer = Map.fetch!(by_kind, kind)

            case {content, answer} do
              {%{"linked" => linked}, %{"facts" => facts}} ->
                Map.put(
                  answer,
                  "facts",
                  Enum.filter(facts, fn fact ->
                    Enum.all?(linked, fn {relation, key} ->
                      key in (get_in(fact, ["links", relation]) || [])
                    end)
                  end)
                )

              _ ->
                answer
            end
          end)

        %{"error" => _} = error ->
          List.duplicate(error, length(reads))

        _ ->
          List.duplicate(%{"error" => "Facts returned invalid page reads"}, length(reads))
      end
    else
      Enum.map(reads, fn {kind, content} -> ask.(kind, content, 1) end)
    end
  end
end
