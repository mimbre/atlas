defmodule AtlasControl.PageReads do
  @moduledoc """
  A page's reads (`AtlasControl.Pages.reads/2`), asked of Facts as one `_page` read:
  answered in order, from one snapshot, at one position, each with what it depended on
  (docs/design/page-freshness.md §1.1). A page without reads asks nothing.
  """
  alias AtlasControl.Pages

  @doc """
  The answers to `route`'s reads, in order. `ask.(kind, content, budget)` reads once,
  waiting `budget` times a read's wait: a page waits as long as its reads would have,
  one by one. When the page read fails, each read has its error.
  """
  def answers(route, m, ask) do
    case Pages.reads(route, m) do
      [] ->
        []

      reads ->
        content = %{"reads" => Enum.map(reads, fn {kind, read} -> [kind, read] end)}

        case ask.("_page", content, length(reads)) do
          %{"answers" => answers} when is_list(answers) and length(answers) == length(reads) ->
            answers

          %{"error" => _} = error ->
            List.duplicate(error, length(reads))

          _ ->
            List.duplicate(%{"error" => "Facts returned invalid page reads"}, length(reads))
        end
    end
  end

  @doc "The reads of `route` as `AtlasControl.Freshness.ReadSet.of/3` takes them: `[{kind, role}]`."
  def roles(route, m) do
    Enum.zip_with(Pages.reads(route, m), Pages.read_roles(route, m), fn {kind, _}, role ->
      {kind, role}
    end)
  end
end
