defmodule RelaDSL.SupervisionTest do
  @moduledoc """
  Supervision (work acquisition design 2026-11-17, §5.6–5.8): a subflow declares its supervised spans
  (`supervise`); the composition maps them, with the relation to a run's human
  supervisor and the pickup and hand-over input fields, into the run mapping, beside the
  subflows so no digest changes; the start page offers the two supervision entries. The
  tests assert structure: what is refused, and the shape of what is compiled.
  """
  use ExUnit.Case, async: true

  alias RelaDSL.{Atlas, DefinitionDigest}

  # -- A subflow's spans (RelaDSL.Schema) ---------------------------------------------

  # The body sits at line 1 of the fixture file, after `defmodule … do use …`.
  defp compile!(body) do
    module = :"Elixir.RelaDSL.SupervisionFixture#{System.unique_integer([:positive])}"
    file = "supervision_#{System.unique_integer([:positive])}.ex"

    src =
      "defmodule #{inspect(module)} do use RelaDSL.Schema, " <>
        "gates: RelaDSL.Example.Gates\n#{body}end\n"

    [{^module, _}] = Code.compile_string(src, file)
    module
  end

  defp refused(body, message) do
    error = assert_raise CompileError, fn -> compile!(body) end
    assert error.description =~ message
    error
  end

  # A gate whose person verdict leads to `decide`; the `spans` vary.
  defp gated(spans) do
    """
    subflow :f, subject: :t do
      owner default: {:team, :desk}
      run_as "system:x"
      start :create
      initial :a
      #{spans}
      state :a do
        timer :t, "1d", to: :check
      end
      state :check do
        gate :size_limit, fits: :b, person: :decide
      end
      state :decide do
        timer :t, "1d", to: :b
      end
      final :b
    end
    """
  end

  test "a span is plain data of its subflow, in the order written" do
    [flow] =
      compile!(gated("supervise :work, label: \"Work\", states: [:a, :check, :decide]\n")).__flows__()

    assert [%{name: :work, label: "Work", states: [:a, :check, :decide], with: []}] = flow.spans

    [plain] = compile!(gated("")).__flows__()
    assert plain.spans == []
  end

  test "a span sits beside the subflow's definition: it changes no digest" do
    [spanned] = compile!(gated("supervise :work, states: [:a, :check, :decide]\n")).__flows__()
    [plain] = compile!(gated("")).__flows__()
    gates = RelaDSL.Example.Gates.__gates__()
    definitions = &Atlas.definitions([&1], gates)

    assert DefinitionDigest.of(definitions.(spanned)["f"]) ==
             DefinitionDigest.of(definitions.(plain)["f"])

    refute Atlas.flows_json([spanned], gates, String.duplicate("0", 64)) =~ "\"spans\""
  end

  test "a span's shape is checked" do
    refused(gated("supervise :work, states: []\n"), "supervise work: needs states:")

    refused(
      gated("supervise :work, states: [:a], colour: :red\n"),
      "supervise work: knows no colour"
    )

    refused(gated("supervise :Work, states: [:a]\n"), "is not a valid name")
    refused(gated("supervise :work, states: [:a], label: 3\n"), "label: is a text")
    refused(gated("supervise :work, [:a]\n"), "takes states:, label: and with:")
  end

  test "a span names known states that are not final, each in one span, once" do
    refused(gated("supervise :work, states: [:z]\n"), "supervise work: names unknown state z")
    refused(gated("supervise :work, states: [:a, :b]\n"), "state b is final")

    refused(
      gated("supervise :work, states: [:a]\nsupervise :more, states: [:a]\n"),
      "state a lies in more than one span"
    )

    refused(
      gated("supervise :work, states: [:a]\nsupervise :work, states: [:check]\n"),
      "supervise work is given more than once"
    )
  end

  test "S3: a gate's person outcome lies in a span, or names its own owner" do
    # Outside every span: refused, at the gate's state.
    error = refused(gated("supervise :work, states: [:a, :check]\n"), "gate size_limit's person")
    assert error.description =~ "decide"

    # Inside a span: its escalation goes to the human supervisor.
    assert compile!(gated("supervise :work, states: [:a, :check, :decide]\n"))

    # Its own owner, such as the configured decider: the fallback is written.
    assert compile!(decider_owned())

    # A subflow without spans keeps today's rule: the decider is the fallback.
    assert compile!(gated(""))
  end

  # The person outcome outside the span, in a state that names the decider as its owner.
  defp decider_owned do
    """
    subflow :f, subject: :t do
      owner default: {:team, :desk}
      run_as "system:x"
      start :create
      initial :a
      supervise :work, states: [:a, :check]
      state :a do
        timer :t, "1d", to: :check
      end
      state :check do
        gate :size_limit, fits: :b, person: :decide
      end
      state :decide do
        owner default: {:person, config: :decider}
        timer :t, "1d", to: :b
      end
      final :b
    end
    """
  end

  # -- A composition's supervision ------------------------------------------------------

  defp model(parts) do
    p = "RelaDSL.SupervisionTest.M#{System.unique_integer([:positive])}"
    get = &Keyword.get(parts, &1, "")

    source = """
    defmodule #{p}.Desk do
      use RelaDSL
      type :op, values: [:choice, :pickup, :hand_over]
      entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
        field :name, :string
      end
      entity :run, label: "Run", plural: "runs", id_type: :manual do
        field :flow, :string
        field :state, :string
      end
      entity :input, label: "Input", plural: "inputs", id_type: :manual do
        field :run, :string
        field :operation, #{Keyword.get(parts, :operation_type, ":op")}
        field :hand_to, :string
      end
      entity :case, label: "Case", plural: "cases", id_type: :manual do
        field :title, :string
      end
      entity :part, label: "Part", plural: "parts", id_type: :manual do
        field :title, :string
      end
      relation :part_of, label: "part of", from: [:part], to: [:case], max_outgoing: 1
      relation :watched_by, label: "watched by", from: [:run], to: [:clerk]#{Keyword.get(parts, :max, ", max_outgoing: 1")}
      flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input#{Keyword.get(parts, :supervision, ", supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]")})
      subflow :case, subject: :case do
        owner default: {:clerk, :desk}
        start :create
        initial :open
        #{Keyword.get(parts, :span, "supervise :work, label: \"Work\", states: [:open], with: [:part]")}
        state :open do
          timer :t, "1d", to: :done
        end
        final :done
      end
      subflow :part, subject: :part do
        owner default: {:clerk, :desk}
        start :create
        initial :open
        state :open do
          timer :t, "1d", to: :done
        end
        final :done
      end
      #{get.(:concept)}
    end
    defmodule #{p}.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Desk]
    end
    defmodule #{p}.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"
      modules [#{p}.Mod]
      #{get.(:composition)}
      defcomposition :c do
        subflows([#{p}.Desk])
      end
    end
    """

    modules = Code.compile_string(source, "model.exs")
    {comp, _} = Enum.find(modules, fn {m, _} -> String.ends_with?(inspect(m), ".Comp") end)
    comp
  end

  defp model_refused(parts, message) do
    error = assert_raise CompileError, fn -> model(parts) end
    assert error.description =~ message
  end

  @entries """
  start_page(
    open_for_you: [title: "Open", count: "{count} open", empty: "None"],
    supervised_by_you: [title: "Yours", count: "{count} yours", empty: "None"]
  )
  """

  test "the run mapping holds the relation, the input fields and every subflow's spans" do
    comp = model([])

    assert %{
             "version" => 1,
             "relation" => "watched_by",
             "inputs" => %{
               "operation" => "operation",
               "hand_to" => "hand_to",
               "operations" => ["pickup", "hand_over"]
             },
             "spans" => %{
               "case" => [
                 %{"name" => "work", "label" => "Work", "states" => ["open"], "with" => ["part"]}
               ]
             }
           } = comp.supervision()

    refute Map.has_key?(comp.supervision()["spans"], "part")
    # The input fields are mapped as every other field of an input.
    assert %{"operation" => "operation", "hand_to" => "hand_to"} = comp.runs()["inputs"]["fields"]
  end

  test "without supervision: declared, nothing is supervised, and no span may be" do
    comp = model(supervision: "", span: "")
    assert comp.supervision() == nil
    model_refused([supervision: ""], "supervise work: flow_runtime declares no supervision:")
  end

  test "supervision names a relation from a run to one supervisor, and the input fields" do
    model_refused([max: ""], "relation watched_by must lead from run to one supervisor")

    model_refused(
      [operation_type: ":string"],
      "input.operation must be a field whose type has the values pickup and hand_over"
    )

    model_refused(
      [
        supervision:
          ", supervision: [relation: :watched_by, operation: :operation, hand_to: :gone]"
      ],
      "input.gone must be a field"
    )

    model_refused(
      [supervision: ", supervision: [relation: :watched_by, colour: :red]"],
      "unknown keys colour"
    )
  end

  test "a span's with: names a running subflow whose subject points at the span's subject" do
    model_refused(
      [span: "supervise :work, states: [:open], with: [:ghost]"],
      "with: ghost is no subflow the composition runs"
    )

    model_refused(
      [span: "supervise :work, states: [:open], with: [:case]"],
      "with: case runs on case, which points at no case"
    )
  end

  test "the start page's supervision entries, from the spans and the relation" do
    comp = model(composition: @entries)

    assert %{
             open_for_you: %{
               title: "Open",
               count: "{count} open",
               empty: "None",
               spans: [
                 %{
                   subflow: "case",
                   subject: nil,
                   span: "work",
                   label: "Work",
                   states: ["open"],
                   with: ["part"]
                 }
               ]
             },
             supervised_by_you: %{relation: "watched_by", title: "Yours"}
           } = comp.start_page()

    plain = model([])
    assert %{open_for_you: nil, supervised_by_you: nil} = plain.start_page()
  end

  test "the start page's supervision entries need declared supervision and their keys" do
    model_refused(
      [supervision: "", span: "", composition: @entries],
      "start_page open_for_you: no flow_runtime declares supervision:"
    )

    model_refused(
      [composition: "start_page(open_for_you: [title: \"Open\", colour: \"red\"])"],
      "start.open_for_you: unknown keys colour"
    )
  end
end
