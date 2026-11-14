defmodule RelaDSL.Office.Clerk do
  @moduledoc "A neutral concept: who handles letters."
  use RelaDSL

  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field(:name, :string, required: true, description: "As it is shown")
    field(:away, :string, description: "Why it cannot work now", set_by: [:runtime])
    top(false)
    primary(:name)

    create(
      ask: [:name],
      id: [from: :name, pattern: "^([a-z]+)$", template: "{1}", error: "a name"]
    )
  end

  todo_words(title: "What to do", why: "Why", instructions: "How", answers: "Answers")
end

defmodule RelaDSL.Office.Desk do
  @moduledoc "Where a letter waits, and who holds it: the component of every letter."
  use RelaDSL

  entity :desk, label: "Desk", plural: "desks", id_type: :manual, id_prefix: "DK-" do
    field(:of, :string, required: true)
    field(:expected, :string, set_by: [:flow])
    field(:due, :datetime)
    field(:handover, :string)
    field(:flow_state, :string)
    top(false)
    late(after: :due, while: :expected, label: "late")
    start key: "d", label: "Desks"
  end

  relation(:held_by,
    label: "held by",
    description: "Who is next: one clerk.",
    from: [:desk],
    to: [:clerk],
    max_outgoing: 1,
    inverse: {:desks, "desks"},
    actions: [change: [key: "h", label: "Hand to…", with: [:due]]]
  )

  start_page(assigned: [relation: :held_by, title: "Yours", count: "{count} yours"])
end

defmodule RelaDSL.Office.Letter do
  @moduledoc "A neutral concept with a type, a kind, its rules, a gate, a subflow and its runs."
  use RelaDSL

  type(:letter_state,
    values: [:draft, :sent, :lost],
    labels: [draft: "Draft", sent: "Sent", lost: "Lost"],
    descriptions: [draft: "Being written", sent: "Out: it says so", lost: "Gone"]
  )

  type(:post_code,
    description: "A post code",
    validations: [[pattern: "^[0-9]{4}$", error: "four digits"]],
    format: :url
  )

  entity :letter,
    label: "Letter",
    plural: "letters",
    aliases: ["le"],
    id_type: :manual,
    id_prefix: "LE-",
    description: """
    One letter, written and posted.
    Its id is LE- and a number.
    """ do
    field(:title, :string, required: true, description: "What it is about: in short")
    field(:body, :string, description: "The text", multiline: true)
    field(:state, :letter_state, description: "on")
    field(:code, :post_code, unique: true)
    field(:urgent, :boolean, default: false, label: "Urgent")
    field(:gate_result, :string, set_by: [:flow])
    field(:choice, :string)
    primary(:title)
    order(:newest)
    create(ask: [:title, :body], id: [prefix: "LE-", digits: 2], defaults: [state: :draft])
    requires(when: [state: [:sent]], fields: [:code], error: "a sent letter has a code")
    frozen(when: [state: [:sent]], only: [urgent: [false]], error: "{key} is sent")

    replaces(
      relation: :replies_to,
      when: [state: [:sent]],
      of: [state: [:sent]],
      set: [state: :lost],
      error: "no"
    )

    action(key: "x", label: "Lose", to: "agent:lose", when: [state: [:sent]])
    delete_error("a letter is kept")
    flag(:urgent, value: true, label: "Urgent letter")
  end

  relation(:written_by,
    label: "written by",
    description: "Who wrote it.",
    from: [:letter],
    to: [:clerk],
    max_outgoing: 1,
    inverse: {:written, "written"},
    only_target: [error: "only the writer sets it"]
  )

  relation(:replies_to,
    label: "replies to",
    description: "The letters it answers.",
    from: [:letter],
    to: [:letter],
    inverse: {:replies, "replies"}
  )

  defgate :check,
    version: 1,
    flavor: :rule,
    purpose: :flow,
    evidence: [:pages],
    rule: [all: [{:equals, :pages, 1}]],
    verdicts: [:ok, :person],
    decide: [pass: :ok, changes_required: :person, uncertain: :person, error: :person],
    answer_within: [test: "1m", prod: "2d"]

  subflow :letter, label: "Letter", subject: :letter do
    run_as "system:post"
    owner via: :desk, relation: :held_by, default: {:clerk, :post_room}
    start :create
    initial :write

    state :write, label: "Write it" do
      gate :check, ok: :sent, person: :stuck
    end

    state :stuck, label: "Someone decides" do
      wait_for [:editor], on: :choice, reset: false, send: :sent, drop: :dropped
      timer :no_answer, {:gate_limit, :check}, to: :write
    end

    final :sent, label: "Sent"
    final :dropped, label: "Dropped"
  end

  select(:letter,
    choices: [:choice],
    roles: [editor: :written_by],
    projection: [on: :desk, state_field: :flow_state, owner_relation: :held_by, field: :expected],
    admission: [state: [:draft, :sent]],
    imports: [[when: [state: [:sent]], state: :sent]]
  )
end

defmodule RelaDSL.Office.Run do
  @moduledoc "The durable runs of the office's subflows and their inputs."
  use RelaDSL

  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field(:flow, :string)
    field(:state, :string)
    top(false)
    by_hand(false)
  end

  entity :input, label: "Input", plural: "inputs", id_type: :manual do
    field(:run, :string)
    field(:actor, :string)
    top(false)
    by_hand(false)
  end

  flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input)
end

defmodule RelaDSL.Office.Post do
  @moduledoc "The neutral module: everything of the post room."
  use RelaDSL.Module,
    path: "modules/post/schema.yaml",
    concepts: [
      RelaDSL.Office.Clerk,
      RelaDSL.Office.Desk,
      RelaDSL.Office.Letter,
      RelaDSL.Office.Run
    ]

  progress_order(order: [:draft, :sent], done_label: "Done")
end

defmodule RelaDSL.Office do
  @moduledoc "The neutral composition: the post room, its bindings, roles and subflow."
  use RelaDSL.Composition, name: "office"

  schema(
    version: "1.0",
    namespace: "https://example.invalid/office#",
    description: "The post room.\n",
    comment: "The office."
  )

  modules([RelaDSL.Office.Post])
  environments([:prod, :test])
  bindings(comment: "What the office binds.")

  relation(:desk,
    label: "desk",
    description: "The desk of a letter; made and deleted with it.",
    from: [:letter],
    to: [:desk],
    max_outgoing: 1,
    inverse: {:desk_of, "desk of"},
    component: [key: "DK-{key}", values: [of: "{key}"]]
  )

  extend_entity(:letter, start: [key: "l", label: "Letters"])

  extend_relation(:replies_to,
    review: [field: :state, value: :lost, label: "Answers a lost letter"]
  )

  review(:replies_to, field: :urgent, value: true, label: "Answers an urgent letter")
  about("What the office adds.")
  shell(title: "Office", tabs: [[id: "letters", label: "Letters", to: "/k/letter"]])

  acl(comment: "The roles the flows name.\n\nRela checks them.")
  role("post-flow", comment: "Post's writer.", read: ["*"], update: [:letter, :run])
  role("editor", read: ["*"], update: [:letter])
  assign("system:post", "post-flow")

  defcomposition :office do
    subflows([RelaDSL.Office.Letter])
  end
end
