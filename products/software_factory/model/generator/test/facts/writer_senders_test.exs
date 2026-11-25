defmodule RelaDSL.Facts.WriterSendersTest do
  @moduledoc """
  `flow_runtime`'s `senders:` (M3 P5): further Bus endpoints of the same run writer, per
  kind, for that kind's field guard only. The run kind's guard keeps the single sender;
  a kind `senders:` does not name keeps today's guard; the writer's `by` never widens.
  Without `senders:` the run mapping is what it was. The tests assert structure: `:ok` or
  `{:refused, _}`, the rules' shape, problem tags and bytes; never a reason's text.
  """
  use ExUnit.Case, async: true

  alias RelaDSL.{Office, Problem, Project}
  alias RelaDSL.Description.{Build, Plain}
  alias RelaDSL.Facts.Writes

  @writer %{"sender" => "flow", "by" => "flow"}
  @senders %{"job" => ["flow/leaser", "flow/receiver"], "step" => ["flow/receiver"]}

  # Three kinds whose fields only the run writer sets, and the run kind (no such field).
  defp description(writer) do
    flow = %{"type" => "string", "set_by" => ["flow"]}

    %{
      "entities" => %{
        "job" => %{"properties" => %{"lease" => flow, "note" => %{"type" => "string"}}},
        "step" => %{"properties" => %{"lease" => flow}},
        "other" => %{"properties" => %{"lease" => flow}},
        "cursor" => %{"properties" => %{"state" => %{"type" => "string"}}}
      },
      "flow_runtime" => %{"kind" => "cursor", "writer" => writer}
    }
  end

  defp widened, do: description(Map.put(@writer, "senders", @senders))

  defp env(by, sender), do: %{"by" => by, "writer" => by, "sender" => sender}

  defp write(d, kind, values, env),
    do: Writes.check_rules(Writes.rules(d, kind), "change", "X-1", nil, values, %{}, env)

  describe "rules/2" do
    test "a named kind's field guard holds the writer and that kind's senders only" do
      d = widened()

      assert Writes.rules(d, "job")["field_writers"] == %{
               "lease" => Map.put(@writer, "senders", @senders["job"])
             }

      assert Writes.rules(d, "step")["field_writers"] == %{
               "lease" => Map.put(@writer, "senders", @senders["step"])
             }

      # A kind senders: does not name, and the run kind's own guard: the writer, exactly.
      assert Writes.rules(d, "other")["field_writers"] == %{"lease" => @writer}
      assert Writes.rules(d, "cursor")["machine_writer"] == @writer
      refute Map.has_key?(Writes.rules(d, "cursor"), "field_writers")
    end

    test "without senders the rules are what they were" do
      d = description(@writer)

      for kind <- ~w(job step other),
          do: assert(Writes.rules(d, kind)["field_writers"] == %{"lease" => @writer})

      assert Writes.rules(d, "cursor")["machine_writer"] == @writer
    end
  end

  describe "the field guard" do
    test "accepts the writer from its sender or from one of the kind's senders" do
      d = widened()

      for sender <- ["flow", "flow/leaser", "flow/receiver"],
          do: assert(write(d, "job", %{"lease" => "L"}, env("flow", sender)) == :ok, sender)

      assert write(d, "step", %{"lease" => "L"}, env("flow", "flow/receiver")) == :ok
      assert write(d, "step", %{"lease" => "L"}, env("flow", "flow")) == :ok
    end

    test "refuses another sender, another by, and a sender listed only for another kind" do
      d = widened()

      for e <- [
            env("flow", "client"),
            env("someone", "flow/leaser"),
            env("someone", "flow"),
            %{"by" => "flow", "sender" => "flow/leaser"},
            %{}
          ],
          do: assert({:refused, _} = write(d, "job", %{"lease" => "L"}, e), inspect(e))

      assert {:refused, _} = write(d, "step", %{"lease" => "L"}, env("flow", "flow/leaser"))

      for sender <- ["flow/leaser", "flow/receiver"],
          do: assert({:refused, _} = write(d, "other", %{"lease" => "L"}, env("flow", sender)))
    end

    test "a field no guard holds is anyone's, as before" do
      assert write(widened(), "job", %{"note" => "n"}, env("someone", "client")) == :ok
    end
  end

  test "the run kind's guard keeps the single sender, whatever senders: lists" do
    d = widened()

    for sender <- ["flow/leaser", "flow/receiver"], op <- ["create", "change", "delete"] do
      assert {:refused, _} =
               Writes.check_rules(
                 Writes.rules(d, "cursor"),
                 op,
                 "C-1",
                 nil,
                 %{},
                 %{},
                 env("flow", sender)
               )
    end

    assert :ok = write(d, "cursor", %{"state" => "a"}, env("flow", "flow"))
  end

  # -- The declaration (RelaDSL.Description.Build) ----------------------------------------

  # A concept with the run kinds, one kind whose field only the writer sets, and
  # `flow_runtime` with `senders` (source text after `inputs: :input`).
  defp concept(p, senders) do
    """
    defmodule #{p}.Run do
      use RelaDSL
      entity :run, label: "Run", plural: "runs", id_type: :manual do
        field :flow, :string
        field :state, :string
      end
      entity :input, label: "Input", plural: "inputs", id_type: :manual do
        field :run, :string
      end
      entity :job, label: "Job", plural: "jobs", id_type: :manual do
        field :lease, :string, set_by: [:flow]
      end
      flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input#{senders})
    end
    """
  end

  defp prefix, do: "RelaDSL.WriterSendersTest.M#{System.unique_integer([:positive])}"

  # The concept in a composition of its own; raises CompileError on any problem.
  defp compile(senders) do
    p = prefix()

    source =
      concept(p, senders) <>
        """
        defmodule #{p}.Mod do
          use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Run]
        end
        defmodule #{p}.Comp do
          use RelaDSL.Composition, name: "c"
          schema version: "1.0"
          modules [#{p}.Mod]
          defcomposition :c do
            subflows([])
          end
        end
        """

    modules = Code.compile_string(source, "senders.exs")
    Enum.find_value(modules, fn {m, _} -> String.ends_with?(inspect(m), ".Comp") && m end)
  end

  # What the composition's shape check finds on the concept's items: tags and names.
  defp shape(senders) do
    p = prefix()
    [{run, _}] = Code.compile_string(concept(p, senders), "senders_concept.exs")

    for {_, _, problem} <- Build.shape_problems(run.__rela__(:concept).items),
        do: Problem.key(problem)
  end

  test "the run mapping's writer carries senders: per kind, as declared" do
    comp = compile(~s|, senders: [job: [:"flow/leaser", :"flow/receiver"]]|)

    assert Plain.unorder(comp.__rela__(:description).flow_runtime)["flow_runtime"]["writer"] ==
             Map.put(@writer, "senders", %{"job" => ["flow/leaser", "flow/receiver"]})
  end

  test "senders: naming no kind, or not shaped as kinds with senders, fails the build" do
    assert_raise CompileError, fn -> compile(~s|, senders: [ghost: [:"flow/leaser"]]|) end

    assert shape(~s|, senders: [ghost: [:"flow/leaser"]]|) == [
             {:not_a_kind, ["flow_runtime", "senders", "ghost"]}
           ]

    for bad <- [~s|, senders: [job: []]|, ~s|, senders: [job: "flow/leaser"]|, ", senders: :job"] do
      assert shape(bad) == [{:flow_runtime_senders, []}], bad
      assert_raise CompileError, fn -> compile(bad) end
    end

    assert shape(", senders: [job: [:a], job: [:b]]") == [
             {:given_twice, ["flow_runtime", "senders", "job"]}
           ]

    assert_raise CompileError, fn -> compile(", senders: [job: [:a], job: [:b]]") end
    assert shape(~s|, senders: [job: [:"flow/leaser"]]|) == []
  end

  test "without senders: the run mapping's writer is the plain one" do
    comp = compile("")

    assert Plain.unorder(comp.__rela__(:description).flow_runtime)["flow_runtime"]["writer"] ==
             @writer

    # The neutral composition declares no senders.
    files = Project.files(Office.__rela__(:description), "app:\n  name: Office\n", "flows: {}\n")
    {_, body} = List.keyfind(files, "flow-runtime.json", 0)
    assert JSON.decode!(body)["flow_runtime"]["writer"] == @writer
  end
end
