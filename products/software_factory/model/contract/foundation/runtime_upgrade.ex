defmodule Model.RuntimeUpgrade do
  @moduledoc """
  A Runtime's upgrade (IS-Atlas-26, UC-Atlas-50): its supervisor starts it through Control
  (the Console, or `atlas put runtime_upgrade --in <machinery> --build <build>`), naming
  the released build, the build Atlas publishes; the Runtime does the rest, with no
  command typed on its machine.

  How it reads:

    * an upgrade belongs under one machinery (`upgrades`), the Runtime whose id is its
      key, and names the build (`build`, asked);
    * one at a time: Facts refuses a second upgrade under a machinery while one is open
      (the relation's `limit`, on `state`: `open` when it is made, `ended` once Flow
      writes it done or failed), naming the one that runs. `state` is not Flow's alone,
      because the create that makes it sets it; `step` is;
    * Flow's work source serves it to that Runtime and writes where it is in `step` with
      every poll (`AtlasFlow.WorkSource.Upgrade`): `draining` (no new work, waiting until
      no slot is busy, `busy` naming the busy ones), `updating` (the Runtime's update
      command installs the build and its launch agent restarts it), `verifying`, and
      `done` once a poll shows the build, a new `incarnation`, mode open and an offer of
      work; or `failed`, with the step (`failed_step`) and `reason`;
    * its run (the `runtime_upgrade` subflow) follows `step`, so Control shows each step
      with what it waits for. Nobody moves it by hand: the steps are Flow's (`set_by`).
  """
  use RelaDSL

  type(:runtime_upgrade_step,
    values: [:requested, :draining, :updating, :verifying, :done, :failed],
    labels: [
      requested: "Requested",
      draining: "Draining",
      updating: "Updating",
      verifying: "Verifying",
      done: "Done",
      failed: "Failed"
    ]
  )

  type(:runtime_upgrade_state,
    values: [:open, :ended],
    labels: [open: "Open", ended: "Ended"]
  )

  entity :runtime_upgrade,
    label: "Runtime upgrade",
    plural: "runtime_upgrades",
    id_type: :manual,
    id_prefix: "RU-",
    description: """
    The upgrade of one Runtime (its machinery) to a released build: drain, wait until no
    slot is busy, update, restart, verify. Its supervisor starts it; the Runtime and Flow
    do every step. The id is RU- and a number, e.g. RU-03.
    """ do
    field(:build, :string,
      required: true,
      description: "The released build to install, as Atlas published it (its commit)"
    )

    field(:state, :runtime_upgrade_state,
      description: "Open until it is done or failed; one open upgrade per Runtime at a time"
    )

    field(:step, :runtime_upgrade_step,
      description: "Where the upgrade is; Flow writes it from the Runtime's polls",
      set_by: [:flow]
    )

    field(:busy, :string,
      description: "While draining: the slots whose turns it waits for",
      set_by: [:flow]
    )

    field(:failed_step, :string,
      description: "Where it failed: drain, update, restart or verify",
      set_by: [:flow]
    )

    field(:reason, :string,
      description: "Why it failed, or why nothing had to be done",
      multiline: true,
      set_by: [:flow]
    )

    field(:from_build, :string,
      description: "The build the Runtime ran when the upgrade began",
      set_by: [:flow]
    )

    field(:from_incarnation, :string,
      description: "The Runtime's incarnation when the upgrade began",
      set_by: [:flow]
    )

    field(:incarnation, :string,
      description: "The incarnation of the restarted Runtime that was verified",
      set_by: [:flow]
    )

    top(false)
    primary(:build)
    order(:newest)

    create(
      ask: [:build],
      id: [prefix: "RU-", digits: 2],
      defaults: [state: :open]
    )
  end

  relation(:upgrades,
    label: "upgrades",
    description: "An upgrade is of one Runtime, its machinery; a machinery has its upgrades.",
    from: [:runtime_upgrade],
    to: [:machinery],
    max_outgoing: 1,
    inverse: {:upgrades_of, "upgrades"},
    parent: true,
    limit: [
      max: 1,
      field: :state,
      values: [:open],
      error: "{parent} is being upgraded already: {child}; start another once it ends"
    ]
  )

  subflow :runtime_upgrade, label: "Runtime upgrade", subject: :runtime_upgrade do
    owner default: {:person, config: :decider}
    start :create
    initial :requested

    state :requested, label: "Requested" do
      present(
        expected: "Wait for the Runtime to take it",
        why: "its Runtime takes it at its next poll",
        instructions:
          "Nothing to do: the Runtime drains at its next poll. A Runtime that does not poll is not running or not linked."
      )

      branch to: :draining, when: "entity.step == 'draining'"
      branch to: :updating, when: "entity.step == 'updating'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :done, when: "entity.step == 'done'"
      branch to: :failed, when: "entity.step == 'failed'"
    end

    state :draining, label: "Draining" do
      present(
        expected: "Wait until no slot is busy",
        why: "the Runtime takes no new work while its running turns end",
        instructions:
          "Nothing to do: busy names the slots it waits for, and the update starts once none is busy."
      )

      branch to: :updating, when: "entity.step == 'updating'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :done, when: "entity.step == 'done'"
      branch to: :failed, when: "entity.step == 'failed'"
    end

    state :updating, label: "Updating" do
      present(
        expected: "Wait for the update and the restart",
        why: "the Runtime installs the released build and its launch agent restarts it",
        instructions: "Nothing to do: it is verified once the restarted Runtime polls."
      )

      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :done, when: "entity.step == 'done'"
      branch to: :failed, when: "entity.step == 'failed'"
    end

    state :verifying, label: "Verifying" do
      present(
        expected: "Wait until it accepts work",
        why: "the restarted Runtime runs the build; it is done once it offers work again",
        instructions: "Nothing to do."
      )

      branch to: :done, when: "entity.step == 'done'"
      branch to: :failed, when: "entity.step == 'failed'"
    end

    final :done, label: "Done"
    final :failed, label: "Failed", status: :cancelled
  end

  # How the runs of runtime_upgrade are selected and imported: an ended one is history, an
  # open one joins the step it is at.
  select(:runtime_upgrade,
    choices: [],
    admission: [],
    imports: [
      [when: [step: [:done]], state: :done],
      [when: [step: [:failed]], state: :failed],
      [when: [step: [:verifying]], state: :verifying],
      [when: [step: [:updating]], state: :updating],
      [when: [step: [:draining]], state: :draining],
      [when: [], state: :requested]
    ]
  )
end
