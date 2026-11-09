defmodule RelaDSL.Flow.Legacy do
  @moduledoc """
  A legacy flow (`legacy_flow`, a flow whose runs are not stored yet) compiled into a
  module a runner calls. Its states are in order: a fact is in the first whose
  conditions hold, and in the last when no other does.

  A composition (`RelaDSL.Composition`) compiles each legacy flow it declares. A module
  can also compile one by itself, from the options `legacy_flow` takes:

      defmodule MyFlows.Post do
        use RelaDSL.Flow.Legacy, name: :post, behaviour: SomeRunner.Legacy,
          flow: [kinds: [:letter], field: :expected, owner_relation: :held_by,
                 states: [[name: :done, when: [values: [state: [:sent]]], done: true],
                          [name: :open, owner: [kind: :clerk, key: "post_room"],
                           expected: "Post it"]]]
      end

  What a state's `when` can say, of the fact as it is read: `completed: true | false`,
  `progress: value`, `values: [field: [values]]`, `empty: relation` (nothing points at it
  through that relation; see `RelaDSL.Flow.Code.empty?/4`) and `reopened: relation` (the
  newest fact about that association removed it; its cause fills `{note}`). Any other
  condition never holds.

  Callbacks, with state names as text: `name/0`, `kinds/0`, `writes/0` (`on`, `field`,
  `state_field`, `handover_field`, `owner_relation`, as given), `empties/0` (the
  relations its `empty` conditions name), `state(fact, children, parents, pointing)`
  (`{state, vars}`: the vars are the fact's own plain values and a condition's `note`),
  `done?(state)`, `owner(state)` (`%{"kind", "key"}` or nil), `expected(state, vars)`
  (filled, nil when done), `why(state)` and `every(state)` (ms, or nil).
  """

  alias RelaDSL.Description.Plain
  alias RelaDSL.Flow.Subflow

  @writes ~w(on field state_field handover_field owner_relation deadline_field)

  defmacro __using__(opts) do
    name = to_string(Keyword.fetch!(opts, :name))
    behaviour = opts[:behaviour] && Macro.expand(opts[:behaviour], __CALLER__)
    {flow, _} = Code.eval_quoted(Keyword.fetch!(opts, :flow), [], __CALLER__)
    body(name, Plain.of(flow), behaviour)
  end

  @doc "The module body for legacy flow `name` and its data (string keys)."
  def body(name, flow, behaviour) do
    fact = Macro.var(:fact, __MODULE__)
    children = Macro.var(:children, __MODULE__)
    parents = Macro.var(:parents, __MODULE__)
    pointing = Macro.var(:pointing, __MODULE__)
    vars = Macro.var(:vars, __MODULE__)
    states = Enum.filter(flow["states"] || [], &is_map/1)

    empties =
      for s <- states, {"empty", relation} <- s["when"] || %{}, uniq: true, do: relation

    clauses =
      for s <- states do
        conditions = Enum.map(s["when"] || %{}, &condition(&1, fact, children, parents, pointing))
        {conditions, s["name"]}
      end

    pick =
      Enum.reduce(Enum.reverse(clauses), quote(do: {nil, own}), fn {conditions, state}, rest ->
        found = quote(do: {unquote(state), Map.merge(own, unquote(Macro.var(:more, __MODULE__)))})

        quote do
          case unquote(all(conditions)) do
            nil -> unquote(rest)
            more -> unquote(found)
          end
        end
      end)

    each = fn f -> for s <- states, do: f.(s) end

    quote do
      unquote(if behaviour, do: quote(do: @behaviour(unquote(behaviour))))

      def name, do: unquote(name)
      def kinds, do: unquote(flow["kinds"] || [])
      def writes, do: unquote(Macro.escape(Map.take(flow, @writes)))
      def empties, do: unquote(empties)

      def state(unquote(fact), unquote(children), unquote(parents), unquote(pointing)) do
        _ = {unquote(children), unquote(parents), unquote(pointing)}
        own = RelaDSL.Flow.Code.own_vars(unquote(fact))
        unquote(pick)
      end

      unquote_splicing(
        each.(&quote(do: def(done?(unquote(&1["name"])), do: unquote(&1["done"] == true))))
      )

      def done?(_state), do: false

      unquote_splicing(
        each.(&quote(do: def(owner(unquote(&1["name"])), do: unquote(Macro.escape(owner(&1))))))
      )

      def owner(_state), do: nil

      unquote_splicing(each.(&quote(do: def(why(unquote(&1["name"])), do: unquote(&1["why"])))))
      def why(_state), do: nil

      unquote_splicing(each.(&quote(do: def(every(unquote(&1["name"])), do: unquote(every(&1))))))
      def every(_state), do: nil

      unquote_splicing(each.(&expected(&1, vars)))
      def expected(_state, _vars), do: ""
    end
  end

  # Each condition gives the vars it adds (%{}), or nil when it does not hold.
  defp condition({"completed", true}, fact, _, _, _),
    do: quote(do: if(unquote(fact)["completion"], do: %{}))

  defp condition({"completed", false}, fact, _, _, _),
    do: quote(do: if(!unquote(fact)["completion"], do: %{}))

  defp condition({"progress", value}, fact, _, _, _),
    do: quote(do: if(get_in(unquote(fact), ["progress", "value"]) == unquote(value), do: %{}))

  defp condition({"reopened", relation}, fact, children, parents, _),
    do:
      quote(
        do:
          RelaDSL.Flow.Code.reopened(
            unquote(fact),
            unquote(children),
            unquote(parents),
            unquote(relation)
          )
      )

  defp condition({"empty", relation}, _fact, children, parents, pointing),
    do:
      quote(
        do:
          if(
            RelaDSL.Flow.Code.empty?(
              unquote(relation),
              unquote(children),
              unquote(parents),
              unquote(pointing)
            ),
            do: %{}
          )
      )

  defp condition({"values", allowed}, fact, _, _, _) when is_map(allowed),
    do:
      quote(
        do: if(RelaDSL.Flow.Code.values?(unquote(fact), unquote(Macro.escape(allowed))), do: %{})
      )

  defp condition(_other, _, _, _, _), do: nil

  # All hold: their vars merged, in the order written; nil as soon as one does not.
  defp all([]), do: Macro.escape(%{})

  defp all([one | rest]) do
    quote do
      case unquote(one) do
        nil -> nil
        vars -> with more when is_map(more) <- unquote(all(rest)), do: Map.merge(vars, more)
      end
    end
  end

  defp owner(%{"done" => true}), do: nil
  defp owner(%{"owner" => %{"key" => key} = o}), do: %{"kind" => o["kind"], "key" => key}
  defp owner(%{"owner" => key}) when is_binary(key), do: %{"kind" => nil, "key" => key}
  defp owner(_), do: nil

  defp every(%{"every_seconds" => s}) when is_integer(s) and s > 0, do: s * 1000
  defp every(_), do: nil

  defp expected(%{"done" => true} = s, _vars),
    do: quote(do: def(expected(unquote(s["name"]), _vars), do: nil))

  defp expected(s, vars) do
    parts = Subflow.parts(s["expected"] || "")

    if Enum.any?(parts, &match?({:var, _}, &1)) do
      quote do
        def expected(unquote(s["name"]), unquote(vars)),
          do: RelaDSL.Flow.Code.fill(unquote(Macro.escape(parts)), unquote(vars))
      end
    else
      quote do
        def expected(unquote(s["name"]), _vars),
          do: unquote(RelaDSL.Flow.Code.fill(parts, %{}))
      end
    end
  end
end
