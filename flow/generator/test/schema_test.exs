defmodule AtlasFlowGenerator.SchemaTest do
  use ExUnit.Case, async: true

  alias AtlasFlowGenerator.Example

  @decide "[pass: :ok, changes_required: :no, uncertain: :person, error: :person]"

  @smart [
    version: "1",
    flavor: ":smart",
    purpose: ":flow",
    advice: ":advisor",
    verdicts: "[:ok, :no, :person]",
    decide: @decide
  ]

  @rule [
    version: "1",
    flavor: ":rule",
    purpose: ":decider",
    evidence: "[:a, :b]",
    rule: ~s([all: [{:equals, :a, "x"}, {:same, :a, :b}]]),
    verdicts: "[:ok, :no, :person]",
    decide: @decide
  ]

  describe "a definition compiles to plain data" do
    test "the subflow header, in the order written" do
      assert [flow] = Example.__flows__()

      assert %{
               name: :letter,
               label: "Letter",
               subject: :letter,
               run_as: "system:post",
               per_subject: :one,
               owner: %{via: :desk, relation: :held_by},
               channel: :mail,
               initial: :draft,
               start: [
                 %{on: :create, when: nil},
                 %{on: :predicate, when: "entity.kind == 'reply'"}
               ]
             } = flow

      assert String.ends_with?(flow.file, "test/support/example.ex")

      assert Enum.map(flow.states, & &1.name) ==
               [:draft, :proofread, :post, :sent, :stuck, :answered, :dropped]
    end

    test "a pass expands into its reset and one writer branch per result" do
      draft = state(:draft)
      assert draft.mechanism == {:pass, %{profile: :writer, mode: :draft}}
      assert draft.set == [pass_result: :none]

      assert branches(draft) == [
               {:proofread, ["atlas-flow"], "entity.pass_result == 'delivered'"},
               {:stuck, ["atlas-flow"], "entity.pass_result == 'failed'"}
             ]

      assert [%{name: :slow, period: "1d", to: :stuck, label: "The writer did not finish"}] =
               draft.timers
    end

    test "a gate expands into its verdicts and carries its version" do
      gate = state(:proofread)
      assert gate.mechanism == {:gate, %{gate: :proofread, version: 2}}
      assert gate.set == [gate_result: :none]
      assert Enum.map(branches(gate), &elem(&1, 0)) == [:post, :draft, :stuck]
    end

    test "an effect writes its own field and keeps its spec" do
      post = state(:post)

      assert {:effect, %{action: :post_letter, field: :post_result, also: [reply: :none]}} =
               post.mechanism

      assert post.set == [post_result: :none]
      assert [%{type: :receipt, relate: :receipt_of}] = post.creates
      assert {:sent, ["atlas-flow"], "entity.post_result == 'done'"} = hd(branches(post))
    end

    test "branches keep the order written, mechanisms included" do
      assert branches(state(:sent)) == [
               {:answered, ["atlas-flow"], "entity.urgent == true"},
               {:answered, ["atlas-flow"], "entity.reply == 'received'"},
               {:stuck, ["atlas-flow"], "entity.reply == 'lost'"}
             ]

      assert state(:sent).awaits == [:reply]
    end

    test "wait_for puts the state in the roles' inbox" do
      stuck = state(:stuck)
      assert stuck.waiting_for == ["editor"]
      assert stuck.status == :input_required
      assert stuck.set == [choice: :none]

      assert branches(stuck) == [
               {:draft, ["editor"], "entity.choice == 'retry'"},
               {:dropped, ["editor"], "entity.choice == 'drop'"},
               {:dropped, ["admin"], "entity.choice == 'drop'"}
             ]
    end

    test "final states carry their outputs and status" do
      assert %{final: true, set: [archived: true], branches: []} = state(:answered)
      assert %{final: true, status: :cancelled} = state(:dropped)
    end

    test "gates are data" do
      assert [smart, rule] = Example.Gates.__gates__()

      assert %{
               name: :proofread,
               version: 2,
               flavor: :smart,
               verdicts: [:send, :redo, :person],
               person: :person,
               decide: [pass: :send, changes_required: :redo, uncertain: :person, error: :person],
               policy: [max_rounds: 2]
             } = smart

      assert %{
               name: :size_limit,
               flavor: :rule,
               purpose: :decider,
               advice: nil,
               evidence: [:pages, :envelope, :format],
               rule: [all: [{:equals, :pages, 1}, {:same, :envelope, :format}]],
               decide: [
                 pass: :fits,
                 changes_required: :person,
                 uncertain: :person,
                 error: :person
               ]
             } = rule

      assert String.ends_with?(rule.file, "test/support/example.ex")
      assert Example.Gates.__flows__() == []
    end

    test "a valid smart gate and a valid rule gate compile; the fixtures below each break one rule" do
      for base <- [@smart, @rule] do
        assert [%{name: :g}] = compile!(gate_source(base)).__gates__()
      end
    end

    test "a pass a person answers (writes: :none) adds no reset or writer branch" do
      [flow] =
        compile!("""
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            pass :signer, writes: :none
            branch to: :b, roles: [:signer], when: "entity.signed == true"
          end
          final :b
        end
        """).__flows__()

      assert [%{mechanism: {:pass, %{profile: :signer}}, set: [], branches: [_]} | _] =
               flow.states
    end
  end

  # One fixture per rule: each is refused at compile time, at the line of the mistake.
  describe "a broken definition does not compile" do
    test "an unreachable state" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            timer :t, "1d", to: :b
          end
          state :orphan do
            timer :t, "1d", to: :b
          end
          final :b
        end
        """,
        7,
        "unreachable state orphan: no branch or timer leads to it from a"
      )
    end

    test "a state that is not final and has no way out" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            timer :t, "1d", to: :b
          end
          state :b, label: "Stuck" do
          end
          final :c
        end
        """,
        7,
        "state b: is not final and has no way out"
      )
    end

    test "a final state with a way out" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            timer :t, "1d", to: :b
          end
          final :b do
            timer :again, "1d", to: :a
          end
        end
        """,
        7,
        "state b: is final, so it has no branches or timers"
      )
    end

    test "a final state with a mechanism" do
      refused(
        gated("""
          state :a do
            timer :t, "1d", to: :b
          end
          final :b do
            gate :size_limit, fits: :a, person: :a
          end
        """),
        8,
        "state b: is final, so it has no mechanism"
      )
    end

    test "a final state that waits for someone" do
      refused(
        """
        subflow :f, subject: :t do
          run_as "system:x"
          start :create
          initial :a
          state :a do
            timer :t, "1d", to: :b
          end
          final :b do
            wait_for [:clerk], on: :choice
          end
        end
        """,
        8,
        "state b: is final, so it waits for no one"
      )
    end

    test "a state only a role can move, that waits for nobody" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            branch to: :b, roles: [:clerk], when: "entity.done == true"
          end
          final :b
        end
        """,
        4,
        "state a: only clerk can move it, but it does not wait_for them"
      )
    end

    test "a role it waits for, with no branch to take" do
      refused(
        """
        subflow :f, subject: :t do
          run_as "system:x"
          start :create
          initial :a
          state :a do
            wait_for [:clerk], on: :choice
            timer :t, "1d", to: :b
          end
          final :b
        end
        """,
        5,
        "state a: waits for clerk, but no branch lets clerk move it"
      )
    end

    test "a gate verdict no branch takes" do
      refused(
        gated("""
          state :a do
            gate :proofread, send: :b, redo: :b
          end
          final :b
        """),
        6,
        "state a: gate proofread can give person, which no branch takes"
      )
    end

    test "a verdict the gate never gives" do
      refused(
        gated("""
          state :a do
            gate :size_limit, fits: :b, person: :b, maybe: :b
          end
          final :b
        """),
        6,
        "state a: gate size_limit never gives maybe"
      )
    end

    test "a smart gate whose decide misses an evaluator outcome" do
      refused_gate(
        @smart,
        [decide: "[pass: :ok, changes_required: :no, uncertain: :person]"],
        "gate g: decide does not cover the evaluator outcome(s) error"
      )
    end

    test "a rule gate whose decide misses an evaluator outcome" do
      refused_gate(
        @rule,
        [decide: "[pass: :ok, uncertain: :person, error: :person]"],
        "gate g: decide does not cover the evaluator outcome(s) changes_required"
      )
    end

    test "a decide that names an outcome no evaluator gives" do
      refused_gate(
        @rule,
        [decide: String.replace(@decide, "]", ", maybe: :person]")],
        "gate g: decide names unknown outcome(s) maybe"
      )
    end

    test "a decide that maps an outcome twice" do
      refused_gate(
        @smart,
        [decide: String.replace(@decide, "[", "[pass: :no, ")],
        "gate g: decide maps pass twice"
      )
    end

    test "a gate that lets an uncertain outcome through" do
      refused_gate(
        @smart,
        [decide: String.replace(@decide, "uncertain: :person", "uncertain: :ok")],
        "gate g: uncertain must decide person"
      )
    end

    test "a gate that lets an error through" do
      refused_gate(
        @rule,
        [decide: String.replace(@decide, "error: :person", "error: :no")],
        "gate g: error must decide person"
      )
    end

    test "a gate that decides a value it has no verdict for" do
      refused_gate(
        @smart,
        [decide: String.replace(@decide, "pass: :ok", "pass: :maybe")],
        "gate g: decide maps to maybe, which is not a verdict"
      )
    end

    test "a gate without a positive version" do
      refused_gate(@rule, [version: "0"], "gate g: needs version: a positive integer")
    end

    test "a gate of an unknown flavor" do
      refused_gate(@smart, [flavor: ":clever"], "gate g: flavor must be :smart or :rule")
    end

    test "a gate without a purpose" do
      refused_gate(@smart, [purpose: nil], "gate g: purpose must be :flow or :decider")
    end

    test "a gate without verdicts" do
      refused(
        gate_source(@rule, verdicts: "[]"),
        1,
        "gate g: needs verdicts: the values it writes"
      )
    end

    test "a gate that names a verdict twice" do
      refused_gate(@rule, [verdicts: "[:ok, :no, :ok, :person]"], "gate g: names a verdict twice")
    end

    test "a gate whose person verdict is not a verdict" do
      refused(
        gate_source(@rule, person: ":human"),
        1,
        "gate g: its person verdict human is not among its verdicts"
      )
    end

    test "a smart gate without advice" do
      refused_gate(@smart, [advice: nil], "gate g: a smart gate needs advice: who advises it")
    end

    test "a smart gate with a rule" do
      refused_gate(
        @smart,
        [evidence: "[:a]", rule: ~s([all: [{:equals, :a, "x"}]])],
        "gate g: a smart gate decides by its advice; rule: is for rule gates"
      )
    end

    test "a rule gate with advice" do
      refused_gate(
        @rule,
        [advice: ":advisor"],
        "gate g: a rule gate decides by its rule; it takes no advice"
      )
    end

    test "a rule gate without a rule" do
      refused_gate(@rule, [rule: nil], "gate g: a rule gate needs rule: [all: conditions]")
    end

    test "a rule that is not all-of at least one condition" do
      for rule <- ["[any: [{:same, :a, :b}]]", "[all: []]", "{:same, :a, :b}"] do
        refused_gate(@rule, [rule: rule], "gate g: rule must be [all: conditions]")
      end
    end

    test "a rule condition of an unknown form" do
      for condition <- ["{:above, :a, 1}", "{:equals, :a, nil}", "{:same, :a, \"b\"}"] do
        refused_gate(
          @rule,
          [rule: "[all: [#{condition}]]"],
          "gate g: rule condition #{condition} is not {:equals, field, value} or {:same, field, other}"
        )
      end
    end

    test "a rule that reads a field outside its evidence" do
      refused_gate(
        @rule,
        [rule: "[all: [{:same, :a, :c}]]"],
        "gate g: rule reads c, which is not in its evidence"
      )
    end

    test "a gate defined twice" do
      refused(gate_source(@rule) <> gate_source(@rule), 9, "gate g is defined twice")
    end

    test "a gate name Rela does not accept" do
      refused(String.replace(gate_source(@rule), ":g,", ":G,"), 1, "G is not a valid name")
    end

    test "a pass that does not map every result" do
      refused(
        """
        subflow :f, subject: :t do
          run_as "system:x"
          start :create
          initial :a
          state :a do
            pass :worker, on: [delivered: :b]
          end
          final :b
        end
        """,
        6,
        "state a: pass_result can give failed, which no branch takes"
      )
    end

    test "an effect that maps a result it never gives" do
      refused(
        """
        subflow :f, subject: :t do
          run_as "system:x"
          start :create
          initial :a
          state :a do
            effect :call, on: [done: :b, refused: :b, late: :b]
          end
          final :b
        end
        """,
        6,
        "state a: effect_result never gives late"
      )
    end

    test "two mechanisms in one state" do
      refused(
        gated("""
          state :a do
            pass :worker, on: [delivered: :b, failed: :b]
            gate :size_limit, fits: :b, person: :b
          end
          final :b
        """),
        7,
        "state a: has a second mechanism (gate)"
      )
    end

    test "a field set twice in one state" do
      refused(
        """
        subflow :f, subject: :t do
          run_as "system:x"
          start :create
          initial :a
          state :a do
            pass :worker, on: [delivered: :b, failed: :b]
            set pass_result: :ready
          end
          final :b
        end
        """,
        7,
        "state a: sets pass_result twice"
      )
    end

    test "no initial state" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          final :b
        end
        """,
        1,
        "subflow f: has no initial state"
      )
    end

    test "an initial state that does not exist" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :nowhere
          final :b
        end
        """,
        3,
        "subflow f: initial names unknown state nowhere"
      )
    end

    test "an initial state that is final" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :b
          final :b
        end
        """,
        3,
        "subflow f: initial b is final"
      )
    end

    test "no start trigger" do
      refused(
        """
        subflow :f, subject: :t do
          initial :a
          state :a do
            timer :t, "1d", to: :b
          end
          final :b
        end
        """,
        1,
        "subflow f: has no start trigger"
      )
    end

    test "outputs without run_as" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            set ready: true
            timer :t, "1d", to: :b
          end
          final :b
        end
        """,
        4,
        "state a has outputs, so the subflow needs run_as"
      )
    end

    test "a name Rela does not accept" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            timer :t, "1d", to: :Done
          end
          final :Done
        end
        """,
        7,
        "state name Done is not a valid name"
      )
    end

    test "more than eight timers" do
      timers = Enum.map_join(1..9, "\n", &"    timer :t#{&1}, \"1d\", to: :b")

      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
        #{timers}
          end
          final :b
        end
        """,
        4,
        "state a: has more than 8 timers"
      )
    end

    test "a branch to a state that does not exist" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            branch to: :nowhere, when: "entity.done == true"
            timer :t, "1d", to: :b
          end
          final :b
        end
        """,
        4,
        "state a: leads to unknown state nowhere"
      )
    end

    test "a branch that takes every change, before another" do
      refused(
        """
        subflow :f, subject: :t do
          start :create
          initial :a
          state :a do
            branch to: :b
            branch to: :c, when: "entity.done == true"
          end
          final :b
          final :c
        end
        """,
        4,
        "state a: the branch to b takes every change"
      )
    end

    test "a gate that is not defined" do
      refused(
        gated("""
          state :a do
            gate :missing, ok: :b
          end
          final :b
        """),
        6,
        "state a: names gate missing, which is not defined"
      )
    end

    test "a state outside a subflow" do
      refused("state :a do\nend\n", 1, "state belongs inside a subflow")
    end

    test "every mistake is reported, the first at its line" do
      error =
        refused(
          """
          subflow :f, subject: :t do
            start :create
            initial :a
            state :a do
              branch to: :nowhere, when: "entity.done == true"
            end
            state :orphan do
              timer :t, "1d", to: :a
            end
          end
          """,
          4,
          "state a: leads to unknown state nowhere"
        )

      assert error.description =~ "line 8: subflow f: unreachable state orphan"
    end
  end

  defp state(name), do: Enum.find(hd(Example.__flows__()).states, &(&1.name == name))
  defp branches(state), do: Enum.map(state.branches, &{&1.to, &1.roles, &1.when})

  defp gated(states) do
    """
    subflow :f, subject: :t do
      run_as "system:x"
      start :create
      initial :a
    #{states}end
    """
  end

  # A gate fixture: a valid gate's options as source, one of them changed or (nil) dropped.
  defp gate_source(base, changes \\ []) do
    opts =
      Enum.reduce(changes, base, fn
        {k, nil}, acc -> Keyword.delete(acc, k)
        {k, v}, acc -> Keyword.put(acc, k, v)
      end)

    "defgate :g,\n" <> Enum.map_join(opts, ",\n", fn {k, v} -> "  #{k}: #{v}" end) <> "\n"
  end

  # The change breaks exactly the one rule the message names.
  defp refused_gate(base, changes, message) do
    error = refused(gate_source(base, changes), 1, message)
    refute error.description =~ "\n  line ", "more than one problem: #{error.description}"
  end

  # The body sits at line 1 of the fixture file; `use` is on the same line as defmodule.
  defp compile!(body) do
    module = :"Elixir.AtlasFlowGenerator.Fixture#{System.unique_integer([:positive])}"
    file = "fixture_#{System.unique_integer([:positive])}.ex"

    src =
      "defmodule #{inspect(module)} do use AtlasFlowGenerator.Schema, " <>
        "gates: AtlasFlowGenerator.Example.Gates\n#{body}end\n"

    [{^module, _}] = Code.compile_string(src, file)
    module
  end

  defp refused(body, line, message) do
    error = assert_raise CompileError, fn -> compile!(body) end
    assert error.description =~ message
    assert error.file =~ ~r/fixture_\d+\.ex$/
    # Fixture line N is file line N + 1 (the defmodule line comes first).
    assert error.line == line + 1,
           "expected line #{line + 1}, got #{error.line}: #{error.description}"

    error
  end
end
