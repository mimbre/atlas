defmodule AtlasControl.Pages do
  @moduledoc """
  Turns the model (`AtlasControl.Model`, as `AtlasControl.Model.catalog/1` looks things
  up in it) and facts into pages of blocks. Knows no kind by name: every title, field,
  choice and rule comes from the model.

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

  Relations are of two sorts, as the model marks them (`parent`):

  - A parent relation (`parent: true`, at most one): a fact belongs under the one it
    points at. A top kind is one that belongs under nothing, unless the model keeps it
    off the top (it is reached only through the facts that point at it). Kinds that
    belong to a parent are reached through it: a fact's page lists the facts that point
    at it, and adds new ones already pointing at it.
  - An association (any other relation): a concept a kind has by being in its `from`,
    such as who accepted it. Its page shows the link together with the fact that set it:
    since when, by whom, why (Facts' `origins`). It is set or removed through its own
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

      {:ok, :answer, p} ->
        {:answer, p.kind, p.key, p.answer}

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
  A route as the model makes it concrete, for a client that knows only keys, such as an
  agent:

  - `_parent` in place of a relation (`/k/<kind>/new/_parent/<p>`) becomes the relation
    by which the kind belongs to a parent (its one parent relation).
  - `_` in place of a kind (`/k/_/<key>`, `.../edit`, `.../delete`, `.../links/<rel>`)
    becomes the kind whose id prefix the key has; the longest prefix wins. A key no prefix
    claims belongs to the one kind without a prefix (such as one whose ids are names).

  When the model gives no single answer, the page does not exist.
  """
  def resolve({:new, kind, {"_parent", parent}}, m) do
    case parent_relations(m, kind) do
      [relation] -> {:new, kind, {relation, parent}}
      _ -> :unknown
    end
  end

  def resolve({page, "_", key}, m) when page in [:item, :edit, :delete] do
    case kind_of_key(m, key) do
      nil -> :unknown
      kind -> {page, kind, key}
    end
  end

  def resolve({page, "_", key, relation}, m) when page in [:links, :set, :remove] do
    case kind_of_key(m, key) do
      nil -> :unknown
      kind -> resolve({page, kind, key, relation}, m)
    end
  end

  # An association its component holds is set there (`link_holder/4`).
  def resolve({page, kind, key, relation}, m) when page in [:links, :set, :remove] do
    {holder, holder_key} = link_holder(m, kind, key, relation)
    {page, holder, holder_key, relation}
  end

  def resolve(route, _m), do: route

  @doc """
  The kinds whose ids have no prefix (made from a name, say). A key no prefix claims is of
  one of them; when there are several, Control asks Facts which one has it.
  """
  def unprefixed_kinds(m), do: for(k <- kinds(m), k.id.prefixes == [], do: k.name)

  defp kind_of_key(m, key) do
    matches =
      for k <- kinds(m),
          prefix <- k.id.prefixes,
          String.starts_with?(key, prefix),
          do: {String.length(prefix), k.name}

    case matches |> Enum.uniq() |> Enum.sort(:desc) do
      [{longest, kind} | rest] ->
        if Enum.any?(rest, fn {length, other} -> length == longest and other != kind end),
          do: nil,
          else: kind

      # A key no prefix claims belongs to the one kind without a prefix, if there is one.
      [] ->
        case unprefixed_kinds(m) do
          [kind] -> kind
          _ -> nil
        end
    end
  end

  # The model's kinds, sorted by name; one kind, or nil; one relation, or nil.
  defp kinds(m), do: m.kinds |> Map.values() |> Enum.sort_by(& &1.name)
  defp kind(m, kind), do: is_binary(kind) && Map.get(m.kinds, kind)
  defp rel(m, relation), do: is_binary(relation) && Map.get(m.relations, relation)
  defp relations(m), do: m.relations |> Map.values() |> Enum.sort_by(& &1.name)

  @doc "Whether the model has `kind`."
  def kind?(m, kind), do: is_map(kind(m, kind))

  @doc """
  The relations by which a fact of `kind` belongs to a parent: those that start at the
  kind and the model marks as `parent` (at most one), sorted. A change form offers each,
  to move the fact. An association is never one.
  """
  def parent_relations(m, kind) do
    case kind(m, kind) do
      %{} = k -> for r <- k.relations, r.parent, do: r.name
      _ -> []
    end
  end

  @doc "The associations that start at `kind`: its other relations."
  def associations(m, kind) do
    case kind(m, kind) do
      %{} = k -> for r <- k.relations, not r.parent, do: r
      _ -> []
    end
  end

  @doc """
  Whether a client that is `by` may set `relation`: an association, unless the model
  says only a migration or a connector sets it (`set_by`), and `by` is not that.
  """
  def settable_relation?(m, relation, by \\ nil) do
    case rel(m, relation) do
      %{} = r -> not r.parent and (r.set_by == nil or by in r.set_by)
      _ -> false
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
  def submit_route(:answer, p), do: {:answer, p.kind, p.key, p.answer}
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
  def path({:answer, kind, key, answer}),
    do: Blocks.path(:answer, kind: kind, key: key, answer: answer)

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
  every page, form and agent tool shows it: `{"Create <kind>", "c"}`, for a kind as
  `AtlasControl.Model.kinds/0` gives it. The one place an action gets its words and key;
  with `nil` for the kind, only the verb (`"Update"`), as a form's button says it.
  """
  def operation(op, nil), do: {elem(@operations[op], 0), elem(@operations[op], 1)}

  def operation(op, k) do
    {verb, key} = @operations[op]
    {"#{verb} #{String.downcase(k.label)}", key}
  end

  defp action(op, k, to, key \\ nil) do
    {label, default} = operation(op, k)
    Blocks.action(label: label, key: key || default, to: to)
  end

  defp verb(op), do: op |> operation(nil) |> elem(0)
  defp key_of(op), do: op |> operation(nil) |> elem(1)

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
  def shows?(:home, _m, _kind), do: true
  def shows?({:assigned, _by}, _m, _kind), do: true

  def shows?({:worker_page, _, _}, m, kind),
    do:
      kind == get_in(m.turn || %{}, ["kind"]) or
        kind in Enum.map(
          ~w(execution interaction receipt),
          &get_in(m.guidance || %{}, [&1, "kind"])
        )

  def shows?({page, of, _key} = route, m, kind) when page in [:item, :delete] do
    listed = Enum.map(child_relations(m, of), &elem(&1, 1))

    kind == kind_of(route) or kind in listed or
      Enum.any?(listed, &(kind in progress_from(m, &1))) or
      kind in Enum.map(cause_fields(m), &elem(&1, 0)) or
      kind in for({_relation, part_kind, _component} <- components(m, of), do: part_kind)
  end

  def shows?({:list, of} = route, m, kind),
    do:
      open_work?(m, of) or kind == kind_of(route) or kind in progress_from(m, of) or
        kind in for(c <- counts(m, of), do: c.from)

  def shows?(route, _m, kind), do: kind == kind_of(route)

  @doc """
  The kinds whose facts change the progress of `kind` (the facts it rolls up, at any
  depth), or whether it is completed (the kinds whose facts it looks at).
  """
  def progress_from(m, kind) do
    case kind(m, kind) do
      %{} = k -> k.progress_from
      _ -> []
    end
  end

  def form?({:worker_page, :worker_guidance, _}), do: true
  def form?(route), do: elem_match?(route, [:new, :edit, :links, :remove, :answer])

  defp elem_match?(route, pages), do: is_tuple(route) and elem(route, 0) in pages

  @doc """
  The relations whose facts point at `kind`, from one kind each: `[{relation, from kind,
  relation}]`. A fact's page lists those facts; under a parent relation it can add one.
  """
  def child_relations(m, kind) do
    # A relation from several kinds (what is assigned to someone, say) is one list per kind.
    for r <- relations(m), kind in r.to, from <- r.from, do: {r.name, from, r}
  end

  # The id of a related list on a page; one per kind for a relation from several.
  defp list_id(relation, from, %{from: [_, _ | _]}), do: "list:#{relation}:#{from}"
  defp list_id(relation, _from, _r), do: "list:" <> relation

  @doc "The reads a route needs: `[{kind, content}]`."
  def reads({:worker_page, _, _}, _m), do: []

  def reads(:home, m) do
    case top_kinds(m) do
      [kind] -> reads({:list, kind}, m)
      _ -> []
    end
  end

  # What is assigned to `by` (the start page's `assigned`): read its Assignments once,
  # then their owner kinds. assigned_facts/2 joins only those selected Assignments;
  # nested linked reads would fetch the same full Assignment list again for every owner.
  def reads({:assigned, by}, m) do
    relation = assigned_rule(m).relation
    froms = (rel(m, relation) || %{from: []}).from

    for(from <- froms, do: {from, %{"linked" => %{relation => by}}}) ++
      for {_component, owner} <- owner_kinds(m, froms), do: {owner, %{}}
  end

  # Open work: every fact of the kinds the start's relation starts at (the Assignments)
  # and of the kinds they are components of, so the same rows as what is assigned to one
  # client, for everyone.
  def reads({:list, kind}, m) when is_binary(kind) do
    if open_work?(m, kind) do
      froms = (rel(m, assigned_rule(m).relation) || %{from: []}).from

      for(from <- froms, do: {from, %{}}) ++
        for {_component, owner} <- owner_kinds(m, froms), do: {owner, %{}}
    else
      list_reads(kind, m)
    end
  end

  def reads({:unavailable, _path, _failed}, _), do: []
  # What can fail is asked of the layers (`AtlasControl.Faults`), not read from Facts.
  def reads({:faults, _on}, _), do: []
  def reads({:fault, _fault, _on}, _), do: []
  def reads({:new, _}, _), do: []
  def reads({:new, _, _}, _), do: []

  def reads({:item, kind, key}, m) do
    children =
      for {relation, from, _} <- child_relations(m, kind),
          do: {from, %{"linked" => %{relation => key}}}

    causes = for {from, _name, _label} <- cause_fields(m), do: {from, %{}}

    parts =
      for {_relation, part_kind, component} <- components(m, kind),
          do: {part_kind, %{"key" => part_key(component, key)}}

    [{kind, %{"key" => key}} | children] ++ causes ++ parts
  end

  # A change form also lists where the fact can move: every fact of each parent kind.
  def reads({:edit, kind, key}, m) do
    parents = for relation <- parent_relations(m, kind), do: {parent_of(m, relation), %{}}
    [{kind, %{"key" => key}} | parents]
  end

  def reads({_, kind, key}, _), do: [{kind, %{"key" => key}}]

  # Setting a link that needs the facts under it completed reads them, as the page does.
  def reads({:answer, kind, key, _}, m), do: reads({:item, kind, key}, m)

  def reads({:set, kind, key, _relation}, m), do: reads({:item, kind, key}, m)
  # Removing reads as the page does too: an owner's answer may remove what is not set.
  def reads({:remove, kind, key, _relation}, m), do: reads({:item, kind, key}, m)

  # The fact, and the facts it may point at: of each kind the relation points at.
  def reads({:links, kind, key, relation}, m) do
    tos = (rel(m, relation) || %{to: []}).to
    [{kind, %{"key" => key}} | for(to <- tos, do: {to, %{}})]
  end

  def reads(:unknown, _), do: []
  def reads(:kinds, _), do: []

  # A kind whose rows count what points at it (`counts`) also reads, plainly, every fact of
  # each kind those relations start at.
  defp list_reads(kind, m),
    do: [
      {kind, %{}} | for(c <- counts(m, kind), do: {c.from, %{"linked" => %{}, "plain" => true}})
    ]

  # What a list row of `kind` counts: `[%{relation, from, text}]`, one per kind the
  # relation starts at.
  defp counts(m, kind) do
    case kind(m, kind) do
      %{} = k -> k.counts
      _ -> []
    end
  end

  @doc """
  The component relations that start at `kind`: the one fact each points at is made and
  deleted with the fact (its Assignment), and the fact's page shows its fields and
  associations as the fact's own. `[{relation, kind, component}]`.
  """
  def components(m, kind) do
    case kind(m, kind) do
      %{} = k ->
        for r <- k.relations,
            %{"key" => _} = component <- [r.component],
            [to] <- [r.to],
            do: {r.name, to, component}

      _ ->
        []
    end
  end

  # The kinds whose facts a fact of `kind` is made and deleted with, as their component.
  defp made_with(m, kind) do
    for r <- relations(m),
        is_map(r.component),
        r.to == [kind],
        from <- r.from,
        uniq: true,
        do: from
  end

  @doc "The key of the component a fact with `key` has, as `component` makes it."
  def part_key(%{"key" => template}, key), do: String.replace(template, "{key}", key)

  @doc """
  Where an association of `kind` is set: on the fact itself, or, when it starts at the kind
  of one of its components and not at `kind`, on that component: `{kind, key}`.
  """
  def link_holder(m, kind, key, relation) do
    from = (rel(m, relation) || %{from: []}).from

    found =
      if kind in from,
        do: nil,
        else:
          Enum.find_value(components(m, kind), fn {_rel, part_kind, component} ->
            if part_kind in from, do: {part_kind, part_key(component, key)}
          end)

    found || {kind, key}
  end

  @doc """
  The fields that name the fact that caused them (`cause`: the title of the list):
  `[{kind, field, title}]`. An item page lists the facts whose such field holds its key.
  """
  def cause_fields(m) do
    for k <- kinds(m),
        f <- Enum.sort_by(k.fields, & &1.name),
        f.cause != nil,
        do: {k.name, f.name, f.cause}
  end

  def top_kinds(m), do: for(k <- kinds(m), k.top, do: k.name)

  @doc """
  The start page of what is assigned to the client (the model's `start_page().assigned`),
  or nil when the model has none: `relation` (whose inverse it reads), and the words it
  shows (`title`, `empty`, `count`).
  """
  def assigned_rule(m), do: m.start[:assigned]

  @doc """
  Whether a client that is `by` (a fact of `by_kind`) opens on what is assigned to it: the
  model has a start page of assignments, and `by_kind` is a kind the relation points at.
  An agent or a migration on the command line opens on the plan, as before.
  """
  def assigned_start?(m, by_kind) do
    case assigned_rule(m) do
      nil -> false
      rule -> by_kind in (rel(m, rule.relation) || %{to: []}).to
    end
  end

  @doc """
  What is assigned, among the answers to `reads({:assigned, by})`: `[{kind, fact, link}]`,
  newest link first. `link` is the fact that points at the client (the Assignment, with
  what is expected and the origin of the link); `fact` is what it is the component of (or
  itself, when it is no component), left out once completed.
  """
  def assigned_facts(m, answers) do
    relation = assigned_rule(m).relation
    froms = (rel(m, relation) || %{from: []}).from
    owners = owner_kinds(m, froms)
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
  defp owner_kinds(m, kinds) do
    for r <- relations(m),
        is_map(r.component),
        [to] <- [r.to],
        to in kinds,
        owner <- r.from,
        do: {r.name, owner}
  end

  @doc "The count of what is assigned, as the model words it (`count`)."
  def assigned_count(m, answers) do
    rule = assigned_rule(m)
    n = length(assigned_facts(m, answers))
    String.replace(rule.count || "{count}", "{count}", Integer.to_string(n))
  end

  defp completed?(fact), do: get_in(fact, ["completion", "done"]) == true

  @doc """
  Open work (the model's `start_page().open`: `title`, `empty`): the list of a kind the
  start's relation starts at shows every open fact with whoever it is assigned to, what is
  expected and its deadline; what is assigned to one client is the same list, filtered on
  it. Nil when the model has none.
  """
  def open_rule(m), do: m.start[:open]

  @doc "Whether the list of `kind` is Open work: a kind the start's relation starts at."
  def open_work?(m, kind) do
    open_rule(m) != nil and kind in (rel(m, assigned_rule(m).relation) || %{from: []}).from
  end

  @doc """
  Open work among the answers to `reads({:list, kind})` of such a kind: as
  `assigned_facts/2`, for everyone, of the facts someone is assigned to or something is
  expected of; late first, then the newest link.
  """
  def open_facts(m, answers) do
    relation = assigned_rule(m).relation
    expected = open_rule(m).expected

    m
    |> assigned_facts(answers)
    |> Enum.filter(fn {_kind, _fact, link} ->
      (get_in(link, ["links", relation]) || []) != [] or
        Enum.any?(expected, fn field -> to_text(get_in(link, ["values", field])) != "" end)
    end)
    |> Enum.sort_by(fn {_, _, link} -> if link["late"] == true, do: 0, else: 1 end)
  end

  # Each row: the fact, what its owner is expected to do (the field its flow writes), and
  # since when and why it is theirs (the fact that set the link).
  defp assigned(m, _by, answers) do
    rule = assigned_rule(m)

    rows = for item <- assigned_facts(m, answers), do: work_row(m, rule.relation, item, false)

    list =
      Blocks.list(
        title: rule.title || "",
        rows: rows,
        empty: rule.empty,
        actions: start_actions(m)
      )

    page(rule.title || "", nil, [list])
  end

  # One row of what is assigned: the fact, whoever it is assigned to (`owner?`, in Open
  # work), what is expected, its deadline (late first), and since when and why.
  defp work_row(m, relation, {from, fact, link}, owner?) do
    k = kind(m, from)
    origin = get_in(link, ["origins", relation]) || %{}
    link_k = kind(m, link_kind(m, relation))

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
        review_text(fact),
        expected(k, fact, link),
        late_detail(link_k, link),
        origin["since"] && "since " <> short_moment(origin["since"]),
        not owner? && origin["cause"]
      ]
      |> Enum.reject(&(&1 in [nil, "", false]))
      |> Enum.join(" · ")

    Blocks.row(
      id: fact["key"],
      label: label(k, fact),
      detail: detail,
      to: path({:item, from, fact["key"]})
    )
  end

  # The kind the start's relation starts at (the Assignment), when it is one.
  defp link_kind(m, relation) do
    case rel(m, relation) do
      %{from: [kind]} -> kind
      _ -> nil
    end
  end

  # Open work: the list of a kind the start's relation starts at, for everyone.
  defp open_work(m, kind, answers) do
    case Enum.find(answers, &match?(%{"error" => _}, &1)) do
      nil ->
        rule = open_rule(m)
        relation = assigned_rule(m).relation

        rows = for item <- open_facts(m, answers), do: work_row(m, relation, item, true)

        list =
          Blocks.list(
            title: rule.title || kind(m, kind).plural,
            rows: rows,
            empty: rule.empty,
            actions: []
          )

        page(rule.title || "", "/", [list])

      failed ->
        unavailable(failed, "/")
    end
  end

  # What the fact's owner is expected to do: the value of the field a flow on its kind
  # writes, on the fact or, for a flow `on` a component, on its component (`link`).
  defp expected(nil, _fact, _link), do: nil

  defp expected(k, fact, link) do
    Enum.find_value(k.expected, fn e ->
      written = if e.on_component, do: link, else: fact
      value = to_text(get_in(written, ["values", e.field]))
      if value == "", do: nil, else: value
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

  # The start page's ways to the kinds kept off it: an action that opens the kind's list.
  defp start_actions(m, except \\ nil) do
    for a <- m.start.actions,
        a.kind != except,
        do: Blocks.action(label: a.label, key: a.key, to: path({:list, a.kind}))
  end

  # The operations a kind offers by hand (`AtlasControl.Model` `actions/3`, no fact).
  defp by_hand?(m, kind, op), do: op in m.module.actions(kind, nil, nil)

  # `newest_first` lists a kind newest first (by key, which counts up).
  defp sort_facts(facts, k) do
    direction = if k && k.newest_first, do: :desc, else: :asc
    Enum.sort_by(facts, & &1["key"], direction)
  end

  # Pages

  @doc """
  The page for `route`: `%{title, back, blocks}`. `answers` are Facts' answers to
  `reads/2`, in order. `form` carries values and errors to show a form again, and who
  views it (`by`, `by_kind`).
  """
  def render(route, m, answers, form \\ %{})

  def render({:assigned, by}, m, answers, _form), do: assigned(m, by, answers)

  def render(:home, m, answers, form) do
    case top_kinds(m) do
      [kind] -> %{render({:list, kind}, m, answers, form) | back: nil}
      kinds -> home(m, kinds)
    end
  end

  # What a client can create and where, for one that has no screen to find out on, such
  # as an agent (`atlas help`): one item per kind, from the model alone.
  def render(:kinds, m, [], _form) do
    items =
      for k <- kinds(m) do
        kind = k.name
        ask = m.module.form(kind, :create).ask

        parents = for relation <- parent_relations(m, kind), do: parent_of(m, relation)

        children =
          for {_relation, from, r} <- child_relations(m, kind), r.parent, do: from

        associations =
          for r <- associations(m, kind) do
            limit = if r.one, do: ", at most one", else: ""

            how =
              cond do
                r.set_by != nil ->
                  "; set by a #{Enum.join(r.set_by, " or ")}, never by hand"

                r.only_target != nil ->
                  "; #{r.only_target.error || "only one of them sets it"}: in the TUI, never by an agent"

                true ->
                  "; set #{r.name}=<key>, empty removes it"
              end

            "#{r.name}: to #{Enum.join(r.to, " or ")}#{limit}#{how}"
          end

        # A parent relation is a field a change sets too: it moves the fact.
        fields =
          for(f <- k.fields, do: "#{f.name}: #{field_text(f, f.name in ask)}") ++
            for relation <- parent_relations(m, kind),
                do: "#{relation}: the key of a #{parent_of(m, relation)}; a change moves it there"

        {"kind:#{kind}",
         Blocks.item(
           title: "#{k.label} (#{kind})",
           # A component (`components/2`): Facts makes and deletes it with its fact.
           # A kind only a layer writes (nothing by hand: a turn, Runtime's) is no tool.
           fields:
             [
               Blocks.pair(label: "Kind", value: kind),
               Blocks.pair(label: "About", value: String.trim(k.about || "")),
               Blocks.pair(label: "Create asks", value: Enum.join(ask, ", ")),
               Blocks.pair(label: "Id", value: id_text(k)),
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
               if(k.agent,
                 do: [Blocks.pair(label: "Agent record", value: k.agent)],
                 else: []
               ) ++
               case made_with(m, kind) do
                 [] -> []
                 froms -> [Blocks.pair(label: "Made with", value: Enum.join(froms, ", "))]
               end ++
               if(m.module.actions(kind, nil, nil) == [],
                 do: [Blocks.pair(label: "By hand", value: "no")],
                 else: []
               ),
           # What can be done with one, named as every page names it; `<key>` is its key.
           actions: [
             action(:create, k, path({:new, kind})),
             action(:update, k, "/k/_/<key>/edit"),
             action(:delete, k, "/k/_/<key>/delete")
           ]
         )}
      end

    page("Kinds", "/", items)
  end

  def render(:unknown, _m, _answers, _form),
    do: missing("No such page", "Control serves no page at this path.", "/")

  # A page of the contract that could not be worked out, because Facts did not answer
  # (`AtlasControl.Session`): said as a failed read says it, never "No such page".
  def render({:unavailable, _path, failed}, _m, _answers, _form),
    do: unavailable(failed, "/")

  def render(route, m, answers, form) do
    case kind(m, kind_of(route)) do
      %{} = k -> page(route, k.name, k, m, answers, form)
      _ -> missing("Nothing here", "This page does not exist (any more).", "/")
    end
  end

  defp home(m, kinds) do
    rows =
      for kind <- kinds do
        k = kind(m, kind)
        Blocks.row(label: k.plural, detail: first_line(k.about), to: path({:list, kind}))
      end

    page("Atlas", nil, [
      Blocks.list(
        title: "Atlas",
        rows: rows,
        empty: "rela describes nothing yet",
        actions: start_actions(m)
      )
    ])
  end

  # Who views a page, as the model's callbacks take it.
  defp viewer(form), do: %{key: form[:by], kind: form[:by_kind]}

  defp page({:list, kind}, kind, k, m, answers, form) do
    if open_work?(m, kind),
      do: open_work(m, kind, answers),
      else: list_page(kind, k, m, answers, form)
  end

  defp page({:item, kind, key}, kind, k, m, [answer | child_answers], form) do
    case answer do
      %{"fact" => nil} ->
        missing("#{k.label} #{key}", "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        back = path(owner(m, kind, answer) || up(m, kind, fact))
        relations = child_relations(m, kind)
        {child_answers, rest} = Enum.split(child_answers, length(relations))
        {cause_answers, part_answers} = Enum.split(rest, length(cause_fields(m)))
        parts = parts(m, kind, part_answers)
        todo = m.module.todo(kind, fact, parts_by_kind(parts), viewer(form))

        fields =
          [Blocks.pair(label: "Id", value: key)] ++
            own_fields(k, fact, k.hidden) ++
            Enum.flat_map(parts, fn {_part_kind, part_k, part, made} ->
              own_fields(part_k, part, made ++ part_k.hidden)
            end) ++
            Enum.map(parents(m, kind, fact), fn {label, keys} ->
              Blocks.pair(label: label, value: Enum.join(keys, ", "))
            end) ++
            progress_pair(m, k, fact) ++
            review_pair(fact) ++
            linked(m, kind, fact) ++
            Enum.flat_map(parts, fn {part_kind, _k, part, _made} -> linked(m, part_kind, part) end) ++
            copy(answer["copy"])

        item =
          Blocks.item(
            title: "#{k.label} #{key}: #{label(k, fact)}",
            fields: fields,
            # Nothing to change when a user may set nothing but where the id comes from, and
            # there is no parent to move it to. The owner's answers (IS-Atlas-56) take the
            # place of an action on the same key.
            actions:
              fact_actions(m, k, fact, form) ++
                link_actions(m, kind, fact, form) ++
                Enum.flat_map(parts, fn {part_kind, _k, part, _made} ->
                  link_actions(m, part_kind, part, form)
                end),
            links: links(k, fact)
          )
          |> answers_first(answer_actions(kind, fact, todo))

        lists =
          relations
          |> Enum.zip(child_answers)
          |> Enum.zip(create_keys(m, kind))
          # A list of what points here through an association shows only when it has some.
          |> Enum.reject(fn {{_relation, answer}, create_key} ->
            create_key == nil and match?(%{"facts" => []}, answer)
          end)
          |> Enum.map(fn {{{relation, from, r}, child_answer}, create_key} ->
            {list_id(relation, from, r),
             child_list(m, {relation, from, r}, key, child_answer, create_key)}
          end)

        # Two parts, by what they hold, never how they look: the main part (the fact
        # itself, and later what is said about it) and the related part (the related
        # lists, what names it as its cause, then the facts it points at). Each list in a
        # section that carries its title. A client lays the parts out as it sees fit.
        references =
          lists ++
            cause_lists(m, key, cause_answers) ++
            parent_lists(m, kind, fact) ++
            Enum.flat_map(parts, fn {part_kind, _k, part, _made} ->
              parent_lists(m, part_kind, part)
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
          case todo do
            nil ->
              {content, markup}

            todo ->
              {[{"todo", todo_item(todo)} | content],
               [Blocks.part("todo", "todo", title: todo.words.title, role: "todo") | markup]}
          end

        page("#{k.label} #{key}", back, content, markup)

      %{"error" => _} = failed ->
        unavailable(failed, path({:list, kind}))
    end
  end

  # Set or remove the links of one association; the change becomes a fact with its note.
  defp page({:links, kind, key, relation}, kind, k, m, [answer | targets], form) do
    back = path({:item, kind, key})
    r = rel(m, relation) || missing_relation(relation)
    name = r.label
    change = change_action(m, relation)

    title =
      if change,
        do: "#{change.label} #{label(k, fact_of(answer, key))}",
        else: "#{String.capitalize(name)}: #{key}"

    case answer do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        cond do
          kind not in r.from ->
            missing(title, "#{k.label} has no #{name}.", back)

          not may_link?(m, relation, form[:by], form[:by_kind]) ->
            why =
              cond do
                r.set_by -> "only a #{Enum.join(r.set_by, " or ")} sets it"
                r.only_target -> r.only_target.error || "not by this client"
                true -> "it says what the fact belongs under"
              end

            missing(title, "#{String.capitalize(name)} is not set here: #{why}.", back)

          true ->
            current = Enum.join(get_in(fact, ["links", relation]) || [], ", ")
            # The fields the change also asks (`with`), as the fact holds them.
            with_fields = if change, do: change.with, else: []

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
                    link_input(r, values["to"], targets)
                  ] ++
                    inputs(k, values, only: with_fields) ++
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

  defp page({:answer, kind, key, name} = route, kind, _k, m, answers, form) do
    back = path({:item, kind, key})

    case declared_answer(m, kind, name, answers, form) do
      nil ->
        missing(key, "This answer is only available to the current owner in this state.", back)

      answer ->
        title = "#{answer.label} #{key}"

        block =
          if answer.note do
            Blocks.form(
              title: title,
              inputs: [
                Blocks.input(
                  name: "note",
                  label: "Note",
                  kind: "multiline",
                  required: true,
                  value: (form[:values] || %{})["note"]
                )
              ],
              submit_label: answer.label,
              submit_to: call_to(route),
              cancel_to: back,
              errors: form[:errors] || []
            )
          else
            Blocks.confirm(
              title: "#{title}?",
              text: title,
              confirm_label: answer.label,
              confirm_to: call_to(route),
              cancel_to: back
            )
          end

        page(title, back, [block])
    end
  end

  # Link the fact to the client itself (Accept), after asking; refused, with why, while it
  # may not: another client, already linked, or facts under it not completed.
  defp page({:set, kind, key, relation} = route, kind, k, m, answers, form) do
    back = path({:item, kind, key})
    r = rel(m, relation) || missing_relation(relation)
    label = (r.set && r.set.label) || String.capitalize(r.label)
    title = "#{label} #{key}"

    case hd(answers) do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        case set_problem(m, route, answers, form[:by], form[:by_kind]) do
          nil ->
            confirm =
              Blocks.confirm(
                title: "#{title}?",
                text: "#{key}: #{label(k, fact)} will be #{r.label} #{form[:by]}.",
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
  defp page({:remove, kind, key, relation} = route, kind, _k, m, [answer | rest], form) do
    back = path({:item, kind, key})
    r = rel(m, relation) || missing_relation(relation)
    # The owner's answer that removes it (reject): also when it is not set (IS-Atlas-56).
    as_answer =
      case answer do
        %{"fact" => %{} = fact} ->
          parts = item_parts(m, kind, rest)
          todo = m.module.todo(kind, fact, parts_by_kind(parts), viewer(form))
          Enum.find((todo && todo.answers) || [], &(&1.remove == relation))

        _ ->
          nil
      end

    label =
      (as_answer && as_answer.label) || (r.remove && r.remove.label) || "Remove #{r.label}"

    title = "#{label} #{key}"

    case answer do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        cond do
          not may_link?(m, relation, form[:by], form[:by_kind]) ->
            missing(title, "#{title} is not done here: #{why_not(r)}.", back)

          (get_in(fact, ["links", relation]) || []) == [] and as_answer == nil ->
            missing(title, "#{key} has no #{r.label}.", back)

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

  defp page({:new, kind, {_relation, parent}} = route, kind, k, m, [], form) do
    %{blocks: [form_block]} = page({:new, kind}, kind, k, m, [], form)
    parent_route = {:item, parent_kind(m, route), parent}
    title = "#{elem(operation(:create, k), 0)} in #{parent}"

    form_block =
      form_block
      |> put_in(["props", "title"], title)
      |> put_in(["props", "submit_to"], call_to(route))
      |> put_in(["props", "cancel_to"], path(parent_route))

    page(title, path(parent_route), [form_block])
  end

  # A create asks only what the kind's create rule asks; the id is made, never typed.
  defp page({:new, kind}, kind, k, m, [], form) do
    values = form[:values] || %{}
    asked = m.module.form(kind, :create).ask

    form_block =
      Blocks.form(
        title: elem(operation(:create, k), 0),
        inputs: inputs(k, values, only: asked),
        submit_label: verb(:create),
        submit_to: call_to({:new, kind}),
        cancel_to: path({:list, kind}),
        errors: form[:errors] || []
      )

    page(elem(operation(:create, k), 0), path({:list, kind}), [form_block])
  end

  defp page({:edit, kind, key}, kind, k, m, [answer | parent_answers], form) do
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
          |> Map.merge(parent_values(m, kind, fact))
          |> Map.merge(form[:values] || %{})

        edit = m.module.form(kind, :edit)

        form_block =
          Blocks.form(
            title: "#{verb(:update)} #{key}",
            # The id is shown, never changed; nor is the field it was made from.
            inputs:
              [Blocks.input(name: "_key", label: "Id", kind: "readonly", value: key)] ++
                from_input(k, values) ++
                inputs(k, values, only: edit.ask) ++
                parent_inputs(m, kind, values, parent_answers),
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

  defp page({:delete, kind, key}, kind, %{delete_error: error}, _m, _answers, _form)
       when is_binary(error) do
    missing("Delete #{key}", error, path({:item, kind, key}))
  end

  defp page({:delete, kind, key}, kind, k, m, [answer], _form) do
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
          for r <- relations(m),
              is_map(r.component),
              kind in r.to,
              owner <- get_in(answer, ["incoming", r.name]) || [],
              do: owner

        held =
          if owners == [],
            do: Enum.reject(children(m, kind, answer), fn {_, keys} -> keys == [] end),
            else: {:part_of, owners}

        parts =
          for {relation, part_kind, _} <- components(m, kind),
              part <- get_in(fact, ["links", relation]) || [],
              do: "#{singular(m, part_kind)} #{part}"

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
                title: "#{elem(operation(:delete, k), 0)} #{key}?",
                text:
                  "#{key}: #{label(k, fact)} will be deleted#{with_parts}. " <>
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

  defp page(_route, _kind, _k, _m, _answers, _form),
    do: missing("Nothing here", "This page does not exist.", "/")

  defp list_page(kind, k, m, [answer | count_answers], form) do
    # The only top kind's list is the start page; there is nothing to go back to.
    start? = top_kinds(m) == [kind]
    # With a start page of assignments, the plan is one key away from it, and back.
    first? = start? and not assigned_start?(m, form[:by_kind])

    case answer do
      %{"facts" => facts} ->
        counted = counted(m, kind, count_answers)

        rows =
          facts
          |> sort_facts(k)
          |> Enum.map(fn fact ->
            Blocks.row(
              id: fact["key"],
              label: label(k, fact),
              detail: join_detail(detail(k, fact), counted.(fact["key"])),
              to: path({:item, kind, fact["key"]}),
              links: links(k, fact)
            )
          end)

        creates? = by_hand?(m, kind, :create)

        list =
          Blocks.list(
            title: k.plural,
            rows: rows,
            empty:
              if(creates?,
                do:
                  "No #{String.downcase(k.plural)} yet. " <>
                    "Press #{key_of(:create)} to create one.",
                else: "No #{String.downcase(k.plural)} yet."
              ),
            actions:
              if(creates?, do: [action(:create, k, path({:new, kind}))], else: []) ++
                if(start?, do: start_actions(m, kind), else: [])
          )

        back = if first?, do: nil, else: "/"
        page(k.plural, back, [list])

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

  # A relation a route names that the model does not have: nothing to set or show.
  defp missing_relation(relation),
    do: %{
      name: relation,
      label: relation,
      from: [],
      to: [],
      one: false,
      parent: false,
      set_by: nil,
      only_target: nil,
      set: nil,
      remove: nil,
      change: nil,
      requires_completed_children: nil
    }

  # The key that creates a fact in each related list, in order; a list of the facts that
  # point at this one through an association creates nothing (nil).
  defp create_keys(m, kind) do
    {keys, _} =
      Enum.map_reduce(
        child_relations(m, kind),
        [key_of(:create) | @more_create_keys],
        fn {_, _, r}, free ->
          case {r.parent, free} do
            {true, [key | rest]} -> {key, rest}
            _ -> {nil, free}
          end
        end
      )

    keys
  end

  defp link_input(%{one: true}, value, [_ | _] = targets) do
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

  defp link_input(_r, value, _targets),
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
  links of `relation`: a client may set it (`settable_relation?/3`), and when the model
  says only one of the facts it points at does (`only_target`), `by` is one of that kind,
  or a client the rule names in `also` (a migration).
  """
  def may_link?(m, relation, by, by_kind) do
    r = rel(m, relation) || missing_relation(relation)

    settable_relation?(m, relation, by) and
      case r.only_target do
        %{} = only -> by in only.also or by_kind in r.to
        _ -> true
      end
  end

  @doc "Whether a client that is `by` may set `relation` to `keys`: only to itself, when so ruled."
  def may_link_to?(m, relation, by, by_kind, keys) do
    only = (rel(m, relation) || missing_relation(relation)).only_target

    may_link?(m, relation, by, by_kind) and
      (only == nil or by in only.also or Enum.all?(keys, &(&1 == by)))
  end

  defp why_not(r), do: (r.only_target && r.only_target.error) || "not by this client"

  @doc """
  Why the client `by` may not link the fact of `route` (`{:set, kind, key, relation}`) to
  itself, or nil. `answers` are Facts' answers to the route's reads: the fact, then the
  facts under it.
  """
  def set_problem(m, {:set, kind, key, relation}, [answer | child_answers], by, by_kind) do
    r = rel(m, relation) || missing_relation(relation)
    fact = answer["fact"] || %{}
    linked = get_in(fact, ["links", relation]) || []

    open =
      for {{_relation, _from, child_r}, %{"facts" => facts}} <-
            Enum.zip(child_relations(m, kind), child_answers),
          child_r.parent,
          child <- facts,
          child["completion"] == nil,
          do: child["key"]

    cond do
      kind not in r.from ->
        "#{key} has no #{r.label}"

      not may_link?(m, relation, by, by_kind) ->
        "#{String.capitalize(r.label)} is not set here: #{why_not(r)}."

      linked != [] ->
        "#{key} is #{r.label} #{Enum.join(linked, ", ")} already."

      open != [] and is_binary(r.requires_completed_children) ->
        r.requires_completed_children
        |> String.replace("{key}", key)
        |> String.replace("{children}", Enum.join(Enum.sort(open), ", "))

      true ->
        nil
    end
  end

  # The operations and actions the model offers on a fact's page, for this client.
  defp fact_actions(m, k, fact, form) do
    for action <- m.module.actions(k.name, fact, viewer(form)) do
      case action do
        %{op: :update} -> action(:update, k, path({:edit, k.name, fact["key"]}))
        %{op: :delete} -> action(:delete, k, path({:delete, k.name, fact["key"]}))
        %{label: label, key: key, to: to} -> Blocks.action(label: label, key: key, to: to)
      end
    end
  end

  # Set or remove, as the model names them, for a client that may.
  defp link_actions(m, kind, fact, form) do
    for r <- associations(m, kind),
        r.set != nil or r.remove != nil or r.change != nil,
        may_link?(m, r.name, form[:by], form[:by_kind]),
        {action, page} <-
          [
            cond do
              r.change != nil -> {r.change, :links}
              (get_in(fact, ["links", r.name]) || []) == [] -> {r.set, :set}
              true -> {r.remove, :remove}
            end
          ],
        %{label: label, key: key} <- [action],
        do: Blocks.action(label: label, key: key, to: path({page, kind, fact["key"], r.name}))
  end

  @doc """
  The action that changes an association whether a link is there or not (`%{label, key,
  with, cause}`), or nil.
  """
  def change_action(m, relation), do: (rel(m, relation) || missing_relation(relation)).change

  @doc """
  The cause of a change made through `change_action/2`: the note, when one is given, as it
  is given; else its `cause` with {to} (the keys, or nobody) and {by} filled in. Nil when
  there is neither.
  """
  def change_cause(_change, _keys, _by, note) when is_binary(note) and note != "", do: note

  def change_cause(%{cause: cause}, keys, by, _note) when is_binary(cause) do
    to = if keys == [], do: "nobody", else: Enum.join(keys, ", ")
    cause |> String.replace("{to}", to) |> String.replace("{by}", to_string(by))
  end

  def change_cause(_change, _keys, _by, _note), do: nil

  @doc """
  Why a fact of `kind` may not go under `parent` (a fact of `parent_kind`, as Facts
  answers it) through a parent relation, or nil: an association of the parent marked
  `closes_parent` has a link (it is accepted).
  """
  def closed_problem(m, kind, parent_kind, parent) do
    Enum.find_value(associations(m, parent_kind), fn r ->
      if is_binary(r.closes_parent) and (get_in(parent, ["links", r.name]) || []) != [] do
        r.closes_parent
        |> String.replace("{parent}", parent["key"])
        |> String.replace("{kind}", singular(m, parent_kind) |> String.downcase())
        |> String.replace("{child}", singular(m, kind) |> String.downcase())
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

  defp child_list(m, {relation, from, r}, key, answer, create_key) do
    from_k = kind(m, from) || unknown_kind(from)
    title = String.capitalize(r.inverse_label || from_k.plural)

    # One list per kind for a relation from several: the kind says which.
    title = if length(r.from) > 1, do: "#{title}: #{from_k.plural}", else: title

    rows =
      case answer do
        %{"facts" => facts} ->
          facts
          |> sort_facts(from_k)
          |> Enum.map(
            &Blocks.row(
              id: &1["key"],
              label: label(from_k, &1),
              detail: detail(from_k, &1),
              to: path({:item, from, &1["key"]}),
              links: links(from_k, &1)
            )
          )

        _ ->
          []
      end

    # A relation marked to add nothing lists its facts without a way to add one here; so
    # does one with no create key (an association).
    add? = create_key != nil and r.add and by_hand?(m, from, :create)

    empty =
      case answer do
        %{"error" => error} -> "#{error}."
        _ when add? -> "No #{String.downcase(title)} yet. Press #{create_key} to create one."
        _ -> "No #{String.downcase(title)} yet."
      end

    actions =
      if add?,
        do: [action(:create, from_k, path({:new, from, {relation, key}}), create_key)],
        else: []

    {title, Blocks.list(rows: rows, empty: empty, actions: actions)}
  end

  # A kind a relation names that the model does not have: named by its own name.
  defp unknown_kind(kind),
    do: %{
      name: kind,
      label: humanize(kind),
      plural: humanize(kind <> "s"),
      primary: nil,
      id: %{from: nil},
      fields: [],
      newest_first: false,
      progress: nil,
      late: nil,
      hidden: []
    }

  # The facts whose cause field holds this fact's key, one list per such field; only those
  # with rows. They follow the related lists in the references part.
  defp cause_lists(m, key, answers) do
    for {{from, name, title}, %{"facts" => facts}} <- Enum.zip(cause_fields(m), answers),
        naming = Enum.filter(facts, &(to_text(&1["values"][name]) == key)),
        naming != [] do
      from_k = kind(m, from)

      rows =
        for fact <- sort_facts(naming, from_k),
            do:
              Blocks.row(
                id: fact["key"],
                label: label(from_k, fact),
                detail: detail(from_k, fact),
                to: path({:item, from, fact["key"]})
              )

      {"cause:#{from}:#{name}", {title, Blocks.list(rows: rows)}}
    end
  end

  @doc "Where to go after a fact of `kind` is deleted: its parent, or the list of its kind."
  def after_delete(m, kind, %{"fact" => fact}) when is_map(fact), do: up(m, kind, fact)
  def after_delete(_m, kind, _answer), do: {:list, kind}

  # The page of the fact a component belongs to (`components/2`), from what points at it.
  defp owner(m, kind, answer) do
    Enum.find_value(relations(m), fn r ->
      with %{} <- r.component,
           true <- kind in r.to,
           [key] <- get_in(answer, ["incoming", r.name]) do
        {:item, "_", key}
      else
        _ -> nil
      end
    end)
  end

  # A fact's parent page, when it points at one through a parent relation.
  defp up(m, kind, fact) do
    parent =
      Enum.find_value(relations(m), fn r ->
        with true <- kind in r.from and r.parent,
             [to] <- r.to,
             [parent_key] <- get_in(fact, ["links", r.name]) do
          {:item, to, parent_key}
        else
          _ -> nil
        end
      end)

    parent || {:list, kind}
  end

  # The facts this one belongs under: `[{label, keys}]`.
  defp parents(m, kind, fact) do
    for r <- relations(m),
        r.parent,
        kind in r.from,
        keys = get_in(fact, ["links", r.name]) || [],
        keys != [],
        do: {String.capitalize(r.label), keys}
  end

  # The fields a page shows of a fact: those a user may set, and the others once they have a
  # value. `made` names those a component's values are made from (the fact's key), and the
  # fields a flow keeps to itself: not shown.
  defp own_fields(k, fact, made) do
    Enum.flat_map(k.fields, fn f ->
      value = fact["values"][f.name]

      # A field only a connector or the system fills shows only once it has a value.
      if f.name not in made and (f.settable or value not in [nil, ""]),
        do: [Blocks.pair(label: f.label, value: show(f, value) <> late(k, fact, f.name))],
        else: []
    end)
  end

  # What its owner is to do (IS-Atlas-54), as the model's `todo/4` gives it: what is
  # expected, why it came to them, the instructions, the section of the fact they name,
  # and the answers they can give. Every word is the model's or the fact's.
  defp todo_item(todo) do
    words = todo.words
    answers = for a <- todo.answers, do: "#{a.key} #{a.label}"

    fields =
      [
        Blocks.pair(
          label: words.why,
          value: todo.why.text,
          origin: todo.why.since && Blocks.origin(since: todo.why.since, by: todo.why.by)
        )
      ] ++
        if(todo.instructions,
          do: [Blocks.pair(label: words.instructions, value: todo.instructions)],
          else: []
        ) ++
        case todo.section do
          %{heading: heading, text: text} -> [Blocks.pair(label: heading, value: text)]
          nil -> []
        end ++
        if(answers == [],
          do: [],
          else: [Blocks.pair(label: words.answers, value: Enum.join(answers, "   "))]
        )

    Blocks.item(title: "#{todo.title}: #{todo.expected}", fields: fields)
  end

  @doc """
  The link that makes `by` the one who decides, when a change sets a value that decides
  (the change form's `decides`: `writes` a value, decided through `relation`) and does not
  name them already; otherwise none. Facts still checks that they may decide.
  """
  def decider_link(m, kind, values, links, by) do
    case m.module.form(kind, :edit) do
      %{decides: %{relation: relation, writes: writes}} when is_binary(by) and by != "" ->
        decides? =
          Enum.any?(writes, fn {field, allowed} ->
            Map.has_key?(values, field) and to_string(values[field]) in allowed
          end)

        if decides? and List.wrap(links[relation]) != [by],
          do: %{relation => [by]},
          else: %{}

      _ ->
        %{}
    end
  end

  @doc "The owner's answer `name` (one that writes a change), from fresh item reads; or nil."
  def declared_answer(m, kind, name, [%{"fact" => fact} | rest], form) when is_map(fact) do
    case m.module.todo(kind, fact, parts_by_kind(item_parts(m, kind, rest)), viewer(form)) do
      %{answers: answers} -> Enum.find(answers, &(&1.key == name and &1.change))
      _ -> nil
    end
  end

  def declared_answer(_, _, _, _, _), do: nil

  @doc "The item an answer is given on, as the model's `answer/4` takes it: the fact and its parts."
  def answer_item(m, kind, [%{"fact" => fact} | rest]) when is_map(fact),
    do: %{"fact" => fact, "parts" => parts_by_kind(item_parts(m, kind, rest))}

  def answer_item(_m, _kind, _answers), do: %{}

  # Each answer that writes a change, or sets or removes an association of the fact, as an
  # action to its page.
  defp answer_actions(_kind, _fact, nil), do: []

  defp answer_actions(kind, fact, todo) do
    changes =
      for a <- todo.answers,
          a.change,
          do:
            Blocks.action(
              label: a.label,
              key: a.key,
              to: path({:answer, kind, fact["key"], a.key})
            )

    changes ++
      for a <- todo.answers,
          {op, relation} <- [{:set, a.set}, {:remove, a.remove}],
          is_binary(relation),
          do:
            Blocks.action(label: a.label, key: a.key, to: path({op, kind, fact["key"], relation}))
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
  defp item_parts(m, kind, rest) do
    {_children, rest} = Enum.split(rest, length(child_relations(m, kind)))
    {_causes, part_answers} = Enum.split(rest, length(cause_fields(m)))
    parts(m, kind, part_answers)
  end

  # The components Facts answered (one that is not there yet shows nothing): `[{kind, kind
  # view, fact, made}]`, where `made` names the fields made from the fact's key.
  defp parts(m, kind, answers) do
    for {{_relation, part_kind, component}, %{"fact" => %{} = part}} <-
          Enum.zip(components(m, kind), answers),
        do:
          {part_kind, kind(m, part_kind) || unknown_kind(part_kind), part,
           Map.keys(component["values"] || %{})}
  end

  defp parts_by_kind(parts), do: Map.new(parts, fn {kind, _k, part, _made} -> {kind, part} end)

  # Its associations, each with the fact that set it (since, by, cause) when Facts knows
  # it. One that was removed shows as removed while that is the latest fact about it.
  defp linked(m, kind, fact) do
    for r <- associations(m, kind),
        not is_map(r.component),
        keys = get_in(fact, ["links", r.name]) || [],
        origin = [get_in(fact, ["origins", r.name])],
        keys != [] or origin != [nil] do
      origin = hd(origin)

      Blocks.pair(
        label: String.capitalize(r.label),
        value: if(keys == [], do: "—", else: Enum.join(keys, ", ")),
        origin:
          origin &&
            Blocks.origin(since: origin["since"], by: origin["by"], cause: origin["cause"])
      )
    end
  end

  # The facts this one points at, as lists to open them from: `[{id, {title, list}}]`.
  defp parent_lists(m, kind, fact) do
    for r <- relations(m),
        kind in r.from,
        r.to != [],
        keys = get_in(fact, ["links", r.name]) || [],
        keys != [] do
      # A relation that points at several kinds: Facts says which kind each key is.
      kind_of = fn key ->
        case r.to do
          [to] -> to
          _ -> get_in(fact, ["link_kinds", r.name, key])
        end
      end

      rows =
        for key <- Enum.sort(keys), to = kind_of.(key), to != nil do
          Blocks.row(id: key, label: singular(m, to), to: path({:item, to, key}))
        end

      {"parent:" <> r.name, {String.capitalize(r.label), Blocks.list(rows: rows)}}
    end
  end

  # The fact's web address, opened outside the client: its first field the model marks as
  # a URL, when it has a value. A client opens only http and https, and Control offers
  # nothing else. Nil when there is none.
  defp links(k, fact) do
    urls =
      for f <- k.fields,
          f.url,
          value = fact["values"][f.name],
          is_binary(value) and String.match?(value, ~r{^https?://\S+$}i),
          do: value

    case urls do
      [url | _] -> [Blocks.link(label: "Open in browser", key: "o", url: url)]
      [] -> nil
    end
  end

  defp parent_kind(m, {:new, _kind, {relation, _parent}}),
    do: (rel(m, relation) || missing_relation(relation)).to |> List.first()

  defp missing(title, text, back),
    do: page(title, back, [Blocks.confirm(title: title, text: text, cancel_to: back)])

  # A read that failed, titled by what happened: Facts did not answer at all, rela could not
  # be reached, or rela answered with an error (its own words, and what to do, are in the
  # text). Never "not reachable" when rela answered.
  defp unavailable(%{"error" => error} = failed, back) do
    title =
      case failed["error_kind"] do
        "unreachable" -> "rela is not reachable"
        "answered" -> "rela answered with an error"
        _ -> "Facts did not answer"
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
  def children(m, kind, answer) do
    for r <- relations(m), kind in r.to do
      keys = get_in(answer, ["incoming", r.name]) || []

      # One of them is named by its kind's label ("1 part"), more by the inverse label ("2 parts").
      label =
        case {keys, r.from} do
          {[_], [from]} -> (kind(m, from) || %{label: nil}).label
          _ -> nil
        end || r.inverse_label || r.name

      {String.capitalize(label), keys}
    end
  end

  defp remove_first([{_, [_]}]),
    do: "Remove it first; Atlas never deletes it along with its parent."

  defp remove_first(_held),
    do: "Remove them first; Atlas never deletes them along with their parent."

  # Form inputs from the model

  # These fields, in this order, those a user may set.
  defp inputs(k, values, only: names) do
    for name <- names, f = field(k, name), f.settable do
      Blocks.input(
        name: f.name,
        label: f.label,
        kind: input_kind(f),
        value: values[f.name],
        required: f.required,
        hint: f.hint,
        choices: choices(f)
      )
    end
  end

  defp field(k, name), do: Enum.find(k.fields, &(&1.name == name))

  defp from_input(k, values) do
    case k.id.from do
      nil ->
        []

      name ->
        [Blocks.input(name: name, label: humanize(name), kind: "readonly", value: values[name])]
    end
  end

  @doc """
  The relations among `links` (`%{relation => [parent]}`) that limit how many facts point
  at one parent (`limit`): `[{relation, parent}]`.
  """
  def limited(m, links) do
    for {relation, parents} <- links,
        is_map((rel(m, relation) || %{limit: nil}).limit),
        parent <- parents,
        do: {relation, parent}
  end

  @doc """
  Why a fact of `kind` with key `key` may not point at `parent` through `relation`, or nil.
  `children` are the facts of `kind` that point at it now. Only those whose `field` is one
  of the limit's `values` count, and never the fact itself (sent again, or not moving).
  """
  def over_limit(m, relation, kind, key, parent, children) do
    limit =
      (rel(m, relation) || %{limit: nil}).limit || %{field: nil, values: [], max: nil, error: nil}

    f = kind(m, kind) && field(kind(m, kind), limit.field)

    counted =
      Enum.filter(children, fn child ->
        child["key"] != key and (child["values"] || %{})[limit.field] in limit.values
      end)

    if is_integer(limit.max) and length(counted) >= limit.max do
      [first | _] = Enum.sort_by(counted, & &1["key"])
      value = first["values"][limit.field]
      label = (f && f.labels[value]) || to_text(value)

      (limit.error || "{parent} already has {child} ({value})")
      |> String.replace("{parent}", parent)
      |> String.replace("{child}", first["key"])
      |> String.replace("{value}", label)
    end
  end

  @doc "The parent a fact points at through each of its parent relations: `%{relation => key}`."
  def parent_values(m, kind, fact) do
    for relation <- parent_relations(m, kind),
        [parent | _] <- [get_in(fact, ["links", relation]) || []],
        into: %{},
        do: {relation, parent}
  end

  # Where a fact can move: per parent relation a choice of every fact of the parent's
  # kind, the current parent selected. A fact that has a parent keeps one: no empty choice.
  defp parent_inputs(m, kind, values, answers) do
    for {relation, at} <- Enum.with_index(parent_relations(m, kind)) do
      answer = Enum.at(answers, at)
      to = parent_of(m, relation)
      to_k = kind(m, to) || unknown_kind(to)
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
            &Blocks.choice(value: &1["key"], label: "#{&1["key"]}: #{label(to_k, &1)}")
          )

      Blocks.input(
        name: relation,
        label: String.capitalize(rel(m, relation).label),
        kind: "choice",
        value: current,
        required: current != "",
        hint: rel(m, relation).description,
        choices: choices
      )
    end
  end

  defp input_kind(%{values: values}) when is_list(values), do: "choice"
  defp input_kind(%{type: "boolean"}), do: "boolean"
  # Text of several lines and sections, as the model marks it.
  defp input_kind(%{multiline: true}), do: "multiline"
  defp input_kind(_), do: "text"

  defp choices(%{values: values} = f) when is_list(values) do
    none = if f.required, do: [], else: [Blocks.choice(value: "", label: "—")]
    none ++ Enum.map(values, &Blocks.choice(value: &1, label: f.labels[&1] || &1))
  end

  defp choices(%{type: "boolean"}),
    do: [Blocks.choice(value: "false", label: "no"), Blocks.choice(value: "true", label: "yes")]

  defp choices(_), do: nil

  @doc """
  The next free key of a kind: its prefix plus one more than the highest number among
  `keys` (and above `after`, when an earlier try was taken), and never below its `first`
  (a ledger whose older numbers are kept for facts made later).
  """
  def next_key(k, keys, after_number \\ 0) do
    %{prefix: prefix, digits: digits, first: first} = k.id
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

  @doc "The values of a new fact: what was asked, then the create form's defaults for the rest."
  def create_values(m, kind, raw) do
    form = m.module.form(kind, :create)
    Map.merge(form.defaults, values_for(kind(m, kind), Map.take(raw, form.ask)))
  end

  @doc "The kind as pages show it (`AtlasControl.Model.kinds/0`), or nil."
  def kind_view(m, kind), do: kind(m, kind) || nil

  defp parent_of(m, relation),
    do: (rel(m, relation) || missing_relation(relation)).to |> Enum.join(" or ")

  defp id_text(k) do
    case k.id do
      %{from: from, template: template} when is_binary(from) and is_binary(template) ->
        "made from #{from}: #{template}"

      id ->
        "made: #{id.prefix} and the next number (#{id.prefix}#{String.duplicate("N", id.digits)})"
    end
  end

  defp field_text(f, asked?) do
    what =
      cond do
        is_list(f.values) -> "one of " <> Enum.join(f.values, ", ")
        f.type == "boolean" -> "true or false"
        f.type == "integer" -> "a whole number"
        f.type == "datetime" -> "a date and time in UTC, e.g. 2026-11-04 17:00"
        f.multiline -> "text of several lines"
        true -> "text"
      end

    notes =
      [
        f.required && "required",
        asked? && "asked on create",
        not f.settable && "set by a #{f.set_by}, never in a form"
      ]
      |> Enum.filter(& &1)

    Enum.join([what | notes], "; ")
  end

  @doc """
  Turn a form's text values into the model's types, for a fact of the kind `k`. Unknown
  names are passed on so Facts can refuse them.
  """
  def values_for(k, raw) do
    for {name, text} <- raw, name != "_key", into: %{} do
      {name, typed(k && field(k, name), text)}
    end
  end

  defp typed(_f, ""), do: ""
  defp typed(%{type: "boolean"}, "true"), do: true
  defp typed(%{type: "boolean"}, "false"), do: false

  defp typed(%{type: "integer"}, text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> text
    end
  end

  # A date and time: `2026-11-04 17:00` (UTC), or any RFC 3339 instant; stored as RFC 3339
  # in UTC. Anything else is passed on, for Facts to refuse.
  defp typed(%{type: "datetime"}, text) do
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

  defp typed(_f, text), do: text

  # Showing values

  @doc """
  A fact's name: its primary value; while it is empty (a connector has not filled it yet),
  the value the id is made from; else the key.
  """
  def label(nil, fact), do: fact["key"]

  def label(k, fact) do
    [k.primary, k.id.from]
    |> Enum.map(&to_text((fact["values"] || %{})[&1]))
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

  # A kind with a progress rule shows how far a fact is (Facts works it out from the facts
  # under it) in place of its own field and the field that marks it done.
  defp detail(nil, _fact), do: nil

  defp detail(k, fact) do
    hidden = if k.progress, do: k.progress.hidden, else: []

    shown =
      for f <- k.fields,
          f.name != k.primary,
          f.name not in hidden,
          v = fact["values"][f.name],
          v not in [nil, "", false] do
        cond do
          is_list(f.values) -> show(f, v)
          f.type == "boolean" -> humanize(f.name) |> String.downcase()
          true -> nil
        end
      end

    progress = if k.progress, do: progress_text(fact["progress"]), else: nil
    # The id is the row's own; the detail does not repeat it.
    case Enum.reject([review_text(fact) | shown] ++ [progress, late_detail(k, fact)], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # For a key, its row's counts as text ("3 assigned"), from the answers to the reads
  # `counts/2` adds: the facts of each kind that point at it through the relation, added up
  # over those kinds. A count whose read failed is left out, never shown as 0.
  defp counted(m, kind, answers) do
    found =
      m
      |> counts(kind)
      |> Enum.zip(answers)
      |> Enum.group_by(fn {c, _} -> {c.relation, c.text} end, &elem(&1, 1))
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
  # while Facts says the fact is late (worked out on every read).
  defp late(%{late: %{after: name} = rule}, %{"late" => true}, name),
    do: " · " <> (rule.label || "late")

  defp late(_k, _fact, _name), do: ""

  # In a list, late comes first, so a narrow column never cuts it off, and the time is
  # short: `Late · deadline 2026-11-04 17:00`.
  defp late_detail(%{late: %{after: name} = rule} = k, fact) do
    case fact["values"][name] do
      value when value in [nil, ""] ->
        nil

      value ->
        f = field(k, name) || %{label: humanize(name), type: nil, labels: %{}}
        time = "#{f.label} #{String.trim_trailing(show(f, value), " UTC")}"

        if fact["late"] == true,
          do: String.capitalize(rule.label || "late") <> " · " <> String.downcase(time),
          else: time
    end
  end

  defp late_detail(_k, _fact), do: nil

  # A fact Facts says is to be reviewed (`review`, worked out on every read) shows the rule's
  # label and the fact that makes it so: first in a list, and as its own line on a page.
  defp review_text(%{"review" => %{"label" => label} = why}),
    do: Enum.join(Enum.reject([label, why["key"]], &(&1 in [nil, ""])), " · ")

  defp review_text(_fact), do: nil

  defp review_pair(%{"review" => %{"label" => label} = why}) do
    value = Enum.join(Enum.reject([why["key"], why["value"]], &(&1 in [nil, ""])), " ")
    [Blocks.pair(label: label, value: value)]
  end

  defp review_pair(_fact), do: []

  defp progress_text(%{"label" => label, "count" => count, "of" => of}),
    do: "#{label} · #{count}/#{of}"

  defp progress_text(%{"label" => label}), do: label
  defp progress_text(_), do: nil

  # How far the fact is, and why it is completed when it is (Facts works both out):
  # "Done · 12/12 · accepted by ada", with the fact that accepted it; "Done · PR-1 merged".
  defp progress_pair(m, k, fact) do
    text = progress_text(fact["progress"])

    {why, origin} =
      case fact["completion"] do
        %{"by" => relation, "keys" => keys} ->
          label = (rel(m, relation) || missing_relation(relation)).label
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
        why -> "#{k.done_label || "Done"} · #{why}"
        true -> text
      end

    # Its own field already says how far a fact without children is, until it is done.
    shown? = why != nil or Map.has_key?(fact["progress"] || %{}, "count")

    if text && shown? && k.shows_progress,
      do: [Blocks.pair(label: "Progress", value: text, origin: origin)],
      else: []
  end

  defp show(%{type: "boolean"}, value), do: if(value in [true, "true"], do: "yes", else: "no")
  defp show(_f, value) when value in [nil, ""], do: "—"
  defp show(%{type: "datetime"}, value), do: moment(value)
  defp show(%{labels: labels}, value) when is_map(labels), do: labels[value] || to_text(value)
  defp show(_f, value), do: to_text(value)

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)

  defp count(keys), do: Integer.to_string(length(keys))

  defp singular(m, kind), do: (kind(m, kind) || unknown_kind(kind)).label

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n") |> hd()
end
