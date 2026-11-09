defmodule AtlasBFFContract.Pages do
  @moduledoc "The pages Control serves; included by the root contract."

  defmacro __using__(_opts) do
    quote do
      # The pages Control serves, and nothing else: a path outside them is no page. Each is
      # fetched and returns a view model. Generic: a kind is a parameter, never a name. The
      # paths are the ones facts already store (an agent request's page), so they stay.
      # `_` for a kind and `_parent` for a relation are values a client that knows only keys
      # passes; Control resolves them from rela's description.
      defpage :home, "/"
      defpage :workers, "/workers"
      defpage :worker, "/workers/:machine/:worker/:turn/:attempt"
      defpage :worker_guidance, "/workers/:machine/:worker/:turn/:attempt/guidance"
      defpage :kinds, "/_kinds"
      defpage :list, "/k/:kind"
      defpage :new, "/k/:kind/new"
      defpage :new_under, "/k/:kind/new/:relation/:parent"
      defpage :item, "/k/:kind/:key"
      defpage :edit, "/k/:kind/:key/edit"
      defpage :delete, "/k/:kind/:key/delete"
      defpage :links, "/k/:kind/:key/links/:relation"
      defpage :set, "/k/:kind/:key/set/:relation"
      defpage :answer, "/k/:kind/:key/answer/:answer"
      defpage :remove, "/k/:kind/:key/remove/:relation"
      # Test only: what can be made to fail (the node, or a fact), and the confirm for one.
      defpage :faults, "/faults"
      defpage :fact_faults, "/k/:kind/:key/faults"
      defpage :fault, "/fault/:fault"
      defpage :fact_fault, "/k/:kind/:key/fault/:fault"
    end
  end
end
