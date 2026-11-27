defmodule Model.RuntimeUpgrade do
  @moduledoc """
  A supervised upgrade of a Runtime to a released build (IS-Atlas-26, UC-Atlas-50): its
  supervisor starts it from Control (the Console, or `atlas create`) under the Runtime's
  machinery, naming the build Atlas published (`build`; the GitHub release
  `atlas-runtime-<build>`, never a checkout on the machine). Then nobody types a command
  on the machine:

    1. Flow's work source orders the Runtime to drain on its next poll
       (`AtlasFlow.WorkSource.Upgrade`): it takes no new work and returns what it had
       not started; its running turns finish (`draining`);
    2. while a slot still runs a turn, `waiting`, and `busy` names the slots;
    3. once no slot is busy, Flow orders the update: the Runtime runs its one update
       command (`atlas-runtime service update`), which refuses while a slot is busy or
       another update holds its lock, installs the release, stops the Runtime and has
       its launch agent start it again (`updating`);
    4. the Runtime polls again from its new boot: Flow checks it reports the build, a
       new incarnation (`from_incarnation` was the old one), and, once Flow ordered it
       to resume, mode open with slots to offer, so it accepts work again (`verifying`);
    5. `done`, or `failed` with the step that failed (`failed_step`) and why (`reason`).

  Flow writes every field but `build` (`set_by: [:flow]`), so its create sets no `step`:
  Flow reads none as `requested`, where its run starts. One upgrade at a time per
  machinery: the composition limits `upgrade_of` to one upgrade that has not ended, so
  a second one is refused when it is made (and the update command's lock refuses a
  second update on the machine itself).
  """
  use RelaDSL

  type(:runtime_upgrade_step,
    values: [:requested, :draining, :waiting, :updating, :verifying, :done, :failed],
    labels: [
      requested: "Requested",
      draining: "Draining",
      waiting: "Waiting for slots",
      updating: "Updating",
      verifying: "Verifying",
      done: "Done",
      failed: "Failed"
    ]
  )

  entity :runtime_upgrade,
    label: "Runtime upgrade",
    plural: "runtime_upgrades",
    id_type: :manual,
    id_prefix: "RU-",
    description: """
    An upgrade of a Runtime to a build Atlas released, started by its supervisor under
    the Runtime's machinery: drain, wait until no slot is busy, update, restart, verify.
    The id is RU- and a number, e.g. RU-01.
    """ do
    icon(:runtime_upgrade)

    field(:build, :string,
      required: true,
      description:
        "The released build to install, as Atlas published it (the GitHub release atlas-runtime-<build>)"
    )

    field(:step, :runtime_upgrade_step,
      description: "Where the upgrade is; Flow moves it as the Runtime reports",
      set_by: [:flow]
    )

    field(:busy, :string,
      description: "The slots that still run a turn while the upgrade waits",
      set_by: [:flow]
    )

    field(:from_build, :string,
      description: "The build the Runtime ran when the upgrade began",
      set_by: [:flow]
    )

    field(:from_incarnation, :string,
      description: "The Runtime's incarnation when the upgrade began; a restart makes a new one",
      set_by: [:flow]
    )

    field(:incarnation, :string,
      description: "The Runtime's incarnation after its restart",
      set_by: [:flow]
    )

    field(:failed_step, :string,
      description: "The step that failed: drain, update, restart or verify",
      set_by: [:flow]
    )

    field(:reason, :string,
      description: "Why it failed, as the Runtime or Flow said",
      multiline: true,
      set_by: [:flow]
    )

    primary(:build)
    top(false)
    order(:newest)

    create(
      ask: [:build],
      id: [prefix: "RU-", digits: 2]
    )

    completion([
      [field: :step, value: :done],
      [field: :step, value: :failed]
    ])
  end

  relation(:upgrade_of,
    label: "upgrade of",
    description: "An upgrade is of one Runtime's machinery; a machinery has its upgrades.",
    from: [:runtime_upgrade],
    to: [:machinery],
    max_outgoing: 1,
    inverse: {:upgrades, "upgrades"},
    parent: true
  )

  subflow :runtime_upgrade, label: "Runtime upgrade", subject: :runtime_upgrade do
    # Its supervisor watches it; the steps are Flow's and the Runtime's.
    owner default: {:person, config: :decider}
    start :create
    initial :requested

    state :requested, label: "Waiting for a poll" do
      present(
        expected: "Watch the upgrade to {build}",
        why: "a Runtime upgrade was started",
        instructions:
          "Flow orders the Runtime to drain on its next poll (within 25 s). Nothing to type on the machine."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :updating, when: "entity.step == 'updating'"
      branch to: :waiting, when: "entity.step == 'waiting'"
      branch to: :draining, when: "entity.step == 'draining'"
      timer :not_polled, "10m", to: :stalled, label: "The Runtime did not poll in ten minutes"
    end

    state :draining, label: "Draining" do
      present(
        expected: "Watch the upgrade to {build}: the Runtime drains",
        why: "a Runtime upgrade was started",
        instructions:
          "The Runtime takes no new work and returns what it had not started; its running turns finish."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :updating, when: "entity.step == 'updating'"
      branch to: :waiting, when: "entity.step == 'waiting'"
      timer :not_drained, "10m", to: :stalled, label: "Not drained in ten minutes"
    end

    # No timer: a turn may run for hours (its profile's max_duration), and the upgrade
    # waits for it.
    state :waiting, label: "Waiting for slots" do
      present(
        expected: "Watch the upgrade to {build}: waiting until no slot is busy ({busy})",
        why: "a Runtime upgrade was started",
        instructions:
          "The upgrade waits until every running turn has ended; then the Runtime updates itself."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :updating, when: "entity.step == 'updating'"
    end

    state :updating, label: "Updating" do
      present(
        expected: "Watch the upgrade to {build}: the Runtime installs it and restarts",
        why: "a Runtime upgrade was started",
        instructions:
          "The Runtime's update command installs the release; its launch agent starts it again."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :done, when: "entity.step == 'done'"

      timer :not_back, "20m",
        to: :stalled,
        label: "The Runtime did not come back in twenty minutes"
    end

    state :verifying, label: "Verifying" do
      present(
        expected: "Watch the upgrade to {build}: verifying it runs it and accepts work",
        why: "a Runtime upgrade was started",
        instructions:
          "Flow checks the Runtime's build, its new incarnation, mode open and its offer."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :done, when: "entity.step == 'done'"
      timer :not_verified, "10m", to: :stalled, label: "Not verified in ten minutes"
    end

    # The Runtime fell silent or did not move on: its supervisor looks on the machine
    # (update.log in the Runtime home). A later report still moves it on.
    state :stalled, label: "Stalled" do
      present(
        expected: "Look at the Runtime: the upgrade to {build} stalled at {step}",
        why: "the Runtime did not move on in time",
        instructions:
          "Look at the machine's update.log and service.log in the Runtime home. The upgrade goes on by itself once the Runtime reports again."
      )

      branch to: :failed, when: "entity.step == 'failed'"
      branch to: :done, when: "entity.step == 'done'"
      branch to: :verifying, when: "entity.step == 'verifying'"
      branch to: :updating, when: "entity.step == 'updating'"
      branch to: :waiting, when: "entity.step == 'waiting'"
      branch to: :draining, when: "entity.step == 'draining'"
    end

    final :done, label: "Done"
    final :failed, label: "Failed"
  end

  # How the runs of runtime_upgrade are selected and imported: an ended one as completed
  # history, every other one into `requested`, from where its step moves it on.
  select(:runtime_upgrade,
    choices: [],
    admission: [],
    imports: [
      [when: [step: [:done]], state: :done],
      [when: [step: [:failed]], state: :failed],
      [when: [], state: :requested]
    ]
  )
end
