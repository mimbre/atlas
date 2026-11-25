defmodule AtlasFlow.Sorts do
  @moduledoc """
  Other versions of the depot's subflow `sort`, each written in the Rela DSL and
  compiled by itself (`use AtlasFlow.Sorts, …`), for the run machine's tests: what one
  test changes about the subflow is a version of its own.
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
    @moduledoc "The depot's sort with another label: another definition, the same states."
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

  defmodule Authoring do
    @moduledoc """
    Authors the box on the machinery it is assigned to (a task), then is authored, its
    check failed, stuck (a clerk may author it again) or abandoned.
    """
    use RelaDSL.Schema

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by, default: {:clerk, :ada})
      start(:create)
      initial(:authoring)

      state :authoring do
        task(:author,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.invalid/depot", base: "develop"],
          check: ["bin/check"],
          instructions: "Pack the box.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: [
            completed: :authored,
            check_failed: :check_failed,
            stuck: :stuck,
            abandoned: :abandoned
          ]
        )
      end

      state :stuck do
        wait_for([:clerk], on: :choice, again: :authoring)
      end

      final(:authored)
      final(:check_failed)
      final(:abandoned)
    end
  end

  defmodule Reviewed do
    @moduledoc """
    Authors the box, and reviews and fixes it as the ladder says (F2): every task a step
    of the review → fix loop (`ladder: true`), each step in a state of its own; ready,
    held or escalated as the ladder decides.
    """
    use RelaDSL.Schema

    @steps [
      author: :authoring,
      review: :reviewing,
      fix: :fixing,
      diagnose: :diagnosing,
      fresh: :fresh,
      stronger: :stronger,
      ready: :ready,
      held: :held,
      escalate: :escalated,
      abandon: :stuck
    ]

    subflow :sort, subject: :box do
      run_as("system:depot")
      owner(relation: :owned_by, default: {:clerk, :ada})
      start(:create)
      initial(:authoring)

      state :authoring do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.invalid/depot", base: "develop"],
          check: ["bin/check"],
          instructions: "Pack the box.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      state :reviewing do
        task(:review,
          ladder: true,
          role: :developer,
          profile: :independent_review,
          input: [result: :latest, access: :read],
          instructions: "Review the box.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      state :fixing do
        task(:fix,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [result: :latest, access: :write],
          check: ["bin/check"],
          instructions: "Fix the box.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      state :diagnosing do
        task(:diagnose,
          ladder: true,
          role: :investigator,
          profile: :deep_coding,
          input: [result: :latest, access: :read],
          instructions: "Find out why.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      state :fresh do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.invalid/depot", base: "develop"],
          check: ["bin/check"],
          instructions: "Pack the box.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      state :stronger do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding_max,
          cost_class: :high,
          input: [repository: "example.invalid/depot", base: "develop"],
          check: ["bin/check"],
          instructions: "Pack the box.",
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: @steps
        )
      end

      final(:ready)
      final(:held)
      final(:escalated)
      final(:stuck)
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

defmodule AtlasFlow.Sorts.Authoring do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Authoring
end

defmodule AtlasFlow.Sorts.Reviewed do
  @moduledoc false
  use AtlasFlow.Sorts, from: AtlasFlow.Sorts.Written.Reviewed
end

defmodule AtlasFlow.Sorts.Loop do
  @moduledoc """
  A neutral model of the review → fix loop on the lease path (F2): a bin is worked on by
  a robot (a machinery kind) through one state per ladder step (`AtlasFlow.Ladder`), all
  in the supervised span `pack`. A clerk supervises the run. Each task state presents,
  and the subflow's owner keeps a clerk or a robot someone linked (`preserve_kind`), so
  the robot stays while the loop runs; `held` and `awaiting_decision` have their own
  owner, the configured decider (so the supervisor in the span), without `preserve_kind`.
  The supervisor answers on the bin's `answer` and hands the bin back. A `decision` kind
  exists only so that a test can see that Flow writes none.
  """
  use RelaDSL.Composition,
    name: "loop",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  defmodule Desk do
    @moduledoc "The bins, their robots, who supervises their runs, the slips and decisions."
    use RelaDSL

    @steps [
      author: :authoring,
      review: :reviewing,
      fix: :fixing,
      diagnose: :diagnosing,
      fresh: :fresh,
      stronger: :stronger,
      ready: :ready,
      held: :held,
      escalate: :awaiting_decision,
      abandon: :stuck
    ]

    type(:slip_operation, values: [:choice, :pickup, :hand_over, :retry])

    entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
      field(:name, :string)
    end

    entity :robot, label: "Robot", plural: "robots", id_type: :manual do
      field(:name, :string)
    end

    entity :decision, label: "Decision", plural: "decisions", id_type: :manual do
      field(:title, :string)
    end

    entity :bin, label: "Bin", plural: "bins", id_type: :manual do
      field(:phase, :string)
      field(:step, :string)
      field(:choice, :string)
      field(:answer, :string)
      field(:todo, :string)
      field(:task_result, :string)
    end

    relation(:owned_by, label: "owned by", from: [:bin], to: [:robot, :clerk], max_outgoing: 1)
    relation(:chosen_by, label: "chosen by", from: [:bin], to: [:clerk], max_outgoing: 1)

    entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
      for f <- ~w(flow subject_kind subject_key state entered_at status
                  deadlines pending last_input blocked_reason)a,
          do: field(f, :string)

      for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
    end

    entity :slip, label: "Slip", plural: "slips", id_type: :manual do
      field(:run, :string)
      field(:actor, :string)
      field(:operation, :slip_operation)
      field(:hand_to, :string)
    end

    relation(:watched_by,
      label: "watched by",
      from: [:cursor],
      to: [:clerk],
      max_outgoing: 1,
      set_by: [:flow]
    )

    flow_runtime(
      runs: :cursor,
      writer: [sender: :flow, by: :flow],
      inputs: :slip,
      supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]
    )

    subflow :work, label: "Work", subject: :bin do
      run_as("system:loop")

      owner(
        relation: :owned_by,
        default: {:clerk, config: :decider},
        preserve_kind: [:clerk, :robot]
      )

      start(:create)
      initial(:authoring)

      supervise(:pack,
        label: "Pack",
        states: [
          :authoring,
          :reviewing,
          :fixing,
          :diagnosing,
          :fresh,
          :stronger,
          :held,
          :awaiting_decision
        ]
      )

      state :authoring do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.org/acme/loop", base: "develop"],
          check: ["bin/check"],
          instructions: "Load the bin.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Load it on the robot", why: "the bin is new")
      end

      state :reviewing do
        task(:review,
          ladder: true,
          role: :developer,
          profile: :independent_review,
          input: [result: :latest, access: :read],
          instructions: "Review the load.",
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Review it on the robot", why: "it is loaded")
      end

      state :fixing do
        task(:fix,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [result: :latest, access: :write],
          check: ["bin/check"],
          instructions: "Fix the load.",
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Fix it on the robot", why: "the review or check found a problem")
      end

      state :diagnosing do
        task(:diagnose,
          ladder: true,
          role: :investigator,
          profile: :deep_coding,
          input: [result: :latest, access: :read],
          instructions: "Find out why the load keeps failing.",
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Diagnose it on the robot", why: "the fixes did not do it")
      end

      state :fresh do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.org/acme/loop", base: "develop"],
          check: ["bin/check"],
          instructions: "Load the bin.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Load it afresh on the robot", why: "the ladder climbed")
      end

      state :stronger do
        task(:author,
          ladder: true,
          role: :developer,
          profile: :deep_coding_max,
          cost_class: :high,
          input: [repository: "example.org/acme/loop", base: "develop"],
          check: ["bin/check"],
          instructions: "Load the bin.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: @steps
        )

        present(expected: "Load it stronger on the robot", why: "the ladder climbed")
      end

      state :held do
        owner(relation: :owned_by, default: {:clerk, config: :decider})
        set(answer: :none)
        branch(to: :fresh, when: "entity.answer == 'fresh'")
        branch(to: :stronger, when: "entity.answer == 'stronger'")
        branch(to: :stuck, when: "entity.answer == 'abandon'")
        present(expected: "Answer, and hand the bin back to its robot", why: "it is held")
      end

      state :awaiting_decision do
        owner(relation: :owned_by, default: {:clerk, config: :decider})
        set(answer: :none)
        branch(to: :fresh, when: "entity.answer == 'fresh'")
        branch(to: :stronger, when: "entity.answer == 'stronger'")
        branch(to: :stuck, when: "entity.answer == 'abandon'")
        present(expected: "Decide, and hand the bin back to its robot", why: "the ladder asks")
      end

      final(:ready)
      final(:stuck)
    end

    select(:work,
      projection: [field: :todo, owner_relation: :owned_by],
      admission: [phase: [:first]],
      imports: []
    )
  end

  defmodule Bins do
    @moduledoc "The loop model's one module."
    use RelaDSL.Module, path: "modules/bins/schema.yaml", concepts: [Desk]
  end

  schema(version: "1.0", namespace: "https://example.invalid/loop#", description: "Bins.\n")
  modules([Bins])
  environments([:prod, :test])

  acl(comment: "The loop's roles.")
  role("loop", read: ["*"], create: [:cursor], update: [:bin, :cursor])
  role("clerk", read: ["*"], update: [:bin])
  assign("system:loop", "loop")

  defcomposition :loop do
    subflows([Desk])
  end
end

defmodule AtlasFlow.Sorts.Loop.Bench do
  @moduledoc """
  The loop's lease bench (F2): real Bases (on `FakeCode`), Dispatch, Delivery and the
  result store, `FakeFacts` and a manual clock, as the task activity's own test runs them.
  The test process stands in for the Engine: it reconciles the bin's run through the run
  store and projects it (`settle/3`), and receives Delivery's casts and Bases' notifies.
  Every wait awaits a message.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock}
  alias AtlasFlow.{Results, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Run, Store}

  @epoch ~U[2026-11-17 12:00:00Z]
  @repository "example.org/acme/loop"
  @readme "# Loop\n"
  @actors %{"decider" => "dee"}
  @offer %{"deep_coding" => 2, "independent_review" => 2, "deep_coding_max" => 1}

  def repository, do: @repository
  def readme, do: @readme
  def actors, do: @actors

  @doc "Facts, the clock, the result store, Code and the model; the clerks and robots."
  def setup! do
    Application.put_env(:atlas_bus, :store, "loop-#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "loop-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@epoch)
    clock = {ManualClock, clock}

    results = [dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end]
    start_supervised!(Supervisor.child_spec({Results, results}, id: Results))

    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, @repository, "develop", "rev_1", %{"README.md" => @readme})

    runner = AtlasFlow.Model.load(AtlasFlow.Sorts.Loop, :prod, @actors)
    assert runner.refusal == nil

    for clerk <- ~w(ada bea dee), do: FakeFacts.put("clerk", %{"key" => clerk})
    for robot <- ~w(mini laptop), do: FakeFacts.put("robot", %{"key" => robot})
    :ok = AtlasBus.attach("flow")

    %{runner: runner, clock: clock, code: code, dir: dir}
  end

  @doc "Bases, Dispatch and Delivery (which casts to the test process)."
  def source!(c) do
    start_bases(c)

    start_supervised!(
      Supervisor.child_spec(
        {Dispatch,
         model: AtlasFlow.Sorts.Loop,
         actors: @actors,
         clock: c.clock,
         poll_wait: 0,
         sweep_ms: nil,
         resync_ms: nil},
        id: Dispatch
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {Delivery, model: AtlasFlow.Sorts.Loop, actors: @actors, clock: c.clock, engine: self()},
        id: Delivery
      )
    )

    c
  end

  def start_bases(c),
    do:
      start_supervised!(
        Supervisor.child_spec({Bases, client: FakeCode.client(c.code), clock: c.clock}, id: Bases)
      )

  @doc "A bin in its first phase, owned by `owner` (a robot, a clerk or nobody), linked by `by`."
  def bin(key, owner, by \\ "someone", values \\ %{}) do
    fact = FakeFacts.get("bin", key) || %{}

    FakeFacts.put("bin", %{
      "key" => key,
      "values" =>
        Map.merge(
          Map.merge(%{"phase" => "first", "step" => "Load #{key}."}, fact["values"] || %{}),
          values
        ),
      "links" => %{"owned_by" => List.wrap(owner)},
      "origins" => %{"owned_by" => %{"by" => by, "position" => 1}},
      "version" => (fact["version"] || 0) + 1
    })
  end

  def owner(key), do: FakeFacts.get("bin", key)["links"]["owned_by"]

  def run(c, key \\ "B-1") do
    case FakeFacts.get(c.runner.config["kind"], Run.key("work", "bin", key, 1)) do
      nil -> nil
      fact -> with {:ok, run} <- Store.decode(c.runner.config, fact), do: run
    end
  end

  @doc "Sets (nil: clears) the run's supervisor, as a checked pickup or hand-over writes it."
  def supervise(c, supervisor, key \\ "B-1") do
    run_key = Run.key("work", "bin", key, 1)
    fact = FakeFacts.get(c.runner.config["kind"], run_key)
    links = Map.put(fact["links"] || %{}, "watched_by", List.wrap(supervisor))
    FakeFacts.put(c.runner.config["kind"], Map.merge(fact, %{"links" => links}))
  end

  def reconcile(c, key \\ "B-1") do
    {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)

    {:ok, runs} =
      Store.reconcile_subjects(c.runner.config, c.runner.flows, now, known, [{"bin", key}])

    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end

  @doc """
  Reconciles until the run holds an intent or rests (a state without a task, or the same
  run twice): a state's entry and its next intent may take two rounds. Then projects it.
  """
  def settle(c, key \\ "B-1", rounds \\ 4) do
    run = reconcile(c, key)

    cond do
      run["pending"]["task"] != nil or rounds == 0 -> projected(c, key, run)
      run == reconcile(c, key) -> projected(c, key, run)
      true -> settle(c, key, rounds - 1)
    end
  end

  # What the Engine does after a round: the subject projected.
  defp projected(c, key, run) do
    assert {:ok, _} = AtlasFlow.Runs.Projection.project(c.runner, "bin", key)
    run
  end

  def base_ready(key \\ "B-1"), do: assert_receive({:reconcile, "bin", ^key}, 2_000)

  @doc "A bin on the mini, supervised by ada, whose run holds its first author's intent."
  def started(c, key \\ "B-1") do
    bin(key, "mini")

    if reconcile(c, key)["pending"]["task"] == nil do
      base_ready(key)
      assert %{"version" => 2} = reconcile(c, key)["pending"]["task"]
    end

    supervise(c, "ada", key)
    run = reconcile(c, key)
    assert %{"version" => 2} = run["pending"]["task"]
    run
  end

  def poll(client, holdings \\ []) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings, @offer))
  end

  def lease!(client) do
    assert {:polled, %{leases: [lease]}} = poll(client)
    lease
  end

  def report(client, lease, revision, report),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: report})

  @doc """
  The lease `client` is offered, worked to its end: accepted, started, ended with
  `files` (none: no change set) on the lease's base, the check's exit status (nil: no
  check; `:unfinished`: a check that gave none), `answer`, and `kind`/`reason` for another
  end; every missing blob put, and Delivery's casts taken.
  """
  def finish(client, opts \\ []) do
    %{lease_id: lease, work: offered} = lease!(client)
    files = Keyword.get(opts, :files, [])
    change_set = if files != [], do: L.change_set(files, offered.input.base.base_id)

    check =
      case Keyword.get(opts, :check) do
        nil -> []
        :unfinished -> [check: %{exit_status: nil, output_tail: "tail unfinished"}]
        status -> [check: %{exit_status: status, output_tail: "tail #{status}"}]
      end

    ended = L.ended(change_set, check ++ Keyword.take(opts, [:answer, :kind, :reason]))
    assert {:recorded, _} = report(client, lease, 1, %{state: :accepted})
    assert {:recorded, _} = report(client, lease, 2, %{state: :started})
    assert {:recorded, answer} = report(client, lease, 3, ended)

    for sha <- Map.get(answer, :missing, []) do
      {_path, bytes} = Enum.find(files, fn {_, b} -> L.sha256(b) == sha end)

      assert :stored =
               WorkSource.put_blob(client, %{
                 lease_id: lease,
                 sha256: sha,
                 size: byte_size(bytes),
                 content: [bytes]
               })
    end

    assert_receive {:"$gen_cast", {:reconcile, "bin", _}}
    drain()
    %{lease_id: lease, work: offered}
  end

  @doc "The lease `client` is offered, refused by its Runtime for `reason`; Delivery's casts taken."
  def refuse(client, reason) do
    %{lease_id: lease, work: offered} = lease!(client)
    assert {:recorded, _} = report(client, lease, 1, %{state: :refused, reason: reason})
    assert_receive {:"$gen_cast", {:reconcile, "bin", _}}
    drain()
    %{lease_id: lease, work: offered}
  end

  # Delivery's further casts of this end, if any (already in the mailbox: no wait).
  defp drain do
    receive do
      {:"$gen_cast", {:reconcile, "bin", _}} -> drain()
    after
      0 -> :ok
    end
  end

  def task_values(key), do: (FakeFacts.get("task", key) || %{})["values"]

  @doc "A review's answer, ending with its verdict block."
  def verdict(verdict, findings \\ []),
    do:
      "I looked at it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => verdict, "findings" => findings}) <> "\n```\n"

  @doc "A diagnose task's answer, ending with its diagnosis block."
  def diagnosis(block), do: "Here is why.\n\n```json\n" <> JSON.encode!(block) <> "\n```\n"

  @doc "The decision facts Facts holds: none, while Flow writes no decision."
  def decisions do
    %{"facts" => facts} = AtlasFlow.Talk.read("decision", %{"plain" => true})
    facts
  end

  @doc "Runs `fun`, then awaits Bases' restore of `manifest` from `snapshot` (traced, an event)."
  def restored(manifest, snapshot, fun) do
    bases = Process.whereis(Bases)
    1 = :erlang.trace(bases, true, [:receive])

    try do
      result = fun.()

      assert_receive {:trace, ^bases, :receive,
                      {ref,
                       {:ok, :pinned, %{base: %{manifest: ^manifest, snapshot_id: ^snapshot}}}}}
                     when is_reference(ref),
                     2_000

      :sys.get_state(bases)
      result
    after
      :erlang.trace(bases, false, [:receive])
    end
  end
end
