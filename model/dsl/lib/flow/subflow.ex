defmodule RelaDSL.Flow.Subflow do
  @moduledoc """
  One subflow in one environment, compiled into a module a runner calls: what it runs
  on, its identity, where a run starts, what entering a state does, where a change or a
  result leads, its timers, mechanism, owner and what its owner sees.

  A composition (`RelaDSL.Composition`) compiles each subflow it runs, per environment.
  A module can also compile one subflow of a flow module by itself:

      defmodule MyFlows.Letter.Run do
        use RelaDSL.Flow.Subflow, from: MyFlows.Letter, subflow: :letter,
          environment: :prod, behaviour: SomeRunner.Subflow
      end

  `gates:` names a module whose gates the subflow's states name besides `from`'s own.
  `behaviour:` is declared on the module, so the compile checks its callbacks.

  The module is built from the subflow's data as `flows.json` holds it, with the
  environment's limits (`RelaDSL.Atlas.definitions/2`), and `digest/0` is the
  `RelaDSL.DefinitionDigest` of that data, so a run started under it keeps its identity.
  Nothing is read from a file. Its callbacks, with state names as text:

    * `name/0`, `subject/0`, `digest/0`, `initial/0`, `states/0` (sorted), `per_subject/0`;
    * `start?(:create | :predicate, values)`: whether that trigger starts a run;
    * `enter(state, values)`: what entering the state writes, in order:
      `{:set, %{field => value}}` and `{:create, %{"type", "properties", "relate"}}`;
    * `next(state, values, nil)`: the first branch no role takes whose condition holds
      on `values`; `next(state, values, :result)`: the first branch whose condition holds
      on a mechanism's result; `next(state, values, %{roles:, changed:})`: the first branch
      one of `roles` takes, on a field in `changed`, whose condition holds. `{:to, state}`
      or `:stay`;
    * `timers(state)`: `[%{"name", "period", "to", "since"}]`, in the order written;
    * `mechanism(state)`: nil or `{:pass | :gate | :effect, spec}`;
    * `waiting_for(state)`, `final?(state)`;
    * `owner()`: the subflow's owner; `owner(state)`: the state's own, else the subflow's;
    * `present(state, values)`: nil, or `%{"expected", "why", "todo", "deadline"}` with
      `expected` filled from `values`.
  """

  alias RelaDSL.{Atlas, DefinitionDigest, Limits}
  alias RelaDSL.Flow.Condition

  defmacro __using__(opts) do
    from = Macro.expand(opts[:from], __CALLER__)
    name = to_string(Keyword.fetch!(opts, :subflow))
    env = Keyword.get(opts, :environment, :prod)
    behaviour = opts[:behaviour] && Macro.expand(opts[:behaviour], __CALLER__)
    more = opts[:gates] && Macro.expand(opts[:gates], __CALLER__)
    file = __CALLER__.file

    Code.ensure_compiled!(from)
    gates = from.__gates__() ++ if(more, do: Code.ensure_compiled!(more).__gates__(), else: [])

    definition =
      definitions(from.__flows__(), gates, env)[name] ||
        raise CompileError,
          file: file,
          line: __CALLER__.line,
          description: "#{inspect(from)} defines no subflow #{name}"

    body(name, definition, behaviour, file)
  end

  @doc "Each subflow's data per `environment`, by name, as the module is built from it."
  def definitions(flows, gates, environment),
    do: Atlas.definitions(Limits.resolve(flows, gates, environment), gates)

  @doc "The module body for subflow `name` and its data (string keys)."
  def body(name, definition, behaviour, file) do
    values = Macro.var(:values, __MODULE__)
    states = definition["states"]
    names = Enum.sort(Map.keys(states))
    owner = definition["owner"] || %{}

    starts =
      for start <- definition["start"] || [], start["on"] == "predicate" do
        Condition.quoted(compile!(start["when"], name, "its start", file), values)
      end

    predicate =
      case starts do
        [] -> quote(do: def(start?(:predicate, _values), do: false))
        _ -> quote(do: def(start?(:predicate, unquote(values)), do: unquote(any(starts))))
      end

    each = fn f -> for state <- names, do: f.(state, states[state]) end

    clauses = [
      each.(fn state, s ->
        quote(do: def(final?(unquote(state)), do: unquote(s["final"] == true)))
      end),
      each.(fn state, s ->
        quote(do: def(mechanism(unquote(state)), do: unquote(Macro.escape(mechanism(s)))))
      end),
      each.(fn state, s ->
        quote(do: def(waiting_for(unquote(state)), do: unquote(s["waiting_for"] || [])))
      end),
      each.(fn state, s ->
        quote(do: def(timers(unquote(state)), do: unquote(Macro.escape(timers(s)))))
      end),
      each.(fn state, s ->
        quote(do: def(owner(unquote(state)), do: unquote(Macro.escape(s["owner"] || owner))))
      end),
      each.(fn state, s ->
        quote(do: def(enter(unquote(state), _values), do: unquote(Macro.escape(outputs(s)))))
      end),
      each.(fn state, s -> present(state, s["present"], values) end),
      each.(fn state, s -> next(state, s["branches"] || [], values, name, file, nil) end),
      each.(fn state, s -> next(state, s["branches"] || [], values, name, file, :result) end),
      each.(fn state, s -> next(state, s["branches"] || [], values, name, file, :input) end)
    ]

    [final?, mechanism, waiting_for, timers, owners, enter, present, plain, result, input] =
      clauses

    quote do
      unquote(if behaviour, do: quote(do: @behaviour(unquote(behaviour))))

      def name, do: unquote(name)
      def subject, do: unquote(definition["subject"])
      def digest, do: unquote(DefinitionDigest.of(definition))
      def initial, do: unquote(definition["initial"])
      def states, do: unquote(names)
      def per_subject, do: unquote(definition["per_subject"])
      def owner, do: unquote(Macro.escape(owner))

      def start?(:create, _values),
        do: unquote(Enum.any?(definition["start"] || [], &(&1["on"] == "create")))

      unquote(predicate)

      # Each callback by state; a state the subflow does not have (a run of another
      # definition) does nothing.
      unquote_splicing(final?)
      def final?(_state), do: false
      unquote_splicing(mechanism)
      def mechanism(_state), do: nil
      unquote_splicing(waiting_for)
      def waiting_for(_state), do: []
      unquote_splicing(timers)
      def timers(_state), do: []
      unquote_splicing(owners)
      def owner(_state), do: unquote(Macro.escape(owner))
      unquote_splicing(enter)
      def enter(_state, _values), do: []
      unquote_splicing(present)
      def present(_state, _values), do: nil
      unquote_splicing(plain)
      unquote_splicing(result)
      unquote_splicing(input)
      def next(_state, _values, _input), do: :stay
    end
  end

  defp mechanism(%{"kind" => kind, "spec" => spec}) when kind in ["pass", "gate", "effect"],
    do: {String.to_atom(kind), spec}

  defp mechanism(_), do: nil

  defp timers(s),
    do: for(t <- s["timers"] || [], do: Map.take(t, ["name", "period", "to", "since"]))

  defp outputs(s) do
    set = Map.new(s["set"] || [], &{&1["field"], &1["value"]})

    if(set == %{}, do: [], else: [{:set, set}]) ++
      for c <- s["creates"] || [], do: {:create, Map.take(c, ["type", "properties", "relate"])}
  end

  defp present(state, nil, _values), do: quote(do: def(present(unquote(state), _values), do: nil))

  defp present(state, p, values) do
    parts = parts(p["expected"] || "")
    fixed = p |> Map.take(["why", "todo", "deadline"]) |> Map.reject(fn {_, v} -> v == nil end)

    if Enum.any?(parts, &match?({:var, _}, &1)) do
      quote do
        def present(unquote(state), unquote(values)) do
          Map.put(
            unquote(Macro.escape(fixed)),
            "expected",
            RelaDSL.Flow.Code.fill(unquote(Macro.escape(parts)), unquote(values))
          )
        end
      end
    else
      filled = RelaDSL.Flow.Code.fill(parts, %{})

      quote(
        do:
          def(present(unquote(state), _values),
            do: unquote(Macro.escape(Map.put(fixed, "expected", filled)))
          )
      )
    end
  end

  @doc "A text as parts: text, and `{:var, name}` for each `{name}` in it."
  def parts(text) do
    ~r/\{([A-Za-z_][A-Za-z0-9_]*)\}/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(~r/\A\{([A-Za-z_][A-Za-z0-9_]*)\}\z/, part) do
        [_, name] -> {:var, name}
        _ -> part
      end
    end)
  end

  # One clause per state and kind of input: a change no role takes (nil), a mechanism's
  # result (:result), a role's input (:input).
  defp next(state, branches, values, name, file, kind) do
    compiled =
      for b <- branches do
        tree = compile!(b["when"], name, "state #{state}", file)

        %{
          to: b["to"],
          roles: b["roles"] || [],
          fields: Condition.fields(tree),
          match: Condition.quoted(tree, values)
        }
      end

    case kind do
      nil ->
        clause(state, values, nil, for(b <- compiled, b.roles == [], do: {b.match, b.to}))

      :result ->
        clause(state, values, :result, for(b <- compiled, do: {b.match, b.to}))

      :input ->
        roles =
          for b <- compiled, b.roles != [] do
            check =
              quote do
                Enum.any?(unquote(b.roles), &(&1 in input_roles)) and
                  Enum.any?(unquote(b.fields), &Map.has_key?(changed, &1)) and unquote(b.match)
              end

            {check, b.to}
          end

        if roles == [] do
          quote(do: def(next(unquote(state), _values, %{roles: _, changed: _}), do: :stay))
        else
          quote do
            def next(unquote(state), unquote(values), %{roles: input_roles, changed: changed}),
              do: unquote(first(roles))
          end
        end
    end
  end

  defp clause(state, _values, input, []),
    do: quote(do: def(next(unquote(state), _values, unquote(input)), do: :stay))

  defp clause(state, values, input, branches),
    do:
      quote(
        do:
          def(next(unquote(state), unquote(values), unquote(input)), do: unquote(first(branches)))
      )

  defp first(branches) do
    clauses =
      for({check, to} <- branches, do: {:->, [], [[check], {:to, to}]}) ++
        [{:->, [], [[true], :stay]}]

    {:cond, [], [[do: clauses]]}
  end

  defp any([one]), do: one
  defp any([one | rest]), do: quote(do: unquote(one) or unquote(any(rest)))

  defp compile!(text, name, where, file) do
    case Condition.compile(text) do
      {:ok, tree} ->
        tree

      {:error, _} ->
        raise CompileError,
          file: file,
          line: 1,
          description:
            "subflow #{name}, #{where}: #{inspect(text)} is no condition a runner evaluates " <>
              "(entity.<field> compared with a value, and, or, parentheses)"
    end
  end
end
