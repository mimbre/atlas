defmodule AtlasBFFContract.Models.Presentation do
  @moduledoc "Shared block, Console and session payload models."
  use AtlasBFF.Schema
  version "0.15.0"
  models_from(AtlasBFFContract.Models.Workers)

  # Something the user can do from a block: open `to`. `key` is the key a keyboard
  # client binds it to; other clients may show it as a button.
  defmodel :action do
    field :label, :string, required: true
    field :key, :string, required: true
    field :to, :string, required: true
  end

  # A web address the user can open outside the client, in a browser: `url`. `key` is
  # the key a keyboard client binds it to. A client opens only http and https addresses.
  defmodel :link do
    field :label, :string, required: true
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
  defmodel :row do
    field :id, :string
    field :label, :string, required: true
    field :detail, :string
    field :to, :string, required: true
    field :links, {:list, :link}
    field :key, :string
    field :pending, :boolean
  end

  # The fact that set a value: since when (ISO 8601, UTC), by whom (a key), and why.
  defmodel :origin do
    field :since, :string
    field :by, :string
    field :cause, :string
  end

  # A labelled value, with the fact that set it when that is known.
  defmodel :pair do
    field :label, :string, required: true
    field :value, :string
    field :origin, :origin
  end

  # A value an input may take, and how to show it.
  defmodel :choice do
    field :value, :string, required: true
    field :label, :string, required: true
  end

  # One input of a form. `kind` is text (one line, wrapped when long), multiline (lines
  # and sections; enter starts a new line), choice, boolean or readonly (shown, never
  # changed, such as an id); values travel as text. A client that does not know a kind
  # edits it as text.
  defmodel :input do
    field :name, :string, required: true
    field :label, :string, required: true
    field :kind, :string, required: true
    field :value, :string
    field :required, :boolean
    field :hint, :string
    field :choices, {:list, :choice}
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
    field :label, :string, required: true
    field :state, :string, required: true
    field :why, :string
    field :detail, :string
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
  end

  defmodel :console_scope do
    field :page, :string, required: true
    field :revision, :string, required: true
    field :context, :string, required: true
    field :on, :string
    field :row, :string
  end

  # Native shell metadata, independent of page blocks and terminal key bindings.
  defmodel :shell_tab do
    field :id, :string, required: true
    field :label, :string, required: true
    field :to, :string, required: true
  end

  defmodel :boot_request do
    field :to, :string
  end

  defmodel :shell do
    field :title, :string, required: true
    field :env, :string, required: true
    field :spec, :string, required: true
    field :revision, :string, required: true
    field :tabs, {:list, :shell_tab}, required: true
    field :initial_to, :string, required: true
    field :active_tab, :string
  end

  defmodel :boot_error do
    field :error, :string, required: true
  end

  # A client's first message: its environment, what it is, and the contract version it
  # implements. Control of another environment, or one newer than the client's version,
  # answers bye and closes; else welcome, then its start page. `as`: the key of the fact
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

  defmodel :bye do
    field :text, :string, required: true
  end

  # A line for the status bar: pending (until Facts answers), ok, error or info.
  defmodel :notice do
    field :tone, :string, required: true
    field :text, :string, required: true
    field :at, :string
  end

  defmodel :turn_context do
    field :key, :string
    field :on, :string
    field :error, :string
  end

  defmodel :turn_outcome do
    field :key, :string, required: true
    field :outcome, :string, required: true
  end

  # The agent behind a client's `:` (today `atlas steer`, which the client starts; later
  # Control): ask for a plan made on the page at `on`, run its kept steps, cancel, stop.
  # It answers the plan block, after every change, and notices.
  defmodel :ask do
    field :request, :string, required: true
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
