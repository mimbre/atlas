defmodule AtlasControl.Model do
  @moduledoc """
  The model Control serves pages for: a module the domain compiles, wired by
  configuration at boot:

      config :atlas, model: SomeModel

  Control reads it when it starts; a missing module, or one without these callbacks,
  refuses the start. Control names no model and no kind: every title, field, choice,
  rule and word on a page is the model's, or the fact's.

  Besides its own callbacks, Control calls three that the component that runs turns
  declares (`turn/0`, `guidance/0` and `read_first/2`): the turn a worker is in, the
  durable guidance records, and what a worker reads first. A model implements them once.
  """

  @typedoc "Who views a page: the client's key, and the kind of fact it is (or nil)."
  @type viewer :: %{key: String.t() | nil, kind: String.t() | nil}

  @typedoc "Facts' answer to a read."
  @type answer :: map

  @doc """
  The native shell: `%{"title", "tabs"}` (each tab `%{"id", "label", "to"}`, and
  `"assigned"` for the start page of assignments), with the tabs the environment's
  settings add (`settings["tabs"]`), after the model's; nil when the model has none.
  """
  @callback shell(settings :: map) :: nil | map

  @doc """
  What a client opens on: `%{assigned, open, actions}`. `assigned` is nil or `%{relation,
  title, empty, count}`: a client that is a fact of a kind `relation` points at opens on
  what points at it through it; `open` is nil or `%{title, empty, expected}`: the list of
  a kind the relation starts at shows every open fact, for everyone, where `expected`
  are the fields a flow writes what is expected in; `actions` (`%{kind, key, label}`)
  open a kind's list from the start page.
  """
  @callback start_page() :: map

  @doc """
  Every kind, sorted by name: `%{name, label, plural, about, top, newest_first, primary,
  id, fields, relations, counts, progress, shows_progress, progress_from, done_label,
  late, start, agent, delete_error, hidden, expected}`. `id` is `%{prefix, digits,
  first, from, template, prefixes}`; `fields` are in the order pages show them, each
  `%{name, label, type, values, labels, required, hint, settable, set_by, multiline,
  url, cause}`; `relations` are those that start at the kind, sorted by name, each
  `%{name, label, description, from, to, one, parent, inverse_label, component, set_by,
  only_target, set, remove, change, requires_completed_children, closes_parent, limit,
  add}`.
  """
  @callback kinds() :: [map]

  @doc """
  What a create (`:create`) or change (`:edit`) form of `kind` asks: `%{ask, defaults,
  made_from, decides}`, where `made_from` is the field the id is made from (never
  changed) and `decides` is nil or `%{relation, writes}`: a change that sets a value of
  `writes` links the client that makes it through `relation`. Nil for no kind.
  """
  @callback form(kind :: String.t(), :create | :edit) :: nil | map

  @doc "The key of a new fact of `kind` whose id is made from a field of `values`."
  @callback key(kind :: String.t(), values :: map) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  With `fact` nil, the operations `kind` offers by hand (`:create`, `:update`,
  `:delete`). With a fact, the actions its page offers: `%{op: :update | :delete}`, and
  each the model adds, `%{label, key, to}`.
  """
  @callback actions(kind :: String.t(), fact :: nil | map, viewer) :: [atom | map]

  @doc """
  What the owner of `fact` is to do, for a `viewer` that is its owner, or nil: `%{title,
  expected, why, instructions, section, answers, words}`. `parts` are the facts the fact
  is made with (its components), by kind, as Control read them.
  """
  @callback todo(kind :: String.t(), fact :: map, parts :: map, viewer) :: nil | map

  @doc """
  The change the owner's answer `name` writes on `item` (`%{"fact", "parts"}`):
  `{:write, %{"values", "self", "label", "note"}}`, or `{:refuse, why}`.
  """
  @callback answer(kind :: String.t(), name :: String.t(), item :: map, viewer) ::
              {:write, map} | {:refuse, String.t()}

  # The callbacks of the component that runs turns that Control calls too, and the
  # configured actors the model's owners name (the flow runner's `actors/0`).
  @shared [turn: 0, guidance: 0, read_first: 2, actors: 0]

  @doc "The model Control is wired to, checked: raises when it is missing or wrong."
  def configured!, do: check!(Application.fetch_env!(:atlas, :model))

  @doc "`model` when it implements this behaviour and the shared callbacks; raises otherwise."
  def check!(model) do
    unless is_atom(model) and Code.ensure_loaded?(model),
      do: raise(ArgumentError, "the model #{inspect(model)} is not a module Control can load")

    missing =
      for {name, arity} <- __MODULE__.behaviour_info(:callbacks) ++ @shared,
          not function_exported?(model, name, arity),
          do: "#{name}/#{arity}"

    if missing != [],
      do: raise(ArgumentError, "the model #{inspect(model)} lacks #{Enum.join(missing, ", ")}")

    model
  end

  @doc """
  The actors `model`'s owners name, as `configured` (`%{role => key}`, the environment's
  settings) fills them (`AtlasBus.Actors.resolve/2`). Raises when it does not fill one:
  Control does not start without it.
  """
  def actors!(model, configured \\ AtlasBus.Actors.configured()) do
    case AtlasBus.Actors.resolve(check!(model).actors(), configured) do
      {:ok, actors} -> actors
      {:error, why} -> raise ArgumentError, "Control does not start: " <> why
    end
  end

  @doc """
  The model as Control serves it: `%{module, kinds, relations, start, turn, guidance,
  settings}`, its kinds and relations by name, with the environment's settings for
  Control (`"tabs"`: the shell's added tabs; `"workers"`: who may read and submit worker
  guidance). Built once, when Control starts.
  """
  def catalog(model, settings \\ %{}) do
    model = check!(model)
    kinds = model.kinds()

    %{
      module: model,
      settings: settings || %{},
      kinds: Map.new(kinds, &{&1.name, &1}),
      relations: Map.new(for(k <- kinds, r <- k.relations, do: {r.name, r})),
      start: model.start_page(),
      turn: model.turn(),
      guidance: model.guidance()
    }
  end
end
