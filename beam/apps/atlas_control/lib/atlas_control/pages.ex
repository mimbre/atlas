defmodule AtlasControl.Pages do
  @moduledoc """
  Turns rela's description and facts into pages of blocks. Knows no kind by name: every
  title, field, choice and rule comes from the description.

  Paths:

  | Path                      | Page                                              |
  |---------------------------|---------------------------------------------------|
  | `/`                       | the top kinds; the list itself when there is one  |
  | `/k/<kind>`               | list of facts of a kind                           |
  | `/k/<kind>/new`           | form to create one                                |
  | `/k/<kind>/new/<rel>/<p>` | form to create one that points at `p` via `rel`   |
  | `/k/<kind>/new/_parent/<p>` | the same, for a client that knows only `p`: `rel` |
  |                           | is the kind's one at-most-one relation (`resolve/2`) |
  | `/k/_/<key>` (and `/edit`, `/delete`) | one fact, for a client that knows only its key: |
  |                           | the kind whose id prefix it has (`resolve/2`)     |
  | `/k/<kind>/<key>`         | one fact, with a list per relation pointing at it |
  | `/k/<kind>/<key>/edit`    | form to change it, and to move it to another parent |
  | `/k/<kind>/<key>/delete`  | confirm deleting it, or why it cannot be deleted  |
  | `/k/<kind>/<key>/links/<rel>` | form to set or remove its links of an association |
  | `/k/<kind>/<key>/set/<rel>` | confirm linking it to the client itself (Accept)  |
  | `/k/<kind>/<key>/remove/<rel>` | form, with a note, to remove that link (Reopen) |
  | `/_kinds`                 | every kind: what a create asks, its id, its parent, its fields, its actions |

  Relations are of two sorts, as the description marks them (`relations.<name>.parent`
  in `rela/atlas.json`):

  - A parent relation (`parent: true`, at most one): a fact belongs under the one it
    points at. A top kind is one that belongs under nothing, unless the description says
    `top: false` (it is reached only through the facts that point at it). Kinds that
    belong to a parent are reached through it: a fact's page lists the facts that point
    at it, and adds new ones already pointing at it.
  - An association (any other relation): a concept a kind has by being in its `from`,
    such as who accepted it. Its page shows the link together with the fact that set it:
    since when, by whom, why (State's `origins`). It is set or removed through its own
    form, never through the change form. One marked `set_by` (a migration, say) is
    history only: shown, and set only by a client that says it is that (`by`). One with
    `only_target` is set and removed only by a client that is one of the facts it points
    at, and links only that one (who accepts is who it names). Its `actions` (`set`, `remove`:
    label and key) are offered on the page, `requires_completed_children` refuses `set`
    while a fact under it is not completed, and `closes_parent` refuses a new fact under
    one that has the link.
  """

  require AtlasControl.Blocks, as: Blocks

  # Every action is one of the CRUD operations: its verb and its key, the same on every
  # page. Read is the row itself: enter opens it.
  @operations %{create: {"Create", "c"}, update: {"Update", "u"}, delete: {"Delete", "d"}}

  # A page with more than one related list: the first creates with c, the others with
  # these (a and r are kept for Accept and Reopen).
  @more_create_keys ~w(s x z)

  # Routes

  # The pages are the contract's (`defpage` in AtlasBFFContract.Pages): Control serves
  # those and nothing else; a path outside them is no page (`:unknown`).
  def route(path) do
    case Blocks.match(path) do
      {:ok, :home, _} ->
        :home

      {:ok, page, params} when page in [:workers, :worker, :worker_guidance] ->
        {:worker_page, page, params}

      {:ok, :kinds, _} ->
        :kinds

      {:ok, :list, p} ->
        {:list, p.kind}

      {:ok, :new, p} ->
        {:new, p.kind}

      {:ok, :new_under, p} ->
        {:new, p.kind, {p.relation, p.parent}}

      {:ok, page, p} when page in [:item, :edit, :delete] ->
        {page, p.kind, p.key}

      {:ok, page, p} when page in [:links, :set, :remove] ->
        {page, p.kind, p.key, p.relation}

      {:ok, :faults, _} ->
        {:faults, nil}

      {:ok, :fact_faults, p} ->
        {:faults, {p.kind, p.key}}

      {:ok, :fault, p} ->
        {:fault, p.fault, nil}

      {:ok, :fact_fault, p} ->
        {:fault, p.fault, {p.kind, p.key}}

      :error ->
        :unknown
    end
  end

  @doc """
  A route as the description makes it concrete, for a client that knows only keys, such
  as an agent:

  - `_parent` in place of a relation (`/k/<kind>/new/_parent/<p>`) becomes the relation
    by which the kind belongs to a parent (its one parent relation).
  - `_` in place of a kind (`/k/_/<key>`, `.../edit`, `.../delete`, `.../links/<rel>`)
    becomes the kind whose id prefix the key has; the longest prefix wins. A key no prefix
    claims belongs to the one kind without a prefix (such as one whose ids are names).

  When the description gives no single answer, the page does not exist.
  """
  def resolve({:new, kind, {"_parent", parent}}, description) do
    case parent_relations(description, kind) do
      [relation] -> {:new, kind, {relation, parent}}
      _ -> :unknown
    end
  end

  def resolve({page, "_", key}, description) when page in [:item, :edit, :delete] do
    case kind_of_key(description, key) do
      nil -> :unknown
      kind -> {page, kind, key}
    end
  end

  def resolve({page, "_", key, relation}, description) when page in [:links, :set, :remove] do
    case kind_of_key(description, key) do
      nil -> :unknown
      kind -> resolve({page, kind, key, relation}, description)
    end
  end

  # An association its component holds is set there (`link_holder/4`).
  def resolve({page, kind, key, relation}, description) when page in [:links, :set, :remove] do
    {holder, holder_key} = link_holder(description, kind, key, relation)
    {page, holder, holder_key, relation}
  end

  def resolve(route, _description), do: route

  @doc """
  The kinds whose ids have no prefix (made from a name, say). A key no prefix claims is of
  one of them; when there are several, Control asks State which one has it.
  """
  def unprefixed_kinds(description) do
    for {kind, spec} <- Enum.sort(description["entities"] || %{}),
        unprefixed?(spec),
        do: kind
  end

  defp kind_of_key(description, key) do
    matches =
      for {kind, spec} <- description["entities"] || %{},
          prefix <- [create_rule(spec).prefix | spec["id_prefixes"] || []],
          prefix not in [nil, ""] and String.starts_with?(key, prefix),
          do: {String.length(prefix), kind}

    case matches |> Enum.uniq() |> Enum.sort(:desc) do
      [{longest, kind} | rest] ->
        if Enum.any?(rest, fn {length, other} -> length == longest and other != kind end),
          do: nil,
          else: kind

      # A key no prefix claims belongs to the one kind without a prefix, if there is one.
      [] ->
        case for({kind, spec} <- description["entities"] || %{}, unprefixed?(spec), do: kind) do
          [kind] -> kind
          _ -> nil
        end
    end
  end

  defp unprefixed?(spec),
    do: create_rule(spec).prefix in [nil, ""] and (spec["id_prefixes"] || []) == []

  @doc """
  The relations by which a fact of `kind` belongs to a parent: those that start at the
  kind and the description marks as `parent` (at most one), sorted. A change form offers
  each, to move the fact. An association is never one.
  """
  def parent_relations(description, kind) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        parent?(spec),
        kind in (spec["from"] || []),
        do: relation
  end

  # A fact belongs under the one it points at through a parent relation, as the
  # description marks it; there is at most one.
  defp parent?(spec), do: spec["parent"] == true and spec["max_outgoing"] == 1

  @doc "The associations that start at `kind`: `[{relation, spec}]`, its other relations."
  def associations(description, kind) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        not parent?(spec),
        kind in (spec["from"] || []),
        do: {relation, spec}
  end

  @doc """
  Whether a client that is `by` may set `relation`: an association, unless the description
  says only a migration or a connector sets it (`set_by`), and `by` is not that.
  """
  def settable_relation?(description, relation, by \\ nil) do
    case get_in(description, ["relations", relation]) do
      %{} = spec ->
        not parent?(spec) and (spec["set_by"] == nil or by in List.wrap(spec["set_by"]))

      _ ->
        false
    end
  end

  @doc """
  The route a submit endpoint of the contract (`defendpoint`, call :submit) acts on, from
  its name and parameters: the page whose form or confirm it comes from.
  """
  def submit_route(:create, p), do: {:new, p.kind}
  def submit_route(:queue_worker_guidance, params), do: {:worker_page, :worker_guidance, params}
  def submit_route(:create_under, p), do: {:new, p.kind, {p.relation, p.parent}}
  def submit_route(:update, p), do: {:edit, p.kind, p.key}
  def submit_route(:delete, p), do: {:delete, p.kind, p.key}
  def submit_route(:link, p), do: {:links, p.kind, p.key, p.relation}
  def submit_route(:accept, p), do: {:set, p.kind, p.key, p.relation}
  def submit_route(:reopen, p), do: {:remove, p.kind, p.key, p.relation}
  def submit_route(:fault, p), do: {:fault, p.fault, nil}
  def submit_route(:fact_fault, p), do: {:fault, p.fault, {p.kind, p.key}}

  @doc """
  The `call` (the contract's `call` model) that submits the form or confirm of `route`:
  its submit endpoint by name and its parameters, as a form's `submit_to` holds it.
  """
  def call_to(route) do
    {:ok, name, params} = Blocks.endpoint(:submit, path(route))

    Blocks.call(
      endpoint: Atom.to_string(name),
      params: Map.new(params, fn {k, v} -> {to_string(k), v} end)
    )
  end

  @doc """
  The submit endpoint a submit message names, and its parameters: `{:ok, name, params}`,
  or `:error`. A message names it as a form's `submit_to` does (`"endpoint"` and
  `"params"`), or by its path (`"to"`), as a client that knows only paths may.
  """
  def submit_call(%{"endpoint" => endpoint} = message) when is_binary(endpoint) do
    params = message["params"] || %{}

    with %{} = found <-
           Enum.find(
             Blocks.endpoints(),
             &(&1.call == :submit and Atom.to_string(&1.name) == endpoint)
           ),
         true <- is_map(params),
         values = for(p <- found.params, do: {p, params[Atom.to_string(p)]}),
         true <- Enum.all?(values, fn {_, v} -> is_binary(v) and v != "" end) do
      {:ok, found.name, Map.new(values)}
    else
      _ -> :error
    end
  end

  def submit_call(%{"to" => to}), do: Blocks.endpoint(:submit, to)
  def submit_call(_message), do: :error

  # A route's path, by the contract's page for it.
  def path(:home), do: Blocks.path(:home)
  def path({:worker_page, page, params}), do: Blocks.path(page, params)
  def path(:kinds), do: Blocks.path(:kinds)
  def path({:list, kind}), do: Blocks.path(:list, kind: kind)
  def path({:new, kind}), do: Blocks.path(:new, kind: kind)

  def path({:new, kind, {relation, parent}}),
    do: Blocks.path(:new_under, kind: kind, relation: relation, parent: parent)

  def path({page, kind, key}) when page in [:item, :edit, :delete],
    do: Blocks.path(page, kind: kind, key: key)

  def path({page, kind, key, relation}) when page in [:links, :set, :remove],
    do: Blocks.path(page, kind: kind, key: key, relation: relation)

  # The failure pages (test only, `AtlasControl.Faults`).
  def path({:faults, nil}), do: Blocks.path(:faults)
  def path({:faults, {kind, key}}), do: Blocks.path(:fact_faults, kind: kind, key: key)
  def path({:fault, fault, nil}), do: Blocks.path(:fault, fault: fault)

  def path({:fault, fault, {kind, key}}),
    do: Blocks.path(:fact_fault, kind: kind, key: key, fault: fault)

  @doc """
  The name and key of a CRUD operation (`:create`, `:update`, `:delete`) on a kind, as
  every page, form and agent tool shows it: `{"Create <kind>", "c"}`. The one place an
  action gets its words and key; with `nil` for the kind, only the verb (`"Update"`), as a
  form's button says it.
  """
  def operation(op, nil, _kind), do: {elem(@operations[op], 0), elem(@operations[op], 1)}

  def operation(op, spec, kind) do
    {verb, key} = @operations[op]
    {"#{verb} #{noun(spec, kind)}", key}
  end

  defp action(op, spec, kind, to, key \\ nil) do
    {label, default} = operation(op, spec, kind)
    Blocks.action(label: label, key: key || default, to: to)
  end

  defp verb(op), do: op |> operation(nil, nil) |> elem(0)
  defp key_of(op), do: op |> operation(nil, nil) |> elem(1)

  @doc "The kind a route is about."
  def kind_of(:home), do: :all
  def kind_of(:unknown), do: nil
  def kind_of({:worker_page, _, _}), do: nil
  def kind_of({:unavailable, _path, _failed}), do: nil
  def kind_of(:kinds), do: nil
  def kind_of(route), do: elem(route, 1)

  @doc """
  Whether a hint of `kind` can change what `route` shows: a fact of the kind on screen,
  of a kind listed under it, or of a kind whose facts change their progress.
  """
  def shows?(:home, _description, _kind), do: true
  def shows?({:assigned, _by}, _description, _kind), do: true

  def shows?({:worker_page, _, _}, description, kind),
    do:
      kind == get_in(description, ["runtime", "turn", "kind"]) or
        kind in Enum.map(
          ~w(execution interaction receipt),
          &get_in(description, ["guidance", &1, "kind"])
        )

  def shows?({page, of, _key} = route, description, kind) when page in [:item, :delete] do
    listed = Enum.map(child_relations(description, of), &elem(&1, 1))

    kind == kind_of(route) or kind in listed or
      Enum.any?(listed, &(kind in progress_from(description, &1))) or
      kind in Enum.map(cause_fields(description), &elem(&1, 0)) or
      kind in for(
        {_relation, part_kind, _component} <- components(description, of),
        do: part_kind
      )
  end

  def shows?({:list, of} = route, description, kind),
    do:
      open_work?(description, of) or kind == kind_of(route) or
        kind in progress_from(description, of) or
        kind in for({_relation, from, _text} <- counts(description, of), do: from)

  def shows?(route, _description, kind), do: kind == kind_of(route)

  @doc """
  The kinds whose facts change the progress of `kind` (its `progress` rule in the
  description: the kind of the facts it rolls up `over`, and theirs, at any depth), or
  whether it is completed (its `completion` rule: the kinds whose facts it looks at).
  """
  def progress_from(description, kind, depth \\ 8)
  def progress_from(_description, _kind, 0), do: []

  def progress_from(description, kind, depth) do
    children =
      with over when is_binary(over) <-
             get_in(description, ["entities", kind, "progress", "over"]),
           [from] <- get_in(description, ["relations", over, "from"]) do
        [from | progress_from(description, from, depth - 1)]
      else
        _ -> []
      end

    Enum.uniq(completion_from(description, kind) ++ children)
  end

  defp completion_from(description, kind) do
    while = List.wrap(get_in(description, ["entities", kind, "progress", "while"]))

    for rule <- completion_rules(description, kind) ++ while,
        kind <-
          (case rule do
             %{"over" => relation} -> get_in(description, ["relations", relation, "from"])
             %{"through" => relation} -> get_in(description, ["relations", relation, "to"])
             _ -> []
           end) || [],
        do: kind
  end

  defp completion_rules(description, kind) do
    case get_in(description, ["entities", kind, "completion"]) do
      rules when is_list(rules) -> rules
      %{} = rule -> [rule]
      _ -> []
    end
  end

  def form?({:worker_page, :worker_guidance, _}), do: true
  def form?(route), do: elem_match?(route, [:new, :edit, :links, :remove])

  defp elem_match?(route, pages), do: is_tuple(route) and elem(route, 0) in pages

  @doc """
  The relations whose facts point at `kind`, from one kind each: `[{relation, from kind,
  spec}]`. A fact's page lists those facts; under a parent relation it can add one.
  """
  def child_relations(description, kind) do
    # A relation from several kinds (what is assigned to someone, say) is one list per kind.
    for {relation, %{"to" => to, "from" => [_ | _] = froms} = spec} <-
          Enum.sort(description["relations"] || %{}),
        kind in to,
        from <- froms,
        do: {relation, from, spec}
  end

  # The id of a related list on a page; one per kind for a relation from several.
  defp list_id(relation, from, %{"from" => [_, _ | _]}), do: "list:#{relation}:#{from}"
  defp list_id(relation, _from, _spec), do: "list:" <> relation

  @doc "The reads a route needs: `[{kind, content}]`."
  def reads({:worker_page, _, _}, _description), do: []

  def reads(:home, description) do
    case top_kinds(description) do
      [kind] -> reads({:list, kind}, description)
      _ -> []
    end
  end

  # What is assigned to `by` (`start.assigned` in the description): read its Assignments
  # once, then their owner kinds. assigned_facts/2 joins only those selected Assignments;
  # nested linked reads would fetch the same full Assignment list again for every owner.
  def reads({:assigned, by}, description) do
    relation = assigned_rule(description)["relation"]
    froms = get_in(description, ["relations", relation, "from"]) || []

    for(from <- froms, do: {from, %{"linked" => %{relation => by}}}) ++
      for {_component, owner} <- owner_kinds(description, froms), do: {owner, %{}}
  end

  # Open work (`start.open`): every fact of the kinds the start's relation starts at (the
  # Assignments) and of the kinds they are components of, so the same rows as what is
  # assigned to one client, for everyone.
  def reads({:list, kind}, description) when is_map(description) and is_binary(kind) do
    if open_work?(description, kind) do
      relation = assigned_rule(description)["relation"]
      froms = get_in(description, ["relations", relation, "from"]) || []

      for(from <- froms, do: {from, %{}}) ++
        for {_component, owner} <- owner_kinds(description, froms), do: {owner, %{}}
    else
      list_reads(kind, description)
    end
  end

  def reads({:unavailable, _path, _failed}, _), do: []
  # What can fail is asked of the layers (`AtlasControl.Faults`), not read from State.
  def reads({:faults, _on}, _), do: []
  def reads({:fault, _fault, _on}, _), do: []
  def reads({:new, _}, _), do: []
  def reads({:new, _, _}, _), do: []

  def reads({:item, kind, key}, description) do
    children =
      for {relation, from, _} <- child_relations(description, kind),
          do: {from, %{"linked" => %{relation => key}}}

    causes = for {from, _name, _label} <- cause_fields(description), do: {from, %{}}

    parts =
      for {_relation, part_kind, component} <- components(description, kind),
          do: {part_kind, %{"key" => part_key(component, key)}}

    [{kind, %{"key" => key}} | children] ++ causes ++ parts
  end

  # A change form also lists where the fact can move: every fact of each parent kind.
  def reads({:edit, kind, key}, description) do
    parents =
      for relation <- parent_relations(description, kind),
          do: {parent_of(description, relation), %{}}

    [{kind, %{"key" => key}} | parents]
  end

  def reads({_, kind, key}, _), do: [{kind, %{"key" => key}}]

  # Setting a link that needs the facts under it completed reads them, as the page does.
  def reads({:set, kind, key, _relation}, description), do: reads({:item, kind, key}, description)
  # Removing reads as the page does too: an owner's answer may remove what is not set.
  def reads({:remove, kind, key, _relation}, description),
    do: reads({:item, kind, key}, description)

  # The fact, and the facts it may point at: of each kind the relation points at.
  def reads({:links, kind, key, relation}, description) do
    tos = get_in(description, ["relations", relation, "to"]) || []
    [{kind, %{"key" => key}} | for(to <- tos, do: {to, %{}})]
  end

  def reads(:unknown, _), do: []
  def reads(:kinds, _), do: []

  # A kind whose rows count what points at it (`counts`) also reads, plainly, every fact of
  # each kind those relations start at.
  defp list_reads(kind, description),
    do: [
      {kind, %{}}
      | for(
          {_relation, from, _text} <- counts(description, kind),
          do: {from, %{"linked" => %{}, "plain" => true}}
        )
    ]

  # What a list row of `kind` counts (`counts` in the description: relation, text with
  # {count}): `[{relation, from, text}]`, one per kind the relation starts at.
  defp counts(description, kind) do
    for %{"relation" => relation, "text" => text} <-
          get_in(description, ["entities", kind, "counts"]) || [],
        kind in (get_in(description, ["relations", relation, "to"]) || []),
        from <- get_in(description, ["relations", relation, "from"]) || [],
        do: {relation, from, text}
  end

  @doc """
  The relations marked `component` that start at `kind` (`rela/atlas.json`): the one fact
  each points at is made and deleted with the fact (its Assignment), and the fact's page
  shows its fields and associations as the fact's own. `[{relation, kind, component}]`.
  """
  def components(description, kind) do
    for {relation, %{"component" => %{"key" => _} = component, "to" => [to]} = spec} <-
          Enum.sort(description["relations"] || %{}),
        kind in (spec["from"] || []),
        do: {relation, to, component}
  end

  # The kinds whose facts a fact of `kind` is made and deleted with, as their component.
  defp made_with(description, kind) do
    for {_relation, %{"component" => %{}, "to" => [^kind]} = spec} <-
          Enum.sort(description["relations"] || %{}),
        from <- spec["from"] || [],
        uniq: true,
        do: from
  end

  @doc "The key of the component a fact with `key` has, as `component` makes it."
  def part_key(%{"key" => template}, key), do: String.replace(template, "{key}", key)

  @doc """
  Where an association of `kind` is set: on the fact itself, or, when it starts at the kind
  of one of its components and not at `kind`, on that component: `{kind, key}`.
  """
  def link_holder(description, kind, key, relation) do
    from = get_in(description, ["relations", relation, "from"]) || []

    found =
      if kind in from,
        do: nil,
        else:
          Enum.find_value(components(description, kind), fn {_rel, part_kind, component} ->
            if part_kind in from, do: {part_kind, part_key(component, key)}
          end)

    found || {kind, key}
  end

  @doc """
  The fields that name the fact that caused them (`"cause"` in the description, `true` or
  the title of the list): `[{kind, field, title}]`. An item page lists the facts whose
  such field holds its key.
  """
  def cause_fields(description) do
    for {kind, spec} <- Enum.sort(description["entities"] || %{}),
        {name, %{"cause" => cause}} <- Enum.sort(spec["properties"] || %{}),
        cause not in [nil, false],
        do: {kind, name, if(is_binary(cause), do: cause, else: plural(spec, kind))}
  end

  def top_kinds(description) do
    children =
      for {_name, %{"from" => from} = spec} <- description["relations"] || %{},
          parent?(spec),
          kind <- from,
          do: kind

    hidden = for {kind, %{"top" => false}} <- description["entities"] || %{}, do: kind

    description
    |> Map.get("entities", %{})
    |> Map.keys()
    |> Kernel.--(children ++ hidden)
    |> Enum.sort()
  end

  # The start page's ways to the kinds kept off it (`start` in the description: the key and
  # label of an action that opens the kind's list).
  @doc """
  The start page of what is assigned to the client (`start.assigned` in the description),
  or nil when the description has none: `relation` (whose inverse it reads), and the
  labels it shows (`title`, `empty`, `count`).
  """
  def assigned_rule(description) do
    case get_in(description, ["start", "assigned"]) do
      %{"relation" => relation} = rule when is_binary(relation) -> rule
      _ -> nil
    end
  end

  @doc """
  Whether a client that is `by` (a fact of `by_kind`) opens on what is assigned to it: the
  description has a start page of assignments, and `by_kind` is a kind the relation points
  at. An agent or a migration on the command line opens on the plan, as before.
  """
  def assigned_start?(description, by_kind) do
    case assigned_rule(description) do
      nil -> false
      rule -> by_kind in (get_in(description, ["relations", rule["relation"], "to"]) || [])
    end
  end

  @doc """
  What is assigned, among the answers to `reads({:assigned, by})`: `[{kind, fact, link}]`,
  newest link first. `link` is the fact that points at the client (the Assignment, with
  what is expected and the origin of the link); `fact` is what it is the component of (or
  itself, when it is no component), left out once completed.
  """
  def assigned_facts(description, answers) do
    relation = assigned_rule(description)["relation"]
    froms = get_in(description, ["relations", relation, "from"]) || []
    owners = owner_kinds(description, froms)
    {linked, owned} = Enum.split(answers, length(froms))

    # Each component's fact, by the component's key.
    whose =
      for {{component, owner}, %{"facts" => facts}} <- Enum.zip(owners, owned),
          fact <- facts,
          part <- get_in(fact, ["links", component]) || [],
          into: %{},
          do: {part, {owner, fact}}

    for {from, %{"facts" => links}} <- Enum.zip(froms, linked),
        link <- links,
        {kind, fact} = Map.get(whose, link["key"], {from, link}),
        not completed?(fact) do
      {kind, fact, link}
    end
    |> Enum.sort_by(
      fn {_, _, link} -> get_in(link, ["origins", relation, "since"]) || "" end,
      :desc
    )
  end

  # The component relations that point at one of `kinds`, with each kind they start at:
  # `[{relation, owner kind}]`.
  defp owner_kinds(description, kinds) do
    for {relation, %{"component" => %{}, "to" => [to]} = spec} <-
          Enum.sort(description["relations"] || %{}),
        to in kinds,
        owner <- spec["from"] || [],
        do: {relation, owner}
  end

  @doc "The count of what is assigned, as the description words it (`start.assigned.count`)."
  def assigned_count(description, answers) do
    rule = assigned_rule(description)
    n = length(assigned_facts(description, answers))
    String.replace(rule["count"] || "{count}", "{count}", Integer.to_string(n))
  end

  defp completed?(fact), do: get_in(fact, ["completion", "done"]) == true

  @doc """
  Open work (`start.open` in the description: `title`, `empty`): the list of a kind the
  start's relation starts at shows every open fact with whoever it is assigned to, what is
  expected and its deadline; what is assigned to one client is the same list, filtered on
  it. Nil when the description has none.
  """
  def open_rule(description) do
    case {get_in(description, ["start", "open"]), assigned_rule(description)} do
      {%{} = rule, %{}} -> rule
      _ -> nil
    end
  end

  @doc "Whether the list of `kind` is Open work: a kind the start's relation starts at."
  def open_work?(description, kind) do
    open_rule(description) != nil and
      kind in (get_in(description, ["relations", assigned_rule(description)["relation"], "from"]) ||
                 [])
  end

  @doc """
  Open work among the answers to `reads({:list, kind})` of such a kind: as
  `assigned_facts/2`, for everyone, of the facts someone is assigned to or something is
  expected of; late first, then the newest link.
  """
  def open_facts(description, answers) do
    relation = assigned_rule(description)["relation"]

    description
    |> assigned_facts(answers)
    |> Enum.filter(fn {_kind, _fact, link} ->
      (get_in(link, ["links", relation]) || []) != [] or
        Enum.any?(description["flows"] || %{}, fn {_, flow} ->
          to_text(get_in(link, ["values", flow["field"]])) != ""
        end)
    end)
    |> Enum.sort_by(fn {_, _, link} -> if link["late"] == true, do: 0, else: 1 end)
  end

  # Each row: the fact, what its owner is expected to do (the field its flow writes), and
  # since when and why it is theirs (the fact that set the link).
  defp assigned(description, _by, answers) do
    rule = assigned_rule(description)
    relation = rule["relation"]

    rows =
      for item <- assigned_facts(description, answers),
          do: work_row(description, relation, item, false)

    list =
      Blocks.list(
        title: rule["title"] || "",
        rows: rows,
        empty: rule["empty"],
        actions: start_actions(description)
      )

    page(rule["title"] || "", nil, [list])
  end

  # One row of what is assigned: the fact, whoever it is assigned to (`owner?`, in Open
  # work), what is expected, its deadline (late first), and since when and why.
  defp work_row(description, relation, {from, fact, link}, owner?) do
    spec = description["entities"][from] || %{}
    origin = get_in(link, ["origins", relation]) || %{}
    link_spec = description["entities"][link_kind(description, relation)] || %{}

    owner =
      if owner? do
        case get_in(link, ["links", relation]) || [] do
          [] -> "—"
          keys -> Enum.join(keys, ", ")
        end
      end

    detail =
      [
        owner,
        expected(description, from, fact, link),
        late_detail(link_spec, link),
        origin["since"] && "since " <> short_moment(origin["since"]),
        not owner? && origin["cause"]
      ]
      |> Enum.reject(&(&1 in [nil, "", false]))
      |> Enum.join(" · ")

    Blocks.row(
      id: fact["key"],
      label: label(spec, fact),
      detail: detail,
      to: path({:item, from, fact["key"]})
    )
  end

  # The kind the start's relation starts at (the Assignment), when it is one.
  defp link_kind(description, relation) do
    case get_in(description, ["relations", relation, "from"]) do
      [kind] -> kind
      _ -> nil
    end
  end

  # Open work: the list of a kind the start's relation starts at, for everyone.
  defp open_work(description, kind, answers) do
    case Enum.find(answers, &match?(%{"error" => _}, &1)) do
      nil ->
        rule = open_rule(description)
        relation = assigned_rule(description)["relation"]

        rows =
          for item <- open_facts(description, answers),
              do: work_row(description, relation, item, true)

        list =
          Blocks.list(
            title: rule["title"] || plural(description["entities"][kind] || %{}, kind),
            rows: rows,
            empty: rule["empty"],
            actions: []
          )

        page(rule["title"] || "", "/", [list])

      failed ->
        unavailable(failed, "/")
    end
  end

  # What the fact's owner is expected to do: the value of the field a flow on its kind
  # writes, on the fact or, for a flow `on` a component, on its component (`link`).
  defp expected(description, kind, fact, link) do
    Enum.find_value(description["flows"] || %{}, fn {_name, flow} ->
      written = if flow["on"], do: link, else: fact
      value = kind in (flow["kinds"] || []) && to_text(written["values"][flow["field"]])
      if value in [false, ""], do: nil, else: value
    end)
  end

  # "3 Nov 17:14", in local time.
  defp short_moment(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} ->
        {{y, mo, d}, {h, mi, _}} =
          :calendar.universal_time_to_local_time(NaiveDateTime.to_erl(DateTime.to_naive(at)))

        Calendar.strftime(NaiveDateTime.from_erl!({{y, mo, d}, {h, mi, 0}}), "%-d %b %H:%M")

      _ ->
        to_text(iso)
    end
  end

  defp start_actions(description, except \\ nil) do
    for {kind, %{"start" => %{"key" => key, "label" => label}}} <-
          Enum.sort(description["entities"] || %{}),
        kind != except,
        do: Blocks.action(label: label, key: key, to: path({:list, kind}))
  end

  # A kind the agent alone writes (`"by_hand": false`) offers no keys to make, change or
  # delete one; its forms still answer at their paths. `"by_hand": "update"` offers only the
  # key to change one (a kind made and deleted with another fact).
  defp by_hand?(%{"by_hand" => false}, _op), do: false
  defp by_hand?(%{"by_hand" => "update"}, op), do: op == :update
  defp by_hand?(_spec, _op), do: true

  # The actions the description adds to a fact's page (`actions`: key, label, to), each
  # only while the fact's fields have one of the values its `when` names. A `to` of
  # `agent:<intent>` is for the client to ask the agent with (spec README).
  defp described_actions(spec, fact) do
    for %{"key" => key, "label" => label, "to" => to} = described <- spec["actions"] || [],
        Enum.all?(described["when"] || %{}, fn {field, values} ->
          to_text(fact["values"][field]) in values
        end),
        do: Blocks.action(label: label, key: key, to: to)
  end

  # `"order": "newest"` lists a kind newest first (by key, which counts up).
  defp sort_facts(facts, spec) do
    direction = if spec["order"] == "newest", do: :desc, else: :asc
    Enum.sort_by(facts, & &1["key"], direction)
  end

  # Pages

  @doc """
  The page for `route`: `%{title, back, blocks}`. `answers` are State's answers to
  `reads/2`, in order. `form` carries values and errors to show a form again.
  """
  def render(route, description, answers, form \\ %{})

  def render({:assigned, by}, description, answers, _form), do: assigned(description, by, answers)

  def render(:home, description, answers, form) do
    case top_kinds(description) do
      [kind] -> %{render({:list, kind}, description, answers, form) | back: nil}
      kinds -> home(description, kinds)
    end
  end

  # What a client can create and where, for one that has no screen to find out on, such
  # as an agent (`atlas help`): one item per kind, from the description alone.
  def render(:kinds, description, [], _form) do
    entities = description["entities"] || %{}

    items =
      for {kind, spec} <- Enum.sort(entities) do
        rule = create_rule(spec)

        parents =
          for relation <- parent_relations(description, kind),
              do: parent_of(description, relation)

        children =
          for {_relation, from, spec} <- child_relations(description, kind),
              parent?(spec),
              do: from

        associations =
          for {relation, spec} <- associations(description, kind) do
            limit = if spec["max_outgoing"] == 1, do: ", at most one", else: ""

            how =
              cond do
                Map.has_key?(spec, "set_by") ->
                  "; set by a #{Enum.join(List.wrap(spec["set_by"]), " or ")}, never by hand"

                is_map(spec["only_target"]) ->
                  "; #{spec["only_target"]["error"] || "only one of them sets it"}: in the TUI, never by an agent"

                true ->
                  "; set #{relation}=<key>, empty removes it"
              end

            "#{relation}: to #{Enum.join(spec["to"] || [], " or ")}#{limit}#{how}"
          end

        # A parent relation is a field a change sets too: it moves the fact.
        fields =
          for({name, prop} <- ordered(spec), do: "#{name}: #{field_text(prop, name in rule.ask)}") ++
            for relation <- parent_relations(description, kind),
                do:
                  "#{relation}: the key of a #{parent_of(description, relation)}; a change moves it there"

        {"kind:#{kind}",
         Blocks.item(
           title: "#{singular(spec, kind)} (#{kind})",
           # A component (`components/2`): State makes and deletes it with its fact.
           # A kind only a layer writes (`by_hand: false`: a turn, Runtime's) is no tool.
           fields:
             [
               Blocks.pair(label: "Kind", value: kind),
               Blocks.pair(label: "About", value: String.trim(spec["description"] || "")),
               Blocks.pair(label: "Create asks", value: Enum.join(rule.ask, ", ")),
               Blocks.pair(label: "Id", value: id_text(spec, rule)),
               Blocks.pair(
                 label: "Belongs under",
                 value:
                   if(parents == [], do: "nothing; a top kind", else: Enum.join(parents, " or "))
               ),
               Blocks.pair(
                 label: "Has under it",
                 value: if(children == [], do: "nothing", else: Enum.join(children, ", "))
               ),
               Blocks.pair(label: "Fields", value: Enum.join(fields, "\n"))
             ] ++
               if(associations == [],
                 do: [],
                 else: [Blocks.pair(label: "Links", value: Enum.join(associations, "\n"))]
               ) ++
               if(spec["agent"],
                 do: [Blocks.pair(label: "Agent record", value: spec["agent"])],
                 else: []
               ) ++
               case made_with(description, kind) do
                 [] -> []
                 froms -> [Blocks.pair(label: "Made with", value: Enum.join(froms, ", "))]
               end ++
               if(spec["by_hand"] == false,
                 do: [Blocks.pair(label: "By hand", value: "no")],
                 else: []
               ),
           # What can be done with one, named as every page names it; `<key>` is its key.
           actions: [
             action(:create, spec, kind, path({:new, kind})),
             action(:update, spec, kind, "/k/_/<key>/edit"),
             action(:delete, spec, kind, "/k/_/<key>/delete")
           ]
         )}
      end

    page("Kinds", "/", items)
  end

  def render(:unknown, _description, _answers, _form),
    do: missing("No such page", "Control serves no page at this path.", "/")

  # A page of the contract that could not be worked out, because State did not answer
  # (`AtlasControl.Session`): said as a failed read says it, never "No such page".
  def render({:unavailable, _path, failed}, _description, _answers, _form),
    do: unavailable(failed, "/")

  def render(route, description, answers, form) do
    kind = kind_of(route)

    case kind && Map.get(description["entities"] || %{}, kind) do
      nil -> missing("Nothing here", "This page does not exist (any more).", "/")
      spec -> page(route, kind, spec, description, answers, form)
    end
  end

  defp home(description, kinds) do
    rows =
      for kind <- kinds do
        spec = description["entities"][kind]

        Blocks.row(
          label: plural(spec, kind),
          detail: spec["description"] |> first_line(),
          to: path({:list, kind})
        )
      end

    page("Atlas", nil, [
      Blocks.list(
        title: "Atlas",
        rows: rows,
        empty: "rela describes nothing yet",
        actions: start_actions(description)
      )
    ])
  end

  defp page({:list, kind}, kind, spec, description, answers, form) do
    if open_work?(description, kind),
      do: open_work(description, kind, answers),
      else: list_page(kind, spec, description, answers, form)
  end

  defp page({:item, kind, key}, kind, spec, description, [answer | child_answers], form) do
    case answer do
      %{"fact" => nil} ->
        missing(
          "#{singular(spec, kind)} #{key}",
          "#{key} does not exist (any more).",
          path({:list, kind})
        )

      %{"fact" => fact} ->
        back = path(owner(description, kind, answer) || up(description, kind, fact))
        relations = child_relations(description, kind)
        {child_answers, rest} = Enum.split(child_answers, length(relations))
        {cause_answers, part_answers} = Enum.split(rest, length(cause_fields(description)))
        parts = parts(description, kind, part_answers)

        fields =
          [Blocks.pair(label: "Id", value: key)] ++
            own_fields(spec, fact, state_fields(description, kind)) ++
            Enum.flat_map(parts, fn {part_kind, part_spec, part, made} ->
              own_fields(part_spec, part, made ++ state_fields(description, part_kind))
            end) ++
            Enum.map(parents(description, kind, fact), fn {label, keys} ->
              Blocks.pair(label: label, value: Enum.join(keys, ", "))
            end) ++
            progress_pair(description, spec, kind, fact) ++
            linked(description, kind, fact) ++
            Enum.flat_map(parts, fn {part_kind, _spec, part, _made} ->
              linked(description, part_kind, part)
            end) ++ copy(answer["copy"])

        item =
          Blocks.item(
            title: "#{singular(spec, kind)} #{key}: #{label(spec, fact)}",
            fields: fields,
            # Nothing to change when a user may set nothing but where the id comes from, and
            # there is no parent to move it to. The owner's answers (IS-Atlas-56) take the
            # place of an action on the same key.
            actions:
              if(by_hand?(spec, :update) and changeable?(description, kind, spec),
                do: [action(:update, spec, kind, path({:edit, kind, key}))],
                else: []
              ) ++
                if(by_hand?(spec, :delete),
                  do: [action(:delete, spec, kind, path({:delete, kind, key}))],
                  else: []
                ) ++
                described_actions(spec, fact) ++
                link_actions(description, kind, fact, form) ++
                Enum.flat_map(parts, fn {part_kind, _spec, part, _made} ->
                  link_actions(description, part_kind, part, form)
                end),
            links: links(description, spec, fact)
          )
          |> answers_first(answer_actions(description, kind, fact, parts, form))

        lists =
          relations
          |> Enum.zip(child_answers)
          |> Enum.zip(create_keys(description, kind))
          # A list of what points here through an association shows only when it has some.
          |> Enum.reject(fn {{_relation, answer}, create_key} ->
            create_key == nil and match?(%{"facts" => []}, answer)
          end)
          |> Enum.map(fn {{{relation, from, rel_spec}, child_answer}, create_key} ->
            {list_id(relation, from, rel_spec),
             child_list(description, {relation, from, rel_spec}, key, child_answer, create_key)}
          end)

        # Two parts, by what they hold, never how they look: the main part (the fact
        # itself, and later what is said about it) and the related part (the related
        # lists, what names it as its cause, then the facts it points at). Each list in a
        # section that carries its title. A client lays the parts out as it sees fit.
        references =
          lists ++
            cause_lists(description, key, cause_answers) ++
            parent_lists(description, kind, fact) ++
            Enum.flat_map(parts, fn {part_kind, _spec, part, _made} ->
              parent_lists(description, part_kind, part)
            end)

        ids = for {id, _} <- references, do: id
        main = Blocks.part("item", "item", title: "Content", role: "main")

        markup =
          case ids do
            [] ->
              [main]

            [first | _] ->
              [main, Blocks.part(first, List.last(ids), title: "References", role: "related")] ++
                for {id, {title, _list}} <- references, do: Blocks.section(id, id, title: title)
          end

        content = [{"item", item} | for({id, {_title, list}} <- references, do: {id, list})]

        # Its owner's part first: what to do (IS-Atlas-54).
        {content, markup} =
          case todo(description, kind, fact, parts, form) do
            nil ->
              {content, markup}

            todo ->
              title = todo_label(description, "title")

              {[{"todo", todo} | content],
               [Blocks.part("todo", "todo", title: title, role: "todo") | markup]}
          end

        page("#{singular(spec, kind)} #{key}", back, content, markup)

      %{"error" => _} = failed ->
        unavailable(failed, path({:list, kind}))
    end
  end

  # Set or remove the links of one association; the change becomes a fact with its note.
  defp page({:links, kind, key, relation}, kind, spec, description, [answer | targets], form) do
    back = path({:item, kind, key})
    rel = get_in(description, ["relations", relation]) || %{}
    name = rel["label"] || relation
    change = change_action(description, relation)

    title =
      if change,
        do: "#{change["label"]} #{label(spec, fact_of(answer, key))}",
        else: "#{String.capitalize(name)}: #{key}"

    case answer do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        cond do
          kind not in (rel["from"] || []) ->
            missing(title, "#{singular(spec, kind)} has no #{name}.", back)

          not may_link?(description, relation, form[:by], form[:by_kind]) ->
            why =
              cond do
                rel["set_by"] -> "only a #{Enum.join(List.wrap(rel["set_by"]), " or ")} sets it"
                rel["only_target"] -> rel["only_target"]["error"] || "not by this client"
                true -> "it says what the fact belongs under"
              end

            missing(title, "#{String.capitalize(name)} is not set here: #{why}.", back)

          true ->
            current = Enum.join(get_in(fact, ["links", relation]) || [], ", ")
            # The fields the change also asks (`with`), as the fact holds them.
            with_fields = List.wrap(change && change["with"])

            held =
              for name <- with_fields,
                  into: %{},
                  do: {name, to_text(get_in(fact, ["values", name]))}

            values = Map.merge(Map.put(held, "to", current), form[:values] || %{})

            form_block =
              Blocks.form(
                title: title,
                inputs:
                  [
                    Blocks.input(name: "_key", label: "Id", kind: "readonly", value: key),
                    link_input(rel, values["to"], targets)
                  ] ++
                    inputs(spec, values, only: with_fields) ++
                    [
                      Blocks.input(
                        name: "note",
                        label: "Note",
                        kind: "multiline",
                        value: values["note"],
                        hint: "Why; kept with the change"
                      )
                    ],
                submit_label: "Save",
                submit_to: call_to({:links, kind, key, relation}),
                cancel_to: back,
                errors: form[:errors] || []
              )

            page(title, back, [form_block])
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  # Link the fact to the client itself (Accept), after asking; refused, with why, while it
  # may not: another client, already linked, or facts under it not completed.
  defp page({:set, kind, key, relation} = route, kind, spec, description, answers, form) do
    back = path({:item, kind, key})
    rel = get_in(description, ["relations", relation]) || %{}

    label =
      get_in(rel, ["actions", "set", "label"]) || String.capitalize(rel["label"] || relation)

    title = "#{label} #{key}"

    case hd(answers) do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        case set_problem(description, route, answers, form[:by], form[:by_kind]) do
          nil ->
            confirm =
              Blocks.confirm(
                title: "#{title}?",
                text:
                  "#{key}: #{label(spec, fact)} will be #{rel["label"] || relation} #{form[:by]}.",
                confirm_label: label,
                confirm_to: call_to(route),
                cancel_to: back
              )

            page(title, back, [confirm])

          problem ->
            missing(title, problem, back)
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  # Remove the link (Reopen); a note says why, and is kept with the fact that removes it.
  defp page(
         {:remove, kind, key, relation} = route,
         kind,
         _spec,
         description,
         [answer | rest],
         form
       ) do
    back = path({:item, kind, key})
    rel = get_in(description, ["relations", relation]) || %{}
    # The owner's answer that removes it (reject): also when it is not set (IS-Atlas-56).
    as_answer =
      case answer do
        %{"fact" => %{} = fact} ->
          parts = item_parts(description, kind, rest)

          Enum.find(
            owner_answers(description, kind, fact, parts, form),
            &(&1["remove"] == relation)
          )

        _ ->
          nil
      end

    label =
      (as_answer && as_answer["label"]) || get_in(rel, ["actions", "remove", "label"]) ||
        "Remove #{rel["label"] || relation}"

    title = "#{label} #{key}"

    case answer do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        cond do
          not may_link?(description, relation, form[:by], form[:by_kind]) ->
            missing(title, "#{title} is not done here: #{why_not(rel)}.", back)

          (get_in(fact, ["links", relation]) || []) == [] and as_answer == nil ->
            missing(title, "#{key} has no #{rel["label"] || relation}.", back)

          true ->
            form_block =
              Blocks.form(
                title: title,
                inputs: [
                  Blocks.input(name: "_key", label: "Id", kind: "readonly", value: key),
                  Blocks.input(
                    name: "note",
                    label: "Note",
                    kind: "multiline",
                    value: (form[:values] || %{})["note"],
                    required: true,
                    hint: "Why; kept with the fact that removes it"
                  )
                ],
                submit_label: label,
                submit_to: call_to(route),
                cancel_to: back,
                errors: form[:errors] || []
              )

            page(title, back, [form_block])
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  defp page({:new, kind, {_relation, parent}} = route, kind, spec, description, [], form) do
    %{blocks: [form_block]} = page({:new, kind}, kind, spec, description, [], form)
    parent_route = {:item, parent_kind(description, route), parent}
    title = "#{elem(operation(:create, spec, kind), 0)} in #{parent}"

    form_block =
      form_block
      |> put_in(["props", "title"], title)
      |> put_in(["props", "submit_to"], call_to(route))
      |> put_in(["props", "cancel_to"], path(parent_route))

    page(title, path(parent_route), [form_block])
  end

  # A create asks only what the kind's create rule asks; the id is made, never typed.
  defp page({:new, kind}, kind, spec, _description, [], form) do
    values = form[:values] || %{}
    asked = create_rule(spec).ask

    form_block =
      Blocks.form(
        title: elem(operation(:create, spec, kind), 0),
        inputs: inputs(spec, values, only: asked),
        submit_label: verb(:create),
        submit_to: call_to({:new, kind}),
        cancel_to: path({:list, kind}),
        errors: form[:errors] || []
      )

    page(elem(operation(:create, spec, kind), 0), path({:list, kind}), [form_block])
  end

  defp page({:edit, kind, key}, kind, spec, description, [answer | parent_answers], form) do
    back = path({:item, kind, key})

    case answer do
      %{"fact" => nil} ->
        missing(
          "#{verb(:update)} #{key}",
          "#{key} does not exist (any more).",
          path({:list, kind})
        )

      %{"fact" => fact} ->
        shown = Map.new(fact["values"] || %{}, fn {k, v} -> {k, to_text(v)} end)

        values =
          shown
          |> Map.merge(parent_values(description, kind, fact))
          |> Map.merge(form[:values] || %{})

        form_block =
          Blocks.form(
            title: "#{verb(:update)} #{key}",
            # The id is shown, never changed; nor is the property it was made from.
            inputs:
              [Blocks.input(name: "_key", label: "Id", kind: "readonly", value: key)] ++
                from_input(spec, values) ++
                inputs(spec, values, except: id_property(spec)) ++
                parent_inputs(description, kind, values, parent_answers),
            submit_label: verb(:update),
            submit_to: call_to({:edit, kind, key}),
            cancel_to: back,
            errors: form[:errors] || []
          )

        page("#{verb(:update)} #{key}", back, [form_block])

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  defp page({:delete, kind, key}, kind, spec, description, [answer], _form) do
    back = path({:item, kind, key})

    case answer do
      %{"fact" => nil} ->
        missing(
          "#{verb(:delete)} #{key}",
          "#{key} does not exist (any more).",
          path({:list, kind})
        )

      %{"fact" => fact} = answer ->
        # A component goes with its fact (`components/2`), never alone.
        owners =
          for {relation, %{"component" => %{}} = rel} <- description["relations"] || %{},
              kind in (rel["to"] || []),
              owner <- get_in(answer, ["incoming", relation]) || [],
              do: owner

        held =
          if owners == [],
            do: Enum.reject(children(description, kind, answer), fn {_, keys} -> keys == [] end),
            else: {:part_of, owners}

        parts =
          for {relation, part_kind, _} <- components(description, kind),
              part <- get_in(fact, ["links", relation]) || [],
              do:
                "#{singular(get_in(description, ["entities", part_kind]) || %{}, part_kind)} #{part}"

        with_parts = if parts == [], do: "", else: ", with its #{Enum.join(parts, " and ")}"

        case held do
          {:part_of, owners} ->
            confirm =
              Blocks.confirm(
                title: "#{key} cannot be deleted",
                text: "#{key} goes with #{Enum.join(owners, ", ")}; delete that instead.",
                cancel_to: back
              )

            page("#{verb(:delete)} #{key}", back, [confirm])

          [] ->
            confirm =
              Blocks.confirm(
                title: "#{elem(operation(:delete, spec, kind), 0)} #{key}?",
                text:
                  "#{key}: #{label(spec, fact)} will be deleted#{with_parts}. " <>
                    "This cannot be undone.",
                confirm_label: verb(:delete),
                confirm_to: call_to({:delete, kind, key}),
                cancel_to: back
              )

            page("#{verb(:delete)} #{key}", back, [confirm])

          held ->
            what =
              Enum.map_join(held, " and ", fn {label, keys} ->
                count(keys) <> " " <> String.downcase(label)
              end)

            confirm =
              Blocks.confirm(
                title: "#{key} cannot be deleted",
                text: "#{key} still has #{what}. " <> remove_first(held),
                cancel_to: back
              )

            page("#{verb(:delete)} #{key}", back, [confirm])
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  defp page(_route, _kind, _spec, _description, _answers, _form),
    do: missing("Nothing here", "This page does not exist.", "/")

  defp list_page(kind, spec, description, [answer | count_answers], form) do
    # The only top kind's list is the start page; there is nothing to go back to.
    start? = top_kinds(description) == [kind]
    # With a start page of assignments, the plan is one key away from it, and back.
    first? = start? and not assigned_start?(description, form[:by_kind])

    case answer do
      %{"facts" => facts} ->
        counted = counted(description, kind, count_answers)

        rows =
          facts
          |> sort_facts(spec)
          |> Enum.map(fn fact ->
            Blocks.row(
              id: fact["key"],
              label: label(spec, fact),
              detail: join_detail(detail(description, spec, fact), counted.(fact["key"])),
              to: path({:item, kind, fact["key"]}),
              links: links(description, spec, fact)
            )
          end)

        list =
          Blocks.list(
            title: plural(spec, kind),
            rows: rows,
            empty:
              if(by_hand?(spec, :create),
                do:
                  "No #{String.downcase(plural(spec, kind))} yet. " <>
                    "Press #{key_of(:create)} to create one.",
                else: "No #{String.downcase(plural(spec, kind))} yet."
              ),
            actions:
              if(by_hand?(spec, :create),
                do: [action(:create, spec, kind, path({:new, kind}))],
                else: []
              ) ++
                if(start?, do: start_actions(description, kind), else: [])
          )

        back = if first?, do: nil, else: "/"
        page(plural(spec, kind), back, [list])

      %{"error" => _} = failed ->
        unavailable(failed, "/")
    end
  end

  # The view model of a page. A block without an id of its own is named by its type; a
  # page holds at most one such block of each type.
  defp page(title, back, content, markup \\ []) do
    content =
      Enum.map(content, fn
        {id, block} -> {id, block}
        block -> {block["type"], block}
      end)

    Map.merge(%{title: title, back: back}, Blocks.view_model(content, markup))
  end

  # The key that creates a fact in each related list, in order; a list of the facts that
  # point at this one through an association creates nothing (nil).
  defp create_keys(description, kind) do
    {keys, _} =
      Enum.map_reduce(
        child_relations(description, kind),
        [key_of(:create) | @more_create_keys],
        fn {_, _, spec}, free ->
          case {parent?(spec), free} do
            {true, [key | rest]} -> {key, rest}
            _ -> {nil, free}
          end
        end
      )

    keys
  end

  defp link_input(%{"max_outgoing" => 1}, value, [_ | _] = targets) do
    facts = Enum.flat_map(targets, &(&1["facts"] || []))

    Blocks.input(
      name: "to",
      label: "To",
      kind: "choice",
      value: value,
      choices:
        [Blocks.choice(value: "", label: "— none")] ++
          for(
            fact <- Enum.sort_by(facts, & &1["key"]),
            do: Blocks.choice(value: fact["key"], label: fact["key"])
          )
    )
  end

  defp link_input(_rel, value, _targets),
    do:
      Blocks.input(
        name: "to",
        label: "To",
        kind: "text",
        value: value,
        hint: "Keys, separated by commas; empty removes them"
      )

  @doc """
  Whether a client that is `by` (a fact of kind `by_kind`, or nil) may set or remove the
  links of `relation`: a client may set it (`settable_relation?/3`), and when the
  description says only one of the facts it points at does (`only_target`), `by` is one of
  that kind, or a client the rule names in `also` (a migration).
  """
  def may_link?(description, relation, by, by_kind) do
    rel = get_in(description, ["relations", relation]) || %{}

    settable_relation?(description, relation, by) and
      case rel["only_target"] do
        %{} = only -> by in (only["also"] || []) or by_kind in (rel["to"] || [])
        _ -> true
      end
  end

  @doc "Whether a client that is `by` may set `relation` to `keys`: only to itself, when so ruled."
  def may_link_to?(description, relation, by, by_kind, keys) do
    rel = get_in(description, ["relations", relation]) || %{}
    only = rel["only_target"]

    may_link?(description, relation, by, by_kind) and
      (only == nil or by in (only["also"] || []) or Enum.all?(keys, &(&1 == by)))
  end

  defp why_not(rel),
    do: get_in(rel, ["only_target", "error"]) || "not by this client"

  @doc """
  Why the client `by` may not link the fact of `route` (`{:set, kind, key, relation}`) to
  itself, or nil. `answers` are State's answers to the route's reads: the fact, then the
  facts under it.
  """
  def set_problem(description, {:set, kind, key, relation}, [answer | child_answers], by, by_kind) do
    rel = get_in(description, ["relations", relation]) || %{}
    fact = answer["fact"] || %{}
    linked = get_in(fact, ["links", relation]) || []

    open =
      for {{_relation, _from, spec}, %{"facts" => facts}} <-
            Enum.zip(child_relations(description, kind), child_answers),
          parent?(spec),
          child <- facts,
          child["completion"] == nil,
          do: child["key"]

    cond do
      kind not in (rel["from"] || []) ->
        "#{key} has no #{rel["label"] || relation}"

      not may_link?(description, relation, by, by_kind) ->
        "#{String.capitalize(rel["label"] || relation)} is not set here: #{why_not(rel)}."

      linked != [] ->
        "#{key} is #{rel["label"] || relation} #{Enum.join(linked, ", ")} already."

      open != [] and is_binary(rel["requires_completed_children"]) ->
        rel["requires_completed_children"]
        |> String.replace("{key}", key)
        |> String.replace("{children}", Enum.join(Enum.sort(open), ", "))

      true ->
        nil
    end
  end

  # Set or remove, as the description names them, for a client that may.
  defp link_actions(description, kind, fact, form) do
    for {relation, spec} <- associations(description, kind),
        %{} = actions <- [spec["actions"]],
        may_link?(description, relation, form[:by], form[:by_kind]),
        {op, page} <-
          [
            cond do
              is_map(actions["change"]) -> {"change", :links}
              (get_in(fact, ["links", relation]) || []) == [] -> {"set", :set}
              true -> {"remove", :remove}
            end
          ],
        %{"label" => label, "key" => key} <- [actions[op]],
        do: Blocks.action(label: label, key: key, to: path({page, kind, fact["key"], relation}))
  end

  @doc """
  The action that changes an association whether a link is there or not
  (`actions.change`: label, key, with, cause), or nil.
  """
  def change_action(description, relation) do
    case get_in(description, ["relations", relation, "actions", "change"]) do
      %{} = change -> change
      _ -> nil
    end
  end

  @doc """
  The cause of a change made through `change_action/2`: the note, when one is given, as it
  is given; else its `cause` with {to} (the keys, or nobody) and {by} filled in. Nil when
  there is neither.
  """
  def change_cause(_change, _keys, _by, note) when is_binary(note) and note != "", do: note

  def change_cause(%{"cause" => cause}, keys, by, _note) when is_binary(cause) do
    to = if keys == [], do: "nobody", else: Enum.join(keys, ", ")
    cause |> String.replace("{to}", to) |> String.replace("{by}", to_string(by))
  end

  def change_cause(_change, _keys, _by, _note), do: nil

  @doc """
  Why a fact of `kind` may not go under `parent` (a fact of `parent_kind`, as State
  answers it) through a parent relation, or nil: an association of the parent marked
  `closes_parent` has a link (it is accepted).
  """
  def closed_problem(description, kind, parent_kind, parent) do
    Enum.find_value(associations(description, parent_kind), fn {relation, spec} ->
      if is_binary(spec["closes_parent"]) and (get_in(parent, ["links", relation]) || []) != [] do
        kind_spec = get_in(description, ["entities", parent_kind]) || %{}

        spec["closes_parent"]
        |> String.replace("{parent}", parent["key"])
        |> String.replace("{kind}", singular(kind_spec, parent_kind) |> String.downcase())
        |> String.replace(
          "{child}",
          singular(get_in(description, ["entities", kind]) || %{}, kind) |> String.downcase()
        )
      end
    end)
  end

  # The fact a read answered, or one with only its key (to title a page that says it is gone).
  defp fact_of(%{"fact" => %{} = fact}, _key), do: fact
  defp fact_of(_answer, key), do: %{"key" => key, "values" => %{}}

  @doc "The keys a links form's `to` names; none removes the links."
  def link_keys(text) do
    text |> to_string() |> String.split(~r/[,\s]+/, trim: true) |> Enum.uniq()
  end

  defp child_list(description, {relation, from, rel_spec}, key, answer, create_key) do
    from_spec = description["entities"][from] || %{}
    title = String.capitalize(get_in(rel_spec, ["inverse", "label"]) || plural(from_spec, from))

    # One list per kind for a relation from several: the kind says which.
    title =
      if length(rel_spec["from"] || []) > 1,
        do: "#{title}: #{plural(from_spec, from)}",
        else: title

    rows =
      case answer do
        %{"facts" => facts} ->
          facts
          |> sort_facts(from_spec)
          |> Enum.map(
            &Blocks.row(
              id: &1["key"],
              label: label(from_spec, &1),
              detail: detail(description, from_spec, &1),
              to: path({:item, from, &1["key"]}),
              links: links(description, from_spec, &1)
            )
          )

        _ ->
          []
      end

    # A relation marked `"add": false` lists its facts without a way to add one here; so
    # does one with no create key (an association).
    add? = create_key != nil and rel_spec["add"] != false and by_hand?(from_spec, :create)

    empty =
      case answer do
        %{"error" => error} -> "#{error}."
        _ when add? -> "No #{String.downcase(title)} yet. Press #{create_key} to create one."
        _ -> "No #{String.downcase(title)} yet."
      end

    actions =
      if add?,
        do: [action(:create, from_spec, from, path({:new, from, {relation, key}}), create_key)],
        else: []

    {title, Blocks.list(rows: rows, empty: empty, actions: actions)}
  end

  # The facts whose cause field holds this fact's key, one list per such field; only those
  # with rows. They follow the related lists in the references part.
  defp cause_lists(description, key, answers) do
    fields = cause_fields(description)

    for {{from, name, title}, %{"facts" => facts}} <- Enum.zip(fields, answers),
        naming = Enum.filter(facts, &(to_text(&1["values"][name]) == key)),
        naming != [] do
      from_spec = description["entities"][from] || %{}

      rows =
        for fact <- sort_facts(naming, from_spec),
            do:
              Blocks.row(
                id: fact["key"],
                label: label(from_spec, fact),
                detail: detail(description, from_spec, fact),
                to: path({:item, from, fact["key"]})
              )

      {"cause:#{from}:#{name}", {title, Blocks.list(rows: rows)}}
    end
  end

  @doc "Where to go after a fact of `kind` is deleted: its parent, or the list of its kind."
  def after_delete(description, kind, %{"fact" => fact}) when is_map(fact),
    do: up(description, kind, fact)

  def after_delete(_description, kind, _answer), do: {:list, kind}

  # The page of the fact a component belongs to (`components/2`), from what points at it.
  defp owner(description, kind, answer) do
    Enum.find_value(description["relations"] || %{}, fn {relation, spec} ->
      with %{} <- spec["component"],
           true <- kind in (spec["to"] || []),
           [key] <- get_in(answer, ["incoming", relation]) do
        {:item, "_", key}
      else
        _ -> nil
      end
    end)
  end

  # A fact's parent page, when it points at one through a parent relation.
  defp up(description, kind, fact) do
    parent =
      Enum.find_value(description["relations"] || %{}, fn {relation, spec} ->
        with true <- kind in (spec["from"] || []) and parent?(spec),
             [to] <- spec["to"],
             [parent_key] <- get_in(fact, ["links", relation]) do
          {:item, to, parent_key}
        else
          _ -> nil
        end
      end)

    parent || {:list, kind}
  end

  # The facts this one belongs under: `[{label, keys}]`.
  defp parents(description, kind, fact) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        parent?(spec),
        kind in (spec["from"] || []),
        keys = get_in(fact, ["links", relation]) || [],
        keys != [],
        do: {String.capitalize(spec["label"] || relation), keys}
  end

  # The fields a page shows of a fact: those a user may set, and the others once they have a
  # value. `made` names those a component's values are made from (the fact's key): not shown.
  defp own_fields(spec, fact, made) do
    Enum.flat_map(ordered(spec), fn {name, prop} ->
      value = fact["values"][name]

      # A field only a connector or the system fills shows only once it has a value.
      if name not in made and (settable?(prop) or value not in [nil, ""]),
        do: [
          Blocks.pair(
            label: field_label(name, prop),
            value: show(prop, value) <> late(spec, fact, name)
          )
        ],
        else: []
    end)
  end

  # What its owner is to do, for a client that is the owner (IS-Atlas-54): from the flow
  # definition on the fact's kind, the state it is in (its `state_field`, which Flow
  # writes) and that state's `todo`: what is expected, why it came to them, the
  # instructions, the section of the fact they name, and the answers they can give. Every
  # word is the description's (the labels: its top-level `todo`) or the fact's.
  defp todo(description, kind, fact, parts, form) do
    with {flow, written, %{"todo" => %{} = todo} = state} <-
           owner_state(description, kind, fact, parts, form) do
      origin = get_in(written, ["origins", flow["owner_relation"]]) || %{}
      expected = to_text(get_in(written, ["values", flow["field"]]))

      section =
        case todo["section"] do
          %{"field" => field, "heading" => heading} ->
            case section(to_text(fact["values"][field]), heading) do
              nil -> []
              text -> [Blocks.pair(label: heading, value: text)]
            end

          _ ->
            []
        end

      answers =
        for %{"key" => key, "label" => label} <- todo["answers"] || [], do: "#{key} #{label}"

      fields =
        [
          Blocks.pair(
            label: todo_label(description, "why"),
            value: origin["cause"] || state["why"] || "—",
            origin: origin["since"] && Blocks.origin(since: origin["since"], by: origin["by"])
          )
        ] ++
          if(todo["instructions"],
            do: [
              Blocks.pair(
                label: todo_label(description, "instructions"),
                value: todo["instructions"]
              )
            ],
            else: []
          ) ++
          section ++
          if(answers == [],
            do: [],
            else: [
              Blocks.pair(
                label: todo_label(description, "answers"),
                value: Enum.join(answers, "   ")
              )
            ]
          )

      Blocks.item(title: "#{todo_label(description, "title")}: #{expected}", fields: fields)
    else
      _ -> nil
    end
  end

  # The flow on the fact's kind, the fact it writes on and the state it is in, when the
  # client is that fact's owner (the flow's owner relation points at it); else nil.
  defp owner_state(description, kind, fact, parts, form) do
    with {_name, flow} <- flow_of(description, kind),
         %{} = written <- written_fact(description, flow, fact, parts),
         by when is_binary(by) <- form[:by],
         true <- by in (get_in(written, ["links", flow["owner_relation"]]) || []),
         name when name not in [nil, ""] <- get_in(written, ["values", flow["state_field"]]),
         %{} = state <- Enum.find(flow["states"] || [], &(&1["name"] == name)) do
      {flow, written, state}
    else
      _ -> nil
    end
  end

  defp todo_label(description, name), do: to_text(get_in(description, ["todo", name]))

  @doc """
  The answers the client may give as the fact's owner, in the state it is in: the state's
  `todo.answers` (`[%{"key", "label", "set" | "remove" => relation}]`), or none.
  """
  def owner_answers(description, kind, fact, parts, form) do
    case owner_state(description, kind, fact, parts, form) do
      {_flow, _written, %{"todo" => %{"answers" => answers}}} when is_list(answers) -> answers
      _ -> []
    end
  end

  # Each answer that sets or removes an association of the fact, as an action to its page.
  defp answer_actions(description, kind, fact, parts, form) do
    for answer <- owner_answers(description, kind, fact, parts, form),
        {op, relation} <- [{:set, answer["set"]}, {:remove, answer["remove"]}],
        is_binary(relation),
        do:
          Blocks.action(
            label: answer["label"],
            key: answer["key"],
            to: path({op, kind, fact["key"], relation})
          )
  end

  # The answers first among an item's actions: an action on the same key gives way to one.
  defp answers_first(item, []), do: item

  defp answers_first(item, answers) do
    keys = Enum.map(answers, & &1["key"])

    update_in(item, ["props", "actions"], fn actions ->
      answers ++ Enum.reject(actions || [], &(&1["key"] in keys))
    end)
  end

  # The component answers of an item page's reads, after its lists and causes.
  defp item_parts(description, kind, rest) do
    {_children, rest} = Enum.split(rest, length(child_relations(description, kind)))
    {_causes, part_answers} = Enum.split(rest, length(cause_fields(description)))
    parts(description, kind, part_answers)
  end

  # The flow definition that runs on `kind`, as `{name, definition}`, or nil.
  defp flow_of(description, kind) do
    Enum.find(Enum.sort(description["flows"] || %{}), fn {_name, flow} ->
      is_map(flow) and kind in (flow["kinds"] || [])
    end)
  end

  # The fact the flow writes on: the component its `on` relation points at, or the fact.
  defp written_fact(description, flow, fact, parts) do
    case flow["on"] && get_in(description, ["relations", flow["on"], "to"]) do
      [to] -> Enum.find_value(parts, fn {kind, _spec, part, _made} -> kind == to && part end)
      _ -> fact
    end
  end

  # Internal flow fields on `kind`: state is shown in What to do; bookkeeping stays hidden.
  defp state_fields(description, kind) do
    for {_name, flow} <- description["flows"] || %{},
        field <- [flow["state_field"], flow["handover_field"]],
        is_binary(field),
        kind in written_kinds(description, flow),
        do: field
  end

  defp written_kinds(description, flow) do
    case flow["on"] && get_in(description, ["relations", flow["on"], "to"]) do
      [to] -> [to]
      _ -> flow["kinds"] || []
    end
  end

  @doc """
  The section of `text` under `heading`: from the line that starts with it ("Melle can
  test: …", or "## Melle can test") to the next heading line ("#" first), without the
  heading itself. Nil when there is none.
  """
  def section(text, heading) do
    lines = String.split(text || "", "\n")
    starts? = &String.starts_with?(String.downcase(&1), String.downcase(heading))

    unheaded = fn line ->
      line |> String.trim_leading() |> String.trim_leading("#") |> String.trim_leading()
    end

    case Enum.split_while(lines, &(not starts?.(unheaded.(&1)))) do
      {_, []} ->
        nil

      {_, [first | rest]} ->
        first = first |> unheaded.() |> String.slice(String.length(heading)..-1//1)
        first = first |> String.trim_leading(":") |> String.trim()
        body = Enum.take_while(rest, &(not String.match?(&1, ~r/^\s*#/)))

        case [first | body] |> Enum.join("\n") |> String.trim() do
          "" -> nil
          text -> text
        end
    end
  end

  # The components State answered (one that is not there yet shows nothing): `[{kind, spec,
  # fact, made}]`, where `made` names the fields made from the fact's key.
  defp parts(description, kind, answers) do
    for {{_relation, part_kind, component}, %{"fact" => %{} = part}} <-
          Enum.zip(components(description, kind), answers),
        do:
          {part_kind, get_in(description, ["entities", part_kind]) || %{}, part,
           Map.keys(component["values"] || %{})}
  end

  # Its associations, each with the fact that set it (since, by, cause) when State knows
  # it. One that was removed shows as removed while that is the latest fact about it.
  defp linked(description, kind, fact) do
    for {relation, spec} <- associations(description, kind),
        not is_map(spec["component"]),
        keys = get_in(fact, ["links", relation]) || [],
        origin = [get_in(fact, ["origins", relation])],
        keys != [] or origin != [nil] do
      origin = hd(origin)

      Blocks.pair(
        label: String.capitalize(spec["label"] || relation),
        value: if(keys == [], do: "—", else: Enum.join(keys, ", ")),
        origin:
          origin &&
            Blocks.origin(since: origin["since"], by: origin["by"], cause: origin["cause"])
      )
    end
  end

  # The facts this one points at, as lists to open them from: `[{id, {title, list}}]`.
  defp parent_lists(description, kind, fact) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        kind in (spec["from"] || []),
        tos = spec["to"] || [],
        tos != [],
        keys = get_in(fact, ["links", relation]) || [],
        keys != [] do
      # A relation that points at several kinds: State says which kind each key is.
      kind_of = fn key ->
        case tos do
          [to] -> to
          _ -> get_in(fact, ["link_kinds", relation, key])
        end
      end

      rows =
        for key <- Enum.sort(keys), to = kind_of.(key), to != nil do
          to_spec = get_in(description, ["entities", to]) || %{}
          Blocks.row(id: key, label: singular(to_spec, to), to: path({:item, to, key}))
        end

      {"parent:" <> relation,
       {String.capitalize(spec["label"] || relation), Blocks.list(rows: rows)}}
    end
  end

  # The fact's web address, opened outside the client: its first field whose type the
  # description marks as a URL (`"format": "url"`), when it has a value. A client opens
  # only http and https, and Control offers nothing else. Nil when there is none.
  defp links(description, spec, fact) do
    urls =
      for {name, prop} <- ordered(spec),
          url?(description, prop),
          value = fact["values"][name],
          is_binary(value) and String.match?(value, ~r{^https?://\S+$}i),
          do: value

    case urls do
      [url | _] -> [Blocks.link(label: "Open in browser", key: "o", url: url)]
      [] -> nil
    end
  end

  defp url?(description, prop),
    do: prop["format"] == "url" or get_in(description, ["types", prop["type"], "format"]) == "url"

  defp parent_kind(description, {:new, _kind, {relation, _parent}}),
    do: description |> get_in(["relations", relation, "to"]) |> List.wrap() |> List.first()

  defp missing(title, text, back),
    do: page(title, back, [Blocks.confirm(title: title, text: text, cancel_to: back)])

  # A read that failed, titled by what happened: State did not answer at all, rela could not
  # be reached, or rela answered with an error (its own words, and what to do, are in the
  # text). Never "not reachable" when rela answered.
  defp unavailable(%{"error" => error} = failed, back) do
    title =
      case failed["error_kind"] do
        "unreachable" -> "rela is not reachable"
        "answered" -> "rela answered with an error"
        _ -> "State did not answer"
      end

    page(title, back, [
      Blocks.confirm(
        title: title,
        text: "#{error}. Showing nothing rather than something old.",
        cancel_to: back,
        code: failed["code"]
      )
    ])
  end

  @doc "The relations whose facts point at `kind`, with the keys pointing at this fact."
  def children(description, kind, answer) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        kind in (spec["to"] || []) do
      keys = get_in(answer, ["incoming", relation]) || []

      # One of them is named by its kind's label ("1 part"), more by the inverse label ("2 parts").
      label =
        case {keys, spec["from"]} do
          {[_], [from]} -> get_in(description, ["entities", from, "label"])
          _ -> nil
        end || get_in(spec, ["inverse", "label"]) || relation

      {String.capitalize(label), keys}
    end
  end

  defp remove_first([{_, [_]}]),
    do: "Remove it first; Atlas never deletes it along with its parent."

  defp remove_first(_held),
    do: "Remove them first; Atlas never deletes them along with their parent."

  # Form inputs from the description

  # `only`: these properties, in this order. Otherwise every property a user may set,
  # `except` one.
  defp inputs(spec, values, opts) do
    properties =
      case opts[:only] do
        nil -> for {name, _} = property <- ordered(spec), name != opts[:except], do: property
        names -> for name <- names, prop = spec["properties"][name], do: {name, prop}
      end

    for {name, prop} <- properties, settable?(prop) do
      Blocks.input(
        name: name,
        label: field_label(name, prop),
        kind: input_kind(prop),
        value: values[name],
        required: prop["required"] == true,
        hint: prop["description"],
        choices: choices(prop)
      )
    end
  end

  defp from_input(spec, values) do
    case id_property(spec) do
      nil ->
        []

      name ->
        [Blocks.input(name: name, label: humanize(name), kind: "readonly", value: values[name])]
    end
  end

  # A fact can be changed when a user may set one of its fields, or move it.
  defp changeable?(description, kind, spec) do
    parent_relations(description, kind) != [] or
      Enum.any?(spec["properties"] || %{}, fn {name, prop} ->
        settable?(prop) and name != id_property(spec)
      end)
  end

  @doc """
  The relations among `links` (`%{relation => [parent]}`) that limit how many facts point
  at one parent (`relations.<name>.limit` in `rela/atlas.json`): `[{relation, parent}]`.
  """
  def limited(description, links) do
    for {relation, parents} <- links,
        is_map(get_in(description, ["relations", relation, "limit"])),
        parent <- parents,
        do: {relation, parent}
  end

  @doc """
  Why a fact of `kind` with key `key` may not point at `parent` through `relation`, or nil.
  `children` are the facts of `kind` that point at it now. Only those whose `field` is one
  of the limit's `values` count, and never the fact itself (sent again, or not moving).
  """
  def over_limit(description, relation, kind, key, parent, children) do
    limit = get_in(description, ["relations", relation, "limit"]) || %{}
    field = limit["field"]
    prop = get_in(description, ["entities", kind, "properties", field]) || %{}

    counted =
      Enum.filter(children, fn child ->
        child["key"] != key and (child["values"] || %{})[field] in (limit["values"] || [])
      end)

    if is_integer(limit["max"]) and length(counted) >= limit["max"] do
      [first | _] = Enum.sort_by(counted, & &1["key"])
      value = first["values"][field]

      label =
        get_in(prop, ["labels", value]) ||
          get_in(description, ["types", prop["type"], "labels", value]) || to_text(value)

      (limit["error"] || "{parent} already has {child} ({value})")
      |> String.replace("{parent}", parent)
      |> String.replace("{child}", first["key"])
      |> String.replace("{value}", label)
    end
  end

  @doc "The parent a fact points at through each of its parent relations: `%{relation => key}`."
  def parent_values(description, kind, fact) do
    for relation <- parent_relations(description, kind),
        [parent | _] <- [get_in(fact, ["links", relation]) || []],
        into: %{},
        do: {relation, parent}
  end

  # Where a fact can move: per parent relation a choice of every fact of the parent's
  # kind, the current parent selected. A fact that has a parent keeps one: no empty choice.
  defp parent_inputs(description, kind, values, answers) do
    for {relation, at} <- Enum.with_index(parent_relations(description, kind)) do
      answer = Enum.at(answers, at)
      to = parent_of(description, relation)
      to_spec = get_in(description, ["entities", to]) || %{}
      current = values[relation] || ""

      facts =
        case answer do
          %{"facts" => facts} -> Enum.sort_by(facts, & &1["key"])
          _ -> []
        end

      # The current parent stays a choice even when the list of its kind could not be read.
      choices =
        if(current == "", do: [Blocks.choice(value: "", label: "—")], else: []) ++
          if(current in ["" | Enum.map(facts, & &1["key"])],
            do: [],
            else: [Blocks.choice(value: current, label: current)]
          ) ++
          Enum.map(
            facts,
            &Blocks.choice(value: &1["key"], label: "#{&1["key"]}: #{label(to_spec, &1)}")
          )

      Blocks.input(
        name: relation,
        label: relation_label(description, relation),
        kind: "choice",
        value: current,
        required: current != "",
        hint: get_in(description, ["relations", relation, "description"]),
        choices: choices
      )
    end
  end

  defp relation_label(description, relation),
    do: String.capitalize(get_in(description, ["relations", relation, "label"]) || relation)

  defp input_kind(%{"values" => values}) when is_list(values), do: "choice"
  defp input_kind(%{"type" => "boolean"}), do: "boolean"
  # Text of several lines and sections, as the description marks it.
  defp input_kind(%{"multiline" => true}), do: "multiline"
  defp input_kind(_), do: "text"

  defp choices(%{"values" => values} = prop) when is_list(values) do
    none = if prop["required"], do: [], else: [Blocks.choice(value: "", label: "—")]
    none ++ Enum.map(values, &Blocks.choice(value: &1, label: get_in(prop, ["labels", &1]) || &1))
  end

  defp choices(%{"type" => "boolean"}),
    do: [Blocks.choice(value: "false", label: "no"), Blocks.choice(value: "true", label: "yes")]

  defp choices(_), do: nil

  @doc """
  How a fact of a kind is created, from the description (`create` in `rela/atlas.json`):
  `ask` (the fields a create form asks for), `id` (`prefix` plus the next free number,
  zero-padded to `digits`, from `first` up; or made `from` a property, see `key_for/2`) and `defaults`
  (values for what it does not ask). Without a rule: every field a user may set,
  rela's id prefix, no defaults.
  """
  def create_rule(spec) do
    rule = spec["create"] || %{}
    prefix = List.first(spec["id_prefixes"] || List.wrap(spec["id_prefix"])) || ""

    %{
      ask: rule["ask"] || for({name, prop} <- ordered(spec), settable?(prop), do: name),
      prefix: get_in(rule, ["id", "prefix"]) || prefix,
      digits: get_in(rule, ["id", "digits"]) || 2,
      first: get_in(rule, ["id", "first"]) || 1,
      from: get_in(rule, ["id", "from"]),
      defaults: rule["defaults"] || %{}
    }
  end

  @doc "The property a kind's id is made from (`create.id.from`), or nil."
  def id_property(spec), do: get_in(spec, ["create", "id", "from"])

  @doc """
  The key of a new fact whose id is made from a property: the rule's `pattern` must
  match the property's value; `template` puts its groups in (`{1}`, `{2}`, …), after
  `replace` (`{"from": "to"}`) on each group, in lower case when `lower` is true.
  `{:error, text}` when it does not match.
  The same value always makes the same key, so it is never "the next number".
  """
  def key_for(spec, raw) do
    rule = get_in(spec, ["create", "id"]) || %{}
    name = rule["from"]
    value = String.trim(raw[name] || "")

    with pattern when is_binary(pattern) <- rule["pattern"],
         {:ok, regex} <- Regex.compile(pattern),
         [_ | groups] <- Regex.run(regex, value) do
      groups = Enum.map(groups, &replace_all(&1, rule["replace"] || %{}))

      key =
        Regex.replace(~r/\{(\d+)\}/, rule["template"] || "", fn _, n ->
          Enum.at(groups, String.to_integer(n) - 1) || ""
        end)

      {:ok, if(rule["lower"] == true, do: String.downcase(key), else: key)}
    else
      _ -> {:error, rule["error"] || "#{name} does not fit the rule for its id"}
    end
  end

  defp replace_all(text, replacements),
    do: Enum.reduce(replacements, text, fn {from, to}, acc -> String.replace(acc, from, to) end)

  @doc """
  The next free key of a kind: the rule's prefix plus one more than the highest number
  among `keys` (and above `after`, when an earlier try was taken), and never below the
  rule's `first` (a ledger whose older numbers are kept for facts made later).
  """
  def next_key(spec, keys, after_number \\ 0) do
    %{prefix: prefix, digits: digits, first: first} = create_rule(spec)
    {:ok, pattern} = Regex.compile("^" <> Regex.escape(prefix) <> "(\\d+)$")

    highest =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(pattern, key) do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    number = max(max(highest, after_number) + 1, if(is_integer(first), do: first, else: 1))
    {prefix <> String.pad_leading(Integer.to_string(number), digits, "0"), number}
  end

  @doc "The values of a new fact: what was asked, then the rule's defaults for the rest."
  def create_values(spec, raw) do
    asked = Map.take(raw, create_rule(spec).ask)
    Map.merge(create_rule(spec).defaults, values_for(spec, asked))
  end

  # A field a user may set; not one only a connector or the system fills.
  defp settable?(prop), do: not Map.has_key?(prop, "set_by")

  defp parent_of(description, relation),
    do: description |> get_in(["relations", relation, "to"]) |> List.wrap() |> Enum.join(" or ")

  defp id_text(spec, rule) do
    case get_in(spec, ["create", "id"]) do
      %{"from" => from, "template" => template} ->
        "made from #{from}: #{template}"

      _ ->
        "made: #{rule.prefix} and the next number (#{rule.prefix}#{String.duplicate("N", rule.digits)})"
    end
  end

  defp field_text(prop, asked?) do
    what =
      cond do
        is_list(prop["values"]) -> "one of " <> Enum.join(prop["values"], ", ")
        prop["type"] == "boolean" -> "true or false"
        prop["type"] == "integer" -> "a whole number"
        prop["type"] == "datetime" -> "a date and time in UTC, e.g. 2026-11-04 17:00"
        prop["multiline"] -> "text of several lines"
        true -> "text"
      end

    notes =
      [
        prop["required"] && "required",
        asked? && "asked on create",
        Map.has_key?(prop, "set_by") && "set by a #{prop["set_by"]}, never in a form"
      ]
      |> Enum.filter(& &1)

    Enum.join([what | notes], "; ")
  end

  @doc """
  Turn a form's text values into the described types, for a fact. Unknown names are
  passed on so State can refuse them.
  """
  def values_for(spec, raw) do
    props = spec["properties"] || %{}

    for {name, text} <- raw, name != "_key", into: %{} do
      {name, typed(props[name], text)}
    end
  end

  defp typed(_prop, ""), do: ""
  defp typed(%{"type" => "boolean"}, "true"), do: true
  defp typed(%{"type" => "boolean"}, "false"), do: false

  defp typed(%{"type" => "integer"}, text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> text
    end
  end

  # A date and time: `2026-11-04 17:00` (UTC), or any RFC 3339 instant; stored as RFC 3339
  # in UTC. Anything else is passed on, for State to refuse.
  defp typed(%{"type" => "datetime"}, text) do
    trimmed = String.trim(text)

    at =
      case DateTime.from_iso8601(trimmed) do
        {:ok, at, _offset} ->
          at

        _ ->
          case NaiveDateTime.from_iso8601(String.replace(trimmed, " ", "T") <> ":00") do
            {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
            _ -> nil
          end
      end

    if at, do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601(), else: text
  end

  defp typed(_prop, text), do: text

  # Showing values

  # The primary property (or the one the id is made from) first, then choices, then flags,
  # then the rest, so long text ends up last.
  defp ordered(spec) do
    primary = primary(spec)

    (spec["properties"] || %{})
    |> Enum.sort_by(fn {name, prop} ->
      rank =
        cond do
          name == primary -> 0
          is_list(prop["values"]) -> 1
          prop["type"] == "boolean" -> 2
          true -> 3
        end

      {rank, name}
    end)
  end

  # A kind without a primary property is labelled by the one its id is made from.
  defp primary(spec), do: spec["primary"] || id_property(spec)

  # The primary value; while it is empty (a connector has not filled it yet), the value
  # the id is made from; else the key.
  def label(spec, fact) do
    [primary(spec), id_property(spec)]
    |> Enum.map(&to_text(fact["values"][&1]))
    |> Enum.find(fact["key"], &(&1 != ""))
  end

  # When a connector last read a copy of an outside fact, and why its last read failed.
  defp copy(%{"source" => source} = copy) do
    read = copy["read_at"] && "#{moment(copy["read_at"])} from #{source}"

    failed =
      copy["failure"] &&
        "the read at #{moment(copy["failed_at"])} failed: #{copy["failure"]}; it is tried again"

    value =
      case {read, failed} do
        {nil, nil} -> nil
        {read, nil} -> read
        {nil, failed} -> "never from #{source}; #{failed}"
        {read, failed} -> "#{read}; #{failed}"
      end

    if value, do: [Blocks.pair(label: "Last read", value: value)], else: []
  end

  defp copy(_none), do: []

  defp moment(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, at, _} -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      _ -> to_text(iso)
    end
  end

  # A kind with a progress rule shows how far a fact is (State works it out from the facts
  # under it) in place of its own field and the field that marks it done.
  defp detail(description, spec, fact) do
    progress? = is_map(spec["progress"])

    hidden =
      if progress?,
        do: [spec["progress"]["own"], get_in(description, ["progress", "done"])],
        else: []

    shown =
      for {name, prop} <- ordered(spec),
          name != primary(spec),
          name not in hidden,
          v = fact["values"][name],
          v not in [nil, "", false] do
        cond do
          is_list(prop["values"]) -> show(prop, v)
          prop["type"] == "boolean" -> humanize(name) |> String.downcase()
          true -> nil
        end
      end

    progress = if progress?, do: progress_text(fact["progress"]), else: nil
    # The id is the row's own; the detail does not repeat it.
    case Enum.reject(shown ++ [progress, late_detail(spec, fact)], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # For a key, its row's counts as text ("3 assigned"), from the answers to the reads
  # `counts/2` adds: the facts of each kind that point at it through the relation, added up
  # over those kinds. A count whose read failed is left out, never shown as 0.
  defp counted(description, kind, answers) do
    found =
      description
      |> counts(kind)
      |> Enum.zip(answers)
      |> Enum.group_by(fn {{relation, _from, text}, _} -> {relation, text} end, &elem(&1, 1))
      |> Enum.flat_map(fn {{relation, text}, answers} ->
        if Enum.all?(answers, &match?(%{"facts" => _}, &1)),
          do: [{relation, text, Enum.flat_map(answers, & &1["facts"])}],
          else: []
      end)

    fn key ->
      texts =
        for {relation, text, facts} <- found do
          n = Enum.count(facts, &(key in (get_in(&1, ["links", relation]) || [])))
          String.replace(text, "{count}", Integer.to_string(n))
        end

      if texts == [], do: nil, else: Enum.join(texts, " · ")
    end
  end

  defp join_detail(nil, more), do: more
  defp join_detail(detail, nil), do: detail
  defp join_detail(detail, more), do: detail <> " · " <> more

  # A kind with a late rule (`late`: after, label) shows the time in `after`, and its label
  # while State says the fact is late (worked out on every read).
  defp late(%{"late" => %{"after" => name} = rule}, %{"late" => true}, name),
    do: " · " <> (rule["label"] || "late")

  defp late(_spec, _fact, _name), do: ""

  # In a list, late comes first, so a narrow column never cuts it off, and the time is
  # short: `Late · deadline 2026-11-04 17:00`.
  defp late_detail(%{"late" => %{"after" => name} = rule} = spec, fact) do
    case fact["values"][name] do
      value when value in [nil, ""] ->
        nil

      value ->
        prop = (spec["properties"] || %{})[name] || %{}
        time = "#{field_label(name, prop)} #{String.trim_trailing(show(prop, value), " UTC")}"

        if fact["late"] == true,
          do: String.capitalize(rule["label"] || "late") <> " · " <> String.downcase(time),
          else: time
    end
  end

  defp late_detail(_spec, _fact), do: nil

  defp progress_text(%{"label" => label, "count" => count, "of" => of}),
    do: "#{label} · #{count}/#{of}"

  defp progress_text(%{"label" => label}), do: label
  defp progress_text(_), do: nil

  # How far the fact is, and why it is completed when it is (State works both out):
  # "Done · 12/12 · accepted by melle", with the fact that accepted it; "Done ·
  # PR-eyra-atlas-20 merged".
  defp progress_pair(description, spec, kind, fact) do
    text = progress_text(fact["progress"])

    {why, origin} =
      case fact["completion"] do
        %{"by" => relation, "keys" => keys} ->
          label = get_in(description, ["relations", relation, "label"]) || relation
          origin = get_in(fact, ["origins", relation])

          {"#{label} #{Enum.join(keys, ", ")}",
           origin &&
             Blocks.origin(since: origin["since"], by: origin["by"], cause: origin["cause"])}

        %{"key" => key, "value" => value} ->
          {"#{key} #{value}", nil}

        _ ->
          # Not done, but showing something else while another fact holds.
          case get_in(fact, ["progress", "while"]) do
            %{"key" => key, "value" => value} -> {"#{key} #{value}", nil}
            _ -> {nil, nil}
          end
      end

    text =
      cond do
        text && why -> "#{text} · #{why}"
        why -> "#{get_in(description, ["progress", "done_label"]) || "Done"} · #{why}"
        true -> text
      end

    # Its own field already says how far a fact without children is, until it is done.
    shown? = why != nil or Map.has_key?(fact["progress"] || %{}, "count")

    if text && shown? && (is_map(spec["progress"]) or completion_rules(description, kind) != []),
      do: [Blocks.pair(label: "Progress", value: text, origin: origin)],
      else: []
  end

  # A field's name on a page: the description's label for it, or its own name.
  defp field_label(name, prop), do: prop["label"] || humanize(name)

  defp show(%{"type" => "boolean"}, value), do: if(value in [true, "true"], do: "yes", else: "no")
  defp show(_prop, value) when value in [nil, ""], do: "—"
  defp show(%{"type" => "datetime"}, value), do: moment(value)
  defp show(%{"labels" => labels}, value) when is_map(labels), do: labels[value] || to_text(value)
  defp show(_prop, value), do: to_text(value)

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)

  defp count(keys), do: Integer.to_string(length(keys))

  defp singular(spec, kind), do: spec["label"] || humanize(kind)
  # A kind as an action names it: its label in lower case.
  defp noun(spec, kind), do: spec |> singular(kind) |> String.downcase()
  defp plural(spec, kind), do: humanize(spec["plural"] || kind <> "s")

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n") |> hd()
end
