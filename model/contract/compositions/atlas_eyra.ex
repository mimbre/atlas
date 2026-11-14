defmodule Model.AtlasEyra do
  @moduledoc """
  The composition Atlas runs: foundation with its audit, software and the product
  plan, bound together; the subflows that run on them and how their results reach one
  another; and the roles Rela checks the flows against.

  Each subflow runs on its own subject; what one reports to another is written here:

    * a pull request's review and test report their outcome to it (`review_outcome`,
      `test_outcome`); a result from a review or test that a newer one replaced is
      dropped;
    * a pull request reports to its issue (`pr_outcome`), which waits for it while it
      is built (`author`);
    * a use case counts its issues, and a scene its use cases (`children`, and
      `open_children`: those whose subflow has not ended), to know when all are built;
    * a decision tallies the work based on it (`work`), so its follow-through ends once
      something carries it out.

  `mix model.gen` generates the Rela project (`rela/`) and the targets from this module.
  """
  use RelaDSL.Composition,
    name: "atlas-eyra",
    subflow_behaviour: AtlasFlow.Subflow

  # The model Facts, Flow, Gates, Runtime and Control are wired to (config :atlas, model: …).
  @behaviour AtlasFacts.Model
  @behaviour AtlasFlow.Model
  @behaviour AtlasGates.Model
  @behaviour AtlasRuntime.Model
  @behaviour AtlasControl.Model

  alias Model.{
    Decision,
    FollowThrough,
    Issue,
    PrReview,
    PrTest,
    PullRequest,
    Scene,
    ToDo,
    UseCase
  }

  schema(
    version: "1.0",
    namespace: "https://eyra.co/ontology/atlas#",
    description: """
    The product plan of Atlas: scenes, their use cases, their issues and the
    pull requests of those issues, and the people who accept them.
    """,
    comment: "Selected Atlas Eyra composition. Definitions use native rela includes."
  )

  modules([Model.Foundation, Model.Foundation.Audit, Model.Software, Model.Eyra])
  environments([:prod, :test])

  bindings(
    comment:
      "Composition owns the complete list of assignable kinds, and what a gate verdict is about."
  )

  relation(:assignment,
    label: "assignment",
    description: "What belongs to being assigned, for one fact; made and deleted with it.",
    from: [:scene, :use_case, :issue, :pull_request, :decision, :to_do],
    to: [:assignment],
    max_outgoing: 1,
    inverse: {:assignment_of, "assignment of"}
  )

  relation(:based_on,
    label: "based on",
    description: "The decisions this work carries out; optional, most work has none.",
    from: [:scene, :use_case, :issue, :to_do],
    to: [:decision],
    inverse: {:work, "work"}
  )

  relation(:about,
    label: "about",
    description: "The fact a gate verdict decided on; any kind the composition has.",
    from: [:gate_verdict],
    to: [:scene, :use_case, :issue, :pull_request, :decision],
    max_outgoing: 1,
    inverse: {:gate_verdicts, "gate verdicts"}
  )

  about(
    "Atlas's additions to rela's description: rules the current rela cannot hold, because it refuses unknown keys in schema.yaml. Facts merges this file into the description it answers, key by key; Control applies the rules for any kind. Data, not code: no BEAM module names a kind. Per kind: create.ask = the only fields a create form asks for; create.id = how the id is made: prefix plus the next free number, zero-padded to digits; or from a property (from), whose value must match pattern, with template filled from its groups ({1}, {2}, ...) after replace, in lower case when lower is true, and error when it does not match; the same value always makes the same id; nobody ever types or changes an id, nor the property it is made from; create.defaults = values for the fields create does not ask; properties.<name>.set_by = a field only a connector or the system fills (never in a form, shown only when it has a value); properties.<name>.multiline = true for text of several lines and sections (a form edits it in a multi-line editor; the line breaks are kept); properties.<name>.label = the name a page shows for the field instead of its own. progress = how far an item is, worked out from the items under it on every read, never stored, and shown in lists instead of its own field: over = the relation whose items point at it, field = the property that says how far such an item is (for a kind without a rule of its own), own = its own property, shown while nothing is under it, while = what it shows instead while something holds, shaped as a completion rule (over or through, field, value) plus shows (an issue shows development while one of its pull requests is open; nothing is stored, and a closed pull request no longer counts). The top-level progress gives the order of the values (least far first; the least far child wins), done_label = what a list shows for an item that is completed itself (never because its children are), to_test = the value and label of an item whose children are all completed while it is not. completion = how an item is completed, worked out on every read, never stored: one way or a list of ways, any of which completes it: by = it has a link through that association (someone accepted it); over, field, value = an item pointing at it through that relation has that value (one of its pull requests is merged); through, field, value = an item it points at through that relation has that value. plural_label = the name a list of its facts has, instead of its plural (To-Dos). primary = the property that names a fact in a list and on its page (when it is empty, the property the id is made from names it); connector = an outside system's connector fills this kind, read-only: system (which connector), address (the property that says where the outside thing is), fields (property: the outside system's field it is copied from), until (property: values; a fact with one of these values is read no more), names (field, relation, when: the keys a fact's field names, of the relation's from kind, get a link to it through relation while its values match when; a merged pull request whose title names other issues is also done for them). Per relation: relations.<name>.parent = true for a relation by which a fact belongs under another (at most one; its page goes back there, a create adds under it); every other relation is an association, a concept a kind has by being in its from (accepted_by: completable), shown with the fact that set it and set through its own form; relations.<name>.component = {key, values}: Facts makes the one fact this relation points at in the same write as the fact, before it, and deletes it with the fact (d-0022: every assignable thing has an Assignment); key and values are made from the fact's key ({key}); a fact's page and atlas get show the component's fields and associations as the fact's own, and setting such an association on the fact sets it on its component. relations.<name>.set_by = an association only a migration or connector sets: shown, never in a form, refused by Control. relations.<name>.only_target = only a client that is one of the facts the association points at sets or removes it, and only to itself (error says why to anyone else; also = clients that may anyway, such as the migration); actions.set and actions.remove = the label and key of the page's action that does so (Accept until it is set, Reopen after, on the same key; remove asks for a note); actions.change = {label, key, with, cause}: an action, whether a link is there or not, that opens the association's form, which also asks the fields named in with of the fact that holds the link (its component, such as the deadline of an Assignment) and stores them with the link in one change; cause is its cause when the form's note is empty, with {to} (the keys, or nobody) and {by} (who) filled in; a note is the cause as it is given (Hand to…); requires_completed_children = set is refused while a fact under it is not completed ({key}, {children}); closes_parent = a new fact under one that has the link, by a create or a move, is refused ({parent}, {kind}). Per kind: top = false for a kind that is not on the start page, reached only through the facts that point at it. Per type: types.<name>.format = \"url\" for values that are web addresses (rela has no such type); Control offers to open a fact's first such field in a browser. relations.<name>.limit = how many facts may point at one parent through it, counting only those whose field is one of values (max, field, values); a new link (a create under the parent, or a move to it) is refused when that many are there already, with error, where {parent}, {child} and {value} (the label of its field's value) are filled in; links that are there already stay. Agent records (UC-Atlas-19): agent = \"request\" or \"step\" names the kinds the agent keeps its requests and steps in (the agent never puts them as tools); start = {key, label} puts an action on the start page that opens the kind's list (with top = false, the kind itself is not there); counts = [{relation, text}]: each row of the kind's list counts the facts that point at it through relation, shown as text with {count} filled in (an agent: 3 assigned); order = \"newest\" lists a kind newest first; by_hand = false: no keys to make, change or delete one (the agent writes it); \"update\": only a key to change one (an Assignment is made and deleted with its fact); late = {after, while, label} (after and while are fields of the kind): a fact is late, worked out on every read and never stored, while the time in its field after has passed and its field while is not empty (an Assignment: past its deadline while something is expected, so not done); pages show label after that field, and lists show both; properties.<name>.cause = true or a title: an item page lists the facts of this kind whose field holds the item's key; relations.<name>.add = false: a page lists the facts of that relation without an action to add one; actions = [{key, label, to, when}]: more actions on a fact's page, only while its fields have one of the values in when; a to of agent:<intent> asks the agent (the TUI's : with that intent) instead of opening a page. The start page (IS-Atlas-55): start.assigned = {relation, title, count, empty}: a client that is a fact of a kind the relation points at (a person at the TUI) opens on what points at it through the relation (its Assignments), each shown as the fact it is the component of, while that fact is open, newest link first, with what its flow expects and since when and why; count is the header's text, with {count}; empty says what fills it. start.open = {title, empty} (IS-Atlas-85): the list of the kind the start's relation starts at (its start action, Open work) is the same list for everyone: every open fact someone is assigned to or something is expected of, with whoever it is assigned to, what is expected and its deadline, late first, then the newest link; what is assigned to one client is this list filtered on it. What to do (IS-Atlas-54): a state's todo = {instructions, section, answers}: a fact's page shows its owner (and atlas get, a client that is the owner) a What to do part above the rest: what is expected, why it came to them, the instructions, the section of the fact's field that section names ({field, heading}: the text from a line that starts with the heading to the next heading), and the answers (key and label) the owner can give. An answer (IS-Atlas-56) is an action on the page and in the footer, for the owner only: set = an association it sets to the owner (accept), remove = one it removes, with a note as its cause, also when it is not set (reject: the newest fact about it removed it, which a flow reads as reopened). The top-level todo = {title, why, instructions, answers}: the words of that part, its title and labels. Runtime (IS-Atlas-15): runtime.turn.outcome names the agent-written outcome Runtime reads to end the turn; a projection's handover_field (flow-runtime.json) is an internal text field holding a deferred owner handover and its original owner link position, hidden from pages, so a later manual assignment cancels it. runtime.turn names the kind Runtime keeps its turns in and its parts: kind, key (made from on, the item's key, and n, the turn's number on it), on and by (the relations to the item and to the agent), state (with its running and ended values), machine, lease (until when it holds its lease), activity (what the agent last did), why (why it ended) and ended_at (when); optionally title (what a turn without an item is about) and model (the model the agent runs), which Runtime fills when it knows them. runtime.agent names the agent kind's field where Runtime says it cannot run on a machine (cannot_run: after 3 crashes in 10 minutes, cleared once that is no longer so; IS-Atlas-18). Runtime runs turns on the facts a selected subflow's projection writes on (its on, or its subject), for owners through its owner_relation that are the agents its machine runs, while Facts presents the work on them as open. Decision rules (Facts refuses a write that breaks one; Control asks nothing of them): requires = [{when, fields, error}]: a fact whose values hold when (as a state's values) must have each of fields; authority = {when, by, kind, agent_kind, decider, error, writes, writer_error, also}: a fact that holds when links through by to one fact of kind, or of agent_kind when the newest decider verdict for its subject and fingerprint permits an agent; decider names gate, relation, verdict kind and fingerprint fields and relations; a write that sets a value of writes is stored only from the writer (its by, as Control says) that by links to, and only when that one may decide it so, or from one of also (writer_error); layering = {relation, field, not, error}: a fact whose field is a key of not never links through relation to one whose field is one of its values, nor takes such a value while such a fact links to it; frozen = {when, only, tallied, error}: a fact that holds when is never deleted, and a change may only set the fields of only to one of their values ({key}, {value}), and those of tallied (a count only Flow keeps on it: the work based on a decision) to any; replaces = {relation, when, of, set, error}: a fact stored holding when sets set on every fact it links to through relation in the same write, each of which must hold of. create.id.first = the lowest number the next free key takes. sealed = {once, links, error, once_error}: a record (a gate verdict) is immutable once written: never deleted, and a change keeps every property and link it has (error, with {key} and {field}), except each of once (a property or relation) and, with links = \"once\", every relation, which is set while it is empty and then kept (once_error). relations.<name>.review = {field, value, label}: a fact that links through the relation to one whose field has that value is to be reviewed, worked out on every read and never stored (work based on a superseded decision); pages show label with that fact's key and value, and lists show label and key first. read_first = {title, through, then, standing, tags, text} (atlas turn, and the fixed context Runtime gives a worker): plain text a worker reads before it acts on its item: the facts the item points at through through (the decisions it is based on), each with those it points at through then (what they follow from), and, per standing group in order (title, first, when), the facts of that kind whose values hold its when, each fact once: first = true lists a group before those (accepted principles, whatever their scope), the others after (accepted guidelines and guardrails of the scopes that apply); one line each: key, primary field, the values of tags, and text, shortened."
  )

  start_page(
    assigned: [
      empty:
        "Nothing is assigned to you now. Flow assigns you what is your move (to test it, say), and anyone can with assigned_to. s opens the scenes."
    ]
  )

  shell(
    title: "Atlas Console",
    tabs: [
      [id: :assigned, label: "Assigned to you", to: "/", assigned: true],
      [id: :scenes, label: "Scenes", to: "/k/scene"],
      [id: "open-work", label: "Open work", to: "/k/assignment"]
    ]
  )

  read_first(
    title: "Read these decisions first.",
    through: :based_on,
    then: :follows_from,
    standing: [
      [
        title: "Principles, never broken",
        first: true,
        when: [status: [:accepted], force: [:principle]]
      ],
      [
        title: "Guidelines and guardrails that apply",
        when: [
          status: [:accepted],
          force: [:guideline, :guardrail],
          scope: [:platform, :software]
        ]
      ]
    ],
    tags: [:force, :status],
    text: "decision"
  )

  extend_entity(:scene,
    start: [key: "s", label: "Scenes"],
    create: [id: [prefix: "SC-Atlas-", digits: 2]]
  )

  extend_entity(:use_case, create: [id: [prefix: "UC-Atlas-", digits: 2]])

  extend_entity(:issue,
    create: [id: [prefix: "IS-Atlas-", digits: 2], defaults: [stage: :specification]],
    completion: [
      [over: :in_issue, field: :state, value: :merged],
      [through: :done_in, field: :state, value: :merged]
    ],
    progress: [
      own: :stage,
      while: [[over: :in_issue, field: :state, value: :open, shows: :development]]
    ]
  )

  extend_entity(:assignment, start: [key: "l", label: "Open work"])
  extend_entity(:agent, start: [key: "g", label: "Agents"])

  extend_entity(:pull_request,
    connector: [names: [field: :title, relation: :done_in, when: [state: [:merged]]]]
  )

  extend_entity(:agent_request,
    start: [key: "w", label: "What the agent did"],
    create: [id: [prefix: "RQ-Atlas-", digits: 2]]
  )

  extend_entity(:agent_step, create: [id: [prefix: "ST-Atlas-", digits: 2]])

  extend_relation(:assignment,
    component: [key: "AS-{key}", values: [of: "{key}"]],
    set_by: [:migration]
  )

  extend_relation(:in_issue,
    limit: [
      max: 1,
      field: :state,
      values: [:open, :merged],
      error:
        "{parent} already has {child} ({value}); an issue is one change: close that PR first, or make a new issue"
    ]
  )

  extend_relation(:based_on,
    review: [field: :status, value: :superseded, label: "Review: based on a superseded decision"]
  )

  # Work based on a decision an agent decided unverified is to be reviewed.
  review(:based_on, field: :unverified, value: true, label: "Based on unverified decisions")

  acl(
    comment: """
    The roles the flows (flows.yaml, generated from model/contract) name, so rela can check
    them: `rela --project rela validate` checks every role a flow names and the grants of
    its run_as. Rela defines and checks the flows; Atlas Flow runs them (D-0068).

    This file is not part of the selected closure that startup and packaging copy into a
    running rela (scripts/config.py): rela-server keeps running without access control on
    its loopback or private bind, and with no flows.yaml (start-test.sh). Who holds a role
    is not decided here: the people come with the owner role work (Flow DSL design, 8).
    """
  )

  role("atlas-flow",
    comment: "Atlas Flow (system:atlas-flow) writes each mechanism's result and moves the runs.",
    read: ["*"],
    create: [:flow_run, :flow_input],
    update: [
      :flow_input,
      :flow_run,
      :issue,
      :pull_request,
      :pr_review,
      :pr_test,
      :use_case,
      :scene,
      :decision
    ]
  )

  role("sf-flow",
    comment: "The principal flows run their outputs as: resets, created reviews and tests.",
    read: ["*"],
    create: [:pr_review, :pr_test],
    update: [:issue, :pull_request, :pr_review, :pr_test, :use_case, :scene, :decision]
  )

  role("maintainer",
    read: ["*"],
    update: [:issue, :pull_request, :pr_review, :pr_test, :use_case]
  )

  role("reviewer", read: ["*"], update: [:pr_review])
  role("tester", read: ["*"], update: [:pr_test])
  role("acceptor", read: ["*"], update: [:use_case, :scene])
  role("decider", read: ["*"], update: [:decision])
  role("principle_authority", read: ["*"], update: [:decision])
  role("delegate", read: ["*"], update: [:decision])
  role("assignee", read: ["*"], update: [:to_do])

  assign("system:atlas-flow", "atlas-flow")
  assign("system:sf-flow", "sf-flow")

  defcomposition :atlas_eyra do
    subflows([
      Issue,
      PullRequest,
      PrReview,
      PrTest,
      UseCase,
      Scene,
      Decision,
      FollowThrough,
      ToDo
    ])

    link(:pr_review,
      to: {:pull_request, :review_of},
      field: :review_outcome,
      states: [approved: :approved, changes_requested: :changes_requested],
      stale: :drop,
      current: {:revision, :revision}
    )

    link(:pr_test,
      to: {:pull_request, :test_of},
      field: :test_outcome,
      states: [passed: :passed, failed: :failed],
      stale: :drop,
      current: {:revision, :revision}
    )

    link(:pull_request,
      to: {:issue, :in_issue},
      field: :pr_outcome,
      states: [changes_requested: :changes_requested, integrated: :integrated, closed: :closed]
    )

    count(:issue, to: {:use_case, :in_use_case}, all: :children, open: :open_children)

    count(:test_and_accept_use_case,
      to: {:scene, :in_scene},
      all: :children,
      open: :open_children
    )

    # An accepted decision's work: every scene, use case and issue based on it.
    tally(to: {:decision, :based_on}, all: :work)
  end
end
