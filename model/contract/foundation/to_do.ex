defmodule Model.ToDo do
  @moduledoc """
  The To-Do: work no flow definition covers, inside or outside the platform (set up an
  account, tidy a text), assigned to a person or an agent like any assigned item. Atlas
  cannot verify such work, so done means its owner says it is done, with a note.

  How it reads:

    * a To-Do is assigned through its Assignment (`assigned_to`, a person or an agent), so
      it is under "Assigned to you" for a person, and an agent's Runtime starts a turn on
      it; while nobody is assigned, the configured decider owns it;
    * one deadline, its Assignment's (`deadline`, set when it is handed to someone, as
      for every assigned item); a To-Do has none of its own;
    * `open` presents "Do it" to its owner, with its `instructions` (required) shown in
      full under "Instructions", so the page, the TUI and an agent's guidance carry them;
    * only that owner moves it (the role `assignee`, made by the Assignment's
      `assigned_to`): Done with a note on how it was done, or Won't do with a note on why
      not. Facts refuses either without a note (`requires`), and refuses the choice from
      anyone the Assignment does not name;
    * no gate and no review, deliberately: Atlas cannot check the work;
    * a done one is not started again when its status is put back: only an explicit
      restart makes a new generation (`reopen: :explicit`).
  """
  use RelaDSL

  type(:to_do_status,
    values: [:open, :done, :wont_do],
    labels: [open: "Open", done: "Done", wont_do: "Won't do"]
  )

  entity :to_do,
    label: "To-Do",
    plural: "to_dos",
    id_type: :manual,
    id_prefix: "TD-",
    description: """
    Work outside the current flow definitions, inside or outside the platform, for a
    person or an agent. Atlas cannot verify it: it is done when its owner says so, with
    a note. The id is TD- and a number, e.g. TD-07.
    """ do
    field(:title, :string, required: true, description: "The work in a few words")

    field(:instructions, :string,
      required: true,
      description: "What to do, where, and what counts as done",
      multiline: true
    )

    field(:status, :to_do_status, description: "Open, done or won't do; its owner closes it")

    field(:note, :string,
      description: "The owner's closing note: how it was done, or why not",
      multiline: true
    )

    field(:evidence, :string, description: "Optional: a link, location or reference")

    primary(:title)
    plural_label("To-Dos")
    start(key: "t", label: "To-Dos")
    order(:newest)

    create(
      ask: [:title, :instructions],
      id: [prefix: "TD-", digits: 2],
      defaults: [status: :open]
    )

    completion([
      [field: :status, value: :done],
      [field: :status, value: :wont_do]
    ])

    requires(
      when: [status: [:done, :wont_do]],
      fields: [:note],
      error: "a To-Do is closed with a note: how it was done, or why it will not be"
    )
  end

  subflow :to_do, label: "To-Do", subject: :to_do do
    owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
    start :create
    initial :open

    state :open, label: "To do" do
      wait_for [:assignee], on: :status, reset: false, done: :done, wont_do: :wont_do

      present(
        expected: "Do it",
        why: "it is assigned to you",
        instructions:
          "Do what its instructions say, then close it: Done with a note on how it was done (and its evidence, if any), or Won't do with a note on why not. Atlas does not check it.",
        section: [field: :instructions, label: "Instructions"],
        answers: [
          [
            key: "x",
            label: "Done",
            note: true,
            change: %{values: %{status: :done, note: "$note"}}
          ],
          [
            key: "n",
            label: "Won't do",
            note: true,
            change: %{values: %{status: :wont_do, note: "$note"}}
          ]
        ]
      )
    end

    final :done, label: "Done"
    final :wont_do, label: "Won't do"
  end

  # How the runs of to_do are selected, imported and presented: on its Assignment, as for
  # every assigned item. Its owner's choice (status) counts only from the one its
  # Assignment's assigned_to names (the role assignee). It admits every To-Do; one closed
  # already is completed history, and an open one starts in `open`, as a new one does.
  select(:to_do,
    choices: [:status],
    roles: [assignee: :assigned_to],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [],
    imports: [
      [when: [status: [:done]], state: :done],
      [when: [status: [:wont_do]], state: :wont_do]
    ],
    reopen: :explicit
  )
end
