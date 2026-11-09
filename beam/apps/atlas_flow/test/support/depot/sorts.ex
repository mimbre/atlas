defmodule AtlasFlow.Sorts do
  @moduledoc """
  Other versions of the depot's subflow `sort`, each written in the Rela DSL and
  compiled by itself (`use AtlasFlow.Sorts, …`), for the run machine's tests: what one
  test changes about the subflow is a version of its own, with a digest of its own.
  """

  @doc false
  defmacro __using__(opts) do
    quote do
      use RelaDSL.Flow.Subflow,
          unquote(Keyword.merge([subflow: :sort, behaviour: AtlasFlow.Subflow], opts))
    end
  end
end

defmodule AtlasFlow.Sorts.Written do
  @moduledoc "The versions, as a flow format module each (one subflow `sort` per module)."

  defmodule Plain do
    @moduledoc "Neither sets nor times anything on entry."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        branch(to: :done, when: "entity.result == 'ok'")
        branch(to: :discarded, when: "entity.result == 'no'")
        present(expected: "Sort it")
      end

      final(:done)
      final(:discarded)
    end
  end

  defmodule Relabelled do
    @moduledoc "The depot's sort with another label: another definition, another digest."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting, label: "Changed" do
        set(mark: "entered")
        branch(to: :done, when: "entity.result == 'ok'")
        branch(to: :discarded, when: "entity.result == 'no'")
        wait_for([:clerk], on: :choice, reset: false, yes: :done)
        timer(:retry, "5m", to: :waiting)
        present(expected: "Sort it")
      end

      final(:done, label: "Done")
      final(:discarded, label: "Discarded")
    end
  end

  defmodule Presented do
    @moduledoc "Presents its timer's due time, and keeps a clerk its owner."
    use RelaDSL.Schema

    subflow :sort, label: "Sort", subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting, label: "Sort it" do
        owner(relation: :owned_by, default: {:clerk, :ada}, preserve_kind: :clerk)
        set(mark: "entered")
        branch(to: :done, when: "entity.result == 'ok'")
        branch(to: :discarded, when: "entity.result == 'no'")
        wait_for([:clerk], on: :choice, reset: false, yes: :done)
        timer(:retry, "5m", to: :waiting)
        present(expected: "Sort it", deadline: :retry)
      end

      final(:done, label: "Done")
      final(:discarded, label: "Discarded")
    end
  end

  defmodule Twice do
    @moduledoc "Two branches hold on the same change: the first written is taken."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        branch(to: :done, when: "entity.result == 'ok'")
        branch(to: :discarded, when: "entity.result == 'ok'")
      end

      final(:done)
      final(:discarded)
    end
  end

  defmodule Ties do
    @moduledoc "Two timers due at once: the first written is taken."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        timer(:first, "5m", to: :done)
        timer(:second, "5m", to: :discarded)
      end

      final(:done)
      final(:discarded)
    end
  end

  defmodule Earlier do
    @moduledoc "Two timers: the one due first is taken, whatever their order."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        timer(:first, "5m", to: :done)
        timer(:second, "1m", to: :discarded)
      end

      final(:done)
      final(:discarded)
    end
  end

  defmodule Chosen do
    @moduledoc "A clerk chooses; entering resets the choice and makes two slips."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        wait_for([:clerk], on: :choice, yes: :done)
        create(:slip, properties: [title: "One"], relate: :of_box)
        create(:slip, properties: [title: "Two"], relate: :of_box)
        timer(:retry, "5m", to: :waiting)
      end

      final(:done)
    end
  end

  defmodule Since do
    @moduledoc "A clerk chooses; its timer runs from the box's own opened_at."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting do
        wait_for([:clerk], on: :choice, yes: :done)
        timer(:retry, "5m", to: :waiting, since: :opened_at)
      end

      final(:done)
    end
  end

  defmodule Ready do
    @moduledoc "Starts when the box is ready, again each time it becomes ready."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:predicate, when: "entity.ready == true")
      initial(:waiting)

      state :waiting do
        set(mark: "entered")
        branch(to: :done, when: "entity.result == 'ok'")
        timer(:retry, "5m", to: :waiting)
      end

      final(:done)
    end
  end

  defmodule Publish do
    @moduledoc "Publishes the box to the ledger (an effect), then is done or stuck."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:publishing)

      state :publishing do
        effect(:publish,
          contract: 1,
          name: "publish",
          service: "ledger",
          operation: "create",
          fingerprint: [fields: ["title"], relations: []],
          payload: ["title"],
          outputs: [reference: "artifact"],
          records: [kind: "crate", relation: "in_box", outputs: [label: "reference"]],
          on: [done: :done, refused: :stuck]
        )

        timer(:no_answer, "1h", to: :stuck)
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :publishing)
      end

      final(:done)
    end
  end

  defmodule Update do
    @moduledoc "Updates the box's artifact in the ledger."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:publishing)

      state :publishing do
        effect(:publish,
          contract: 1,
          name: "publish",
          service: "ledger",
          operation: "update",
          fingerprint: [fields: ["title"], relations: []],
          payload: ["title"],
          outputs: [reference: "artifact"],
          records: [kind: "crate", relation: "in_box", outputs: [label: "reference"]],
          target: "artifact",
          on: [done: :done, refused: :stuck]
        )

        timer(:no_answer, "1h", to: :stuck)
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :publishing)
      end

      final(:done)
    end
  end

  defmodule Integrate do
    @moduledoc """
    Integrates the box's artifact once its title is approved (its check, through the
    composition's link, wrote `verdict: yes`); discarded by hand (`result: no`) while
    nothing was asked yet.
    """
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:publishing)

      state :publishing do
        branch(to: :discarded, when: "entity.result == 'no'")

        effect(:publish,
          contract: 1,
          name: "publish",
          service: "ledger",
          operation: "integrate",
          fingerprint: [fields: ["title"], relations: []],
          payload: ["title"],
          outputs: [reference: "artifact"],
          records: [kind: "crate", relation: "in_box", outputs: [label: "reference"]],
          target: "artifact",
          approved: "title",
          approving: [verdict: ["yes"]],
          on: [done: :done, refused: :stuck]
        )

        timer(:no_answer, "1h", to: :stuck)
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :publishing)
      end

      final(:done)
      final(:discarded)
    end
  end

  defmodule Inspect do
    @moduledoc "Someone's Runtime inspects the box (a pass), routed to its owner's machine."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by)
      start(:create)
      initial(:working)

      state :working do
        pass(:inspector,
          contract: 1,
          name: "inspect",
          routing: [machine_field: "node"],
          fingerprint: [fields: ["revision"], relations: []],
          request: [
            mode: "start",
            assignment: "Inspect this input",
            cwd: "/private/work",
            permissions: "read-only",
            backend: "codex",
            vendors: ["codex"]
          ],
          on: [delivered: :done, failed: :stuck]
        )
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :working)
      end

      final(:done)
    end
  end

  defmodule InspectHeld do
    @moduledoc "As `Inspect`, owned through the box's holder (an assignment)."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(via: :holder, relation: :owned_by)
      start(:create)
      initial(:working)

      state :working do
        pass(:inspector,
          contract: 1,
          name: "inspect",
          routing: [machine_field: "node"],
          fingerprint: [fields: ["revision"], relations: []],
          request: [
            mode: "start",
            assignment: "Inspect this input",
            cwd: "/private/work",
            permissions: "read-only",
            backend: "codex",
            vendors: ["codex"]
          ],
          on: [delivered: :done, failed: :stuck]
        )
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :working)
      end

      final(:done)
    end
  end

  defmodule Handover do
    @moduledoc """
    Two open states, each with its own owner: bob packs the box, ada checks it, and it is
    done once checked. A projection test's subflow: what is expected, the state and the
    owner move with the run.
    """
    use RelaDSL.Schema

    subflow :sort, label: "Sort", subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by, default: {:clerk, :bob})
      start(:create)
      initial(:packing)

      state :packing, label: "Pack it" do
        branch(to: :check, when: "entity.stage == 'check'")
        present(expected: "Pack it", why: "not all in it is packed")
      end

      state :check, label: "Check it" do
        owner(relation: :owned_by, default: {:clerk, :ada})
        branch(to: :done, when: "entity.result == 'ok'")
        branch(to: :packing, when: "entity.stage == 'packing'")
        present(expected: "Check it", why: "all in it is packed")
      end

      final(:done, label: "Done")
    end
  end

  defmodule Checked do
    @moduledoc "Checked by whoever the environment configures as its checker."
    use RelaDSL.Schema

    subflow :sort, label: "Sort", subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by, default: {:clerk, config: :checker})
      start(:create)
      initial(:check)

      state :check, label: "Check it" do
        branch(to: :done, when: "entity.result == 'ok'")
        present(expected: "Check it")
      end

      final(:done, label: "Done")
    end
  end

  defmodule Handing do
    @moduledoc """
    Ends by moving the box out of the phase its runs are admitted in: its final state
    sets the phase whose boxes another subflow presents (a two-phase hand-off).
    """
    use RelaDSL.Schema

    subflow :sort, label: "Sort", subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:waiting)

      state :waiting, label: "Sort it" do
        branch(to: :done, when: "entity.result == 'ok'")
        present(expected: "Sort it")
      end

      final :done, label: "Done" do
        set(phase: "second")
      end
    end
  end

  defmodule Unbound do
    @moduledoc "An effect as the flow format writes one without a contract: no runner runs it."
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(default: {:clerk, :ada})
      start(:create)
      initial(:publishing)

      state :publishing do
        effect(:publish,
          service: :ledger,
          fingerprint: [:approved_by, :check],
          records: [:crate, :in_box],
          on: [done: :done, refused: :done]
        )
      end

      final(:done)
    end
  end
end

# Each version compiled into a subflow module (`AtlasFlow.Subflow`).
defmodule AtlasFlow.Sorts.Plain do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Plain
end

defmodule AtlasFlow.Sorts.Relabelled do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Relabelled
end

defmodule AtlasFlow.Sorts.Presented do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Presented
end

defmodule AtlasFlow.Sorts.Twice do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Twice
end

defmodule AtlasFlow.Sorts.Ties do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Ties
end

defmodule AtlasFlow.Sorts.Earlier do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Earlier
end

defmodule AtlasFlow.Sorts.Chosen do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Chosen
end

defmodule AtlasFlow.Sorts.Since do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Since
end

defmodule AtlasFlow.Sorts.Ready do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Ready
end

defmodule AtlasFlow.Sorts.Publish do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Publish
end

defmodule AtlasFlow.Sorts.Update do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Update
end

defmodule AtlasFlow.Sorts.Integrate do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Integrate
end

defmodule AtlasFlow.Sorts.Unbound do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Unbound
end

defmodule AtlasFlow.Sorts.Inspect do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Inspect
end

defmodule AtlasFlow.Sorts.InspectHeld do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.InspectHeld
end

defmodule AtlasFlow.Sorts.Handing do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Handing
end

defmodule AtlasFlow.Sorts.Handover do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Handover
end

defmodule AtlasFlow.Sorts.Checked do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Checked
end
