defmodule RelaDSL.Schema.Composition do
  @moduledoc """
  A composition: the subflows that run together, and how their results reach one
  another. A subflow says only what it waits for (`await :field, …`); the
  composition says what writes that field, because only here are the subflow on the
  child subject and the one on its parent both visible.

      defmodule MyFlows.Post do
        use RelaDSL.Schema.Composition

        defcomposition :post do
          subflows [MyFlows.Letter, MyFlows.Receipt]

          link :receipt, to: {:letter, :receipt_of}, field: :receipt,
            states: [signed: :signed, lost: :lost], stale: :drop, current: {:round, :round}

          count :receipt, to: {:letter, :receipt_of}, all: :receipts, open: :open_receipts

          tally to: {:letter, :answers}, all: :answered
        end
      end

    * `link child, to: {parent_subject, relation}, field:, states:, stale:, current:`:
      when a run of the subflow `child` reaches one of `states` (child state: value),
      the value is written to `field` on the parent the child relates to by
      `relation`. Only the current child writes: `current: {child_field,
      parent_field}` makes a child current when its `child_field` equals the parent's
      `parent_field` (a revision or fingerprint, never a time); without it every
      related child is. More than one current child is ambiguous and writes nothing.
      `stale: :drop` drops a value from a child that is no longer the current one; a
      runner refuses it without `current:`, since nothing then says which one is.
    * `count child, to: {parent_subject, relation}, all:, open:`: the parent's
      fields `all` (how many children relate to it) and `open` (how many of them
      have no run of `child` in a final state yet).
    * `tally to: {parent_subject, relation}, all:`: the parent's field `all`, how many
      facts relate to it by `relation`, of every kind the relation starts at, whether
      a subflow runs on them or not (work that points at the parent, say). It is given
      only to the runs of the subflows on the parent that read the field (its
      `readers`), never to another subflow on the same kind.

  `__composition__/0` holds the links, counts and tallies as written; `RelaDSL.Atlas.composition/2`
  gives them as versioned data (`"version" => 1`), as a runner and `flows.json` take them.

  `use` gives the module `__composition__/0` (the composition as plain data) and
  `__flows__/0` (every subflow of the listed modules, in the order listed), so the
  writers and `mix model.gen` can take the composition as their contract.

  ## Checks

  When the module compiles, the composition is checked against its subflows. A
  mistake fails the compile with this file and the line of the `link`, `count` or
  `subflows` at fault (a subflow's own file and line are named in the message):

    * every field a state awaits is written to that subject by exactly one link,
      count or tally; every value a link writes, and every field a count or tally
      writes, is read by a branch of a subflow on the parent subject;
    * a link's or count's subflow exists, a link's states exist in it, and some
      subflow runs on the parent subject;
    * an effect that `records: {type, relation}` names a type some subflow starts
      on (`start :create`);
    * one field on one subject type has one writer: the passes (`pass_result`), the
      gates (`gate_result`), one effect action, or one link, count or tally; the fields an
      effect writes `also` and the values people choose are not counted;
    * no two subflows with `per_subject: :one` start on one subject type by the same
      trigger;
    * every listed module defines subflows, and no subflow name is used twice.

  Not checked here: that `relation` leads from the child to the parent in the
  description; that is Rela's knowledge, not the composition's.
  """

  @macros [defcomposition: 2, subflows: 1, link: 2, count: 2, tally: 1]

  @doc "Makes the module a composition."
  defmacro __using__(_opts) do
    quote do
      import RelaDSL.Schema.Composition, only: unquote(@macros)
      Module.register_attribute(__MODULE__, :afg_composition, [])
      Module.put_attribute(__MODULE__, :afg_in_composition, false)
      @before_compile RelaDSL.Schema.Composition
    end
  end

  @doc "The composition `name` and a block of `subflows`, `link`, `count` and `tally`."
  defmacro defcomposition(name, do: block) do
    quote do
      RelaDSL.Schema.Composition.__open__(
        __MODULE__,
        unquote(name),
        __ENV__.file,
        __ENV__.line
      )

      unquote(block)
      Module.put_attribute(__MODULE__, :afg_in_composition, false)
    end
  end

  @doc "The modules whose subflows run together, in the order their subflows are written."
  defmacro subflows(modules), do: entry(:subflows, modules)

  @doc "A child subflow's states written to a field of its parent: `to:`, `field:`, `states:`, `stale:`."
  defmacro link(child, opts), do: entry(:link, {child, opts})

  @doc "A parent's counts of its children: `to:`, `all:`, `open:`."
  defmacro count(child, opts), do: entry(:count, {child, opts})

  @doc "A parent's count of every fact that relates to it: `to:`, `all:`."
  defmacro tally(opts), do: entry(:tally, opts)

  defp entry(kind, value) do
    quote do
      RelaDSL.Schema.Composition.__add__(
        __MODULE__,
        unquote(kind),
        unquote(value),
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  @doc false
  def __open__(mod, name, file, line) do
    if Module.get_attribute(mod, :afg_composition) do
      raise CompileError, file: file, line: line, description: "one composition per module"
    end

    Module.put_attribute(mod, :afg_composition, %{
      name: name,
      line: line,
      subflows: nil,
      links: [],
      counts: [],
      tallies: []
    })

    Module.put_attribute(mod, :afg_in_composition, true)
  end

  @doc false
  def __add__(mod, kind, value, file, line) do
    unless Module.get_attribute(mod, :afg_in_composition) do
      raise CompileError,
        file: file,
        line: line,
        description: "#{kind} belongs inside defcomposition"
    end

    c = Module.get_attribute(mod, :afg_composition)
    Module.put_attribute(mod, :afg_composition, add(c, kind, value, line, file))
  end

  defp add(%{subflows: nil} = c, :subflows, modules, line, _file),
    do: %{c | subflows: {List.wrap(modules), line}}

  defp add(_c, :subflows, _modules, line, file),
    do:
      raise(CompileError, file: file, line: line, description: "subflows is given more than once")

  defp add(c, :link, {child, opts}, line, _file) do
    {subject, relation} = to(opts)

    link = %{
      child: child,
      subject: subject,
      relation: relation,
      field: opts[:field],
      states: Keyword.get(opts, :states, []),
      stale: opts[:stale],
      current: opts[:current],
      unknown: Keyword.keys(opts) -- [:to, :field, :states, :stale, :current],
      line: line
    }

    %{c | links: c.links ++ [link]}
  end

  defp add(c, :count, {child, opts}, line, _file) do
    {subject, relation} = to(opts)

    count = %{
      child: child,
      subject: subject,
      relation: relation,
      all: opts[:all],
      open: opts[:open],
      unknown: Keyword.keys(opts) -- [:to, :all, :open],
      line: line
    }

    %{c | counts: c.counts ++ [count]}
  end

  defp add(c, :tally, opts, line, _file) do
    {subject, relation} = to(opts)

    tally = %{
      subject: subject,
      relation: relation,
      all: opts[:all],
      unknown: Keyword.keys(opts) -- [:to, :all],
      line: line
    }

    %{c | tallies: c.tallies ++ [tally]}
  end

  defp to(opts) do
    case opts[:to] do
      {subject, relation} -> {subject, relation}
      _ -> {nil, nil}
    end
  end

  # -- Building and checking, before the module is compiled ----------------------

  @doc false
  defmacro __before_compile__(env) do
    file = env.file

    c =
      Module.get_attribute(env.module, :afg_composition) ||
        raise CompileError, file: file, line: 1, description: "no defcomposition in this module"

    {modules, subflows_line} = c.subflows || {[], c.line}
    {flows, module_problems} = load(modules, subflows_line)
    refuse!(module_problems, file)

    problems = check(c, flows, subflows_line)
    refuse!(problems, file)

    # Each tally names its readers: the runs it is given to. What the composition is built
    # from later (its data, `RelaDSL.Atlas.composition/2`) reads them from here.
    c = %{c | tallies: Enum.map(c.tallies, &Map.put(&1, :readers, tally_readers(&1, flows)))}
    Module.put_attribute(env.module, :afg_composition, c)

    composition = %{
      name: c.name,
      file: file,
      subflows: modules,
      links: Enum.map(c.links, &Map.drop(&1, [:line, :unknown])),
      counts: Enum.map(c.counts, &Map.drop(&1, [:line, :unknown])),
      tallies: Enum.map(c.tallies, &Map.drop(&1, [:unknown]))
    }

    quote do
      @doc "The composition, as plain data."
      def __composition__, do: unquote(Macro.escape(composition))

      @doc "Every subflow of the composition, in the order its modules are listed."
      def __flows__, do: unquote(Macro.escape(flows))
    end
  end

  defp load(modules, line) do
    Enum.reduce(modules, {[], []}, fn m, {flows, problems} ->
      case Code.ensure_compiled(m) do
        {:module, ^m} ->
          if function_exported?(m, :__flows__, 0) and m.__flows__() != [],
            do: {flows ++ m.__flows__(), problems},
            else: {flows, problems ++ [{line, {:no_subflows, m}}]}

        {:error, reason} ->
          {flows, problems ++ [{line, {:not_compiled, m, reason}}]}
      end
    end)
  end

  # A mistake is refused at the line of the first one; the others follow in the message.
  defp refuse!([], _file), do: :ok

  defp refuse!(problems, file) do
    [{line, problem} | rest] = Enum.sort_by(problems, &elem(&1, 0))
    also = Enum.map_join(rest, "", fn {l, p} -> "\n  line #{l}: #{message(p)}" end)
    raise CompileError, file: file, line: line, description: message(problem) <> also
  end

  @doc """
  The problems of `composition` (its `links`, `counts` and `tallies`, as written or as
  `__composition__/0` holds them) against `flows`: `[{line, problem}]`, each `problem` a
  tagged tuple that names its kind and what it is about, such as `{:unread, {:tally,
  relation}, field, subject}` or `{:many_writers, subject, field, writers}`. `message/1`
  says it in words, for display; nothing else should read the words.
  """
  def problems(composition, flows, line \\ 1) do
    c =
      Map.merge(
        %{links: [], counts: [], tallies: []},
        Map.take(composition, [:links, :counts, :tallies])
      )

    c =
      Map.new(c, fn {k, xs} -> {k, Enum.map(xs, &Map.merge(%{line: line, unknown: []}, &1))} end)

    check(c, flows, line)
  end

  defp check(c, flows, line) do
    by_name = Map.new(flows, &{&1.name, &1})

    problems =
      twice(flows, line) ++
        Enum.flat_map(c.links, &link_problems(&1, by_name, flows)) ++
        Enum.flat_map(c.counts, &count_problems(&1, by_name, flows)) ++
        Enum.flat_map(c.tallies, &tally_problems(&1, flows)) ++
        awaits(c, flows, line) ++
        records(flows, line) ++
        writers(c, flows, line) ++
        starts(flows, line)

    for {l, p} <- problems, p, do: {l, p}
  end

  defp twice(flows, line) do
    names = Enum.map(flows, & &1.name)
    for n <- Enum.uniq(names -- Enum.uniq(names)), do: {line, {:defined_twice, n}}
  end

  defp link_problems(l, by_name, flows) do
    who = {:link, l.child}
    child = by_name[l.child]
    parents = on_subject(flows, l.subject)

    [
      {l.line, l.subject == nil && {:missing_option, who, :to}},
      {l.line, l.field == nil && {:missing_option, who, :field}},
      {l.line, l.states == [] && {:missing_option, who, :states}},
      {l.line, child == nil && {:no_such_subflow, who}},
      {l.line, (l.subject != nil and parents == []) && {:no_parent_subflow, who, l.subject}},
      {l.line, l.unknown != [] && {:unknown_options, who, l.unknown}},
      {l.line, l.stale not in [nil, :drop] && {:bad_option, who, :stale}},
      {l.line, not current?(l.current) && {:bad_option, who, :current}}
    ] ++
      for {state, _value} <- l.states,
          child != nil,
          state not in Enum.map(child.states, & &1.name),
          do: {l.line, {:no_such_state, who, state}}
  end

  defp count_problems(n, by_name, flows) do
    who = {:count, n.child}
    parents = on_subject(flows, n.subject)

    [
      {n.line, n.subject == nil && {:missing_option, who, :to}},
      {n.line, (n.all == nil or n.open == nil) && {:missing_option, who, :fields}},
      {n.line, by_name[n.child] == nil && {:no_such_subflow, who}},
      {n.line, (n.subject != nil and parents == []) && {:no_parent_subflow, who, n.subject}},
      {n.line, n.unknown != [] && {:unknown_options, who, n.unknown}}
    ] ++
      for field <- [n.all, n.open],
          field != nil,
          parents != [],
          not read?(parents, ~r/\bentity\.#{field}\b/),
          do: {n.line, {:unread, who, field, n.subject}}
  end

  defp tally_problems(t, flows) do
    who = {:tally, t.relation}
    parents = on_subject(flows, t.subject)

    [
      {t.line, t.subject == nil && {:missing_option, who, :to}},
      {t.line, t.all == nil && {:missing_option, who, :all}},
      {t.line, (t.subject != nil and parents == []) && {:no_parent_subflow, who, t.subject}},
      {t.line, t.unknown != [] && {:unknown_options, who, t.unknown}},
      {t.line,
       (t.all != nil and parents != [] and not read?(parents, ~r/\bentity\.#{t.all}\b/)) &&
         {:unread, who, t.all, t.subject}}
    ]
  end

  # The subflows on a tally's parent whose branches read its field, by name: the runs it is
  # given to.
  defp tally_readers(t, flows) do
    for f <- on_subject(flows, t.subject),
        t.all != nil and read?([f], ~r/\bentity\.#{t.all}\b/),
        do: f.name
  end

  defp current?(nil), do: true
  defp current?({child, parent}), do: is_atom(child) and is_atom(parent)
  defp current?(_), do: false

  # Values a link writes are read where its parent's subflows branch on them, by an
  # await or by a branch's own condition.
  defp awaits(c, flows, line) do
    unread =
      for l <- c.links,
          l.field != nil,
          parents = on_subject(flows, l.subject),
          parents != [],
          {_state, value} <- l.states,
          not read?(parents, equals(l.field, value)),
          do: {l.line, {:unread_value, {:link, l.child}, l.field, value, l.subject}}

    unwritten =
      for f <- flows, s <- f.states, field <- s.awaits do
        case writers_of(c, f.subject, field) do
          [] -> {line, {:unwritten_await, f.name, s.name, where(f, s), field, f.subject}}
          [_] -> nil
          [_, second | _] -> {second.line, {:awaited_twice, f.name, s.name, field, f.subject}}
        end
      end

    unread ++ Enum.uniq(unwritten)
  end

  defp writers_of(c, subject, field) do
    Enum.filter(c.links, &(&1.subject == subject and &1.field == field)) ++
      Enum.filter(c.counts, &(&1.subject == subject and field in [&1.all, &1.open])) ++
      Enum.filter(c.tallies, &(&1.subject == subject and &1.all == field))
  end

  defp records(flows, line) do
    for f <- flows,
        s <- f.states,
        {:effect, %{records: {type, _relation}} = spec} <- [s.mechanism],
        not Enum.any?(flows, fn g ->
          g.subject == type and Enum.any?(g.start, &(&1.on == :create))
        end),
        do: {line, {:records_unstarted, f.name, s.name, where(f, s), spec.action, type}}
  end

  # One writer per field and subject type: [{subject, field, writer, line}].
  defp writers(c, flows, line) do
    mechanisms =
      for f <- flows, s <- f.states, w <- mechanism_writes(s.mechanism) do
        {f.subject, elem(w, 0), elem(w, 1), line}
      end

    links = for l <- c.links, do: {l.subject, l.field, {:link, l.child}, l.line}

    counts =
      for n <- c.counts,
          field <- [n.all, n.open],
          do: {n.subject, field, {:count, n.child}, n.line}

    tallies = for t <- c.tallies, do: {t.subject, t.all, {:tally, t.relation}, t.line}

    (mechanisms ++ links ++ counts ++ tallies)
    |> Enum.reject(fn {subject, field, _, _} -> subject == nil or field == nil end)
    |> Enum.group_by(fn {subject, field, _, _} -> {subject, field} end)
    |> Enum.sort()
    |> Enum.flat_map(fn {{subject, field}, ws} ->
      case Enum.uniq_by(ws, &elem(&1, 2)) do
        [_] ->
          []

        [_ | _] = distinct ->
          at = distinct |> Enum.map(&elem(&1, 3)) |> Enum.max()
          [{at, {:many_writers, subject, field, Enum.map(distinct, &elem(&1, 2))}}]
      end
    end)
  end

  defp mechanism_writes({:pass, %{writes: :none}}), do: []
  defp mechanism_writes({:pass, _}), do: [{:pass_result, :pass}]
  defp mechanism_writes({:gate, _}), do: [{:gate_result, :gate}]
  defp mechanism_writes({:effect, spec}), do: [{spec.field, {:effect, spec.action}}]
  defp mechanism_writes(nil), do: []

  defp starts(flows, line) do
    flows
    |> Enum.filter(&(&1.per_subject == :one))
    |> Enum.flat_map(fn f -> for t <- f.start, do: {{f.subject, t}, f.name} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.flat_map(fn
      {_, [_]} -> []
      {{subject, t}, names} -> [{line, {:same_start, subject, t, Enum.uniq(names)}}]
    end)
  end

  @doc "A problem of `problems/2` in words, for display."
  def message({:no_subflows, m}), do: "#{inspect(m)} defines no subflows"
  def message({:not_compiled, m, reason}), do: "the subflow module #{inspect(m)} is #{reason}"
  def message({:defined_twice, n}), do: "subflow #{n} is defined more than once"
  def message({:missing_option, who, :to}), do: pre(who) <> "needs to: {parent subject, relation}"

  def message({:missing_option, who, :field}),
    do: pre(who) <> "needs field: the parent's field it writes"

  def message({:missing_option, who, :states}),
    do: pre(who) <> "needs states: [child state: value]"

  def message({:missing_option, who, :fields}), do: pre(who) <> "needs all: and open: fields"

  def message({:missing_option, who, :all}),
    do: pre(who) <> "needs all: the parent's field it writes"

  def message({:no_such_subflow, who}), do: pre(who) <> "names no subflow of this composition"
  def message({:no_parent_subflow, who, subject}), do: pre(who) <> "no subflow runs on #{subject}"
  def message({:unknown_options, who, keys}), do: pre(who) <> "knows no #{Enum.join(keys, ", ")}"
  def message({:bad_option, who, :stale}), do: pre(who) <> "stale: is :drop or left out"

  def message({:bad_option, who, :current}),
    do: pre(who) <> "current: is {child field, parent field}, two names"

  def message({:no_such_state, {_, child} = who, state}),
    do: pre(who) <> "subflow #{child} has no state #{state}"

  def message({:unread, who, field, subject}),
    do: pre(who) <> "writes #{field} to #{subject}, which no branch of a subflow on it reads"

  def message({:unread_value, {:link, child}, field, value, subject}),
    do:
      "link #{child}: writes #{field} #{value} to #{subject}, " <>
        "which no branch of a subflow on it awaits or reads"

  def message({:unwritten_await, flow, state, where, field, subject}),
    do:
      "subflow #{flow}, state #{state} (#{where}) awaits #{field}, " <>
        "which no link or count writes to #{subject}"

  def message({:awaited_twice, flow, state, field, subject}),
    do:
      "#{field} on #{subject} is written by more than one link or count; " <>
        "subflow #{flow}, state #{state} awaits it from exactly one"

  def message({:records_unstarted, flow, state, where, action, type}),
    do:
      "subflow #{flow}, state #{state} (#{where}): effect #{action} records " <>
        "a #{type}, but no subflow starts on #{type} when one is created (start :create)"

  def message({:many_writers, subject, field, writers}),
    do:
      "#{field} on #{subject} has more than one writer: " <>
        Enum.map_join(writers, ", ", &writer/1)

  def message({:same_start, subject, t, names}),
    do:
      "subflows #{Enum.join(names, ", ")} each start one run per #{subject} " <>
        "on #{t.on}#{if t.when, do: " when #{t.when}"}; only one of them may"

  defp pre({:link, child}), do: "link #{child}: "
  defp pre({:count, child}), do: "count #{child}: "
  defp pre({:tally, relation}), do: "tally #{relation}: "

  defp writer(:pass), do: "the passes"
  defp writer(:gate), do: "the gates"
  defp writer({:effect, action}), do: "effect #{action}"
  defp writer({:link, child}), do: "link #{child}"
  defp writer({:count, child}), do: "count #{child}"
  defp writer({:tally, relation}), do: "tally #{relation}"

  defp on_subject(_flows, nil), do: []
  defp on_subject(flows, subject), do: Enum.filter(flows, &(&1.subject == subject))

  defp read?(flows, pattern) do
    Enum.any?(flows, fn f ->
      Enum.any?(f.states, fn s ->
        Enum.any?(s.branches, &(&1.when && matches?(&1.when, pattern)))
      end)
    end)
  end

  defp matches?(text, %Regex{} = r), do: Regex.match?(r, text)
  defp matches?(text, piece), do: String.contains?(text, piece)

  # As RelaDSL.Schema writes an await's condition.
  defp equals(field, value) when is_boolean(value) or is_number(value),
    do: "entity.#{field} == #{value}"

  defp equals(field, value), do: "entity.#{field} == '#{value}'"

  defp where(f, s), do: "#{Path.relative_to_cwd(f.file)}:#{s.line}"
end
