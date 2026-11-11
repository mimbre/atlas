defmodule AtlasFlowGenerator.Schema do
  @moduledoc """
  The flow format: how a subflow and its gates are written, and the checks that
  stop a broken definition from compiling.

  A **subflow** is one Rela flow on one subject type: it follows a subject through
  a series of **states**, from `initial` to a `final` state. A state is where a run
  of the subflow is: who or what acts there and where each outcome leads; it is not
  data of the subject. The words follow Rela. A **gate** is a checkpoint
  that gives a verdict, defined once as data and named by the subflows that use it.

      defmodule MyFlows.Gates do
        use AtlasFlowGenerator.Schema

        defgate :check, version: 1, flavor: :rule, verdicts: [:ok, :person]
      end

      defmodule MyFlows.Letter do
        use AtlasFlowGenerator.Schema, gates: MyFlows.Gates

        subflow :letter, label: "Letter", subject: :letter do
          run_as "system:post"
          start :create
          initial :write

          state :write, label: "Write it" do
            pass :writer, on: [delivered: :check, failed: :stuck]
            timer :slow, "1d", to: :stuck
          end

          state :check do
            gate :check, ok: :sent, person: :stuck
          end

          state :stuck, label: "Someone decides" do
            wait_for [:editor], on: :choice, retry: :write, drop: :sent
          end

          final :sent
        end
      end

  ## Mechanisms

  A state does its work through at most one **mechanism**: a `pass` (someone's
  Runtime does a piece of work), a `gate` (a verdict) or an `effect` (a call to an
  outside service). Each writes one result field on the subject. The macro expands
  into what Rela needs for that: the field is reset to `none` when the state is
  entered, and there is one change branch per result value, taken by the role
  `atlas-flow`. A definition maps every value the mechanism can give,
  no more and no fewer, so the two sides cannot drift apart.

  | mechanism | field | values |
  |---|---|---|
  | `pass` | `pass_result` | `delivered`, `failed` |
  | `gate` | `gate_result` | the gate's `verdicts` |
  | `effect` | `effect_result`, or `field:` | `done`, `refused` |

  A result may lead to `{state, label}` instead of a state: the branch then carries
  that label, as `failed: {:decide, "The pass failed; a person decides"}`.

  `wait_for` is the same for people: the state waits in their inbox, the field is
  reset, and each value they may choose is a branch only they can take. With
  `reset: false` the field is not reset; a subflow without `run_as` cannot set it.
  A state that waits for people and has no mechanism is `input_required`; one with
  a pass that people work in (`with_person: true`) stays working, as a state with a
  mechanism does. `await` waits for a field that something outside this subflow
  writes; a composition (`AtlasFlowGenerator.Schema.Composition`) says what writes it.

  Branches are tried in the order written; a mechanism's branches sit where the
  mechanism is written.

  ## Gates

  A gate is data for the shared Gates framework, which evaluates it, records each
  verdict with the gate's name and version, and writes the verdict on the subject.
  Its **evaluator** gives one of four outcomes, and `decide` maps every one of them
  to a verdict:

  | outcome | smart gate (advice) | rule gate (`rule`) |
  |---|---|---|
  | `pass` | the advice passes it | every condition holds |
  | `changes_required` | the advice asks for changes | a condition does not hold |
  | `uncertain` | the advice is not sure | a field a condition reads is missing or null |
  | `error` | the evaluation failed or timed out | the evaluation failed |

  Both flavors share the outcomes, so a gate can change flavor without changing
  `decide`. No verdict, `uncertain` or `error` means a person: both must decide the
  gate's `person` verdict. A missing field outweighs a condition that does not hold.

  A rule is `[all: conditions]`; each condition reads fields of the gate's
  `evidence` (the fixed input set, nothing else):

    * `{:equals, field, value}`: the field equals `value` (a string, number or boolean);
    * `{:same, field, other}`: the two fields are equal.

      defgate :match, version: 1, flavor: :rule, purpose: :flow,
        evidence: [:status, :sent, :seen],
        rule: [all: [{:equals, :status, "ok"}, {:same, :sent, :seen}]],
        verdicts: [:go, :stop, :person],
        decide: [pass: :go, changes_required: :stop, uncertain: :person, error: :person]

  A gate need not be named by a subflow: it is checked the same way, and other
  callers of Gates may name it.

  ## Data

  `use AtlasFlowGenerator.Schema` gives the module `__flows__/0` and `__gates__/0`,
  plain data in the order written. Writers read only that.

  ## Checks

  When the module compiles, every subflow and gate is checked. A mistake fails
  the compile with the file and line of the macro at fault:

    * every state is reachable from `initial` (through branches and timers);
    * every state that is not final has a way out; a final state has none,
      no mechanism and waits for no one;
    * a state that only people with a role can move waits for them (`wait_for`),
      has a mechanism, or awaits a field; each role it waits for has a branch;
    * a gate's verdicts are mapped exactly; its `decide` covers every evaluator
      outcome, and `uncertain` and `error` decide its person verdict;
    * a gate's `purpose` is `:flow` or `:decider`; a smart gate names its `advice`
      and has no `rule`; a rule gate has a `rule` (below) and no `advice`;
    * a pass or an effect maps exactly its result values;
    * at most one mechanism per state, and no field set twice in a state;
    * `initial` names a state that is not final; there is a start trigger;
      `run_as` is given when a state has outputs; names are Rela names; at most
      8 timers per state; branches and timers lead to states;
    * no branch that takes every change comes before another branch;
    * every gate a subflow names is defined.

  What Rela itself checks (properties, values, roles, grants) is left to Rela.
  """

  @writer "atlas-flow"
  @pass_results [:delivered, :failed]
  @effect_results [:done, :refused]
  @outcomes [:pass, :changes_required, :uncertain, :error]
  @purposes [:flow, :decider]
  @max_timers 8
  @name ~r/^[a-z][a-z0-9_-]{0,63}$/
  @once [:run_as, :per_subject, :owner, :channel, :initial]

  @macros [
    subflow: 2,
    subflow: 3,
    run_as: 1,
    per_subject: 1,
    owner: 1,
    channel: 1,
    start: 1,
    start: 2,
    initial: 1,
    state: 2,
    state: 3,
    final: 1,
    final: 2,
    final: 3,
    pass: 2,
    gate: 2,
    effect: 2,
    wait_for: 2,
    await: 2,
    branch: 1,
    set: 1,
    create: 2,
    timer: 3,
    defgate: 2
  ]

  @doc "Makes the module a flow definition. `gates:` names the module whose gates its subflows use."
  defmacro __using__(opts) do
    quote do
      import AtlasFlowGenerator.Schema, only: unquote(@macros)
      Module.register_attribute(__MODULE__, :afg_flows, accumulate: true)
      Module.register_attribute(__MODULE__, :afg_gates, accumulate: true)
      Module.put_attribute(__MODULE__, :afg_gates_module, unquote(opts[:gates]))
      Module.put_attribute(__MODULE__, :afg_scope, nil)
      @before_compile AtlasFlowGenerator.Schema
    end
  end

  # -- The subflow and its header ---------------------------------------------------

  @doc "One subflow: `name`, `label:`, the `subject:` type it runs on, and a block of the macros below."
  defmacro subflow(name, opts \\ [], do: block) do
    quote do
      AtlasFlowGenerator.Schema.__open__(
        __MODULE__,
        :subflow,
        {unquote(name), unquote(opts)},
        __ENV__.file,
        __ENV__.line
      )

      unquote(block)
      AtlasFlowGenerator.Schema.__close__(__MODULE__, :subflow)
    end
  end

  @doc "The principal Rela runs the subflow's outputs as, such as `\"system:flow\"`."
  defmacro run_as(principal), do: header(:run_as, principal)

  @doc "How many runs a subject may have at once (`:one`, the default, or another Rela value)."
  defmacro per_subject(value), do: header(:per_subject, value)

  @doc "Who owns the subject: `via:` the type that assigns it and the `relation:` to the assignee."
  defmacro owner(opts), do: header(:owner, opts)

  @doc "The channel type the subject's conversations use."
  defmacro channel(type), do: header(:channel, type)

  @doc "A start trigger: `on` (such as `:create` or `:predicate`) with `when:`, `permission:` or `every:`."
  defmacro start(on, opts \\ []), do: header(:start, {on, opts})

  @doc "The state a new run begins in."
  defmacro initial(state), do: header(:initial, state)

  defp header(key, value) do
    quote do
      AtlasFlowGenerator.Schema.__add__(
        __MODULE__,
        :header,
        {unquote(key), unquote(value)},
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- States -----------------------------------------------------------------------

  @doc "A state: `name`, `label:`, `status:`, and a block with its mechanism, branches, outputs and timers."
  defmacro state(name, opts \\ [], block \\ []), do: open_state(name, opts, block, false)

  @doc "A final state: `name`, `label:`, `status:`; an optional block may only `set` or `create`."
  defmacro final(name, opts \\ [], block \\ []), do: open_state(name, opts, block, true)

  defp open_state(name, opts, block, final?) do
    {body, opts} = Keyword.pop(opts ++ block, :do)

    quote do
      AtlasFlowGenerator.Schema.__open__(
        __MODULE__,
        :state,
        {unquote(name), unquote(opts), unquote(final?)},
        __ENV__.file,
        __ENV__.line
      )

      unquote(body)
      AtlasFlowGenerator.Schema.__close__(__MODULE__, :state)
    end
  end

  # -- What a state holds -----------------------------------------------------------

  @doc "Mechanism: a pass by `profile`, with its spec (`mode:`, `folder:`, …) and `on: [delivered:, failed:]`."
  defmacro pass(profile, opts), do: item(:pass, [profile, opts])

  @doc "Mechanism: the gate `name`, mapping each of its verdicts to a state (`ready: :next, …`)."
  defmacro gate(name, verdicts), do: item(:gate, [name, verdicts])

  @doc "Mechanism: the outside `action`, with its spec (`service:`, `field:`, `also:`, …) and `on: [done:, refused:]`."
  defmacro effect(action, opts), do: item(:effect, [action, opts])

  @doc "People with `roles` decide: `on:` the field they set, then each value they may choose and its state."
  defmacro wait_for(roles, opts), do: item(:wait_for, [roles, opts])

  @doc "Waits for `field`, written outside this subflow: each value and its state."
  defmacro await(field, values), do: item(:await, [field, values])

  @doc "One change branch as written: `to:`, `when:`, `roles:` (or `by: :atlas`), `label:`."
  defmacro branch(opts), do: item(:branch, [opts])

  @doc "Properties the state sets when it is entered."
  defmacro set(props), do: item(:set, [props])

  @doc "A subject of `type` the state creates when it is entered: `properties:`, `relate:`."
  defmacro create(type, opts), do: item(:create, [type, opts])

  @doc "A timer: `name`, `period` (such as `\"1h\"`), `to:` a state, `since:`, `label:`."
  defmacro timer(name, period, opts), do: item(:timer, [name, period, opts])

  defp item(kind, args) do
    quote do
      AtlasFlowGenerator.Schema.__add__(
        __MODULE__,
        :item,
        {unquote(kind), unquote_splicing(args)},
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- Gates ------------------------------------------------------------------------

  @doc """
  A gate: `version:`, `flavor:` (`:smart`, advised then decided by policy, or `:rule`),
  `purpose:` (`:flow` or `:decider`), `verdicts:` it writes, `person:` (the verdict
  that hands over to a person, default `:person`), `decide:` (evaluator outcome to
  verdict), `evidence:`, `advice:` (smart) or `rule:` (rule), `policy:`.
  """
  defmacro defgate(name, opts) do
    quote do
      AtlasFlowGenerator.Schema.__add__(
        __MODULE__,
        :gate,
        {unquote(name), unquote(opts)},
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- Recording, while the module body runs -----------------------------------------

  @doc false
  def __open__(mod, :subflow, {name, opts}, file, line) do
    in_scope!(mod, nil, "subflow", "at the top of the module", file, line)
    flow = %{name: name, opts: opts, line: line, header: [], states: []}
    Module.put_attribute(mod, :afg_flow, flow)
    Module.put_attribute(mod, :afg_scope, :subflow)
  end

  def __open__(mod, :state, {name, opts, final?}, file, line) do
    word = if final?, do: "final", else: "state"
    in_scope!(mod, :subflow, word, "inside a subflow", file, line)
    state = %{name: name, opts: opts, final: final?, line: line, items: []}
    Module.put_attribute(mod, :afg_state, state)
    Module.put_attribute(mod, :afg_scope, :state)
  end

  @doc false
  def __close__(mod, :state) do
    state = Module.get_attribute(mod, :afg_state)
    update(mod, :afg_flow, :states, state)
    Module.put_attribute(mod, :afg_scope, :subflow)
  end

  def __close__(mod, :subflow) do
    Module.put_attribute(mod, :afg_flows, Module.get_attribute(mod, :afg_flow))
    Module.put_attribute(mod, :afg_scope, nil)
  end

  @doc false
  def __add__(mod, :header, {key, _} = entry, file, line) do
    in_scope!(mod, :subflow, key, "directly inside a subflow", file, line)
    update(mod, :afg_flow, :header, {entry, line})
  end

  def __add__(mod, :item, entry, file, line) do
    in_scope!(mod, :state, elem(entry, 0), "inside a state", file, line)
    update(mod, :afg_state, :items, {entry, line})
  end

  def __add__(mod, :gate, {name, opts}, file, line) do
    in_scope!(mod, nil, "defgate", "at the top of the module", file, line)
    Module.put_attribute(mod, :afg_gates, %{name: name, opts: opts, line: line})
  end

  defp in_scope!(mod, scope, what, place, file, line) do
    if Module.get_attribute(mod, :afg_scope) != scope do
      raise CompileError, file: file, line: line, description: "#{what} belongs #{place}"
    end
  end

  defp update(mod, attr, key, value) do
    current = Module.get_attribute(mod, attr)
    Module.put_attribute(mod, attr, Map.update!(current, key, &(&1 ++ [value])))
  end

  # -- Building and checking, before the module is compiled --------------------------

  @doc false
  defmacro __before_compile__(env) do
    file = env.file
    own = env.module |> Module.get_attribute(:afg_gates) |> Enum.reverse()
    {gates, gate_problems} = build_gates(own)
    refuse!(gate_problems, file)

    raw = env.module |> Module.get_attribute(:afg_flows) |> Enum.reverse()
    known = gates ++ imported_gates(env.module, raw, file)

    {flows, problems} =
      Enum.reduce(raw, {[], []}, fn r, {flows, problems} ->
        {flow, ps} = build_flow(r, known)
        {flows ++ [flow], problems ++ ps ++ check_flow(flow)}
      end)

    refuse!(problems, file)
    flows = Enum.map(flows, &(&1 |> Map.delete(:initial_line) |> Map.put(:file, file)))
    gates = Enum.map(gates, &Map.put(&1, :file, file))

    quote do
      @doc "The subflows this module defines, as plain data."
      def __flows__, do: unquote(Macro.escape(flows))

      @doc "The gates this module defines, as plain data."
      def __gates__, do: unquote(Macro.escape(gates))
    end
  end

  defp imported_gates(module, raw, file) do
    case Module.get_attribute(module, :afg_gates_module) do
      nil ->
        []

      gates_module ->
        line = with [%{line: l} | _] <- raw, do: l, else: (_ -> 1)

        case Code.ensure_compiled(gates_module) do
          {:module, m} when is_atom(m) ->
            if function_exported?(m, :__gates__, 0),
              do: m.__gates__(),
              else: refuse!([{line, "#{inspect(m)} defines no gates"}], file)

          {:error, reason} ->
            refuse!([{line, "the gates module #{inspect(gates_module)} is #{reason}"}], file)
        end
    end
  end

  # A mistake is refused at the line of the first one; the others follow in the message.
  defp refuse!([], _file), do: :ok

  defp refuse!(problems, file) do
    [{line, message} | rest] = Enum.sort_by(problems, &elem(&1, 0))
    also = Enum.map_join(rest, "", fn {l, m} -> "\n  line #{l}: #{m}" end)
    raise CompileError, file: file, line: line, description: message <> also
  end

  # -- Gates --

  defp build_gates(raw) do
    Enum.reduce(raw, {[], []}, fn %{name: name, opts: opts, line: line}, {gates, problems} ->
      gate = %{
        name: name,
        version: opts[:version],
        flavor: opts[:flavor],
        purpose: opts[:purpose],
        advice: opts[:advice],
        rule: opts[:rule],
        evidence: Keyword.get(opts, :evidence, []),
        verdicts: Keyword.get(opts, :verdicts, []),
        person: Keyword.get(opts, :person, :person),
        decide: Keyword.get(opts, :decide, []),
        policy: Keyword.get(opts, :policy, [])
      }

      twice = Enum.any?(gates, &(&1.name == name))
      ps = for p <- [twice_problem(twice, name) | gate_problems(gate)], p, do: {line, p}
      {gates ++ [gate], problems ++ ps}
    end)
  end

  defp twice_problem(true, name), do: "gate #{name} is defined twice"
  defp twice_problem(false, _), do: nil

  defp gate_problems(g) do
    pre = "gate #{g.name}: "

    [
      not valid_name?(g.name) && "#{g.name} is not a valid name",
      not (is_integer(g.version) and g.version > 0) && pre <> "needs version: a positive integer",
      g.flavor not in [:smart, :rule] && pre <> "flavor must be :smart or :rule",
      g.purpose not in @purposes && pre <> "purpose must be :flow or :decider",
      g.verdicts == [] && pre <> "needs verdicts: the values it writes",
      g.verdicts != Enum.uniq(g.verdicts) && pre <> "names a verdict twice",
      (g.verdicts != [] and g.person not in g.verdicts) &&
        pre <> "its person verdict #{g.person} is not among its verdicts"
    ] ++ decide_problems(g, pre) ++ flavor_problems(g, pre)
  end

  # decide is total over the evaluator's outcomes, whatever the flavor, and what the
  # evaluator cannot settle goes to a person.
  defp decide_problems(g, pre) do
    decided = Keyword.keys(g.decide)
    missing = @outcomes -- decided
    unknown = Enum.uniq(decided) -- @outcomes
    twice = decided -- Enum.uniq(decided)
    wrong = for {_, v} <- g.decide, v not in g.verdicts, do: v

    [
      missing != [] && pre <> "decide does not cover the evaluator outcome(s) #{list(missing)}",
      unknown != [] && pre <> "decide names unknown outcome(s) #{list(unknown)}",
      twice != [] && pre <> "decide maps #{list(Enum.uniq(twice))} twice",
      wrong != [] && pre <> "decide maps to #{list(wrong)}, which is not a verdict"
    ] ++
      for k <- [:uncertain, :error], k in decided, g.decide[k] != g.person do
        pre <> "#{k} must decide #{g.person}: an uncertain or failed evaluation goes to a person"
      end
  end

  defp flavor_problems(%{flavor: :smart} = g, pre) do
    [
      g.advice == nil && pre <> "a smart gate needs advice: who advises it",
      g.rule != nil && pre <> "a smart gate decides by its advice; rule: is for rule gates"
    ]
  end

  defp flavor_problems(%{flavor: :rule} = g, pre) do
    [g.advice != nil && pre <> "a rule gate decides by its rule; it takes no advice"] ++
      rule_problems(g.rule, g.evidence, pre)
  end

  defp flavor_problems(_g, _pre), do: []

  defp rule_problems(nil, _evidence, pre),
    do: [pre <> "a rule gate needs rule: [all: conditions] over its evidence"]

  defp rule_problems([all: [_ | _] = conditions], evidence, pre) do
    Enum.flat_map(conditions, fn c ->
      case condition_fields(c) do
        nil ->
          [
            pre <>
              "rule condition #{inspect(c)} is not {:equals, field, value} or {:same, field, other}"
          ]

        fields ->
          for f <- fields,
              f not in evidence,
              do: pre <> "rule reads #{f}, which is not in its evidence"
      end
    end)
  end

  defp rule_problems(_rule, _evidence, pre),
    do: [pre <> "rule must be [all: conditions], with at least one condition"]

  defp condition_fields({:equals, field, value})
       when is_atom(field) and (is_binary(value) or is_number(value) or is_boolean(value)),
       do: [field]

  defp condition_fields({:same, field, other}) when is_atom(field) and is_atom(other),
    do: [field, other]

  defp condition_fields(_), do: nil

  # -- Subflows: from what was written to plain data --

  defp build_flow(%{name: name, opts: opts, line: line, header: header, states: states}, gates) do
    once = for {{k, v}, l} <- header, k in @once, do: {k, v, l}

    twice =
      for {k, _, l} <- once, Enum.count(once, &(elem(&1, 0) == k)) > 1, uniq: true do
        {l, "subflow #{name}: #{k} is given more than once"}
      end

    get = fn key -> Enum.find_value(once, fn {k, v, _} -> k == key && v end) end
    at = fn key -> Enum.find_value(once, line, fn {k, _, l} -> k == key && l end) end

    starts =
      for {{:start, {on, o}}, l} <- header do
        %{on: on, when: o[:when], permission: o[:permission], every: o[:every], line: l}
      end

    {built, problems} =
      Enum.reduce(states, {[], twice}, fn s, {acc, ps} ->
        {state, more} = build_state(s, gates)
        {acc ++ [state], ps ++ more}
      end)

    flow = %{
      name: name,
      label: opts[:label],
      subject: opts[:subject],
      run_as: get.(:run_as),
      per_subject: get.(:per_subject) || :one,
      owner: if(o = get.(:owner), do: Map.new(o)),
      channel: get.(:channel),
      start: Enum.map(starts, &Map.delete(&1, :line)),
      initial: get.(:initial),
      line: line,
      initial_line: at.(:initial),
      states: built
    }

    {flow, problems}
  end

  defp build_state(%{name: name, opts: opts, final: final?, line: line, items: items}, gates) do
    state = %{
      name: name,
      label: opts[:label],
      status: opts[:status],
      final: final?,
      line: line,
      mechanism: nil,
      waiting_for: [],
      awaits: [],
      set: [],
      creates: [],
      branches: [],
      timers: []
    }

    {state, problems} =
      Enum.reduce(items, {state, []}, fn {entry, l}, {s, ps} ->
        {s, more} = put(entry, s, gates)
        {s, ps ++ Enum.map(more, &{l, "state #{name}: " <> &1})}
      end)

    # Waiting for people with nothing at work in the state is waiting for input.
    status =
      state.status || if(state.waiting_for != [] and state.mechanism == nil, do: :input_required)

    {%{state | status: status, waiting_for: Enum.uniq(state.waiting_for)}, problems}
  end

  # Each returns the state with the entry added, and the problems found.
  defp put({:pass, profile, opts}, s, _gates) do
    spec = Map.new([{:profile, profile} | Keyword.delete(opts, :on)])
    {s, ps} = mechanism(s, {:pass, spec})

    if opts[:writes] == :none,
      do: {s, ps},
      else: also(results(s, :pass_result, @pass_results, Keyword.get(opts, :on, [])), ps)
  end

  defp put({:gate, name, mapping}, s, gates) do
    case Enum.find(gates, &(&1.name == name)) do
      nil ->
        # Keep its branches, so one mistake is reported once.
        {add_branches(s, :gate_result, mapping, [@writer]),
         ["names gate #{name}, which is not defined"]}

      gate ->
        {s, ps} = mechanism(s, {:gate, %{gate: name, version: gate.version}})
        also(results(s, :gate_result, gate.verdicts, mapping, "gate #{name}"), ps)
    end
  end

  defp put({:effect, action, opts}, s, _gates) do
    field = Keyword.get(opts, :field, :effect_result)
    spec = Map.new([action: action, field: field] ++ Keyword.drop(opts, [:on, :field]))
    {s, ps} = mechanism(s, {:effect, spec})
    also(results(s, field, @effect_results, Keyword.get(opts, :on, [])), ps)
  end

  defp put({:wait_for, roles, opts}, s, _gates) do
    roles = Enum.map(List.wrap(roles), &to_string/1)

    case Keyword.pop(opts, :on) do
      {nil, _} ->
        {s, ["wait_for needs on: the field the people set"]}

      {field, choices} ->
        {reset, choices} = Keyword.pop(choices, :reset, true)
        s = %{s | waiting_for: s.waiting_for ++ roles}
        {s, ps} = if reset, do: put_set(s, [{field, :none}]), else: {s, []}
        {add_branches(s, field, choices, roles), ps}
    end
  end

  defp put({:await, field, choices}, s, _gates) do
    s = %{s | awaits: s.awaits ++ [field]}
    {add_branches(s, field, choices, [@writer]), []}
  end

  defp put({:branch, opts}, s, _gates) do
    roles = if opts[:by] == :atlas, do: [@writer], else: Keyword.get(opts, :roles, [])

    branch = %{
      to: opts[:to],
      roles: Enum.map(roles, &to_string/1),
      when: opts[:when],
      label: opts[:label]
    }

    problem = if opts[:to] == nil, do: ["a branch needs to: a state"], else: []
    {%{s | branches: s.branches ++ [branch]}, problem}
  end

  defp put({:set, props}, s, _gates), do: put_set(s, props)

  defp put({:create, type, opts}, s, _gates) do
    create = %{type: type, properties: Keyword.get(opts, :properties, []), relate: opts[:relate]}
    {%{s | creates: s.creates ++ [create]}, []}
  end

  defp put({:timer, name, period, opts}, s, _gates) do
    timer = %{name: name, period: period, to: opts[:to], since: opts[:since], label: opts[:label]}

    problems =
      [
        opts[:to] == nil && "timer #{name} needs to: a state",
        not valid_name?(name) && "timer name #{name} is not a valid name",
        Enum.any?(s.timers, &(&1.name == name)) && "timer #{name} is defined twice"
      ]

    {%{s | timers: s.timers ++ [timer]}, Enum.filter(problems, & &1)}
  end

  defp mechanism(%{mechanism: nil} = s, m), do: {%{s | mechanism: m}, []}

  defp mechanism(s, {kind, _}),
    do: {s, ["has a second mechanism (#{kind}); a state has at most one pass, gate or effect"]}

  # One branch per result value, in the order the definition maps them.
  defp results(s, field, values, mapping, source \\ nil) do
    source = source || to_string(field)
    keys = Keyword.keys(mapping)
    missing = values -- keys
    extra = keys -- values
    twice = keys -- Enum.uniq(keys)

    problems =
      [
        missing != [] && "#{source} can give #{list(missing)}, which no branch takes",
        extra != [] && "#{source} never gives #{list(extra)}",
        twice != [] && "#{source} maps #{list(Enum.uniq(twice))} twice"
      ]
      |> Enum.filter(& &1)

    {s, ps} = put_set(s, [{field, :none}])
    {add_branches(s, field, mapping, [@writer]), problems ++ ps}
  end

  defp also({s, ps}, earlier), do: {s, earlier ++ ps}

  defp put_set(s, props) do
    twice = for {k, _} <- props, Keyword.has_key?(s.set, k), do: "sets #{k} twice"
    {%{s | set: s.set ++ props}, twice}
  end

  defp add_branches(s, field, choices, roles) do
    new =
      for {value, target} <- choices do
        {to, label} = with to when is_atom(to) <- target, do: {to, nil}
        %{to: to, roles: roles, when: eq(field, value), label: label}
      end

    %{s | branches: s.branches ++ new}
  end

  defp eq(field, value) when is_boolean(value) or is_number(value),
    do: "entity.#{field} == #{value}"

  defp eq(field, value), do: "entity.#{field} == '#{value}'"

  # -- Subflows: the rules over the whole --

  defp check_flow(flow) do
    by_name = Map.new(flow.states, &{&1.name, &1})
    names = Enum.map(flow.states, & &1.name)
    initial = by_name[flow.initial]
    pre = "subflow #{flow.name}: "

    header =
      [
        {flow.line, flow.subject == nil && pre <> "needs subject: the type it runs on"},
        {flow.line,
         not valid_name?(flow.name) && "subflow name #{flow.name} is not a valid name"},
        {flow.line, flow.start == [] && pre <> "has no start trigger"},
        {flow.initial_line, flow.initial == nil && pre <> "has no initial state"},
        {flow.initial_line,
         (flow.initial != nil and initial == nil) &&
           pre <> "initial names unknown state #{flow.initial}"},
        {flow.initial_line,
         (initial != nil and initial.final) &&
           pre <>
             "initial #{flow.initial} is final; a run would end before it begins"}
      ] ++
        for(
          {s, i} <- Enum.with_index(flow.states),
          s.name in Enum.take(names, i),
          do: {s.line, pre <> "state #{s.name} is defined twice"}
        ) ++
        for(
          s <- flow.states,
          not valid_name?(s.name),
          do: {s.line, "state name #{s.name} is not a valid name"}
        ) ++
        outputs_need_run_as(flow, pre)

    states = Enum.flat_map(flow.states, &check_state(&1, by_name))
    reach = if initial, do: unreachable(flow, by_name), else: []

    for {line, p} <- header ++ states ++ reach, p, do: {line, p}
  end

  defp outputs_need_run_as(%{run_as: nil} = flow, pre) do
    case Enum.find(flow.states, &(&1.set != [] or &1.creates != [])) do
      nil -> []
      s -> [{s.line, pre <> "state #{s.name} has outputs, so the subflow needs run_as"}]
    end
  end

  defp outputs_need_run_as(_flow, _pre), do: []

  defp check_state(s, by_name) do
    pre = "state #{s.name}: "
    targets = Enum.map(s.branches, & &1.to) ++ Enum.map(s.timers, & &1.to)

    leads =
      for t <- Enum.uniq(targets),
          t != nil,
          not Map.has_key?(by_name, t),
          do: {s.line, pre <> "leads to unknown state #{t}"}

    leads ++
      if s.final do
        [
          {s.line, targets != [] && pre <> "is final, so it has no branches or timers"},
          {s.line, s.mechanism != nil && pre <> "is final, so it has no mechanism"},
          {s.line, s.waiting_for != [] && pre <> "is final, so it waits for no one"}
        ]
      else
        roles = s.branches |> Enum.flat_map(& &1.roles) |> Enum.uniq()
        only_roles? = s.branches != [] and Enum.all?(s.branches, &(&1.roles != []))
        moved? = s.waiting_for != [] or s.mechanism != nil or s.awaits != [] or @writer in roles

        [
          {s.line,
           targets == [] &&
             pre <> "is not final and has no way out (no branch or timer)"},
          {s.line,
           (only_roles? and not moved?) &&
             pre <>
               "only #{list(roles)} can move it, but it does not wait_for them; " <>
               "add wait_for, a mechanism or an await"},
          {s.line, length(s.timers) > @max_timers && pre <> "has more than #{@max_timers} timers"}
        ] ++
          for(
            r <- s.waiting_for,
            r not in roles,
            do: {s.line, pre <> "waits for #{r}, but no branch lets #{r} move it"}
          ) ++ shadowed(s, pre)
      end
  end

  # Rela takes the first branch that applies; one that takes every change hides the rest.
  defp shadowed(s, pre) do
    s.branches
    |> Enum.drop(-1)
    |> Enum.filter(&(&1.roles == [] and &1.when == nil))
    |> Enum.map(
      &{s.line,
       pre <>
         "the branch to #{&1.to} takes every change, so the branches after it are never taken"}
    )
  end

  defp unreachable(flow, by_name) do
    seen = walk([flow.initial], MapSet.new(), by_name)

    for s <- flow.states,
        not MapSet.member?(seen, s.name),
        do:
          {s.line,
           "subflow #{flow.name}: unreachable state #{s.name}: no branch or timer leads to it from #{flow.initial}"}
  end

  defp walk([], seen, _by_name), do: seen

  defp walk([n | rest], seen, by_name) do
    case by_name[n] do
      nil ->
        walk(rest, seen, by_name)

      s ->
        if MapSet.member?(seen, n) do
          walk(rest, seen, by_name)
        else
          next = Enum.map(s.branches, & &1.to) ++ Enum.map(s.timers, & &1.to)
          walk(next ++ rest, MapSet.put(seen, n), by_name)
        end
    end
  end

  defp valid_name?(name), do: is_atom(name) and Regex.match?(@name, to_string(name))
  defp list(items), do: Enum.map_join(items, ", ", &to_string/1)
end
