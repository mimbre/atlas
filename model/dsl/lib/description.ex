defmodule RelaDSL.Description do
  @moduledoc """
  The description vocabulary: what a model says about its kinds, besides its subflows.
  Each construct is one key of the description Atlas has always had: Rela's schema
  (`types`, `entities`, `relations`), Atlas's additions to it (`atlas.json`), the
  roles Rela checks flows against (`acl.yaml`) and the mapping of the durable runs
  (`flow-runtime.json`). Nothing else is accepted: a key with no construct is refused
  where it is written, so the model cannot say what no target holds.

  ## In a concept (`use RelaDSL`)

  | construct | holds | target |
  |---|---|---|
  | `type name, values:, labels:, descriptions:, description:, validations:, format:` | a type | schema; `format` to `atlas.json` `types` |
  | `entity name, label:, plural:, aliases:, id_type:, id_prefix:, description: do … end` | a kind | schema `entities` |
  | `field name, type, required:, unique:, default:, description:, label:, multiline:, set_by:, cause:` | a property, in form order | schema; the last four to `atlas.json` `properties` |
  | `relation name, label:, description:, from:, to:, max_outgoing:, inverse: {id, label}` and `parent:, add:, component:, set_by:, limit:, actions:, only_target:, requires_completed_children:, closes_parent:, review:` | a relation | schema; the rest to `atlas.json` `relations` |
  | inside `entity`: `top`, `primary`, `start`, `create`, `completion`, `progress`, `connector`, `agent`, `order`, `by_hand`, `late`, `action`, `counts`, `requires`, `authority`, `frozen`, `replaces`, `layering`, `sealed`, `delete_error` | one rule of the kind each | `atlas.json` `entities` |
  | inside `entity`: `flag field, value:, label:` | the kind's flag | `flow-runtime.json` `flags` |
  | `select subflow, legacy:, choices:, roles:, projection:, admission:, imports:, follow_through:, verification:, reopen:` | how a subflow's runs are selected (`nil` among allowed values: no value; an import row may also say `completed:`; `reopen: :new_generation` restarts reopened work, else only an explicit restart does) | `flow-runtime.json` `selection` |
  | `migrate subflow, from:, to:, states:, rekey:, preserve_entry:, reason:` | an approved run migration | `flow-runtime.json`, `digests.json` |

  `action`, `counts` and `requires` add one item each to the kind's list; the others
  are given once. `completion` takes one rule (a keyword list) or a list of them.

  ## Anywhere (a concept, a module or a composition)

  `todo_words`, `runtime`, `guidance`, `start_page`, `progress_order`, `shell`,
  `read_first`, `about`, `legacy_flow name, opts`, `flow_runtime`, `review relation,
  field:, value:, label:`, and `extend_entity kind, rules` / `extend_relation name,
  rules`, which add rules to a kind or relation another file defines. Every leaf has
  one author: two declarations that say the same leaf are refused, even when equal.

  Values are written as Elixir terms: atoms become strings (but `true`, `false` and
  `nil`), keyword lists become objects in the order written, other lists stay lists.
  """

  @entity [
    top: 1,
    primary: 1,
    create: 1,
    completion: 1,
    progress: 1,
    connector: 1,
    agent: 1,
    order: 1,
    by_hand: 1,
    late: 1,
    action: 1,
    counts: 1,
    requires: 1,
    authority: 1,
    frozen: 1,
    replaces: 1,
    layering: 1,
    sealed: 1,
    delete_error: 1,
    flag: 2,
    field: 2,
    field: 3
  ]

  @root [
    about: 1,
    todo_words: 1,
    runtime: 1,
    guidance: 1,
    start_page: 1,
    progress_order: 1,
    shell: 1,
    read_first: 1,
    legacy_flow: 2,
    flow_runtime: 1,
    review: 2,
    extend_entity: 2,
    extend_relation: 2
  ]

  @concept [type: 2, entity: 2, entity: 3, relation: 2, select: 2, migrate: 2, start: 1, start: 2]

  # The root keys of atlas.json each root construct writes.
  @root_keys %{
    about: "_about",
    todo_words: "todo",
    runtime: "runtime",
    guidance: "guidance",
    start_page: "start",
    progress_order: "progress",
    shell: "shell",
    read_first: "read_first"
  }

  @doc false
  def __macros__(:concept), do: @concept ++ @entity ++ @root
  def __macros__(:root), do: @root
  def __macros__(:entity), do: @entity

  @doc false
  def root_key(construct), do: Map.fetch!(@root_keys, construct)

  defmacro __using__(:concept) do
    quote do
      import RelaDSL.Description, only: unquote(__macros__(:concept))
      RelaDSL.Description.__init__(__MODULE__)
      @before_compile {RelaDSL.Description, :__concept__}
    end
  end

  defmacro __using__(:root) do
    quote do
      import RelaDSL.Description, only: unquote(__macros__(:root))
      RelaDSL.Description.__init__(__MODULE__)
    end
  end

  @doc false
  def __init__(mod) do
    Module.register_attribute(mod, :rela_items, accumulate: true)
    unless Module.has_attribute?(mod, :afg_scope), do: Module.put_attribute(mod, :afg_scope, nil)
  end

  # -- A concept ---------------------------------------------------------------------

  @doc "A type: `values:` with `labels:` and `descriptions:`, or `description:` and `validations:`; `format: :url`."
  defmacro type(name, opts), do: item(:type, name, opts)

  @doc "A kind: `label:`, `plural:`, `aliases:`, `id_type:`, `id_prefix:`, `description:`, and a block of fields and rules."
  defmacro entity(name, opts \\ [], block \\ []) do
    {body, opts} = Keyword.pop(opts ++ block, :do)

    quote do
      RelaDSL.Description.__open__(
        __MODULE__,
        unquote(name),
        unquote(opts),
        __ENV__.file,
        __ENV__.line
      )

      unquote(body)
      RelaDSL.Description.__close__(__MODULE__)
    end
  end

  @doc "A property of the kind, in form order: its type, and its Rela and Atlas options."
  defmacro field(name, type, opts \\ []) do
    quote do
      RelaDSL.Description.__field__(
        __MODULE__,
        unquote(name),
        unquote(type),
        unquote(opts),
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  @doc "A relation: Rela's `label:`, `description:`, `from:`, `to:`, `max_outgoing:`, `inverse:` and Atlas's rules."
  defmacro relation(name, opts), do: item(:relation, name, opts)

  @doc "How the runs of `subflow` are selected and imported from the facts."
  defmacro select(subflow, opts), do: item(:select, subflow, opts)

  @doc "An approved migration of the runs of `subflow`: `from:` digest, `to:` digest, `states:` (a map, or `:same`)."
  defmacro migrate(subflow, opts), do: item(:migrate, subflow, opts)

  @doc "In an entity: the start page action of the kind. In a subflow: a start trigger."
  defmacro start(arg, opts \\ []) do
    quote do
      RelaDSL.Description.__start__(
        __MODULE__,
        unquote(arg),
        unquote(opts),
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  for {name, 1} <- @entity, name != :field do
    @doc "One of the kind's rules: `#{name}` (`atlas.json`, `entities.<kind>`)."
    defmacro unquote(name)(value) do
      key = unquote(name)

      quote do
        RelaDSL.Description.__note__(
          __MODULE__,
          unquote(key),
          unquote(value),
          __ENV__.file,
          __ENV__.line
        )
      end
    end
  end

  @doc "The kind's flag: a fact whose `field` has `value:` shows `label:`."
  defmacro flag(field, opts) do
    quote do
      RelaDSL.Description.__note__(
        __MODULE__,
        :flag,
        {unquote(field), unquote(opts)},
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- Anywhere ----------------------------------------------------------------------

  for {name, 1} <- @root do
    @doc "The description's `#{name}`."
    defmacro unquote(name)(value) do
      key = unquote(name)

      quote do:
              RelaDSL.Description.__item__(
                __MODULE__,
                :root,
                {unquote(key), unquote(value)},
                __ENV__.file,
                __ENV__.line
              )
    end
  end

  @doc "A legacy flow definition (`atlas.json` `flows`), until the flow runs replace it."
  defmacro legacy_flow(name, opts), do: item(:legacy_flow, name, opts)

  @doc "A review of facts that link through `relation` to one whose `field:` has `value:` (`flow-runtime.json` `reviews`)."
  defmacro review(relation, opts), do: item(:review, relation, opts)

  @doc "Rules for a kind defined elsewhere, as the keys `entity`'s rules write."
  defmacro extend_entity(kind, rules), do: item(:extend_entity, kind, rules)

  @doc "Rules for a relation defined elsewhere, as the keys of `relation`'s Atlas options."
  defmacro extend_relation(name, rules), do: item(:extend_relation, name, rules)

  defp item(kind, name, opts) do
    quote do
      RelaDSL.Description.__item__(
        __MODULE__,
        unquote(kind),
        {unquote(name), unquote(opts)},
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- Recording ---------------------------------------------------------------------

  @doc false
  def __item__(mod, kind, value, file, line) do
    if Module.get_attribute(mod, :afg_scope) != nil do
      raise CompileError,
        file: file,
        line: line,
        description: "#{label(kind, value)} belongs at the top of the module"
    end

    Module.put_attribute(mod, :rela_items, %{kind: kind, value: value, file: file, line: line})
  end

  defp label(:root, {key, _}), do: to_string(key)
  defp label(kind, _), do: to_string(kind)

  @doc false
  def __open__(mod, name, opts, file, line) do
    if Module.get_attribute(mod, :afg_scope) != nil do
      raise CompileError,
        file: file,
        line: line,
        description: "entity belongs at the top of the module"
    end

    Module.put_attribute(mod, :rela_entity, %{
      name: name,
      opts: opts,
      fields: [],
      notes: [],
      file: file,
      line: line
    })

    Module.put_attribute(mod, :afg_scope, :entity)
  end

  @doc false
  def __close__(mod) do
    entity = Module.get_attribute(mod, :rela_entity)

    Module.put_attribute(mod, :rela_items, %{
      kind: :entity,
      value: entity,
      file: entity.file,
      line: entity.line
    })

    Module.put_attribute(mod, :afg_scope, nil)
  end

  @doc false
  def __field__(mod, name, type, opts, file, line) do
    entity!(mod, "field", file, line)
    field = %{name: name, type: type, opts: opts, line: line}
    update(mod, :fields, field)
  end

  @doc false
  def __note__(mod, key, value, file, line) do
    entity!(mod, to_string(key), file, line)
    update(mod, :notes, {key, value, line})
  end

  @doc false
  def __start__(mod, arg, opts, file, line) do
    case Module.get_attribute(mod, :afg_scope) do
      :entity when opts == [] ->
        __note__(mod, :start, arg, file, line)

      :entity ->
        raise CompileError,
          file: file,
          line: line,
          description: "an entity's start is [key:, label:]"

      _ ->
        RelaDSL.Schema.__add__(mod, :header, {:start, {arg, opts}}, file, line)
    end
  end

  defp entity!(mod, what, file, line) do
    if Module.get_attribute(mod, :afg_scope) != :entity do
      raise CompileError, file: file, line: line, description: "#{what} belongs inside an entity"
    end
  end

  defp update(mod, key, value) do
    entity = Module.get_attribute(mod, :rela_entity)
    Module.put_attribute(mod, :rela_entity, Map.update!(entity, key, &(&1 ++ [value])))
  end

  @doc false
  def items(mod), do: mod |> Module.get_attribute(:rela_items) |> Enum.reverse()

  @doc false
  defmacro __concept__(env) do
    concept = %{module: env.module, file: env.file, items: items(env.module)}

    quote do
      @doc "What the module declares, as plain data: `__rela__(:concept)`."
      def __rela__(:concept), do: unquote(Macro.escape(concept))
    end
  end
end
