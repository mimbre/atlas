defmodule AtlasBFFContract.Models.Presentation do
  @moduledoc "Shared block, Console and session payload models."
  use AtlasBFF.Schema
  version "0.47.0"

  models_from(AtlasBFFContract.Models.Workers)

  # Something the user can do from a block: open `to`. `key` is the key a keyboard
  # client binds it to; other clients may show it as a button. `page`: the action is the
  # page's (what is done with the page's subject: create one, the fact's next step), not
  # its block's; a client shows it with the page's title, not under the block. `icon`: what
  # kind of thing the action does, by name (edit, delete, hand_over, create, open), which a
  # client may show as an icon; one it does not know it shows without. `button`: what a
  # client that shows it as a button says on it, when that is not its `label` (`Hand to`
  # for `Hand to…`): a button says nothing of what follows its click. `help` (since
  # 0.41.0): what the action does, in full, which a client shows as its tooltip (without
  # it, its label).
  defmodel :action do
    field :label, :string, intent: :label, required: true
    field :key, :string, required: true
    field :to, :string, required: true
    field :submit_to, :call
    field :page, :boolean
    field :icon, :string
    field :button, :string, intent: :label
    field :help, :string, intent: :body
  end

  # A line of an `instruction` block, in order: `kind` `text` (its `text`, the lines
  # between two commands or routes, kept with their breaks), `command` (its `text`, a line
  # to run as it is, the instructions' `$ ` taken off) or `route` (its `parts`, the way to
  # something in an app, `> Keychain Access > login`, without the ` > ` between them).
  defmodel :instruction_line do
    field :kind, :string, required: true
    field :text, :string, intent: :body
    field :parts, {:list, :string}, intent: :label
  end

  # One part of a panel's byline (`panel`): `text`, and with `since` (ISO 8601, UTC) how
  # long ago that was, which a client shows after the text ("waiting 3h"; the age alone
  # when the text is empty) and keeps current.
  defmodel :clause do
    field :text, :string, intent: :body, required: true
    field :since, :string
  end

  # One of the items a panel is judged on: the fact (`key`, `label`) and its page (`to`);
  # `details`, what a client shows of the selected one.
  defmodel :panel_item do
    field :key, :string, required: true
    field :label, :string, intent: :label, required: true
    field :to, :string, required: true
    field :details, {:list, :pair}
  end

  # One check a panel is judged on: its `label`, its `state` (success, error, pending or
  # none: not known) and what it says (`text`, "—" when not known).
  defmodel :check do
    field :label, :string, intent: :label, required: true
    field :state, :string, required: true
    field :text, :string, intent: :body, required: true
  end

  # A framed text of a panel; `tone` error: something went wrong.
  defmodel :box do
    field :title, :string, intent: :title, required: true
    field :text, :string, intent: :body, required: true
    field :tone, :string
  end

  # One answer of a panel (as its page's action of the same key gives it), of an
  # `answers` block (the page's action itself, on its key) or of an `option`: opening
  # `to`, or `submit_to` at once. `note`: given with a note saying why, as `to`'s form
  # asks it. `weight`: how much the answer weighs among the page's answers: `main` (the
  # positive one, exactly one per page: Done, Choose the recommended, Accept), `decline`
  # (the declining one, at most one: Won't do, Decline, Decline all; `no` before 0.38.0,
  # deprecated: a client takes it as `decline`) or `other`; a client styles an answer by
  # it, never by `note`. `button`: what a client that shows it as a button says on it,
  # when that is not its `label` (no `…`); a note it asks opens on the click, the button
  # does not say so. `detail`: a short explanation shown with it (Decline: what declining
  # keeps). `icon` (since 0.39.0): what it does, by name (question, hand_over, delegate, decline),
  # which a client may show as an icon; one it does not know it shows without. `help`
  # (since 0.41.0): what the answer does, in full, which a client shows as its tooltip
  # (without it, its label).
  defmodel :panel_answer do
    field :label, :string, intent: :label, required: true
    field :key, :string, required: true
    field :to, :string, required: true
    field :submit_to, :call
    field :note, :boolean
    field :weight, :string
    field :button, :string, intent: :label
    field :detail, :string, intent: :body
    field :icon, :string
    field :help, :string, intent: :body
  end

  # A web address the user can open outside the client, in a browser: `url`. `key` is
  # the key a keyboard client binds it to. A client opens only http and https addresses.
  defmodel :link do
    field :label, :string, intent: :label, required: true
    field :key, :string, required: true
    field :url, :string, required: true
  end

  # One line of a list; opening it opens `to`. Its links are for the row while it is
  # selected.
  # `id` is the item's id, which a client shows first, in a column of its own.
  # `key` is the key of the fact the row opens (Control takes it from `to`): an opaque
  # identity a client keeps the selection on when a page replaces the list, and compares
  # with nothing else. `pending` (set only by Control) says a write to that fact is stored
  # but not yet settled; a client shows it next to the label and never sets or clears it.
  # `tone` is where the row's work stands for the viewer, one meaning on every list (Control
  # decides it): "attention" (the next step is the viewer's), "active" (under way: someone
  # else, or an agent, is at it), "waiting" (planned, or waiting on someone or something
  # else), "done". Left out where Control cannot tell. A client shows it as a mark beside
  # the row, never instead of the row's own words. `since` (ISO 8601, UTC) is when the row
  # entered the state it is in, so a client can say how long it has been there. `kind` is
  # the kind of the item the row opens, in plain words (its label, "Decision"), so a client
  # can say what the row is; `icon` is that kind's icon, a semantic name the model gives the
  # kind (`scales`, `checklist`), the same on its page's header and its tab, which a client
  # draws as it likes and leaves out when it does not know it.
  defmodel :row do
    field :id, :string
    field :label, :string, intent: :label, required: true
    field :detail, :string, intent: :body
    field :to, :string, required: true
    field :links, {:list, :link}
    field :key, :string
    field :pending, :boolean
    field :tone, :string
    field :since, :string
    field :kind, :string, intent: :label
    field :icon, :string
  end

  # One group of a `groups` block: its name, how many items it has, the page that shows
  # only them (`to`), and whether it is the one this page shows (`active`).
  defmodel :group do
    field :label, :string, intent: :label, required: true
    field :count, :integer, required: true
    field :to, :string, required: true
    field :active, :boolean
  end

  # The fact that set a value: since when (ISO 8601, UTC), by whom (a key), and why.
  defmodel :origin do
    field :since, :string
    field :by, :string
    field :cause, :string
  end

  # A labelled value, with its origin and optional syntax (markdown; otherwise plain).
  defmodel :pair do
    field :label, :string, intent: :label, required: true
    field :value, :string, intent: :body, syntax: :markdown
    field :syntax, :string
    field :origin, :origin
  end

  # A value an input may take, and how to show it; `help` (since 0.41.0): what choosing it
  # means, in full, which a client shows as its tooltip.
  defmodel :choice do
    field :value, :string, required: true
    field :label, :string, intent: :label, required: true
    field :help, :string, intent: :body
  end

  # The input and value another input depends on (`input`'s `shown_when`).
  defmodel :input_condition do
    field :name, :string, required: true
    field :value, :string, required: true
  end

  # One input of a form. `kind` is text (one line, wrapped when long), multiline (lines
  # and sections; enter starts a new line), choice, boolean or readonly (shown, never
  # changed, such as an id); values travel as text. A client that does not know a kind
  # edits it as text. A `required` input needs a value before the form is sent: a client
  # keeps its submit disabled until each shown one has one, and Control refuses it
  # without; a required choice without a `value` has nothing chosen until the user
  # chooses. `shown_when` (since 0.41.0): the input is shown, and asked, only while the
  # input it names holds that value; a client sends no value for it otherwise.
  defmodel :input do
    field :name, :string, required: true
    field :label, :string, intent: :label, required: true
    field :kind, :string, required: true
    field :value, :string
    field :required, :boolean
    field :hint, :string, intent: :body
    field :choices, {:list, :choice}
    field :shown_when, :input_condition
  end

  # A call of one of the contract's endpoints: its name and its parameters, by name. A
  # client sends it as it is: {"op": "submit", "endpoint": ..., "params": ..., "values": ...}.
  defmodel :call do
    field :endpoint, :string, required: true
    field :params, {:map, :string}
  end

  # One step of an agent's plan: the form it fills (`label`, its title; `inputs`, its
  # inputs with the values the step gives them), why, and how far it got. `state` is
  # proposed, blocked (it cannot run; `detail` says why), dropped, running, stored,
  # refused or not_run. `detail` is what happened: the id it stored, or why not.
  defmodel :step do
    field :n, :integer, required: true
    field :label, :string, intent: :label, required: true
    field :state, :string, required: true
    field :why, :string, intent: :body
    field :detail, :string, intent: :body
    field :inputs, {:list, :input}
  end

  # Opt-in Console presentation. These are auxiliary action content, not page layout.
  defmodel :console_operation do
    field :name, :string, required: true
    field :to, :string
    field :url, :string
    field :intent, :string
    field :execution, :runtime_execution
    field :cursor, :string
    field :interaction_source, :string
    field :call, :call
  end

  defmodel :console_scope do
    field :page, :string, required: true
    field :revision, :string, required: true
    field :context, :string, required: true
    field :on, :string
    field :row, :string
  end

  # Native shell metadata, independent of page blocks and terminal key bindings. `icon`
  # is a semantic name a client may draw as it likes (a Mac app: a symbol): the model's,
  # else, for a tab that lists one kind, that kind's icon (as on its rows), else one
  # Control derives from the page the tab opens (assigned, supervised, open, workers);
  # `section` is
  # what the tab is for: "work" (what needs someone; the tabs a client cycles through) or
  # "browse" (reference, after them); `key`, a browse tab's own key sequence (as "g s"),
  # which the console projection binds to opening it; `count` is the page's All, as its
  # `groups` block says it; `for_you`, whether that
  # count is what waits for the viewer (what is assigned to them), not a plain count.
  defmodel :shell_tab do
    field :id, :string, required: true
    field :label, :string, intent: :label, required: true
    field :to, :string, required: true
    field :section, :string, required: true
    field :key, :string
    field :icon, :string
    field :count, :integer
    field :for_you, :boolean
  end

  defmodel :boot_request do
    field :to, :string
  end

  # `greeting`: the words a client greets its viewer with, the viewer's name filled in,
  # for a viewer the start's assigned relation points at, when the model words
  # one; `name`, that viewer's name (none for an agent or a migration). Control reads the
  # name once at boot, so it is part of the shell's revision. `assistant` (0.43.0): the
  # line a client shows under that name, the agent that assists the viewer in the
  # model's words ("assistant: coordinator"); none when no such agent assists them.
  defmodel :shell do
    field :title, :string, intent: :title, required: true
    field :env, :string, required: true
    field :spec, :string, required: true
    field :revision, :string, required: true
    field :tabs, {:list, :shell_tab}, required: true
    field :initial_to, :string, required: true
    field :active_tab, :string
    field :greeting, :string, intent: :body
    field :name, :string, intent: :label
    field :assistant, :string, intent: :label
  end

  defmodel :boot_error do
    field :error, :string, intent: :body, required: true
  end

  # A client's first message: its environment, what it is, and the contract version it
  # implements. Control of another environment answers bye and closes; else, whatever
  # version the client says (D-0105), welcome with Control's, then its start page. `as`: the key of the fact
  # an agent client is (an agent's, such as coordinator), when it says so; no sign-in yet.
  defmodel :hello do
    field :surface, :string
    field :env, :string, required: true
    field :client, :string, required: true
    field :spec, :string, required: true
    field :as, :string
  end

  defmodel :welcome do
    field :surface, :string
    field :env, :string, required: true
    field :spec, :string, required: true
  end

  # Why Control closes. Until 0.32.0, `reason` "too_old" with `spec` (Control's contract)
  # closed a client older than Control; from 0.33.0 Control welcomes any version (D-0105).
  defmodel :bye do
    field :text, :string, intent: :body, required: true

    field :reason, :string,
      deprecated: "never sent: Control closes no client for its version (D-0105)"

    field :spec, :string, deprecated: "never sent: the welcome says Control's version (D-0105)"
  end

  # A line for the status bar: pending (until Facts answers), ok, error or info.
  defmodel :notice do
    field :tone, :string, required: true
    field :text, :string, intent: :body, required: true
    field :at, :string
  end

  defmodel :turn_context do
    field :key, :string
    field :on, :string
    field :error, :string, intent: :body
  end

  defmodel :turn_outcome do
    field :key, :string, required: true
    field :outcome, :string, required: true
  end

  # The agent behind a client's `:` (today `atlas steer`, which the client starts; later
  # Control): ask for a plan made on the page at `on`, run its kept steps, cancel, stop.
  # It answers the plan block, after every change, and notices.
  defmodel :ask do
    field :request, :string, intent: :body, required: true
    field :on, :string, required: true
    field :intent, :string
  end

  defmodel :run_step do
    field :n, :integer, required: true
    field :values, {:map, :string}
  end

  defmodel :run do
    field :steps, {:list, :run_step}, required: true
  end
end
