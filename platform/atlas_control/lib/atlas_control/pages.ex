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
  | `/_open`                  | Open for you: per supervised span, the flows in it that have no human |
  |                           | supervisor yet (`start_page().open_for_you`)       |
  | `/_supervised`            | Supervised by you: the flows the client supervises, still in a span, |
  |                           | with a quiet count of its running work            |
  | `/k/<kind>/<key>/pick_up/<run>` | confirm becoming the supervisor of `run` (Pick up) |
  | `/k/<kind>/<key>/hand_over/<run>` | form to hand `run` over to someone else, with the |
  |                           | running work that will stop (Hand over…)          |
  | `/k/<kind>/<key>/retry/<run>` | confirm taking `run` back to the start of its span (Retry) |
  | `/k/<kind>/<key>/remove_item/<run>` | confirm deleting the fact with the work Flow made |
  |                           | for it, which ends `run` (Remove)                 |

  Supervision (work acquisition decision 2026-11-17, §5.6–5.8, M3b): which flows are
  supervised, in which states (spans), by which relation, and what a supervisor's running
  work is, all come from the model's start page (`open_for_you`, `supervised_by_you`);
  who supervises a run, from Facts' presentation (`supervisor`). Pick up and Hand over…
  are sent as inputs of the flow (`pickup`, `hand_over`), only from a TUI session, as the
  client it is; Flow checks them again and sets the supervisor. Retry is sent the same way
  (`retry`), and Flow takes the run back to the first state of its span (IS-Atlas-09).
  Remove deletes what is under the fact through the work's relation (its tasks, and what
  is under each, as their attempts), then the fact itself, which ends its run
  (IS-Atlas-09, IS-Atlas-30).


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
    label and key) are offered on the page. Pages only show these rules: Facts enforces
    them, and every other write rule of a relation (`limit`, `closes_parent`,
    `requires_completed_children`, the link to the one who decides), by the model.
  """

  require AtlasControl.Blocks, as: Blocks

  # Every action is one of the CRUD operations: its verb and its key, the same on every
  # page. Read is the row itself: enter opens it.
  @operations %{create: {"Create", "c"}, update: {"Update", "u"}, delete: {"Delete", "d"}}

  # Supervision's two generic verbs and their keys (M3b plan Q9): supervision is the
  # platform's, so they sit beside the operations. `h` is not free: a model's change
  # action may take it on the same page (an Assignment's Hand to…), so Hand over… is `v`.
  @supervision %{
    pick_up: {"Pick up", "p"},
    hand_over: {"Hand over…", "v"},
    retry: {"Retry", "y"},
    remove_item: {"Remove", "m"}
  }

  # What each of them does, in full (an action's `help`, a client's tooltip).
  @supervision_help %{
    pick_up: "Supervise this flow yourself: its next steps come to you",
    hand_over: "Hand the supervision of this flow to someone else",
    retry: "Run the step that failed again",
    remove_item: "Remove it from its flow: its run ends"
  }

  # The client one supervises from (M3b plan §1, S-6): only its session sends a pickup
  # or a hand-over, until there is sign-in.
  @supervising_client "tui"

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

      # Who views it is the session's (`AtlasControl.Session`), as for `/`.
      {:ok, screen, _} when screen in [:open_for_you, :supervised_by_you] ->
        {screen, nil}

      # One group of a screen (`groups/2`); who views it is the session's too.
      {:ok, :assigned_group, p} ->
        {:group, :assigned, p.kind, nil}

      {:ok, :open_for_you_group, p} ->
        {:group, :open_for_you, {p.subflow, p.span}, nil}

      {:ok, :supervised_by_you_group, p} ->
        {:group, :supervised_by_you, {p.subflow, p.span}, nil}

      {:ok, page, p} when page in [:pick_up, :hand_over, :retry, :remove_item] ->
        {page, p.kind, p.key, p.run}

      {:ok, page, params} when page in [:health, :worker, :worker_guidance] ->
        {:worker_page, page, params}

      # The Workers board's path shows the Machines page (deprecated, 0.43.0).
      {:ok, page, _} when page in [:machines, :workers] ->
        {:machine_page, :machines, %{}}

      {:ok, page, params} when page in [:machine, :machine_upgrade] ->
        {:machine_page, page, params}

      {:ok, :kinds, _} ->
        :kinds

      {:ok, :list, p} ->
        {:list, p.kind}

      {:ok, :new, p} ->
        {:new, p.kind}

      {:ok, :new_under, p} ->
        {:new, p.kind, {p.relation, p.parent}}

      {:ok, page, p} when page in [:item, :more, :edit, :delete] ->
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

  When the model gives no single answer, the page does not exist. A supervision screen
  (`/_open`, `/_supervised`) exists only when the model has its start entry
  (`open_for_you_rule/1`, `supervised_rule/1`), as its tab does (`AtlasControl.Shell`).
  """
  def resolve({:new, kind, {"_parent", parent}}, m) do
    case parent_relations(m, kind) do
      [relation] -> {:new, kind, {relation, parent}}
      _ -> :unknown
    end
  end

  def resolve({page, "_", key}, m) when page in [:item, :more, :edit, :delete] do
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

  def resolve({screen, _by} = route, m) when screen in [:open_for_you, :supervised_by_you],
    do: if(screen_rule(m, screen), do: route, else: :unknown)

  # A group exists only when its page has it (`groups/2`).
  def resolve({:group, screen, key, _by} = route, m),
    do: if(List.keymember?(groups(m, screen), key, 0), do: route, else: :unknown)

  def resolve(route, _m), do: route

  @doc """
  The kinds whose ids have no prefix (made from a name, say). A key no prefix claims is of
  one of them; when there are several, Control asks Facts which one has it.
  """
  def unprefixed_kinds(m), do: for(k <- kinds(m), k.id.prefixes == [], do: k.name)

  @doc "The kind whose id prefix `key` has (the longest wins), or nil (`resolve/2`)."
  def kind_of_key(m, key) do
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
  The icon the model names for `kind`, a semantic name (`scales`, `checklist`) a client draws
  as it likes; nil when the model names none, or has no such kind. One kind has one icon
  everywhere: on its rows, on its page's header and on its tab or group.
  """
  def kind_icon(m, kind) do
    case kind(m, kind) do
      %{} = k -> Map.get(k, :icon)
      _ -> nil
    end
  end

  # A page's header and panel with the icon of the kind of its fact; as they are without one.
  defp iconed(blocks, nil), do: blocks

  defp iconed(blocks, icon) do
    Enum.map(blocks, fn
      {id, block} when id in ["header", "panel"] -> {id, put_in(block, ["props", "icon"], icon)}
      other -> other
    end)
  end

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
  def submit_route(:pick_up, p), do: {:pick_up, p.kind, p.key, p.run}
  def submit_route(:hand_over, p), do: {:hand_over, p.kind, p.key, p.run}
  def submit_route(:retry, p), do: {:retry, p.kind, p.key, p.run}
  def submit_route(:remove_item, p), do: {:remove_item, p.kind, p.key, p.run}

  def submit_route(:upgrade_machine, p),
    do: {:machine_page, :machine_upgrade, %{machine: p.machine}}

  @doc "The names of the machines the Machines page shows (`AtlasControl.Model`), or nil."
  def machines(m), do: Map.get(m, :machines)

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

  def path({screen, _by}) when screen in [:open_for_you, :supervised_by_you],
    do: Blocks.path(screen)

  def path({:assigned, _by}), do: Blocks.path(:home)
  def path({:group, :assigned, kind, _by}), do: Blocks.path(:assigned_group, kind: kind)

  def path({:group, :open_for_you, {subflow, span}, _by}),
    do: Blocks.path(:open_for_you_group, subflow: subflow, span: span)

  def path({:group, :supervised_by_you, {subflow, span}, _by}),
    do: Blocks.path(:supervised_by_you_group, subflow: subflow, span: span)

  # A hand-over the session reads for its client (`by`) is at the same path.
  def path({page, kind, key, run}) when page in [:pick_up, :hand_over, :retry, :remove_item],
    do: Blocks.path(page, kind: kind, key: key, run: run)

  def path({:hand_over, kind, key, run, _by}), do: path({:hand_over, kind, key, run})
  def path({:worker_page, page, params}), do: Blocks.path(page, params)
  def path({:machine_page, page, params}), do: Blocks.path(page, params)
  def path(:kinds), do: Blocks.path(:kinds)
  def path({:list, kind}), do: Blocks.path(:list, kind: kind)
  def path({:new, kind}), do: Blocks.path(:new, kind: kind)

  def path({:new, kind, {relation, parent}}),
    do: Blocks.path(:new_under, kind: kind, relation: relation, parent: parent)

  def path({page, kind, key}) when page in [:item, :more, :edit, :delete],
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

  @icons %{create: "create", update: "edit", delete: "delete"}

  # A CRUD operation's action, with the icon of what it does and what it does in full.
  defp action(op, k, to, key \\ nil) do
    {label, default} = operation(op, k)

    Blocks.action(
      label: label,
      key: key || default,
      to: to,
      icon: @icons[op],
      help: operation_help(op, k)
    )
  end

  defp operation_help(:create, k), do: "Create a new #{String.downcase(k.label)}"
  defp operation_help(:update, k), do: "Change the fields of this #{String.downcase(k.label)}"
  defp operation_help(:delete, k), do: "Delete this #{String.downcase(k.label)}"

  defp verb(op), do: op |> operation(nil) |> elem(0)
  defp key_of(op), do: op |> operation(nil) |> elem(1)

  @doc "The kind a route is about."
  def kind_of(:home), do: :all
  def kind_of(:unknown), do: nil
  def kind_of({:worker_page, _, _}), do: nil
  def kind_of({:machine_page, _, _}), do: nil
  def kind_of({:unavailable, _path, _failed}), do: nil
  def kind_of(:kinds), do: nil
  def kind_of({screen, _by}) when screen in [:open_for_you, :supervised_by_you], do: nil
  def kind_of({:group, _screen, _key, _by}), do: nil
  def kind_of(route), do: elem(route, 1)

  def form?({:worker_page, :worker_guidance, _}), do: true
  def form?(route), do: elem_match?(route, [:new, :edit, :links, :remove, :answer, :hand_over])

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
  def reads({:machine_page, _, _}, _m), do: []

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

    for(from <- froms, do: {from, presented(m, from, %{"linked" => %{relation => by}})}) ++
      for {_component, owner} <- owner_kinds(m, froms), do: {owner, %{}}
  end

  # Open for you: the facts each span's work is written on, with how Facts presents that
  # work (which run, in which state, supervised by whom), then the span subjects they are
  # components of (`span_reads/1`). Supervised by you: the same, with the client's running
  # work (`work`), linked to it (`for`), before those subjects: the lookups come last.
  def reads({:open_for_you, _by}, m) do
    {rows, lookups} = span_reads(m)
    rows ++ lookups
  end

  # A group of a screen reads as the whole screen: its counts are of every group.
  def reads({:group, _screen, _key, _by} = route, m), do: reads(whole(route), m)

  def reads({:supervised_by_you, by}, m) do
    {rows, lookups} = span_reads(m)
    rows ++ work_reads(m, by) ++ lookups
  end

  # Pick up reads as the fact's page does; Hand over… too, and the facts of the span's
  # `with:` subjects that point at it, and the client's running work: what will stop.
  def reads({page, kind, key, _run}, m) when page in [:pick_up, :retry, :remove_item],
    do: reads({:item, kind, key}, m)

  def reads({:hand_over, kind, key, run}, m), do: reads({:hand_over, kind, key, run, nil}, m)

  def reads({:hand_over, kind, key, _run, by}, m),
    do: reads({:item, kind, key}, m) ++ with_reads(m, kind, key) ++ work_reads(m, by)

  # Open work: every fact of the kinds the start's relation starts at (the Assignments)
  # and of the kinds they are components of, so the same rows as what is assigned to one
  # client, for everyone.
  def reads({:list, kind}, m) when is_binary(kind) do
    if open_work?(m, kind) do
      froms = (rel(m, assigned_rule(m).relation) || %{from: []}).from

      for(from <- froms, do: {from, presented(m, from, %{})}) ++
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
          do: {part_kind, presented(m, part_kind, %{"key" => part_key(component, key)})}

    [{kind, presented(m, kind, %{"key" => key})} | children] ++
      causes ++ parts ++ candidate_reads(m, kind)
  end

  # A fact's secondary menu offers what its page would: it reads as the page does.
  def reads({:more, kind, key}, m), do: reads({:item, kind, key}, m)

  # A change form also lists where the fact can move: every fact of each parent kind.
  def reads({:edit, kind, key}, m) do
    parents = for relation <- parent_relations(m, kind), do: {parent_of(m, relation), %{}}
    [{kind, %{"key" => key}} | parents]
  end

  def reads({_, kind, key}, _), do: [{kind, %{"key" => key}}]

  # Setting a link that needs the facts under it completed reads them, as the page does.
  # An answer reads too whom its decider may delegate it to (a Delegate's other one),
  # last.
  def reads({:answer, kind, key, _}, m),
    do: reads({:item, kind, key}, m) ++ for(to <- delegate_kinds(m, kind), do: {to, %{}})

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

  # A read of a kind whose work is presented asks Facts for each fact's presentation.
  defp presented(m, kind, read) do
    case kind(m, kind) do
      %{presented: true} -> Map.put(read, "presentation", true)
      _ -> read
    end
  end

  @doc """
  The role of each of `reads(route, m)`, in the same order (`AtlasControl.Freshness.ReadSet`):
  `:rows` when its facts are the page's rows, `:lookup` when it only resolves facts that
  the rows point at or that point at them: on what is assigned and in Open work, the
  facts the Assignments are components of; on Open for you and Supervised by you, the
  span subjects the work is written on a component of.
  """
  def read_roles(:home, m) do
    case top_kinds(m) do
      [kind] -> read_roles({:list, kind}, m)
      _ -> []
    end
  end

  def read_roles({:group, _screen, _key, _by} = route, m), do: read_roles(whole(route), m)

  def read_roles(route, m) do
    lookups =
      case route do
        {:assigned, _} ->
          owner_reads(m)

        {:list, kind} when is_binary(kind) ->
          if open_work?(m, kind), do: owner_reads(m), else: length(status_reads(m, kind))

        {screen, _} when screen in [:open_for_you, :supervised_by_you] ->
          span_lookups(m)

        _ ->
          0
      end

    n = length(reads(route, m))
    List.duplicate(:rows, n - lookups) ++ List.duplicate(:lookup, lookups)
  end

  # How many reads of the span subjects a supervision screen ends with.
  defp span_lookups(m), do: length(elem(span_reads(m), 1))

  # How many reads of the owners of the Assignments a page of them ends with.
  defp owner_reads(m) do
    froms = (rel(m, assigned_rule(m).relation) || %{from: []}).from
    length(owner_kinds(m, froms))
  end

  # A kind whose rows count what points at it (`counts`) also reads, plainly, every fact of
  # each kind those relations start at; then the components its work is presented on
  # (`status_reads/2`), lookups that say where each row stands.
  defp list_reads(kind, m),
    do:
      [
        {kind, presented(m, kind, %{})}
        | for(c <- counts(m, kind), do: {c.from, %{"linked" => %{}, "plain" => true}})
      ] ++ status_reads(m, kind)

  # The components of a fact of `kind` whose work Facts presents, every fact of each,
  # plainly, with that presentation: where a list row of the kind stands (`status/4`).
  defp status_reads(m, kind) do
    for {_relation, part_kind, _component} <- presented_components(m, kind),
        do: {part_kind, %{"linked" => %{}, "plain" => true, "presentation" => true}}
  end

  # The component relations of `kind` (as `components/2`) whose kind's work Facts presents.
  defp presented_components(m, kind) do
    for {_relation, part_kind, _component} = c <- components(m, kind),
        match?(%{presented: true}, kind(m, part_kind)),
        do: c
  end

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
  itself, when it is no component), left out once completed, and left out while Facts'
  presentation of the work on it has nothing to do and nobody set its owner by hand: a
  run that ended leaves nothing to act on, whatever is still written. A row whose fact
  this session just wrote (`marked`, the keys it marks until Flow settles) stays.
  """
  def assigned_facts(m, answers, marked \\ []) do
    relation = assigned_rule(m).relation
    froms = (rel(m, relation) || %{from: []}).from
    owners = owner_kinds(m, froms)
    {linked, owned} = Enum.split(answers, length(froms))
    whose = by_component(owners, owned)

    for {from, %{"facts" => links}} <- Enum.zip(froms, linked),
        link <- links,
        {kind, fact} = Map.get(whose, link["key"], {from, link}),
        not completed?(fact),
        current?(link, fact, marked) do
      {kind, fact, link}
    end
    |> Enum.sort_by(
      fn {_, _, link} -> get_in(link, ["origins", relation, "since"]) || "" end,
      :desc
    )
  end

  # Each component's fact, by the component's key: `%{key => {owner kind, fact}}`, from the
  # answers (`owned`) to the reads of the owner kinds (`owners`: `[{relation, owner
  # kind}]`, as `owner_kinds/2` gives them), in the same order.
  defp by_component(owners, owned) do
    for {{component, owner}, %{"facts" => facts}} <- Enum.zip(owners, owned),
        fact <- facts,
        part <- get_in(fact, ["links", component]) || [],
        into: %{},
        do: {part, {owner, fact}}
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

  @doc "The count of what is assigned, as the model words it (`count`); `marked` as `assigned_facts/3`."
  def assigned_count(m, answers, marked \\ []) do
    rule = assigned_rule(m)
    n = length(assigned_facts(m, answers, marked))
    String.replace(rule.count || "{count}", "{count}", Integer.to_string(n))
  end

  defp completed?(fact), do: get_in(fact, ["completion", "done"]) == true

  # Work to show: its presentation has something to do, or someone set its owner by hand;
  # a fact no presenter presents is shown as it is. A row this session just wrote (one
  # it marks, `marked`: Flow has not settled past the write) stays as it was, flagged
  # pending, until Flow settles; then it leaves or changes as Flow decided (page
  # freshness, F7).
  defp current?(link, fact, marked) do
    case link["presentation"] do
      %{} = shown ->
        shown["actionable"] == true or shown["manual"] == true or
          link["key"] in marked or fact["key"] in marked

      _ ->
        true
    end
  end

  # The keys of the facts this session wrote that Flow has not settled yet (`marked` in
  # the form, the session's marks).
  defp marked(form), do: (is_map(form) && form[:marked]) || []

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
  def open_facts(m, answers, marked \\ []) do
    relation = assigned_rule(m).relation

    m
    |> assigned_facts(answers, marked)
    |> Enum.filter(fn {_kind, fact, link} ->
      (get_in(link, ["links", relation]) || []) != [] or expected(fact, link) != nil
    end)
    |> Enum.sort_by(fn {_, _, link} -> if link["late"] == true, do: 0, else: 1 end)
  end

  # What is assigned to the client, calm (platform/atlas_control/backend/README.md): its
  # groups (per kind) and the list, each row with its key, without technical noise, in
  # work order (`work_order/1`); on a group's page (`active`, a kind) only that kind's. No
  # Overview: the tab and the groups carry the count. The technical details are an agent's
  # or developer's (`atlas get`).
  defp assigned(m, by, answers, marked, active) do
    rule = assigned_rule(m)
    all = assigned_facts(m, answers, marked)
    items = Enum.filter(all, &(active in [nil, elem(&1, 0)]))

    list =
      Blocks.list(
        title: rule.title || "",
        rows:
          work_order(
            for {from, fact, link} = item <- items do
              {calm_row(m, rule.relation, item, by),
               deadline(m, [{link_kind(m, rule.relation), link}, {from, fact}])}
            end
          ),
        empty: rule.empty,
        actions: start_actions(m)
      )

    grouped_page(
      m,
      {:assigned, by},
      Enum.frequencies_by(all, &elem(&1, 0)),
      active,
      rule.title || "",
      [{"list", list}]
    )
  end

  # Work order, the one order of every work list (Assigned to you, Open for you, Supervised
  # by you; browse lists keep theirs): `[{row, deadline}]` to rows, those with a deadline
  # first, soonest at the top; then by how long each has waited (the row's `since`), oldest
  # first, undated last; ties by key. Clients show rows in the order they get them.
  defp work_order(rows) do
    rows
    |> Enum.sort_by(fn {row, deadline} ->
      since = instant(row["since"])
      {deadline == nil, deadline, since == nil, since, key_order(row["id"])}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # A work row's deadline: the first of `written` (`[{kind, fact}]`) that sets one, as
  # Facts' presentation of the work says it (`deadline`), else in the field its kind's late
  # rule names (`after`); nil when none does.
  defp deadline(m, written) do
    Enum.find_value(written, fn {kind_name, fact} ->
      instant(get_in(fact, ["presentation", "deadline"])) ||
        case kind_name && kind(m, kind_name) do
          %{late: %{after: name}} -> instant(get_in(fact, ["values", name]))
          _ -> nil
        end
    end)
  end

  # An ISO 8601 time as microseconds since the epoch, to compare; nil when it is none.
  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at, :microsecond)
      _ -> nil
    end
  end

  defp instant(_), do: nil

  @doc """
  A page's technical details (the worker pages'): `{content, markup}` to add to the page,
  one pair per row in list order in an `item` `details` titled "Technical details" inside a
  collapsible `section` titled "Details"; nothing when there are no pairs. A page with
  them offers `details_action/0`.
  """
  def technical_details([]), do: {[], []}

  def technical_details(pairs) do
    {[{"details", Blocks.item(title: "Technical details", fields: pairs)}],
     [Blocks.section("details", "details", title: "Details", collapsible: true)]}
  end

  @doc """
  The console action that folds or unfolds a page's collapsible sections (`sections_toggle`,
  key d): the one every page with a Details section offers.
  """
  def details_action,
    do: %{
      label: "Show or hide details",
      keys: ["d"],
      operation: %{"name" => "sections_toggle"},
      on: nil,
      row: nil,
      available: true,
      reason: nil
    }

  # Open work's Overview: how many (`main`), and how many of those are late or blocked, and
  # any `more` counts (only when some are).
  defp overview(items, main, more) do
    late = Enum.count(items, fn {_, fact, link} -> true in [link["late"], fact["late"]] end)

    blocked =
      Enum.count(items, fn {_, fact, link} -> shown(fact, link, "status") == "blocked" end)

    summary([{main, length(items)}, {"Late", late}, {"Blocked", blocked} | more])
  end

  @doc """
  A calm page's Overview (platform/atlas_control/backend/README.md): an `item` titled "Overview" with one pair per
  `{label, count}`; the first, the main count, always, the others only when some are.
  `actions`, when given, are the page's (`page_actions/1`): the Workers page's Health.
  """
  def summary([main | more], actions \\ []) do
    fields =
      for {label, n} <- [main | Enum.filter(more, fn {_, n} -> n > 0 end)],
          do: Blocks.pair(label: label, value: Integer.to_string(n))

    case actions do
      [] -> Blocks.item(title: "Overview", fields: fields)
      actions -> Blocks.item(title: "Overview", fields: fields, actions: page_actions(actions))
    end
  end

  # One calm row of what is assigned: the fact's key, the fact, who it is with (`owner?`, on
  # Open work), why it is to be reviewed (the rule's label), what is to be done (its
  # state's short name, `Merge it`; on Open work the flow its work is in; never the long
  # sentence of what is expected), whether it is blocked, and its deadline (late first);
  # where it stands for the viewer `by`, since when (`status/4`).
  defp calm_row(m, relation, {from, fact, link}, by, owner? \\ false) do
    link_k = kind(m, link_kind(m, relation))

    detail =
      [
        owner? && owner_text(link, relation),
        get_in(fact, ["review", "label"]),
        if(owner?, do: flow_name(m, fact, link), else: todo_name(m, fact, link)),
        shown(fact, link, "status") == "blocked" && "blocked",
        late_detail(link_k, link)
      ]
      |> Enum.reject(&(&1 in [nil, "", false]))
      |> Enum.join(" · ")

    {tone, since} =
      status(fact, [link, fact], by,
        owners: owners(link, relation),
        since: get_in(link, ["origins", relation, "since"])
      )

    Blocks.row(
      id: fact["key"],
      label: label(kind(m, from), fact),
      kind: singular(m, from),
      icon: kind_icon(m, from),
      detail: detail,
      to: path({:item, from, fact["key"]}),
      tone: tone,
      since: since
    )
  end

  # Where a row's work stands for the viewer `by`, with one meaning on every list (a row's
  # `tone` and `since`, platform/atlas_control/backend/README.md): `{tone, since}`, both nil
  # where nothing says. Facts' presentation of the work decides it, on the first of
  # `written` (the component it is presented on, then the fact) that has one, with who it
  # is assigned to (`owners:`) where nothing presents it:
  #
  #   * "done": the fact is completed and no run is still at it (active or blocked), or its
  #     run ended (and it is not reopened);
  #   * "attention": the next step is the viewer's (or it was handed to them by hand), or
  #     its run is blocked and the viewer owns or supervises it;
  #   * "waiting": it was reopened, waits for another fact, is blocked on someone else, or
  #     its next step is nobody's or someone's whose flow nobody drives (no supervisor);
  #   * "active": under way: the viewer's running work is on it (`doing:`), its next step
  #     is someone else's in a flow someone supervises, or Flow is at it.
  #
  # `since` is when the presenting run entered its state, else (`since:`) when it was
  # assigned; for a completed fact, when it was completed.
  defp status(fact, written, by, opts \\ []) do
    shown =
      Enum.find_value(written, %{}, fn w ->
        is_map(w) and is_map(w["presentation"]) and w["presentation"]
      end)

    mine? = by != nil and by in (shown["owner"] || opts[:owners] || [])
    supervisor = shown["supervisor"] || []
    since = shown["since"] || opts[:since]

    cond do
      completed?(fact) and shown["status"] not in ["active", "blocked"] ->
        {"done", completed_since(fact) || shown["since"]}

      shown["status"] == "completed" and shown["reopened"] != true ->
        {"done", shown["since"]}

      shown["status"] == "blocked" ->
        {if(mine? or (by != nil and by in supervisor), do: "attention", else: "waiting"), since}

      shown["reopened"] == true or is_binary(shown["waiting_for"]) ->
        {"waiting", since}

      mine? and (shown["actionable"] != false or shown["manual"] == true) ->
        {"attention", since}

      opts[:doing] != nil ->
        {"active", since}

      shown["actionable"] == true ->
        {if(supervisor != [], do: "active", else: "waiting"), since}

      shown["status"] == "active" ->
        {"active", since}

      true ->
        {nil, nil}
    end
  end

  # When a completed fact was completed: the fact that set the link that completes it.
  defp completed_since(fact) do
    case fact["completion"] do
      %{"by" => relation} -> get_in(fact, ["origins", relation, "since"])
      _ -> nil
    end
  end

  # What Facts' presentation of the work says of `name`: on the component it is presented
  # on (`link`), or on the fact itself; nil when neither says anything.
  defp shown(fact, link, name) do
    Enum.find_value([link, fact], fn written ->
      case written["presentation"] do
        %{^name => value} when value not in [nil, "", false, []] -> value
        _ -> nil
      end
    end)
  end

  # Who an Open work row is with: the keys its link points at, or "unassigned".
  defp owner_text(link, relation) do
    case owners(link, relation) do
      [] -> "unassigned"
      keys -> Enum.join(keys, ", ")
    end
  end

  defp owners(link, relation), do: get_in(link, ["links", relation]) || []

  # The kind the start's relation starts at (the Assignment), when it is one.
  defp link_kind(m, relation) do
    case rel(m, relation) do
      %{from: [kind]} -> kind
      _ -> nil
    end
  end

  # Open work: the list of a kind the start's relation starts at, for everyone; calm by
  # default as what is assigned (`assigned/4`), each row with who it is with.
  defp open_work(m, kind, answers, marked, by) do
    case Enum.find(answers, &match?(%{"error" => _}, &1)) do
      nil ->
        rule = open_rule(m)
        relation = assigned_rule(m).relation
        items = open_facts(m, answers, marked)
        unassigned = Enum.count(items, fn {_, _, link} -> owners(link, relation) == [] end)

        list =
          Blocks.list(
            title: rule.title || kind(m, kind).plural,
            rows: for(item <- items, do: calm_row(m, relation, item, by, true)),
            empty: rule.empty,
            actions: []
          )

        page(rule.title || "", "/", [
          {"summary", overview(items, "Open", [{"Unassigned", unassigned}])},
          {"list", list}
        ])

      failed ->
        unavailable(failed, "/")
    end
  end

  # What the fact's owner is expected to do, as Facts' presentation of the work says: on
  # the component it is presented on (`link`), or on the fact itself.
  defp expected(fact, link) do
    Enum.find_value([link, fact], fn written ->
      case to_text(get_in(written, ["presentation", "expected"])) do
        "" -> nil
        value -> value
      end
    end)
  end

  # The short name of the flow the work is in, as the model names its subflow (`flows`),
  # while something is expected of its owner: what a list row says of the work, in place of
  # the sentence of what is expected, which the item's page says.
  defp flow_name(m, fact, link) do
    if expected(fact, link) do
      names = m.start[:flows] || %{}
      Enum.find_value([link, fact], &names[get_in(&1, ["presentation", "flow"])])
    end
  end

  # The short name of the state the work is in (the model's `label:` of the subflow's
  # state, `Merge it`), while something is expected of its owner: what is to be done, as
  # Assigned to you says it; the flow's short name when the state has none.
  defp todo_name(m, fact, link) do
    if expected(fact, link) do
      Enum.find_value([link, fact], fn written ->
        presentation = written["presentation"] || %{}
        get_in(m.start, [:states, presentation["flow"], presentation["state"]])
      end) || flow_name(m, fact, link)
    end
  end

  # The start page's ways to the kinds kept off it: an action that opens the kind's list.
  defp start_actions(m, except \\ nil) do
    page_actions(
      for a <- m.start.actions,
          a.kind != except,
          do:
            Blocks.action(
              label: a.label,
              key: a.key,
              to: path({:list, a.kind}),
              help:
                "Open the list of #{String.downcase((kind(m, a.kind) || %{plural: a.label}).plural)}"
            )
    )
  end

  @doc """
  `actions` as the page's rather than their block's (`page`, contract 0.24.0): what is
  done with the page's subject (create one, the fact's next step and More…, a way to
  another list), which a client shows with the page's title, not under the block.
  """
  def page_actions(actions), do: Enum.map(actions, &Map.put(&1, "page", true))

  # The operations a kind offers by hand (`AtlasControl.Model` `actions/3`, no fact).
  defp by_hand?(m, kind, op), do: op in m.module.actions(kind, nil, nil)

  # `newest_first` lists a kind newest first (by key, which counts up).
  defp sort_facts(facts, k) do
    direction = if k && k.newest_first, do: :desc, else: :asc
    Enum.sort_by(facts, &key_order(&1["key"]), direction)
  end

  # How keys sort wherever rows go by key: their numbers as numbers, so IS-Atlas-100 comes
  # after IS-Atlas-99, not between IS-Atlas-07 and IS-Atlas-11. Equal numbers (07, 7) go
  # by the key itself.
  defp key_order(key) when is_binary(key) do
    parts =
      for part <- Regex.split(~r/\d+/, key, include_captures: true, trim: true) do
        case Integer.parse(part) do
          {n, ""} -> n
          _ -> part
        end
      end

    {parts, key}
  end

  defp key_order(key), do: {[], key}

  # Supervision (work acquisition decision 2026-11-17, §5.6–5.8; M3b P4)

  @doc """
  Open for you (the model's `start_page().open_for_you`), or nil: its words (`title`,
  `count`, `empty`), the supervision `relation` and the kind a pickup is sent as
  (`inputs`), and the supervised spans: `%{subflow, subject, span, label, states, with,
  with_subjects}`.
  """
  def open_for_you_rule(m), do: m.start[:open_for_you]

  @doc """
  Supervised by you (the model's `start_page().supervised_by_you`), or nil: its words,
  the supervision `relation`, `inputs`, and the client's running work (`work`: `kind`,
  `of`, `for`, `ended`), or nil.
  """
  def supervised_rule(m), do: m.start[:supervised_by_you]

  # A supervision screen's start entry, or nil when the model has none.
  defp screen_rule(m, :open_for_you), do: open_for_you_rule(m)
  defp screen_rule(m, :supervised_by_you), do: supervised_rule(m)

  @doc """
  The groups of a screen, from the model alone, each a filter of it: `[{key, label}]`.
  What is assigned (`:assigned`) per kind of the facts the assignments are components of
  (else per kind they start at); Open for you and Supervised by you per supervised span,
  keyed `{subflow, span}`. A group's page is `{:group, screen, key, by}`; the shell offers
  the same groups under the page's tab (`AtlasControl.Shell`).
  """
  def groups(m, :assigned) do
    case assigned_rule(m) do
      nil ->
        []

      rule ->
        froms = (rel(m, rule.relation) || %{from: []}).from

        kinds =
          case for({_component, owner} <- owner_kinds(m, froms), uniq: true, do: owner) do
            [] -> froms
            owners -> owners
          end

        for k <- kinds, do: {k, (kind(m, k) || unknown_kind(k)).plural}
    end
  end

  def groups(m, screen) when screen in [:open_for_you, :supervised_by_you] do
    if screen_rule(m, screen),
      do: for(s <- spans(m), kind?(m, s.subject), do: {{s.subflow, s.span}, span_title(m, s)}),
      else: []
  end

  def groups(_m, _screen), do: []

  # The whole page a group of it filters.
  defp whole({:group, :assigned, _key, by}), do: {:assigned, by}
  defp whole({:group, screen, _key, by}), do: {screen, by}

  # Either entry names the relation and the inputs' kind; the spans are Open for you's.
  defp supervision(m), do: open_for_you_rule(m) || supervised_rule(m)
  defp spans(m), do: (open_for_you_rule(m) || %{spans: []}).spans

  # The span subjects the model has, each once, in the spans' order.
  defp span_kinds(m),
    do: for(s <- spans(m), kind?(m, s.subject), uniq: true, do: s.subject)

  # The kind the work in span `s` is written on, which Facts presents it on: the span's
  # `written_on`, or the subject itself.
  defp written_on(s), do: s[:written_on] || s.subject

  # The supervision screens' reads of the spans, `{rows, lookups}`: each kind a span's work
  # is written on, once, with its presentation; then each span subject that is not that
  # kind itself, once, to join the work to (`span_work/3`). Every read of the spans and
  # every split of their answers is made from this, so the two cannot drift.
  defp span_reads(m) do
    spans = for s <- spans(m), kind?(m, s.subject), kind?(m, written_on(s)), do: s

    {for(s <- spans, uniq: true, do: {written_on(s), presented(m, written_on(s), %{})}),
     for(s <- spans, written_on(s) != s.subject, uniq: true, do: {s.subject, %{}})}
  end

  # The work in each span, joined to its subject: `[{span, [{kind, subject, work}]}]`, from
  # the answers to `span_reads/1`'s rows and lookups. `work` is the fact the work is
  # written on (Facts presents it); `subject` the span subject's fact it is a component of,
  # joined as what is assigned joins them (`by_component/2`), or the work itself when it
  # is written on the subject. Work whose subject was not answered is left out.
  defp span_work(m, rows_answers, lookup_answers) do
    {rows, lookups} = span_reads(m)
    written = Map.new(Enum.zip(Enum.map(rows, &elem(&1, 0)), rows_answers))
    subjects = Map.new(Enum.zip(Enum.map(lookups, &elem(&1, 0)), lookup_answers))

    for s <- spans(m), kind?(m, s.subject) do
      on = written_on(s)
      facts = (written[on] || %{})["facts"] || []

      if on == s.subject do
        {s, Enum.sort_by(for(work <- facts, do: {s.subject, work, work}), &item_key/1)}
      else
        owners = for {_, owner} = o <- owner_kinds(m, [on]), owner == s.subject, do: o
        whose = by_component(owners, List.duplicate(subjects[s.subject], length(owners)))

        {s,
         Enum.sort_by(
           for(work <- facts, {kind, subject} <- [whose[work["key"]]], do: {kind, subject, work}),
           &item_key/1
         )}
      end
    end
  end

  defp item_key({_kind, fact, _work}), do: key_order(fact["key"])

  # How Facts presents the work on a fact of `kind`, on its page: on the component among
  # its `parts` (`item_parts/3`) that a span's work is written on, else on the fact itself.
  defp work_presentation(m, kind, fact, parts) do
    on =
      for s <- spans(m), s.subject == kind, written_on(s) != kind, uniq: true, do: written_on(s)

    Enum.find_value(parts, fact["presentation"] || %{}, fn {part_kind, _k, part, _made} ->
      part_kind in on && part["presentation"]
    end)
  end

  @doc """
  The span the work on a fact of `kind` is in, as Facts presents it: the span of the
  presenting subflow on that kind whose states hold the presented state; nil when none.
  """
  def span_of(m, kind, %{} = presentation) do
    Enum.find(spans(m), fn s ->
      s.subject == kind and s.subflow == presentation["flow"] and
        presentation["state"] in s.states
    end)
  end

  def span_of(_m, _kind, _presentation), do: nil

  @doc "The kinds a supervisor is a fact of: those the supervision relation points at."
  def supervisor_kinds(m) do
    case supervision(m) do
      %{relation: relation} -> (rel(m, relation) || %{to: []}).to
      _ -> []
    end
  end

  @doc "The kind a pickup or hand-over is sent as (the run mapping's inputs), or nil."
  def inputs_kind(m), do: (supervision(m) || %{})[:inputs]

  defp supervisors(fact), do: supervisor(fact["presentation"])
  defp supervisor(%{} = presentation), do: presentation["supervisor"] || []
  defp supervisor(_), do: []

  # The page of a span subject reads every candidate supervisor too: whom one may hand over to.
  defp candidate_reads(m, kind) do
    if kind in span_kinds(m), do: for(p <- supervisor_kinds(m), do: {p, %{}}), else: []
  end

  # The candidates among the answers that end an item page's reads (they come last).

  defp candidates(m, kind, child_answers) do
    n = length(candidate_reads(m, kind))

    for %{"facts" => facts} <- Enum.take(child_answers, -n), n > 0, fact <- facts, do: fact
  end

  @doc """
  Whom the client `by` may hand a fact of `kind` over to, from a page's answers (the item's
  reads first): the keys of the candidates other than `by`.
  """
  def hand_over_targets(m, kind, answers, by),
    do: for(p <- others(m, kind, answers, by), do: p["key"])

  # The candidates other than `by`, from a page of `kind`'s answers (the item's reads first).
  defp others(m, kind, answers, by) do
    item = Enum.take(answers, length(reads({:item, kind, ""}, m)))

    for p <- candidates(m, kind, tl(item)), p["key"] != by, do: p
  end

  # The client's running work: the facts of the work's kind done for it (`for`).
  defp work_reads(m, by) do
    case supervised_rule(m) do
      %{work: %{kind: kind, for: for_}} when is_binary(by) ->
        if kind?(m, kind), do: [{kind, %{"linked" => %{for_ => by}}}], else: []

      _ ->
        []
    end
  end

  # The facts of the span's `with:` subjects that point at the fact `key` of `kind`, by
  # every relation from such a subject to `kind`.
  defp with_reads(m, kind, key) do
    for s <- spans(m),
        s.subject == kind,
        w <- s[:with_subjects] || [],
        kind?(m, w),
        r <- relations(m),
        w in r.from and kind in r.to,
        uniq: true,
        do: {w, %{"linked" => %{r.name => key}}}
  end

  # Work that has not ended: its `ended` field is empty.
  defp running?(work, fact), do: get_in(fact, ["values", work.ended]) in [nil, ""]

  @doc """
  The rows of Open for you among the answers to `reads({:open_for_you, by})`, per span in
  the declared order: `[{span, [{kind, fact, work}]}]`, `work` the fact the work on `fact`
  is written on (`span_work/3`). A fact is open for you while its work is presented by the
  span's subflow, active, in one of the span's states, without a human supervisor, waiting
  for no other (its flow takes its subjects in order, Facts' `waiting_for`), and the fact
  is not completed.
  """
  def open_for_you_facts(m, answers) do
    {rows, _lookups} = span_reads(m)
    {rows_answers, lookup_answers} = Enum.split(answers, length(rows))

    for {s, items} <- span_work(m, rows_answers, lookup_answers) do
      open =
        for {_kind, fact, work} = item <- items,
            p = work["presentation"] || %{},
            p["flow"] == s.subflow,
            p["status"] == "active",
            p["state"] in s.states,
            supervisors(work) == [],
            p["waiting_for"] == nil,
            not completed?(fact),
            do: item

      {s, open}
    end
  end

  @doc """
  The rows of Supervised by you among the answers to `reads({:supervised_by_you, by})`:
  `[{kind, fact, work}]` (as `open_for_you_facts/2`), the facts whose presented supervisor
  is `by` while their work is still in a span (until Flow clears the supervisor as it
  leaves one, F-2), and the running work done for `by` (`[fact]`).
  """
  def supervised_facts(m, by, answers) do
    {rows, lookups} = span_reads(m)
    {rows_answers, rest} = Enum.split(answers, length(rows))
    {work, lookup_answers} = Enum.split(rest, max(length(rest) - length(lookups), 0))

    supervised =
      for {_s, items} <- span_work(m, rows_answers, lookup_answers),
          {kind, _fact, w} = item <- items,
          is_binary(by) and by in supervisors(w),
          span_of(m, kind, w["presentation"]) != nil,
          uniq: true,
          do: item

    running =
      case {supervised_rule(m)[:work], work} do
        {%{} = w, [%{"facts" => facts}]} -> Enum.filter(facts, &running?(w, &1))
        _ -> []
      end

    {supervised, running}
  end

  @doc """
  The client's running work that a hand-over of the fact stops (§6.3), among the answers
  to `reads({:hand_over, kind, key, run, by})`: the work done for `by` that is of the fact,
  or of a fact of a `with:` subject that points at it, and has not ended.
  """
  def stopping_tasks(m, {:hand_over, kind, key, _run, _by}, answers) do
    item = length(reads({:item, kind, key}, m))
    withs = length(with_reads(m, kind, key))
    {with_answers, work_answers} = answers |> Enum.drop(item) |> Enum.split(withs)
    of = [key | for(%{"facts" => facts} <- with_answers, f <- facts, do: f["key"])]

    case {supervised_rule(m)[:work], work_answers} do
      {%{} = w, [%{"facts" => facts}]} ->
        for t <- facts,
            running?(w, t),
            Enum.any?(get_in(t, ["links", w.of]) || [], &(&1 in of)),
            do: t

      _ ->
        []
    end
  end

  # The client may supervise: a fact of a supervisor's kind, at the TUI. An agent that
  # assists someone (`assists`, its key) may pick up on their behalf (IS-Atlas-47); it
  # never supervises itself, so it never hands over.
  defp may_supervise?(m, form),
    do:
      (form[:client] == @supervising_client and form[:by_kind] in supervisor_kinds(m)) or
        is_binary(form[:assists])

  @doc """
  Why the client cannot pick up `run` on the fact now, from fresh reads of the page; nil
  when it can: someone at the TUI who may supervise, or an agent that assists someone
  (who becomes the supervisor), the run still the one that presents the fact, active, in
  a span, without a supervisor, and waiting for no other.
  """
  def pick_up_problem(m, {:pick_up, kind, _key, run}, [%{"fact" => %{} = fact} | rest], form) do
    p = work_presentation(m, kind, fact, item_parts(m, kind, rest))

    cond do
      not may_supervise?(m, form) ->
        "Only someone at the TUI who may supervise, or an agent that assists them, picks a flow up."

      p["run"] != run ->
        "The flow moved on since this page was made; open it again."

      p["status"] != "active" or span_of(m, kind, p) == nil ->
        "The flow is not open for you."

      supervisor(p) != [] ->
        "The flow is supervised already."

      is_binary(p["waiting_for"]) ->
        "It waits for #{p["waiting_for"]}, which is picked up first."

      true ->
        nil
    end
  end

  def pick_up_problem(_m, _route, _answers, _form), do: "It cannot be read now."

  @doc """
  Why the client cannot hand `run` on the fact over now, from fresh reads of the page; nil
  when it can: its supervisor at the TUI, the run still the one that presents the fact,
  active and in a span, and someone else to hand it to.
  """
  def hand_over_problem(m, route, answers, form)

  def hand_over_problem(m, {:hand_over, kind, key, run}, answers, form),
    do: hand_over_problem(m, {:hand_over, kind, key, run, form[:by]}, answers, form)

  def hand_over_problem(
        m,
        {:hand_over, kind, _key, run, _by},
        [%{"fact" => %{} = fact} | rest] = answers,
        form
      ) do
    p = work_presentation(m, kind, fact, item_parts(m, kind, rest))

    cond do
      not may_supervise?(m, form) or form[:by] not in supervisor(p) ->
        "Only the flow's supervisor at the TUI hands it over."

      p["run"] != run ->
        "The flow moved on since this page was made; open it again."

      p["status"] != "active" or span_of(m, kind, p) == nil ->
        "The flow is no longer in a supervised part."

      others(m, kind, answers, form[:by]) == [] ->
        "There is nobody else to hand it over to."

      true ->
        nil
    end
  end

  def hand_over_problem(_m, _route, _answers, _form), do: "It cannot be read now."

  @doc """
  Why the client cannot retry `run` on the fact now, from fresh reads of the page; nil
  when it can: the run's supervisor, or an agent that assists them, while the run still
  presents the fact and is active in a span (IS-Atlas-09).
  """
  def retry_problem(m, {:retry, kind, _key, run}, [%{"fact" => %{} = fact} | rest], form) do
    p = work_presentation(m, kind, fact, item_parts(m, kind, rest))

    cond do
      p["run"] != run ->
        "The flow moved on since this page was made; open it again."

      not may_retry?(m, kind, p, form) ->
        "Only the flow's supervisor, or an agent that assists them, retries it, while it is in a supervised part."

      true ->
        nil
    end
  end

  def retry_problem(_m, _route, _answers, _form), do: "It cannot be read now."

  @doc """
  Why the client cannot remove the fact now, from fresh reads of the page; nil when it
  can: the run's supervisor (while nobody supervises it, the one who decides), or an agent
  that assists them, while the run still presents the fact and nothing but its work hangs
  under it (IS-Atlas-09).
  """
  def remove_problem(
        m,
        {:remove_item, kind, key, run},
        [%{"fact" => %{} = fact} = answer | rest],
        form
      ) do
    p = work_presentation(m, kind, fact, item_parts(m, kind, rest))
    {_work, held} = held(m, kind, answer)

    cond do
      p["run"] != run ->
        "The flow moved on since this page was made; open it again."

      not may_remove?(m, kind, p, form) ->
        "Only the flow's supervisor removes it (while nobody supervises it, the one who decides), or an agent that assists them."

      held != [] ->
        "#{key} still has #{counted(held)}. " <> remove_first(held)

      true ->
        nil
    end
  end

  def remove_problem(_m, _route, _answers, _form), do: "It cannot be read now."

  @doc """
  What hangs under the fact, from its read: `{work, other}`, each `[{label, keys}]` as
  `children/3` gives them. `work` is what Flow made for it (the supervised work's kind,
  through its `of`), which Remove deletes with it; `other` is the rest.
  """
  def held(m, kind, answer) do
    of = work_relation(m)
    incoming = answer["incoming"] || %{}

    under = fn links ->
      Enum.reject(children(m, kind, Map.put(answer, "incoming", links)), &(elem(&1, 1) == []))
    end

    {under.(Map.take(incoming, [of])), under.(Map.delete(incoming, of))}
  end

  @doc "The work Flow made for the fact, from its read, as `[{kind, key}]`: what Remove deletes first."
  def work_of(m, answer) do
    case supervised_rule(m)[:work] do
      %{kind: kind, of: of} -> for key <- get_in(answer, ["incoming", of]) || [], do: {kind, key}
      _ -> []
    end
  end

  @doc """
  The facts right under one of `kind`, from its read, as `[{kind, key}]`: those its parent
  relations from one kind bring (a task's attempts).
  """
  def under(m, kind, answer) do
    for r <- relations(m),
        r.parent,
        kind in r.to,
        [from] <- [r.from],
        key <- get_in(answer, ["incoming", r.name]) || [],
        do: {from, key}
  end

  defp work_relation(m), do: (supervised_rule(m)[:work] || %{})[:of]

  # Whom the client acts for as a supervisor: itself, at the TUI, as one who may supervise;
  # an agent, whom it assists (IS-Atlas-47); nil for anyone else.
  defp acts_for(m, form) do
    cond do
      is_binary(form[:assists]) -> form[:assists]
      may_supervise?(m, form) -> form[:by]
      true -> nil
    end
  end

  defp in_span?(m, kind, p),
    do: is_binary(p["run"]) and p["status"] == "active" and span_of(m, kind, p) != nil

  # Retry: the run's supervisor, or an agent that assists them, while it is in a span.
  defp may_retry?(m, kind, p, form) do
    holder = acts_for(m, form)
    in_span?(m, kind, p) and is_binary(holder) and holder in supervisor(p)
  end

  # Remove: the run's supervisor, whatever its state; while nobody supervises it, the one
  # who decides (the configured decider). Or an agent that assists them.
  defp may_remove?(m, kind, p, form) do
    holder = acts_for(m, form)

    kind in span_kinds(m) and is_binary(p["run"]) and is_binary(holder) and
      case supervisor(p) do
        [] -> holder == get_in(restart_actors(m), ["decider", "key"])
        supervisors -> holder in supervisors
      end
  end

  # Whom to hand over to: one choice of the candidates other than the client.
  defp choice_input(m, others, form) do
    kinds = supervisor_kinds(m)
    candidate_k = (length(kinds) == 1 && kind(m, hd(kinds))) || nil

    Blocks.input(
      name: "hand_to",
      label: (candidate_k && candidate_k.label) || "—",
      kind: "choice",
      value: (form[:values] || %{})["hand_to"],
      required: true,
      choices:
        for(
          p <- Enum.sort_by(others, &key_order(&1["key"])),
          do: Blocks.choice(value: p["key"], label: "#{p["key"]}: #{label(candidate_k, p)}")
        )
    )
  end

  # Pick up, Hand over…, Retry and Remove on a fact's page, `{next, more}`: Pick up and
  # Retry are the flow's next step, Hand over… and Remove are among its other actions. Pick up for one
  # who may supervise, at the TUI, while the presenting run is active in a span with no
  # supervisor; Hand over… for its supervisor at the TUI while someone else could take
  # it; Retry and Remove as `may_retry?/4` and `may_remove?/4` say.
  defp supervision_actions(m, kind, fact, p, candidates, form) do
    supervisor = supervisor(p)
    route = &{&1, kind, fact["key"], p["run"]}
    supervising? = in_span?(m, kind, p) and may_supervise?(m, form)

    offered =
      for {verb, may?} <- [
            pick_up: supervising? and supervisor == [] and p["waiting_for"] == nil,
            hand_over:
              supervising? and form[:by] in supervisor and
                Enum.any?(candidates, &(&1["key"] != form[:by])),
            retry: may_retry?(m, kind, p, form),
            remove_item: may_remove?(m, kind, p, form)
          ],
          may?,
          do: {verb, supervision_action(verb, route.(verb))}

    {for({verb, a} <- offered, verb in [:pick_up, :retry], do: a),
     for({verb, a} <- offered, verb in [:hand_over, :remove_item], do: a)}
  end

  defp supervision_action(verb, route) do
    {label, key} = @supervision[verb]

    Blocks.action(
      label: label,
      key: key,
      to: path(route),
      button: button(label),
      help: @supervision_help[verb]
    )
  end

  @doc """
  What a button says for an action or answer labelled `label`, when that is not `label`:
  the label without its `…` (Hand to for Hand to…), since a button says nothing of what
  its click opens; nil when it is the label.
  """
  def button(label) when is_binary(label) do
    plain = String.trim_trailing(label, "…")
    if plain != label, do: plain
  end

  def button(_label), do: nil

  # The run's supervisor on a span subject's page, keys only, by the relation's label,
  # with the fact that set it when Facts knows it (who picked it up, on whose behalf).
  defp supervisor_pair(m, kind, p) do
    with keys when keys != [] <- supervisor(p),
         true <- kind in span_kinds(m),
         %{} = r <- rel(m, supervision(m).relation) do
      origin = p["supervisor_origin"]

      [
        Blocks.pair(
          label: String.capitalize(r.label),
          value: Enum.join(keys, ", "),
          origin:
            origin &&
              Blocks.origin(since: origin["since"], by: origin["by"], cause: origin["cause"])
        )
      ]
    else
      _ -> []
    end
  end

  # What the work waits for, when its flow takes its subjects in order and another is
  # first (Facts' `waiting_for`): no Pick up until that one is done.
  defp waiting_pair(%{"waiting_for" => key}) when is_binary(key),
    do: [Blocks.pair(label: "Waiting for", value: key)]

  defp waiting_pair(_p), do: []

  # Open for you, calm: its groups and one list per span, titled with the span's flow; on a
  # group's page (`active`, `{subflow, span}`) only that span's list.
  defp open_for_you(m, by, answers, active) do
    case Enum.find(answers, &match?(%{"error" => _}, &1)) do
      nil ->
        rule = open_for_you_rule(m)
        per_span = open_for_you_facts(m, answers)
        counts = Map.new(per_span, fn {s, facts} -> {{s.subflow, s.span}, length(facts)} end)
        shown = for {s, _} = group <- per_span, active in [nil, {s.subflow, s.span}], do: group

        lists =
          for {s, facts} <- shown do
            {"list:#{s.subflow}:#{s.span}",
             Blocks.list(
               title: span_title(m, s),
               rows:
                 work_order(
                   for {kind, fact, work} <- facts do
                     {screen_row(m, kind, fact, work, by, false),
                      deadline(m, [{written_on(s), work}, {kind, fact}])}
                   end
                 ),
               empty: rule.empty
             )}
          end

        grouped_page(m, {:open_for_you, nil}, counts, active, rule.title || "", lists)

      failed ->
        unavailable(failed, "/")
    end
  end

  # A screen, `{screen, by}`, with its groups first (`groups/2`): All, then each group
  # that has items with its count (`counts`, by key), the one shown (`active`; nil: All)
  # marked, and shown even when empty. A group's page is titled with the group's name too
  # and goes back to the whole page. `[` and `]` open the previous and the next group.
  defp grouped_page(m, {screen, by} = whole, counts, active, title, blocks) do
    named = groups(m, screen)

    groups = [
      Blocks.group(
        label: "All",
        count: Enum.sum(Map.values(counts)),
        to: path(whole),
        active: active == nil
      )
      | for {key, label} <- named, (counts[key] || 0) > 0 or active == key do
          Blocks.group(
            label: label,
            count: counts[key] || 0,
            to: path({:group, screen, key, by}),
            active: active == key
          )
        end
    ]

    {title, back} =
      case List.keyfind(named, active, 0) do
        {_key, label} -> {"#{title} · #{label}", path(whole)}
        nil -> {title, nil}
      end

    title
    |> page(back, [{"groups", Blocks.groups(groups: groups)} | blocks])
    |> Map.put(:console_actions, group_actions(groups))
  end

  # The Console's way through a page's groups: `[` opens the previous, `]` the next.
  defp group_actions(groups) do
    at = Enum.find_index(groups, & &1["active"]) || 0

    for {label, key, step} <- [{"Previous group", "[", -1}, {"Next group", "]", 1}] do
      to = Enum.at(groups, Integer.mod(at + step, length(groups)))["to"]

      %{
        label: label,
        keys: [key],
        operation: %{"name" => "open", "to" => to},
        on: nil,
        row: nil,
        available: true,
        reason: nil
      }
    end
  end

  # A span's name on the screens: its label; when another span has that label too, with
  # the plural of the kind its work is on, so each one is told apart.
  defp span_title(m, s) do
    label = s.label || s.span

    if Enum.count(spans(m), &((&1.label || &1.span) == label)) > 1,
      do: "#{label} #{String.downcase((kind(m, s.subject) || unknown_kind(s.subject)).plural)}",
      else: label
  end

  # Supervised by you, calm: its groups (per span the flows are in) and the flows it
  # supervises (state, who it waits on); on a group's page (`active`) only those in that span.
  defp supervised_by_you(m, by, answers, active) do
    case Enum.find(answers, &match?(%{"error" => _}, &1)) do
      nil ->
        rule = supervised_rule(m)
        {all, running} = supervised_facts(m, by, answers)

        span_key = fn {kind, _fact, w} ->
          s = span_of(m, kind, w["presentation"])
          {s.subflow, s.span}
        end

        items = Enum.filter(all, &(active in [nil, span_key.(&1)]))

        doing =
          case rule[:work] do
            %{kind: kind, of: of} ->
              for t <- running,
                  key <- get_in(t, ["links", of]) || [],
                  into: %{},
                  do: {key, {kind, t}}

            _ ->
              %{}
          end

        list =
          Blocks.list(
            title: rule.title || "",
            rows:
              work_order(
                for {kind, fact, work} <- items do
                  {screen_row(m, kind, fact, work, by, active == nil, doing[fact["key"]]),
                   deadline(m, [
                     {written_on(span_of(m, kind, work["presentation"])), work},
                     {kind, fact}
                   ])}
                end
              ),
            empty: rule.empty
          )

        counts = Enum.frequencies_by(all, span_key)

        grouped_page(m, {:supervised_by_you, by}, counts, active, rule.title || "", [
          {"list", list}
        ])

      failed ->
        unavailable(failed, "/")
    end
  end

  # One calm row of a screen: the fact's key, the fact, the flow its work is in (its short
  # name, when no heading says it: `flow?`), whom it waits on (the owner keys Facts presents
  # on the `work`, only once someone supervises it or set it by hand: Flow's default holder
  # of unpicked work is not news), whether it is blocked; the rest is on its page. Where a
  # heading or group says the flow, the row says what it belongs under (its parents' keys)
  # instead. While the client's running work is on it (`doing`, `{kind, fact}`), the row
  # says that work (its kind and detail) in place of the flow: an agent is at it. Where it
  # stands for the viewer `by`, since when: `status/4`.
  defp screen_row(m, kind, fact, work, by, flow?, doing \\ nil) do
    parents = if flow?, do: [], else: Map.values(parent_values(m, kind, fact))
    p = work["presentation"] || %{}

    todo =
      case doing do
        {work_kind, t} ->
          Enum.join([singular(m, work_kind), detail(kind(m, work_kind), t)] -- [nil], " · ")

        nil ->
          if flow?, do: flow_name(m, fact, work)
      end

    detail =
      (parents ++
         [
           todo,
           case p["owner"] do
             [_ | _] = keys ->
               if p["supervisor"] not in [nil, []] or p["manual"] == true,
                 do: Enum.join(keys, ", ")

             _ ->
               nil
           end,
           shown(fact, work, "status") == "blocked" && "blocked"
         ])
      |> Enum.reject(&(&1 in [nil, "", false]))
      |> Enum.join(" · ")

    {tone, since} = status(fact, [work, fact], by, doing: doing)

    Blocks.row(
      id: fact["key"],
      label: label(kind(m, kind), fact),
      kind: singular(m, kind),
      icon: kind_icon(m, kind),
      detail: detail,
      to: path({:item, kind, fact["key"]}),
      tone: tone,
      since: since
    )
  end

  # Pages

  @doc """
  The page for `route`: `%{title, back, blocks}`. `answers` are Facts' answers to

  `reads/2`, in order. `form` carries values and errors to show a form again, and who
  views it (`by`, `by_kind`).
  """
  def render(route, m, answers, form \\ %{})

  def render({:assigned, by}, m, answers, form),
    do: assigned(m, by, answers, marked(form), nil)

  # A supervision screen without its start entry is no page (`resolve/2`).
  def render({screen, by}, m, answers, form) when screen in [:open_for_you, :supervised_by_you] do
    case {screen, screen_rule(m, screen)} do
      {_, nil} -> render(:unknown, m, answers, form)
      {:open_for_you, _} -> open_for_you(m, by || form[:by], answers, nil)
      {:supervised_by_you, _} -> supervised_by_you(m, by, answers, nil)
    end
  end

  def render({:group, screen, key, by} = route, m, answers, form) do
    case {resolve(route, m), screen} do
      {:unknown, _} -> render(:unknown, m, answers, form)
      {_, :assigned} -> assigned(m, by, answers, marked(form), key)
      {_, :open_for_you} -> open_for_you(m, by || form[:by], answers, key)
      {_, :supervised_by_you} -> supervised_by_you(m, by, answers, key)
    end
  end

  def render({:hand_over, kind, key, run}, m, answers, form),
    do: render({:hand_over, kind, key, run, form[:by]}, m, answers, form)

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
        empty: "Nothing here yet.",
        actions: start_actions(m)
      )
    ])
  end

  # Who views a page, as the model's callbacks take it: also whom it assists, when it is
  # an agent, so it is offered their answers on their behalf.
  defp viewer(form), do: %{key: form[:by], kind: form[:by_kind], assists: form[:assists]}

  defp page({:list, kind}, kind, k, m, answers, form) do
    if open_work?(m, kind),
      do: open_work(m, kind, answers, marked(form), form[:by]),
      else: list_page(kind, k, m, answers, form)
  end

  defp page({:item, kind, key}, kind, k, m, [answer | child_answers], form) do
    case answer do
      %{"fact" => nil} ->
        missing("#{k.label} #{key}", "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        back = path(owner(m, kind, answer) || up(m, kind, fact))
        relations = child_relations(m, kind)
        parts = item_parts(m, kind, child_answers)
        work = work_presentation(m, kind, fact, parts)
        todo = m.module.todo(kind, fact, parts_by_kind(parts), viewer(form))
        {next, more} = offered(m, kind, k, fact, child_answers, form)
        {child_answers, rest} = Enum.split(child_answers, length(relations))
        {cause_answers, _part_answers} = Enum.split(rest, length(cause_fields(m)))

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
            supervisor_pair(m, kind, work) ++
            waiting_pair(work) ++
            copy(answer["copy"])

        # Beside what its owner decides, only what says something about the fact:
        # its title says its key; then its own fields that are filled but its title, who it
        # is for and from whom since when, and what it reaches. Agents read the rest with
        # `atlas get`.
        details_fields =
          Enum.reject(own_fields(k, fact, [k.primary | k.hidden]), &(&1["value"] == "—")) ++
            progress_pair(m, k, fact) ++
            review_pair(fact) ++
            linked(m, kind, fact) ++
            Enum.flat_map(parts, fn {part_kind, _k, part, _made} -> linked(m, part_kind, part) end) ++
            supervisor_pair(m, kind, work) ++
            waiting_pair(work) ++
            copy(answer["copy"])

        # The flow's next step, the page's actions, which a client shows with the page's
        # title; everything else (`offered/6`) in an `actions` block of its own.
        item =
          Blocks.item(
            title: "#{k.label} #{key}: #{label(k, fact)}",
            fields: fields,
            actions: page_actions(next),
            links: links(k, fact)
          )

        # Where its owner decides (the to-do has answers, or a panel), what is judged is
        # what is under it that anyone may put there (not what only a layer links, such as
        # its runs): those lists say what each one is about.
        panel = todo && Map.get(todo, :panel)
        deciding = todo != nil and (todo.answers != [] or panel != nil)

        {judged, lists} =
          relations
          |> Enum.zip(child_answers)
          |> Enum.zip(create_keys(m, kind))
          # A list of what points here through an association shows only when it has some;
          # where its owner decides, never the fact's own components (its Assignment).
          |> Enum.reject(fn {{{_relation, from, _r}, answer}, create_key} ->
            (create_key == nil and match?(%{"facts" => []}, answer)) or
              (deciding and Enum.any?(parts, &(elem(&1, 0) == from)))
          end)
          |> Enum.map(fn {{{relation, from, r}, child_answer}, _create_key} ->
            judged = deciding and r.parent and r.set_by == nil

            {judged,
             {list_id(relation, from, r),
              child_list(m, {relation, from, r}, child_answer, judged, form[:by])}}
          end)
          |> Enum.split_with(&elem(&1, 0))

        judged = Enum.map(judged, &elem(&1, 1))

        # Two parts, by what they hold, never how they look: the main part (the fact
        # itself, and later what is said about it) and the related part (the related
        # lists, what names it as its cause, then the facts it points at). Each list in a
        # section that carries its title. A client lays the parts out as it sees fit.
        # Where its owner decides, not the fact's own components (its Assignment, and whom
        # that names): its details say for whom it is.
        component = fn "parent:" <> name ->
          deciding and
            Enum.all?(rel(m, name).to, fn to -> Enum.any?(parts, &(elem(&1, 0) == to)) end)
        end

        references =
          Enum.map(lists, &elem(&1, 1)) ++
            cause_lists(m, key, cause_answers, form[:by]) ++
            Enum.reject(parent_lists(m, kind, fact), &component.(elem(&1, 0))) ++
            if(deciding,
              do: [],
              else:
                Enum.flat_map(parts, fn {part_kind, _k, part, _made} ->
                  parent_lists(m, part_kind, part)
                end)
            )

        sections =
          for {id, {title, _list}} <- references, do: Blocks.section(id, id, title: title)

        lists = for {id, {_title, list}} <- references, do: {id, list}

        # Where its owner decides: the fact as its details (`details_fields`), with what it
        # refers to, in a part of role details after what is decided; a client shows it
        # beside that when there is room, else under it. The part is titled Details; the
        # item no title of its own (the header has key and title), and no field whose text
        # a main block already shows (`head`).
        details = fn item, head ->
          shown = shown_texts(head)

          item
          |> put_in(["props", "title"], "")
          |> put_in(
            ["props", "fields"],
            Enum.reject(details_fields, &(normalize_text(&1["value"]) in shown))
          )
        end

        details_markup =
          [
            Blocks.part("item", List.last(["item" | Enum.map(lists, &elem(&1, 0))]),
              title: "Details",
              role: "details"
            )
          ] ++ sections

        cond do
          is_map(Map.get(k, :page)) ->
            spec = k.page
            {_tone, since} = status(fact, for({_, _, part, _} <- parts, do: part) ++ [fact], form[:by])
            state =
              for name <- List.wrap(spec["state"]),
                  f = field(k, name),
                  f != nil,
                  value = fact["values"][name],
                  value not in [nil, ""],
                  do: show(f, value)

            intro = get_in(spec, ["intro", "field"])
            text = if intro, do: to_text(fact["values"][intro]), else: ""
            related = Enum.zip(relations, child_answers)
            item_relation = get_in(spec, ["items", "relation"])
            item_state =
              if Enum.any?(next, fn action ->
                   is_binary(action["to"]) and String.contains?(action["to"], "/pick_up/")
                 end),
                do: "pick_up",
                else: work["state"]

            {primary, remaining} =
              related
              |> Enum.map(fn {{relation, from, r} = rel, child_answer} ->
                {title, list} = child_list(m, rel, child_answer, false, form[:by])
                id = list_id(relation, from, r)
                rows = list["props"]["rows"]
                list = put_in(list, ["props", "title"], title)

                list =
                  if relation == item_relation do
                    empty =
                      if match?(%{"facts" => facts} when is_list(facts), child_answer),
                        do: get_in(spec, ["items", "empty", item_state]) || list["props"]["empty"],
                        else: list["props"]["empty"]

                    list
                    |> put_in(["props", "empty"], empty)
                    |> put_in(["props", "aside"], if(rows == [], do: nil, else: "#{Enum.count(rows, &(&1["tone"] == "done"))} of #{length(rows)} done"))
                  else
                    list
                  end

                {relation == item_relation, {id, {title, list}}}
              end)
              |> Enum.split_with(&elem(&1, 0))

            primary = Enum.map(primary, &elem(&1, 1))
            remaining = Enum.map(remaining, &elem(&1, 1)) ++ cause_lists(m, key, cause_answers, form[:by]) ++
              parent_lists(m, kind, fact) ++
              Enum.flat_map(parts, fn {part_kind, _k, part, _made} -> parent_lists(m, part_kind, part) end)

            header =
              Blocks.header(
                eyebrow: String.upcase(k.label),
                key: key,
                title: label(k, fact),
                icon: kind_icon(m, kind),
                detail: if(state == [], do: nil, else: Enum.join(state, " · ")),
                since: since
              )

            # Keep the existing proposal panel and its navigation, including its answer actions.
            panel_blocks =
              if panel do
                {block, _listed} = panel_block(m, kind, key, fact, todo, panel, related)
                [{"panel", block}]
              else
                []
              end

            todo_blocks = if todo && !panel, do: [{"todo", todo_item(todo)}], else: []
            panel_keys =
              for {"panel", block} <- panel_blocks,
                  answer <- block["props"]["answers"] || [],
                  do: answer["key"]

            remaining_next = Enum.reject(next, &(&1["key"] in panel_keys))
            answer_blocks =
              if remaining_next == [],
                do: [],
                else: [{"answers", answers_block(remaining_next, (todo && todo.answers) || [])}]

            content =
              [{"header", header}] ++
                if(text == "", do: [], else: [{"intro", Blocks.text(text: text)}]) ++
                todo_blocks ++
                for({id, {_title, list}} <- primary, do: {id, list}) ++
                panel_blocks ++ answer_blocks ++ others_block(more) ++
                [{"item", item |> put_in(["props", "title"], "") |> put_in(["props", "actions"], [])}] ++
                for({id, {_title, list}} <- remaining, do: {id, list})

            markup =
              [Blocks.part("item", List.last(["item" | Enum.map(remaining, &elem(&1, 0))]),
                 title: "Details", role: "details")] ++
                for({id, {title, _list}} <- remaining, do: Blocks.section(id, id, title: title))

            page("#{k.label} #{key}", back, content, markup)

          deciding and todo.section[:steps] != nil ->
            # A to-do with steps, as a stack of simple blocks: its header, why, each step,
            # its answers and the page's next steps; what is judged; then the details,
            # without what the steps already show.
            %{steps: %{from: from}} = todo.section
            shown = for f <- k.fields, f.name == from, do: f.label

            head = todo_blocks(todo, key, label(k, fact), next) |> iconed(kind_icon(m, kind))

            item =
              item
              |> details.(head)
              |> update_in(["props", "fields"], fn fields ->
                Enum.reject(fields, &(&1["label"] in shown))
              end)
              |> put_in(["props", "actions"], [])

            content =
              head ++
                others_block(more) ++
                for({id, {_title, list}} <- judged, do: {id, list}) ++
                [{"item", item}] ++ lists

            markup =
              for({id, {title, _list}} <- judged, do: Blocks.section(id, id, title: title)) ++
                details_markup

            page("#{k.label} #{key}", back, content, markup)

          deciding ->
            # A page where its owner decides is one stretch, top down: the to-do and its
            # answers, the panel the model declares for its state, or a choice as a stack
            # of simple blocks (`decision_blocks/3`) with the page's other next steps as
            # its answers; the page's other actions; what is judged (the section of the
            # fact the state names, the facts under it, but those the panel lists); then the
            # details.
            choice = Map.get(todo, :choice)

            {head, judged, item} =
              case panel do
                %{"choose" => true} = spec ->
                  related = Enum.zip(relations, child_answers)

                  {stuck_blocks(m, kind, key, fact, todo, spec, related, next), judged,
                   put_in(item, ["props", "actions"], [])}

                %{} = spec ->
                  related = Enum.zip(relations, child_answers)
                  {block, listed} = panel_block(m, kind, key, fact, todo, spec, related)
                  keys = for link <- block["props"]["links"] || [], do: link["key"]

                  {[{"panel", block}], Enum.reject(judged, &(elem(&1, 0) in listed)),
                   update_in(item, ["props", "links"], fn links ->
                     links && Enum.reject(links, &(&1["key"] in keys))
                   end)}

                nil when is_map(choice) ->
                  {choice_blocks(todo, choice, key, next), judged,
                   put_in(item, ["props", "actions"], [])}

                nil ->
                  {decide_blocks(todo, next), judged, put_in(item, ["props", "actions"], [])}
              end

            detail_item = details.(item, head)
            {detail_item, detail_blocks, technical} = decision_details(k, fact, detail_item)

            content =
              iconed(head, kind_icon(m, kind)) ++
                others_block(more) ++
                for({id, {_title, list}} <- judged, do: {id, list}) ++
                [{"item", detail_item}] ++ detail_blocks ++ lists ++ technical

            markup =
              for({id, {title, _list}} <- judged, do: Blocks.section(id, id, title: title)) ++
                decision_details_markup(details_markup, detail_blocks, technical)

            page("#{k.label} #{key}", back, content, markup)

          true ->
            ids = for {id, _} <- references, do: id
            others = others_block(more)

            main =
              Blocks.part("item", if(others == [], do: "item", else: "actions"),
                title: "Content",
                role: "main"
              )

            markup =
              case ids do
                [] ->
                  [main]

                [first | _] ->
                  [main, Blocks.part(first, List.last(ids), title: "References", role: "related")] ++
                    sections
              end

            {item, detail_blocks, technical} = decision_details(k, fact, item)
            content = [{"item", item} | others] ++ lists ++ detail_blocks ++ technical

            markup =
              if detail_blocks != [] or technical != [] do
                first = elem(hd(detail_blocks ++ technical), 0)
                last = elem(List.last(detail_blocks ++ technical), 0)

                markup ++
                  [Blocks.part(first, last, title: "Details", role: "details")] ++
                  technical_section(technical)
              else
                markup
              end

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
        end

      %{"error" => _} = failed ->
        unavailable(failed, path({:list, kind}))
    end
  end

  # Deprecated (contract 0.34.0, no page links here): a fact's secondary menu, what its
  # page offers besides the flow's next step, which the page now shows itself.
  defp page({:more, kind, key}, kind, k, m, [answer | rest], form) do
    title = "More… #{key}"

    case answer do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        {_next, more} = offered(m, kind, k, fact, rest, form)

        page(title, path({:item, kind, key}), [
          Blocks.item(title: "#{k.label} #{key}: #{label(k, fact)}", fields: [], actions: more)
        ])

      %{"error" => _} = failed ->
        unavailable(failed, path({:item, kind, key}))
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

      %{hand_over: true, choices: %{}} = answer ->
        title = "#{answer.label} #{key} to…"
        d = delegation(m, kind, answer, answers, form)
        page(title, back, [delegate_form(m, route, title, d, form, back)])

      answer ->
        title = "#{answer.label} #{key}"

        # A note it needs is asked with its own question when it has one ("What is your
        # alternative?"); given without, the form asks it again.
        block =
          if answer.note do
            Blocks.form(
              title: title,
              inputs: [
                Blocks.input(
                  name: "note",
                  label: Map.get(answer, :prompt) || "Note",
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
  # may not (as the page shows it: another client), or it is linked already.
  defp page({:set, kind, key, relation} = route, kind, k, m, answers, form) do
    back = path({:item, kind, key})
    r = rel(m, relation) || missing_relation(relation)
    label = (r.set && r.set.label) || String.capitalize(r.label)
    title = "#{label} #{key}"

    case hd(answers) do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        problem =
          if may_link?(m, relation, form[:by], form[:by_kind]),
            do: set_problem(m, route, answers),
            else: "#{String.capitalize(r.label)} is not set here: #{why_not(r)}."

        case problem do
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
            confirm =
              Blocks.confirm(
                title: "#{key} cannot be deleted",
                text: "#{key} still has #{counted(held)}. " <> remove_first(held),
                cancel_to: back
              )

            page("#{verb(:delete)} #{key}", back, [confirm])
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  # Pick up (become the supervisor of the run that presents the fact), Retry (take the run
  # back to the start of its span) and Remove (delete the fact with the work Flow made for
  # it, which ends the run): a confirm, after asking; why not, while it may not
  # (`pick_up_problem/4`, `retry_problem/4`, `remove_problem/4`).
  defp page({verb, kind, key, _run} = route, kind, k, m, answers, form)
       when verb in [:pick_up, :retry, :remove_item] do
    back = path({:item, kind, key})
    {label, _key} = @supervision[verb]
    title = "#{label} #{key}"

    case hd(answers) do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} = answer ->
        case confirm_problem(verb, m, route, answers, form) do
          nil ->
            page(title, back, [
              Blocks.confirm(
                title: "#{title}?",
                text: "#{key}: #{label(k, fact)}" <> confirming(verb, m, kind, answer, form),
                confirm_label: label,
                confirm_to: call_to(route),
                cancel_to: back
              )
            ])

          problem ->
            missing(title, problem, back)
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  # Hand the run over to someone else (decision 4; §6.3): a choice of who, and the
  # client's running work on the flow that will stop. No note. Why not, while it may not.
  defp page({:hand_over, kind, key, run, _by} = route, kind, k, m, answers, form) do
    back = path({:item, kind, key})
    {label, _key} = @supervision.hand_over
    title = "#{label} #{key}"
    submit = {:hand_over, kind, key, run}

    case hd(answers) do
      %{"fact" => nil} ->
        missing(title, "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        case hand_over_problem(m, route, answers, form) do
          nil ->
            to = choice_input(m, others(m, kind, answers, form[:by]), form)
            stopping = stopping_tasks(m, route, answers)
            work = supervised_rule(m)[:work]
            work_k = work && (kind(m, work.kind) || unknown_kind(work.kind))

            stops =
              if work_k,
                do: [
                  {"stopping",
                   Blocks.list(
                     title: work_k.plural,
                     rows:
                       for(
                         t <- stopping,
                         do:
                           Blocks.row(
                             id: t["key"],
                             label: label(work_k, t),
                             to: path({:item, work.kind, t["key"]})
                           )
                       ),
                     empty: "—"
                   )}
                ],
                else: []

            form_block =
              Blocks.form(
                title: "#{title}: #{label(k, fact)}",
                inputs: [to],
                submit_label: label,
                submit_to: call_to(submit),
                cancel_to: back,
                errors: form[:errors] || []
              )

            page(title, back, [{"form", form_block} | stops])

          problem ->
            missing(title, problem, back)
        end

      %{"error" => _} = failed ->
        unavailable(failed, back)
    end
  end

  defp page(_route, _kind, _k, _m, _answers, _form),
    do: missing("Nothing here", "This page does not exist.", "/")

  # A delegation's form (D-0106): to whom, nothing chosen until the viewer chooses: its
  # proposer, who decides as the viewer delegates, or, when the page can hand it over,
  # someone else, then asked whom.
  defp delegate_form(m, route, title, d, form, back) do
    values = form[:values] || %{}
    words = d.answer.choices
    other? = d.handing != nil and d.delegates != []
    kinds = delegate_kinds(m, elem(route, 1))
    whom_k = (length(kinds) == 1 && kind(m, hd(kinds))) || nil

    to =
      Blocks.input(
        name: "to",
        label: "To",
        kind: "choice",
        required: true,
        value: values["to"],
        choices:
          [Blocks.choice(value: "proposer", label: d.proposer, help: words.change.help)] ++
            if(other?,
              do: [
                Blocks.choice(
                  value: "other",
                  label: words.hand_over.label,
                  help: words.hand_over.help
                )
              ],
              else: []
            )
      )

    whom =
      Blocks.input(
        name: "whom",
        label: (whom_k && whom_k.label) || "Whom",
        kind: "choice",
        required: true,
        value: values["whom"],
        shown_when: Blocks.input_condition(name: "to", value: "other"),
        choices:
          for(
            p <- Enum.sort_by(d.delegates, &key_order(&1["key"])),
            do: Blocks.choice(value: p["key"], label: "#{p["key"]}: #{label(whom_k, p)}")
          )
      )

    Blocks.form(
      title: title,
      inputs: [to | if(other?, do: [whom], else: [])],
      submit_label: d.answer.label,
      submit_to: call_to(route),
      cancel_to: back,
      errors: form[:errors] || []
    )
  end

  defp list_page(kind, k, m, [answer | rest], form) do
    # The only top kind's list is the start page; there is nothing to go back to.
    start? = top_kinds(m) == [kind]
    # With a start page of assignments, the plan is one key away from it, and back.
    first? = start? and not assigned_start?(m, form[:by_kind])
    {count_answers, status_answers} = Enum.split(rest, length(counts(m, kind)))

    case answer do
      %{"facts" => facts} ->
        counted = counted(m, kind, count_answers)
        written = presented_parts(m, kind, status_answers)

        rows =
          facts
          |> sort_facts(k)
          |> Enum.map(fn fact ->
            {tone, since} = status(fact, written.(fact) ++ [fact], form[:by])

            Blocks.row(
              id: fact["key"],
              label: label(k, fact),
              detail: join_detail(detail(k, fact), counted.(fact["key"])),
              kind: k && k.label,
              icon: kind_icon(m, kind),
              to: path({:item, kind, fact["key"]}),
              links: links(k, fact),
              tone: tone,
              since: since
            )
          end)

        creates? = by_hand?(m, kind, :create)

        list =
          Blocks.list(
            title: k.plural,
            rows: rows,
            empty: "No #{String.downcase(k.plural)} yet.",
            actions:
              page_actions(
                if(creates?, do: [action(:create, k, path({:new, kind}))], else: []) ++
                  if(start?, do: start_actions(m, kind), else: [])
              )
          )

        back = if first?, do: nil, else: "/"
        page(k.plural, back, [list])

      %{"error" => _} = failed ->
        unavailable(failed, "/")
    end
  end

  # For a fact of `kind`, its components whose work Facts presents, from the answers to
  # `status_reads/2` (in its order): `fact -> [component fact]`. A failed read is left out:
  # its rows then say nothing of where they stand.
  defp presented_parts(m, kind, answers) do
    found =
      for {{relation, _, _}, %{"facts" => facts}} <-
            Enum.zip(presented_components(m, kind), answers),
          do: {relation, Map.new(facts, &{&1["key"], &1})}

    fn fact ->
      for {relation, by_key} <- found,
          key <- get_in(fact, ["links", relation]) || [],
          part = by_key[key],
          part != nil,
          do: part
    end
  end

  # The view model of a page. A block without an id of its own is named by its type; a
  # page holds at most one such block of each type. A list's title that only repeats the
  # page's is not sent: the page's title says it.
  defp page(title, back, content, markup \\ []) do
    content =
      Enum.map(content, fn
        {id, block} -> {id, untitled(block, title)}
        block -> {block["type"], untitled(block, title)}
      end)

    result = Map.merge(%{title: title, back: back}, Blocks.view_model(content, markup))

    if Enum.any?(markup, &(get_in(&1, ["props", "collapsible"]) == true)),
      do: Map.put(result, :console_actions, [details_action()]),
      else: result
  end

  defp untitled(%{"type" => "list", "props" => %{"title" => title} = props} = block, title),
    do: unshared(%{block | "props" => Map.delete(props, "title")})

  defp untitled(block, _title), do: unshared(block)

  # A list's rows (two or more) that all have the same detail do not each say it: the list
  # says it (every to-do "Open"). Where they differ, each row keeps its own.
  defp unshared(%{"type" => "list", "props" => %{"rows" => [_, _ | _] = rows} = props} = block) do
    case Enum.uniq_by(rows, & &1["detail"]) do
      [%{"detail" => detail}] when detail not in [nil, ""] ->
        %{block | "props" => %{props | "rows" => Enum.map(rows, &Map.delete(&1, "detail"))}}

      _ ->
        block
    end
  end

  defp unshared(block), do: block

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
            fact <- Enum.sort_by(facts, &key_order(&1["key"])),
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

  defp why_not(r), do: (r.only_target && r.only_target.error) || "not by this client"

  @doc """
  Why the fact of `route` (`{:set, kind, key, relation}`) cannot be linked to the client,
  or nil: it has no such relation, or is linked already. `answers` are Facts' answers to
  the route's reads, the fact first. Whether the client may, and whatever else the model
  rules about the link, Facts checks.
  """
  def set_problem(m, {:set, kind, key, relation}, [answer | _]) do
    r = rel(m, relation) || missing_relation(relation)
    fact = answer["fact"] || %{}
    linked = get_in(fact, ["links", relation]) || []

    cond do
      kind not in r.from -> "#{key} has no #{r.label}"
      linked != [] -> "#{key} is #{r.label} #{Enum.join(linked, ", ")} already."
      true -> nil
    end
  end

  @doc """
  The answer of the state the work on the fact is presented in that links the fact to
  the one who answers through `relation` (its change's `self`), as the presentation's
  todo declares it (`%{"values", "self", "label", "note"}`, as the model's `answer/4`
  gives one), or nil. Setting `relation` on the page (Accept) writes what that answer
  writes, by whoever may set it, so the run moves as when the owner answers. `answers` are
  Facts' answers to the route's reads, the fact first.
  """
  def self_answer(m, kind, relation, [%{"fact" => fact} | rest]) when is_map(fact) do
    parts = for {_kind, _k, part, _made} <- item_parts(m, kind, rest), do: part

    Enum.find_value([fact | parts], fn written ->
      with %{"actionable" => true, "todo" => %{} = todo} <- written["presentation"],
           %{"change" => %{} = change} = answer <-
             Enum.find(todo["answers"] || [], &(get_in(&1, ["change", "self"]) == relation)) do
        %{
          "values" => change["values"] || %{},
          "self" => relation,
          "label" => answer["label"],
          "note" => false
        }
      else
        _ -> nil
      end
    end)
  end

  def self_answer(_m, _kind, _relation, _answers), do: nil

  # What a fact's page offers, `{next, more}`, as the page's reads answered it (the fact's
  # answer is not among `rest`): the flow's next step (the owner's answers, the restart,
  # Pick up and Retry), and everything else (`others_block/1`). Nothing raw
  # where the flow covers it: no Delete where Remove ends the run instead, no change of
  # who has a supervised flow's work while nobody picked it up (D-0099), and no Create of
  # what a flow makes under it. An action on the same key as a next step gives way to it,
  # and Pick up or Retry to an owner's answer of the same label: a state's own Retry
  # (back to the step that failed, IS-Atlas-134) stands for the span's. An answer that
  # hands the work over (Delegate, D-0106) stands for the page's own hand-over.
  defp offered(m, kind, k, fact, rest, form) do
    parts = item_parts(m, kind, rest)
    work = work_presentation(m, kind, fact, parts)
    todo = m.module.todo(kind, fact, parts_by_kind(parts), viewer(form))
    part_answers = Enum.drop(rest, length(child_relations(m, kind)) + length(cause_fields(m)))

    {picks, supervising} =
      supervision_actions(m, kind, fact, work, candidates(m, kind, part_answers), form)

    span? = kind in span_kinds(m)

    handing =
      if span? and supervisor(work) == [],
        do: [],
        else:
          Enum.flat_map(parts, fn {part_kind, _k, part, _made} ->
            link_actions(m, part_kind, part, form)
          end)

    answers = answer_actions(kind, fact, todo, handing)
    answered = Enum.map(answers, & &1["label"])

    next =
      answers ++
        restart_actions(m, kind, fact, parts, form) ++
        Enum.reject(picks, &(&1["label"] in answered))

    delegating? = todo != nil and Enum.any?(todo.answers, &Map.get(&1, :hand_over))

    more =
      supervising ++
        fact_actions(m, k, fact, form, span? and is_binary(work["run"])) ++
        link_actions(m, kind, fact, form) ++
        if(delegating?, do: [], else: handing) ++ create_actions(m, kind, fact["key"])

    keys = Enum.map(next, & &1["key"])
    {next, Enum.reject(more, &(&1["key"] in keys))}
  end

  # Everything a fact's page offers besides the flow's next step, below its answers and
  # quieter than they are; nothing when there is nothing.
  defp others_block([]), do: []
  defp others_block(more), do: [{"actions", Blocks.actions(actions: more)}]

  # The operations and actions the model offers on a fact's page, for this client; no
  # Delete when the fact is `removed?` instead (Remove). On its own page a button needs
  # not name the kind: Update, Delete (the label, for menus and tools, keeps it).
  defp fact_actions(m, k, fact, form, removed?) do
    for action <- m.module.actions(k.name, fact, viewer(form)),
        not (removed? and action == %{op: :delete}) do
      case action do
        %{op: :update} ->
          own_page(action(:update, k, path({:edit, k.name, fact["key"]})), :update)

        %{op: :delete} ->
          own_page(action(:delete, k, path({:delete, k.name, fact["key"]})), :delete)

        %{label: label, key: key, to: to} = a ->
          Blocks.action(
            label: label,
            key: key,
            to: to,
            icon: "open",
            button: button(label),
            help: a[:help] || label
          )
      end
    end
  end

  defp own_page(action, op), do: Map.put(action, "button", elem(operation(op, nil), 0))

  # A Create in each related list a fact of the kind may be made by hand in: not under a
  # relation marked to add nothing, nor an association (no create key), nor of a kind a
  # flow on `kind` makes: what its tasks create (a span's `creates`) and the subjects of
  # the runs its span holds (`with_subjects`).
  defp create_actions(m, kind, key) do
    made =
      for s <- spans(m),
          s.subject == kind,
          made <- (s[:creates] || []) ++ (s[:with_subjects] || []),
          do: made

    for {{relation, from, r}, create_key} <-
          Enum.zip(child_relations(m, kind), create_keys(m, kind)),
        create_key != nil and r.add and by_hand?(m, from, :create),
        from not in made,
        do:
          action(
            :create,
            kind(m, from) || unknown_kind(from),
            path({:new, from, {relation, key}}),
            create_key
          )
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
        do:
          Blocks.action(
            label: label,
            key: key,
            to: path({page, kind, fact["key"], r.name}),
            icon: "hand_over",
            button: button(label),
            help: action[:help] || label
          )
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

  # The fact a read answered, or one with only its key (to title a page that says it is gone).
  defp fact_of(%{"fact" => %{} = fact}, _key), do: fact
  defp fact_of(_answer, key), do: %{"key" => key, "values" => %{}}

  @doc "The keys a links form's `to` names; none removes the links."
  def link_keys(text) do
    text |> to_string() |> String.split(~r/[,\s]+/, trim: true) |> Enum.uniq()
  end

  # A judged list (its owner decides on what is under it) says what each fact is about:
  # its label, then the first line of its first text of several lines. Each row says where
  # it stands for the viewer `by` as far as the fact itself says (`status/4`).
  defp child_list(m, {_relation, from, r}, answer, judged, by) do
    from_k = kind(m, from) || unknown_kind(from)
    title = String.capitalize(r.inverse_label || from_k.plural)

    # One list per kind for a relation from several: the kind says which.
    title = if length(r.from) > 1, do: "#{title}: #{from_k.plural}", else: title

    rows =
      case answer do
        %{"facts" => facts} ->
          facts
          |> sort_facts(from_k)
          |> Enum.map(fn fact ->
            {tone, since} = status(fact, [fact], by)

            Blocks.row(
              id: fact["key"],
              label: if(judged, do: about(from_k, fact), else: label(from_k, fact)),
              detail: detail(from_k, fact),
              kind: from_k && from_k.label,
              icon: kind_icon(m, from),
              to: path({:item, from, fact["key"]}),
              links: links(from_k, fact),
              tone: tone,
              since: since
            )
          end)

        _ ->
          []
      end

    empty =
      case answer do
        %{"error" => error} -> "#{error}."
        _ -> "No #{String.downcase(title)} yet."
      end

    {title, Blocks.list(rows: rows, empty: empty)}
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
  defp cause_lists(m, key, answers, by) do
    for {{from, name, title}, %{"facts" => facts}} <- Enum.zip(cause_fields(m), answers),
        naming = Enum.filter(facts, &(to_text(&1["values"][name]) == key)),
        naming != [] do
      from_k = kind(m, from)

      rows =
        for fact <- sort_facts(naming, from_k) do
          {tone, since} = status(fact, [fact], by)

          Blocks.row(
            id: fact["key"],
            label: label(from_k, fact),
            detail: detail(from_k, fact),
            kind: from_k && from_k.label,
            icon: kind_icon(m, from),
            to: path({:item, from, fact["key"]}),
            tone: tone,
            since: since
          )
        end

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

  # The model names the groups and the exact offer records; raw records share one section.
  defp decision_details(k, fact, item) do
    case Map.get(k, :decision_options) do
      %{"details" => groups} = rule when is_list(groups) ->
        fields = item["props"]["fields"] || []
        raw_names = Enum.map(~w(definition snapshot revision history), &rule[&1])
        raw_labels = for f <- k.fields, f.name in raw_names, do: f.label
        fields = Enum.reject(fields, &(&1["label"] in raw_labels))

        {blocks, remaining} =
          groups
          |> Enum.with_index()
          |> Enum.map_reduce(fields, fn {group, index}, remaining ->
            names = group["fields"] ++ if(index == 0, do: [rule["selected"]], else: [])
            labels = for f <- k.fields, f.name in names, do: f.label
            {selected, rest} = Enum.split_with(remaining, &(&1["label"] in labels))

            present =
              for f <- k.fields,
                  f.name in names,
                  fact["values"][f.name] not in [nil, ""],
                  do: f.label

            selected = Enum.filter(selected, &(&1["label"] in present))

            block =
              if selected == [],
                do: [],
                else: [
                  {"decision-detail-#{index}",
                   Blocks.item(title: group["title"], fields: selected)}
                ]

            {block, rest}
          end)

        history_blocks = decision_history(k, rule, fact)

        technical =
          for name <- raw_names,
              value = get_in(fact, ["values", name]),
              value not in [nil, ""],
              field = Enum.find(k.fields, &(&1.name == name)),
              field != nil do
            {"decision-raw-#{name}",
             Blocks.item(
               title: field.label,
               fields: [Blocks.pair(label: field.label, value: value)]
             )}
          end

        {put_in(item, ["props", "fields"], remaining), List.flatten(blocks) ++ history_blocks,
         technical}

      _ ->
        {item, [], []}
    end
  end

  defp decision_history(k, rule, fact) do
    text = get_in(fact, ["values", rule["history"]])

    current = %{
      "definition" => get_in(fact, ["values", rule["definition"]]),
      "values" =>
        Map.take(fact["values"] || %{}, rule["content"] || [])
        |> Map.reject(fn {_, value} -> value in [nil, ""] end),
      "links" =>
        Map.new(rule["content_links"] || [], fn relation ->
          {relation, Enum.sort(get_in(fact, ["links", relation]) || [])}
        end)
    }

    selected_revision = get_in(fact, ["values", rule["revision"]])

    with true <- is_binary(text),
         {:ok, entries} when is_list(entries) <- JSON.decode(text) do
      entries
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {%{} = entry, index} ->
          same =
            if is_binary(selected_revision) and selected_revision != "",
              do: entry["revision"] == selected_revision,
              else: Map.take(entry, ~w(definition values links)) == current

          fields = if same, do: [], else: history_fields(k, entry)

          if fields == [],
            do: [],
            else: [
              {"decision-history-#{index}",
               Blocks.item(title: "Earlier offer #{index}", fields: fields)}
            ]

        _ ->
          []
      end)
    else
      _ -> []
    end
  end

  defp history_fields(k, entry) do
    offer =
      case entry["definition"] do
        text when is_binary(text) ->
          case JSON.decode(text) do
            {:ok, %{} = decoded} -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    intro = history_pairs([{"Question", offer["question"]}, {"Rationale", offer["rationale"]}])

    options =
      offer["options"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {%{} = option, index} ->
          recommended = is_binary(offer["recommended"]) and option["id"] == offer["recommended"]
          label = "Option #{index}" <> if(recommended, do: " (recommended)", else: "")

          history_pairs([
            {label, option["text"]},
            {"Details", option["details"]},
            {"Rule", option["rule"]},
            {"Consequences", option["consequences"]}
          ])

        _ ->
          []
      end)

    values =
      for {name, value} <- Enum.sort(if(is_map(entry["values"]), do: entry["values"], else: %{})),
          is_binary(value) or is_number(value) or is_boolean(value),
          value not in [nil, ""] do
        field = Enum.find(k.fields, &(&1.name == name))
        Blocks.pair(label: if(field, do: field.label, else: name), value: to_text(value))
      end

    links =
      for {name, keys} <- Enum.sort(if(is_map(entry["links"]), do: entry["links"], else: %{})),
          is_list(keys),
          keys != [],
          Enum.all?(keys, &is_binary/1) do
        relation = Enum.find(k.relations, &(&1.name == name))

        Blocks.pair(
          label: if(relation, do: String.capitalize(relation.label), else: name),
          value: Enum.join(keys, ", ")
        )
      end

    intro ++ options ++ values ++ links
  end

  defp history_pairs(pairs),
    do:
      for(
        {label, value} <- pairs,
        is_binary(value),
        value != "",
        do: Blocks.pair(label: label, value: value)
      )

  defp decision_details_markup(markup, [], []), do: markup

  defp decision_details_markup([part | sections], blocks, technical) do
    last =
      cond do
        technical != [] -> elem(List.last(technical), 0)
        sections != [] -> part["end"]
        true -> elem(List.last(blocks), 0)
      end

    [%{part | "end" => last} | sections] ++ technical_section(technical)
  end

  defp technical_section([]), do: []

  defp technical_section(blocks) do
    [
      Blocks.section(elem(hd(blocks), 0), elem(List.last(blocks), 0),
        title: "Technical details",
        collapsible: true
      )
    ]
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

  # A to-do with steps (`AtlasControl.Steps`) as a stack of simple blocks: a header (the
  # work's title and key), its why since when it is theirs, each step in full, then the
  # answers: the page's next steps (`actions`), each on its key and with its weight, those
  # that ask a note saying so.
  defp todo_blocks(todo, key, title, actions) do
    %{why: why, steps: steps} = AtlasControl.Steps.parse(todo.section.text)

    why =
      if why,
        do: [{"why", Blocks.text(text: why, since: todo.why.since)}],
        else: []

    [{"header", Blocks.header(eyebrow: "TO DO FOR YOU", key: key, title: title)}] ++
      why ++
      for(
        s <- steps,
        do:
          {"step-#{s.n}",
           Blocks.instruction(n: s.n, lines: for(line <- s.lines, do: instruction_line(line)))}
      ) ++
      [{"answers", answers_block(actions, todo.answers)}]
  end

  # The page's `actions` as what the viewer can answer, each on its key, as the to-do's
  # answer of the same key gives it (`answers`): whether it asks a note, its weight. One
  # that is no answer of the to-do (Retry, Pick up) weighs other; the first is the main
  # one when no answer is. Under a decision's options (`main?` false), whose own answers
  # carry the main and decline, every one weighs other. Each keeps its action's icon and
  # help.
  defp answers_block(actions, answers, main? \\ true) do
    by_key = Map.new(answers, &{&1.key, &1})

    weights =
      for a <- actions,
          do: if(main?, do: (by_key[a["key"]] || %{})[:weight] || "other", else: "other")

    Blocks.answers(
      answers:
        for {a, weight} <- Enum.zip(actions, with_main(weights, main?)) do
          Blocks.panel_answer(
            label: a["label"],
            key: a["key"],
            to: a["to"],
            submit_to: a["submit_to"],
            note: if(by_key[a["key"]][:note], do: true),
            weight: weight,
            button: button(a["label"]),
            icon: a["icon"],
            help: a["help"]
          )
        end
    )
  end

  # The weights with exactly one main: the first when none is.
  defp with_main([_ | rest] = weights, true),
    do: if("main" in weights, do: weights, else: ["main" | rest])

  defp with_main(weights, _main?), do: weights

  defp instruction_line(%{kind: :route, parts: parts}),
    do: Blocks.instruction_line(kind: "route", parts: parts)

  defp instruction_line(%{kind: kind, text: text}),
    do: Blocks.instruction_line(kind: Atom.to_string(kind), text: text)

  # What its owner is to do (IS-Atlas-54), as the model's `todo/4` gives it: what is
  # expected, why it came to them, the instructions, the section of the fact they name.
  # Every word is the model's or the fact's.
  defp todo_item(todo),
    do:
      Blocks.item(
        title: "#{todo.title}: #{todo.expected}",
        fields: todo_pairs(todo) ++ section_pairs(todo)
      )

  # Where its owner decides: the to-do, with what is judged of the fact itself under it
  # (the section the state names), then its answers and the page's other next steps
  # (`next`: Retry, Pick up, the restart), each on its key.
  defp decide_blocks(todo, next) do
    [
      {"todo", Blocks.item(title: "#{todo.title}: #{todo.expected}", fields: section_pairs(todo))}
    ] ++
      if(next == [],
        do: [],
        else: [{"answers", answers_block(next, todo.answers)}]
      )
  end

  # A decision's choice (`todo.choice`): the question, why, then each alternative to adopt
  # with its rule and what follows from it, one added from whoever declined marked as
  # theirs (`by`, D-0106): until its proposer works it out it has neither, and shows none.
  # Declining is the page's own Decline (with an alternative).
  defp choice_blocks(todo, choice, key, others) do
    adopts = choice["options"]
    chosen = Enum.filter(todo.answers, &Map.has_key?(&1, :name))

    options =
      for {option, a} <- Enum.zip(adopts, chosen) do
        %{
          text: option["text"],
          recommended: option["id"] == choice["recommended"],
          by: option["by"],
          answer: a,
          fields:
            for(
              {label, field} <- [{"Rule", "rule"}, {"Consequences", "consequences"}],
              is_binary(option[field]) and String.trim(option[field]) != "",
              do: Blocks.pair(label: label, value: option[field])
            )
        }
      end

    decision_blocks(
      [
        {"header", Blocks.header(eyebrow: "YOUR DECISION", key: key, title: choice["question"])},
        {"why", Blocks.text(text: choice["rationale"])}
      ],
      options,
      others,
      todo
    )
  end

  # Stuck work, as the model's `panel` with `choose` declares it: its title as the
  # question, its byline, what went wrong (its `box`), then each answer as an option, the
  # first recommended, with what it does (`details`); its `actions` (the agent's log) go
  # with the page's other answers.
  defp stuck_blocks(m, kind, key, fact, todo, spec, related, others) do
    k = kind(m, kind) || unknown_kind(kind)

    records =
      for {name, r} <- spec["records"] || %{}, into: %{} do
        {name, latest_record(m, related, r)}
      end

    scope = %{m: m, k: k, key: key, fact: fact, records: records}
    clauses = byline(scope, spec["byline"] || [], todo)
    details = spec["details"] || %{}
    keys = Enum.map(others, & &1["key"])

    options =
      todo.answers
      |> Enum.filter(&(&1.key in keys))
      |> Enum.with_index()
      |> Enum.map(fn {a, i} ->
        detail = details[a.key] || Map.get(a, :details)

        %{
          text: a.label,
          recommended: i == 0,
          answer: a,
          fields:
            if(detail,
              do: [
                Blocks.pair(label: if(a.note, do: "Details", else: "Consequences"), value: detail)
              ],
              else: []
            )
        }
      end)

    byline =
      case clauses do
        [] ->
          []

        _ ->
          text = Enum.map_join(clauses, " · ", & &1["text"])
          since = Enum.find_value(clauses, & &1["since"])
          [{"why", Blocks.text(text: text, since: since)}]
      end

    failure =
      case panel_box(scope, spec["box"]) do
        nil ->
          []

        box ->
          [{"failure", Blocks.text(label: box["title"], text: box["text"], role: box["tone"])}]
      end

    decision_blocks(
      [
        {"header",
         Blocks.header(
           eyebrow: spec["heading"],
           key: key,
           title: template(scope, spec["title"] || "") || "—"
         )}
      ] ++ byline ++ failure,
      options,
      panel_actions(scope, spec["actions"] || []) ++ others,
      todo
    )
  end

  # Every text the page's main blocks show (`{id, block}`): their texts, titles and field
  # values, whitespace-normalized, so details leave out what is already on the page.
  defp shown_texts(blocks) do
    blocks
    |> Enum.flat_map(fn {_id, block} -> texts_in(block["props"]) end)
    |> MapSet.new(&normalize_text/1)
    |> MapSet.delete("")
  end

  defp texts_in(%{} = map),
    do:
      Enum.flat_map(map, fn
        {k, v} when k in ["text", "title", "value"] and is_binary(v) -> [v]
        {_k, v} -> texts_in(v)
      end)

  defp texts_in(list) when is_list(list), do: Enum.flat_map(list, &texts_in/1)
  defp texts_in(_), do: []

  defp normalize_text(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp normalize_text(_), do: ""

  # A decision as a stack of simple blocks (D-0104): `intro` (its header, why, what went
  # wrong), then its adopt options as `option` blocks, the recommended one first (one an
  # earlier decider added, marked as theirs), and below them the page's answers. With one
  # adopt option its card shows no answer (`alone`): the answers start with Accept (main,
  # its answer). With more, each card has its own Choose (the recommended main, the rest
  # other). Then the decline: a decision's own Decline (D-0106: always, with an
  # alternative), or stuck work's declining option (the one given with a note); Decline
  # all when several alternatives are offered. Each answer is the page's action of the
  # same key (`others`), its call unchanged, with what it does in full (`help`: the
  # action's, else these words); the rest of `others` follow in the answers, each
  # weighing other, with its icon (Ask, Delegate).
  defp decision_blocks(intro, options, others, todo) do
    by_key = Map.new(others, &{&1["key"], &1})
    options = Enum.filter(options, &Map.has_key?(by_key, &1.answer.key))

    {declines, adopts} = Enum.split_with(options, & &1.answer.note)
    adopts = Enum.sort_by(adopts, &(!&1.recommended))
    alone? = match?([_], adopts)

    # The decline: stuck work's declining option, else the page's own answer weighing
    # decline that is no option (a decision's Decline).
    option_keys = Enum.map(options, & &1.answer.key)

    decline =
      List.first(declines) ||
        Enum.find_value(todo.answers, fn a ->
          if a.weight == "decline" and not Map.has_key?(a, :name) and
               a.key not in option_keys and Map.has_key?(by_key, a.key),
             do: %{answer: a}
        end)

    taken = option_keys ++ if(decline, do: [decline.answer.key], else: [])

    answer = fn o, label, weight, icon, help ->
      action = by_key[o.answer.key]

      Blocks.panel_answer(
        label: label,
        key: action["key"],
        to: action["to"],
        submit_to: action["submit_to"],
        note: if(o.answer.note, do: true),
        weight: weight,
        icon: icon,
        help: action["help"] || help
      )
    end

    option_blocks =
      adopts
      |> Enum.with_index(1)
      |> Enum.map(fn {o, n} ->
        {badge, tone} =
          cond do
            alone? ->
              {nil, nil}

            o.recommended ->
              {"★ Recommended", "success"}

            # Not yet worked out (no Rule, no Consequences): the note says who does that.
            is_binary(o[:by]) and o.fields == [] ->
              {"#{o.by}'s alternative, to be worked out by the proposer", nil}

            is_binary(o[:by]) ->
              {"#{o.by}'s alternative", nil}

            true ->
              {nil, nil}
          end

        {"option-#{n}",
         Blocks.option(
           n: n,
           text: o.text,
           badge: badge,
           tone: tone,
           fields: o.fields,
           answer:
             answer.(
               o,
               "Choose",
               if(n == 1, do: "main", else: "other"),
               nil,
               "Choose this alternative: it becomes the decision, decided by you"
             ),
           alone: if(alone?, do: true)
         )}
      end)

    # Under several alternatives Decline all is a quiet action with its icon; under one
    # proposal Decline stands next to Accept, as a decline.
    decline_all? = not (alone? or adopts == [])

    decided =
      if(alone?,
        do: [
          answer.(
            hd(adopts),
            "Accept",
            "main",
            nil,
            "Accept it as proposed: it becomes the decision, decided by you"
          )
        ],
        else: []
      ) ++
        cond do
          decline == nil ->
            []

          decline_all? ->
            [
              answer.(decline, "Decline all", "decline", "decline", nil)
              |> Map.put(
                "help",
                "Decline every alternative and give your own: it goes back to its proposer"
              )
            ]

          true ->
            [answer.(decline, "Decline", "decline", nil, nil)]
        end

    # `0` answers the recommended option again (`answer_actions/4`); its option shows it.
    rest = Enum.reject(others, &(&1["key"] in ["0" | taken]))

    answers =
      if(rest == [], do: [], else: answers_block(rest, todo.answers, false)["props"]["answers"])

    intro ++
      option_blocks ++
      if(decided ++ answers == [],
        do: [],
        else: [{"answers", Blocks.answers(answers: decided ++ answers)}]
      )
  end

  # -- The panel its owner decides in --------------------------------------------------
  #
  # The model's `panel` for the state the work is in (`todo.panel`, as written) says what
  # the panel shows, in names of the kind's fields and relations; every word is the
  # model's or a fact's. Its texts are templates: `{name}` is the fact's key (`key`), one
  # of its fields (shown as the page shows it), the keys it links to through a relation,
  # or a record (`records`: the latest fact of a relation pointing at it, by key, with
  # `where` values): its key, or `{record.field}` its field. `{name|number}` keeps the
  # trailing number of a value, `{name|line}` the first line of a text. A text whose
  # values are not all there is not shown: a byline part is left out, anything else is
  # "—". `{panel block, ids of the lists it shows the items of}`.
  defp panel_block(m, kind, key, fact, todo, spec, related) do
    k = kind(m, kind) || unknown_kind(kind)

    records =
      for {name, r} <- spec["records"] || %{}, into: %{} do
        {name, latest_record(m, related, r)}
      end

    scope = %{m: m, k: k, key: key, fact: fact, records: records}
    {items, aside, listed} = panel_items(m, spec["items"], related)

    block =
      Blocks.panel(
        heading: spec["heading"] || "",
        title: template(scope, spec["title"] || "") || "—",
        key: key,
        aside: aside,
        byline: byline(scope, spec["byline"] || [], todo),
        items: items,
        checks: for(c <- spec["checks"] || [], do: check(scope, c)),
        box: panel_box(scope, spec["box"]),
        answers: panel_answers(kind, key, todo),
        actions: panel_actions(scope, spec["actions"] || []),
        links: panel_links(scope, spec["links"] || [])
      )

    {block, listed}
  end

  # The latest fact (by key, its numbers compared as numbers) of the relation `r` names
  # that points at the fact, of those whose values `where` gives: `{kind, fact}` or nil.
  defp latest_record(m, related, r) do
    where = r["where"] || %{}

    related
    |> Enum.filter(fn {{relation, _from, _r}, _} -> relation == r["relation"] end)
    |> Enum.flat_map(fn {{_relation, from, _r}, answer} ->
      for fact <- answer["facts"] || [],
          Enum.all?(where, fn {field, value} ->
            to_text(fact["values"][field]) in Enum.map(List.wrap(value), &to_text/1)
          end),
          do: {from, fact}
    end)
    |> Enum.max_by(fn {_from, fact} -> natural(fact["key"]) end, fn -> nil end)
    |> case do
      nil -> nil
      {from, fact} -> {kind(m, from) || unknown_kind(from), fact}
    end
  end

  defp natural(key),
    do:
      for(
        part <- Regex.split(~r/(\d+)/, key || "", include_captures: true, trim: true),
        do: if(part =~ ~r/^\d+$/, do: {0, String.to_integer(part)}, else: {1, part})
      )

  # The items under the fact through `relation` (in `order`, those without one last), each
  # with its details; how many there are, in the model's words (`count: [one, many]`).
  defp panel_items(_m, nil, _related), do: {nil, nil, []}

  defp panel_items(m, spec, related) do
    found =
      for {{relation, from, r}, answer} <- related, relation == spec["relation"] do
        {list_id(relation, from, r), from, answer["facts"] || []}
      end

    facts =
      for({_id, from, facts} <- found, fact <- facts, do: {from, fact})
      |> Enum.sort_by(fn {_from, fact} ->
        case Integer.parse(to_text(fact["values"][spec["order"]])) do
          {n, ""} -> {0, n, natural(fact["key"])}
          _ -> {1, 0, natural(fact["key"])}
        end
      end)

    items =
      facts
      |> Enum.with_index()
      |> Enum.map(fn {{from, fact}, i} ->
        item_k = kind(m, from) || unknown_kind(from)
        before = for {_from, f} <- Enum.take(facts, i), do: f["key"]

        Blocks.panel_item(
          key: fact["key"],
          label: label(item_k, fact),
          to: path({:item, from, fact["key"]}),
          details: for(d <- spec["details"] || [], do: item_detail(d, fact, before))
        )
      end)

    aside =
      case spec["count"] do
        [one, many] -> "#{length(items)} #{if length(items) == 1, do: one, else: many}"
        _ -> nil
      end

    {items, aside, for({id, _from, _facts} <- found, do: id)}
  end

  # One detail of an item: the part of a field before or after a marker (all of it
  # without either), or (`earlier`) the items before it, which it builds on.
  defp item_detail(%{"earlier" => true} = d, _fact, before),
    do: Blocks.pair(label: d["label"], value: dash(Enum.join(before, ", ")))

  defp item_detail(d, fact, _before) do
    text = to_text(fact["values"][d["field"]])

    value =
      case {d["before"], d["after"]} do
        {marker, _} when is_binary(marker) -> text |> String.split(marker, parts: 2) |> hd()
        {_, marker} when is_binary(marker) -> Enum.at(String.split(text, marker, parts: 2), 1)
        _ -> text
      end

    Blocks.pair(label: d["label"], value: dash(String.trim(value || "")))
  end

  defp dash(""), do: "—"
  defp dash(text), do: text

  # Each part of the byline that has its values; an `age` part says since when the work
  # has been its owner's.
  defp byline(scope, parts, todo) do
    for part <- parts, clause = byline_part(scope, part, todo), clause != nil, do: clause
  end

  defp byline_part(_scope, %{"age" => text}, todo) do
    if since = todo.why.since, do: Blocks.clause(text: text, since: since)
  end

  defp byline_part(scope, text, _todo) when is_binary(text) do
    if shown = template(scope, text), do: Blocks.clause(text: shown)
  end

  defp check(scope, c) do
    state = c["state"] || %{}
    value = to_text(raw(scope, state["field"]))

    found =
      Enum.find(~w(success error pending), fn s ->
        value != "" and value in Enum.map(List.wrap(state[s]), &to_text/1)
      end)

    Blocks.check(
      label: c["label"],
      state: found || "none",
      text: template(scope, c["text"] || "") || "—"
    )
  end

  defp panel_box(_scope, nil), do: nil

  defp panel_box(scope, box) do
    text = String.trim(to_text(raw(scope, box["field"])))
    text = if text in Enum.map(box["empty"] || [], &to_text/1), do: "", else: text
    Blocks.box(title: box["title"], text: dash(text), tone: box["tone"])
  end

  # The answers, as the page's actions of the same keys (`answer_actions/3`) give them.
  defp panel_answers(kind, key, todo) do
    answers =
      Enum.filter(todo.answers, &(&1.change or is_binary(&1.set) or is_binary(&1.remove)))

    weights = with_main(Enum.map(answers, &(&1[:weight] || "other")), true)

    for {a, weight} <- Enum.zip(answers, weights) do
      name = Map.get(a, :name) || a.key

      to =
        cond do
          a.change -> path({:answer, kind, key, name})
          is_binary(a.set) -> path({:set, kind, key, a.set})
          true -> path({:remove, kind, key, a.remove})
        end

      Blocks.panel_answer(
        label: a.label,
        key: a.key,
        to: to,
        submit_to:
          if((a.change and a[:name]) && !a.note, do: call_to({:answer, kind, key, name})),
        note: if(a.note, do: true),
        weight: weight,
        button: button(a.label),
        help: Map.get(a, :help) || a.label
      )
    end
  end

  defp panel_actions(scope, actions) do
    for a <- actions, {record_k, fact} <- [scope.records[a["record"]]] do
      Blocks.action(
        label: a["label"],
        key: a["key"],
        to: path({:item, record_k.name, fact["key"]}),
        button: button(a["label"]),
        help: a["help"] || "Open #{String.downcase(record_k.label)} #{fact["key"]}"
      )
    end
  end

  defp panel_links(scope, links) do
    for l <- links,
        url = to_text(raw(scope, l["field"])),
        String.match?(url, ~r{^https?://\S+$}i),
        do: Blocks.link(label: l["label"], key: l["key"], url: url)
  end

  # A template with each `{name}` filled in; nil when a value is not there.
  defp template(scope, text) do
    filled =
      Regex.scan(~r/\{([^{}|]+)(?:\|(\w+))?\}/, text)
      |> Enum.map(fn [whole | ref] -> {whole, filter(shown(scope, hd(ref)), Enum.at(ref, 1))} end)

    if Enum.all?(filled, fn {_, value} -> value not in [nil, ""] end),
      do: Enum.reduce(filled, text, fn {whole, value}, t -> String.replace(t, whole, value) end)
  end

  defp filter(nil, _), do: nil
  defp filter(value, nil), do: value

  defp filter(value, "number") do
    case Regex.run(~r/(\d+)\D*$/, value) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp filter(value, "line") do
    value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))
  end

  defp filter(value, _), do: value

  # A name as the page shows it: the fact's key, field or links, a record's key or field.
  defp shown(scope, "key"), do: scope.key

  defp shown(scope, name) do
    case String.split(name, ".", parts: 2) do
      [record, field] ->
        case scope.records[record] do
          {record_k, fact} -> field_text(record_k, fact, field)
          nil -> nil
        end

      [name] ->
        case scope.records do
          %{^name => {_k, fact}} -> fact["key"]
          %{^name => nil} -> nil
          _ -> field_text(scope.k, scope.fact, name) || links_text(scope.fact, name)
        end
    end
  end

  defp field_text(k, fact, name) do
    value = fact["values"][name]

    case Enum.find(k.fields, &(&1.name == name)) do
      _ when value in [nil, ""] -> nil
      nil -> to_text(value)
      f -> show(f, value)
    end
  end

  defp links_text(fact, relation) do
    case get_in(fact, ["links", relation]) do
      [_ | _] = keys -> Enum.join(keys, ", ")
      _ -> nil
    end
  end

  # The stored value a name refers to, as stored (a check compares it).
  defp raw(_scope, nil), do: nil

  defp raw(scope, name) do
    case String.split(name, ".", parts: 2) do
      [record, field] ->
        case scope.records[record] do
          {_k, fact} -> fact["values"][field]
          nil -> nil
        end

      [field] ->
        scope.fact["values"][field]
    end
  end

  # Why it came to its owner, and how to do it.
  defp todo_pairs(todo) do
    [
      Blocks.pair(
        label: todo.words.why,
        value: todo.why.text,
        origin: todo.why.since && Blocks.origin(since: todo.why.since, by: todo.why.by)
      )
    ] ++
      if(todo.instructions,
        do: [Blocks.pair(label: todo.words.instructions, value: todo.instructions)],
        else: []
      )
  end

  # The section of the fact the state names.
  defp section_pairs(%{section: %{heading: heading, text: text}}),
    do: [Blocks.pair(label: heading, value: text)]

  defp section_pairs(_todo), do: []

  @doc "The owner's answer `name` (one that writes a change), from fresh item reads; or nil."
  def declared_answer(m, kind, "_restart-" <> run, answers, form) do
    case restart_offer(m, kind, answers, form) do
      %{run: ^run} = offer -> Map.put(offer, :note, false)
      _ -> nil
    end
  end

  def declared_answer(m, kind, name, [%{"fact" => fact} | rest], form) when is_map(fact) do
    case m.module.todo(kind, fact, parts_by_kind(item_parts(m, kind, rest)), viewer(form)) do
      %{answers: answers} ->
        Enum.find(answers, &((Map.get(&1, :name) || &1.key) == name and &1.change))

      _ ->
        nil
    end
  end

  def declared_answer(_, _, _, _, _), do: nil

  @doc """
  A delegation (D-0106: an owner's answer that writes a change and hands the work over
  too, Delegate), as its form offers it, from fresh answer-page reads (`reads/2`):
  `%{answer, proposer, delegates, handing}`. `proposer` is its change's choice, `{relation}`
  in it the keys the fact links through it (left out with its brackets when none);
  `delegates` the facts its decider may delegate it to (the kind's `delegate_kinds`), the
  viewer not among them; `handing` the page's own hand-over the other one is given
  through, `{kind, key, relation}` of the component it changes, nil when the viewer may not.
  """
  def delegation(m, kind, answer, [%{"fact" => fact} | rest] = answers, form) do
    n = length(delegate_kinds(m, kind))

    delegates =
      for %{"facts" => facts} <- Enum.take(answers, -n),
          n > 0,
          p <- facts,
          p["key"] != form[:by],
          do: p

    handing =
      Enum.find_value(item_parts(m, kind, rest), fn {part_kind, _k, part, _made} ->
        Enum.find_value(associations(m, part_kind), fn r ->
          if r.change != nil and may_link?(m, r.name, form[:by], form[:by_kind]),
            do: {part_kind, part["key"], r.name}
        end)
      end)

    %{
      answer: answer,
      proposer: fill_links(answer.choices.change.label, fact),
      delegates: delegates,
      handing: handing
    }
  end

  @doc """
  What a delegation's form sends (`raw`: its `to`, and `whom`), as `delegation/5`
  offered it: `{:answer, name}` to the proposer (the answer's own change), `{:link, kind,
  key, relation, whom}` to someone else (the page's own hand-over to them), or
  `{:error, why}` without a choice the form offered.
  """
  def delegate_submit(d, raw) do
    case {raw["to"], d.handing} do
      {"proposer", _} ->
        {:answer, d.answer.key}

      {"other", {kind, key, relation}} ->
        if raw["whom"] in Enum.map(d.delegates, & &1["key"]),
          do: {:link, kind, key, relation, raw["whom"]},
          else: {:error, "Choose whom to delegate it to."}

      _ ->
        {:error, "Choose to whom you delegate it."}
    end
  end

  # The kinds a fact of `kind` may be delegated to (a Delegate's other one).
  defp delegate_kinds(m, kind), do: Map.get(kind(m, kind) || %{}, :delegate_kinds, [])

  # A text with each `{relation}` the keys the fact links through it; one it links none
  # through is left out, with the brackets around it.
  defp fill_links(text, fact) do
    Regex.replace(~r/( ?\()?\{(\w+)\}(\))?/, text, fn _whole, open, relation, close ->
      case get_in(fact, ["links", relation]) || [] do
        [] -> ""
        keys -> open <> Enum.join(keys, ", ") <> close
      end
    end)
  end

  def restart_offer(m, kind, answers, form) do
    case answer_item(m, kind, answers) do
      %{"fact" => fact, "parts" => parts} ->
        m.module.restart(kind, fact, parts, viewer(form), restart_actors(m))

      _ ->
        nil
    end
  end

  defp restart_actors(m) do
    Map.get_lazy(m, :actors, fn -> configured_restart_actors(m) end)
  end

  @doc """
  The key of the configured decider: as the model's owners name it, else as the
  environment's settings give it (`"actors": {"decider": …}`); nil when neither does.
  """
  def decider(m) do
    case get_in(restart_actors(m), ["decider", "key"]) do
      key when is_binary(key) -> key
      _ -> configured_decider()
    end
  end

  defp configured_decider do
    case AtlasBus.Actors.configured() do
      %{"decider" => key} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp configured_restart_actors(m) do
    configured = AtlasBus.Actors.configured() || %{}

    for {role, kind} <- m.module.actors(),
        key = configured[to_string(role)] || configured[role],
        is_binary(key),
        into: %{},
        do: {to_string(role), %{"kind" => kind, "key" => key}}
  end

  defp restart_actions(m, kind, fact, parts, form) do
    case m.module.restart(kind, fact, parts_by_kind(parts), viewer(form), restart_actors(m)) do
      nil ->
        []

      offer ->
        [
          Blocks.action(
            label: offer.label,
            key: offer.key,
            to: path({:answer, kind, fact["key"], "_restart-" <> offer.run}),
            button: button(offer.label),
            help: Map.get(offer, :help) || offer.label
          )
        ]
    end
  end

  @doc "The item an answer is given on, as the model's `answer/4` takes it: the fact and its parts."
  def answer_item(m, kind, [%{"fact" => fact} | rest]) when is_map(fact),
    do: %{"fact" => fact, "parts" => parts_by_kind(item_parts(m, kind, rest))}

  def answer_item(_m, _kind, _answers), do: %{}

  # Each answer that writes a change, or sets or removes an association of the fact, as an
  # action to its page, with what it does by name (`icon`) and in full (`help`; an option's
  # its card words). One that only hands the work over (`hand_over`, D-0106) is the page's
  # own hand-over (`handing`: Hand to…), under the answer's label and key; none when the
  # page offers none. One that also changes (a delegation) opens its own form.
  defp answer_actions(_kind, _fact, nil, _handing), do: []

  defp answer_actions(kind, fact, todo, handing) do
    changes =
      for a <- todo.answers,
          a.change or Map.get(a, :hand_over) == true,
          action = answer_action(kind, fact, a, handing),
          action != nil,
          do: action

    changes =
      case {todo.answers, changes} do
        {[%{name: _, label: label} | _], [first | _]} ->
          # `0` is the recommended choice 1 again: the same page, call and note.
          changes ++
            [
              Map.merge(Map.delete(first, "button"), %{
                "label" => "Recommended: " <> label,
                "key" => "0"
              })
            ]

        _ ->
          changes
      end

    changes ++
      for a <- todo.answers,
          {op, relation} <- [{:set, a.set}, {:remove, a.remove}],
          is_binary(relation),
          do:
            Blocks.action(
              label: a.label,
              key: a.key,
              to: path({op, kind, fact["key"], relation}),
              button: button(a.label),
              help: Map.get(a, :help) || a.label
            )
  end

  defp answer_action(kind, fact, %{change: true} = a, _handing),
    do:
      Blocks.action(
        label: a.label,
        key: a.key,
        to: path({:answer, kind, fact["key"], Map.get(a, :name) || a.key}),
        button: button(a.label),
        icon: Map.get(a, :icon),
        help: Map.get(a, :help) || if(!a[:name], do: a.label),
        # One that needs a note (a decline) opens its form to ask for it first.
        submit_to: if(a[:name] && !a.note, do: call_to({:answer, kind, fact["key"], a.name}))
      )

  defp answer_action(_kind, _fact, a, handing) do
    case Enum.find(handing, &(&1["key"] == a.key)) || List.first(handing) do
      nil ->
        nil

      action ->
        Map.merge(action, %{
          "label" => a.label,
          "key" => a.key,
          "button" => button(a.label),
          "icon" => Map.get(a, :icon) || action["icon"],
          "help" => Map.get(a, :help) || action["help"]
        })
        |> Map.reject(fn {_, v} -> v == nil end)
    end
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
        for key <- Enum.sort_by(keys, &key_order/1), to = kind_of.(key), to != nil do
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

  # What hangs under a fact, counted: "3 tasks and 1 attempt" ("children/3"'s labels).
  defp counted(held),
    do:
      Enum.map_join(held, " and ", fn {label, keys} ->
        count(keys) <> " " <> String.downcase(label)
      end)

  defp confirm_problem(:pick_up, m, route, answers, form),
    do: pick_up_problem(m, route, answers, form)

  defp confirm_problem(:retry, m, route, answers, form),
    do: retry_problem(m, route, answers, form)

  defp confirm_problem(:remove_item, m, route, answers, form),
    do: remove_problem(m, route, answers, form)

  # What a supervision confirm says it does, after the fact's key and label.
  defp confirming(:pick_up, _m, _kind, _answer, form),
    do: if(form[:assists], do: ", on behalf of #{form[:assists]}", else: "")

  defp confirming(:retry, _m, _kind, _answer, _form),
    do:
      ". Its flow goes back to the start of its supervised part, where its agent work is " <>
        "offered again, fresh; the work it runs now is stopped."

  defp confirming(:remove_item, m, kind, answer, _form) do
    {work, _held} = held(m, kind, answer)
    with_work = if work == [], do: "", else: ", with its #{counted(work)} and what is under them"
    " will be deleted#{with_work}. Its flow ends. This cannot be undone."
  end

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
          %{"facts" => facts} -> Enum.sort_by(facts, &key_order(&1["key"]))
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

  @doc """
  What a create of `kind` links to who puts the fact in (`form.producer`, IS-Atlas-70),
  taken from who the client is (`viewer`: `%{by, by_kind, assists}`), never from the
  form: `{:ok, links, on_behalf}`, where `on_behalf` is nil, or `{agent, whom}` when an
  agent puts it in for whom it assists (its cause says so). The client itself when it is
  a fact of the kind the relation leads to (the user at the TUI); whom it assists when it
  is an agent. A client that is neither puts no such fact in (UC-Atlas-23: every one
  records its producer), and neither does a form that names an association nobody sets
  by hand (`set_by`), as the producer: both are refused, `{:refuse, reasons}`. A kind
  whose create names no producer links nobody (`%{}`). A kind whose create names a
  proposer (`form.proposer`, D-0106) links the client itself through it, when it is a
  fact of the kind that relation leads to and assists nobody; an agent's
  proposal links nobody there, and is not refused for it.
  """
  def put_in_by(m, kind, raw, viewer) do
    k = kind(m, kind)
    form = m.module.form(kind, :create) || %{}
    producer = form[:producer]
    proposer = form[:proposer]

    named =
      for %{name: name, set_by: set_by} <- (k && k.relations) || [],
          set_by != nil,
          Map.has_key?(raw, name),
          do:
            if(name in [producer, proposer],
              do: "#{name} is not set in a form: it is who puts it in, taken from who you are",
              else: "#{name} is set by a #{Enum.join(set_by, " or ")}, never in a form"
            )

    rel = producer && m.relations[producer]
    proposed = proposed_links(proposer && m.relations[proposer], proposer, viewer)

    cond do
      named != [] ->
        {:refuse, named}

      rel == nil ->
        {:ok, proposed, nil}

      is_binary(viewer[:assists]) and viewer[:assists] != "" ->
        {:ok, Map.put(proposed, producer, [viewer.assists]), {viewer.by, viewer.assists}}

      is_binary(viewer[:by_kind]) and viewer.by_kind in rel.to ->
        {:ok, Map.put(proposed, producer, [viewer.by]), nil}

      true ->
        to = Enum.join(rel.to, " or ")

        {:refuse,
         [
           "#{viewer[:by] || "You"} is no #{to} and assists nobody, so a new #{String.downcase((k && k.label) || kind)} would record no producer (#{producer}): create it as a #{to}, or as an agent that assists one"
         ]}
    end
  end

  defp proposed_links(nil, _proposer, _viewer), do: %{}

  defp proposed_links(rel, proposer, viewer) do
    if viewer[:assists] in [nil, ""] and is_binary(viewer[:by_kind]) and viewer.by_kind in rel.to,
      do: %{proposer => [viewer.by]},
      else: %{}
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

  @doc """
  A moment in plain words, in this machine's local time: "3 Nov 17:14"; anything that is
  no ISO 8601 time as it is.
  """
  def short_moment(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, at, _} ->
        {{y, mo, d}, {h, mi, _}} =
          at
          |> DateTime.to_naive()
          |> NaiveDateTime.to_erl()
          |> :calendar.universal_time_to_local_time()

        Calendar.strftime(NaiveDateTime.from_erl!({{y, mo, d}, {h, mi, 0}}), "%-d %b %H:%M")

      _ ->
        to_text(iso)
    end
  end

  # A fact's label and what it is about: the first line of its first text of several
  # lines that says something, without the marks of a heading.
  defp about(k, fact) do
    line =
      Enum.find_value(k.fields, fn f ->
        f.multiline &&
          fact["values"][f.name]
          |> to_text()
          |> String.split("\n")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("#") |> String.trim()))
          |> Enum.find(&(&1 != ""))
      end)

    if line, do: "#{label(k, fact)} — #{line}", else: label(k, fact)
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
