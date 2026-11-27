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
      # What is assigned to the client (`/`), only the facts of one kind.
      defpage :assigned_group, "/_assigned/:kind"
      # Supervision (work acquisition decision 2026-11-17, §5.8): the flows one may
      # pick up (Open for you) and those the client supervises (Supervised by you). Each
      # per group: the flows in one supervised span of a subflow.
      defpage :open_for_you, "/_open"
      defpage :open_for_you_group, "/_open/:subflow/:span"
      defpage :supervised_by_you, "/_supervised"
      defpage :supervised_by_you_group, "/_supervised/:subflow/:span"
      # Deprecated (0.41.0): the Workers board; Control shows the Machines page here.
      defpage :workers, "/workers"
      # The machines (Runtimes) of the environment (0.41.0): with one, its page; with more,
      # a list of them, each opening its page. A machine's page: its state, health, slots,
      # queue, recently finished work and upgrades; Upgrade to the newest build (a confirm)
      # when a newer Runtime release exists.
      defpage :machines, "/machines"
      defpage :machine, "/machines/:machine"
      defpage :machine_upgrade, "/machines/:machine/upgrade"
      # The core's health (IS-Atlas-117), reached from the Machines page: each sync, Flow's
      # lag, Facts' queue and each Runtime's last poll, each marked late past its limit.
      defpage :health, "/health"
      defpage :worker, "/workers/:machine/:worker/:turn/:attempt"
      defpage :worker_guidance, "/workers/:machine/:worker/:turn/:attempt/guidance"
      defpage :kinds, "/_kinds"
      defpage :list, "/k/:kind"
      defpage :new, "/k/:kind/new"
      defpage :new_under, "/k/:kind/new/:relation/:parent"
      defpage :item, "/k/:kind/:key"
      # Deprecated (0.34.0): the fact's secondary menu, what its page offers besides the
      # flow's next step; the page now shows that itself (`actions`), and links here no more.
      defpage :more, "/k/:kind/:key/more"
      defpage :edit, "/k/:kind/:key/edit"
      defpage :delete, "/k/:kind/:key/delete"
      defpage :links, "/k/:kind/:key/links/:relation"
      defpage :set, "/k/:kind/:key/set/:relation"
      defpage :answer, "/k/:kind/:key/answer/:answer"
      defpage :remove, "/k/:kind/:key/remove/:relation"
      # Become the supervisor of the run `run` presents on the fact (Pick up), or hand it
      # over to someone else (Hand over…); `run` pins the run the page was made for.
      defpage :pick_up, "/k/:kind/:key/pick_up/:run"
      defpage :hand_over, "/k/:kind/:key/hand_over/:run"
      # Its supervisor takes the run back to the start of its span (Retry), or deletes the
      # fact with the work made for it, which ends the run (Remove).
      defpage :retry, "/k/:kind/:key/retry/:run"
      defpage :remove_item, "/k/:kind/:key/remove_item/:run"

      # Test only: what can be made to fail (the node, or a fact), and the confirm for one.
      defpage :faults, "/faults"
      defpage :fact_faults, "/k/:kind/:key/faults"
      defpage :fault, "/fault/:fault"
      defpage :fact_fault, "/k/:kind/:key/fault/:fault"
    end
  end
end
