defmodule AtlasFlowGenerator.RelaTest do
  use ExUnit.Case, async: true

  alias AtlasFlowGenerator.{Example, Rela}

  # Every key of Rela 26.11.2's flows.yaml (rela refuses others, at file, flow and state
  # level). The writer may emit no key outside this list.
  @rela_keys ~w(flows label subject run_as per_subject start on when permission every
                initial states final status waiting_for outputs set properties create
                type relate change to roles after period since)

  test "the example's flows.yaml, the same as the golden file (the style is pinned)" do
    assert Rela.flows_yaml(Example.__flows__()) == File.read!("test/golden/example.flows.yaml")
  end

  test "only Rela's keys are written; the owner, channel, mechanisms and presentation stay out" do
    yaml = Rela.flows_yaml(Example.__flows__())
    keys = ~r/(?:^\s*-?\s*|[{,]\s*)([a-z_]+):/m |> Regex.scan(yaml) |> Enum.map(&List.last/1)

    # States, flows, timers and set properties are named by the definition, not by Rela.
    named =
      ~w(letter draft proofread post sent stuck answered dropped slow) ++
        ~w(pass_result gate_result post_result choice archived title)

    assert Enum.uniq(keys) -- (@rela_keys ++ named) == []

    for word <- ~w(owner channel mechanism profile held_by mail post_room retried_by notes),
        do: refute(yaml =~ word)

    refute yaml =~ "Decide on it"
  end

  test "labels stay plain where that is safe, and are quoted where YAML would misread them" do
    [flow] = Example.__flows__()
    label = fn l -> Rela.flows_yaml([%{flow | label: l}]) |> String.split("\n") |> Enum.at(2) end

    assert label.("The owner's turn") == "    label: The owner's turn"
    assert label.("yes") == ~s(    label: "yes")
    assert label.("a: b") == ~s(    label: "a: b")
    assert label.("x #1") == ~s(    label: "x #1")
    # A comma is plain as a block value (a flow's or state's label), quoted in a branch.
    assert label.("Build, test and accept") == "    label: Build, test and accept"

    [draft | rest] = flow.states
    [branch | others] = draft.branches
    draft = %{draft | branches: [%{branch | label: "Late, again"} | others]}
    yaml = Rela.flows_yaml([%{flow | states: [draft | rest]}])
    assert yaml =~ ~s(label: "Late, again", when:)
  end

  test "the check project has each subject with what its subflows read and set, and their roles" do
    [{"schema.yaml", schema}, {"acl.yaml", acl}] = Rela.check_project(Example.__flows__())

    assert schema =~ "  letter:\n"

    for p <- ~w(kind pass_result gate_result post_result reply choice),
        do: assert(schema =~ "      #{p}: {type: string}\n")

    assert schema =~ "      urgent: {type: boolean}\n"
    assert schema =~ "      archived: {type: boolean}\n"
    # A created type gets generated ids and a relation back to the subject.
    assert schema =~ ~r/  receipt:\n.*\n.*\n    id_type: short\n/
    assert schema =~ "  receipt_of:\n    from: [receipt]\n    to: [letter]\n"

    for role <- ~w(flow-runner atlas-flow editor admin), do: assert(acl =~ "  #{role}:\n")
    assert acl =~ "  system:post: flow-runner\n"
  end

  test "a diagram is the Mermaid Rela draws, in a fenced block, with the flow version" do
    page =
      Rela.diagram(%{
        "name" => "letter",
        "label" => "Letter",
        "version" => "abc123",
        "mermaid" => "stateDiagram-v2\n    [*] --> s0\n"
      })

    assert page =~ "abc123"
    assert page =~ "\n```mermaid\nstateDiagram-v2\n    [*] --> s0\n```\n"
  end

  test "a binary that is not the pinned rela is refused before anything runs", %{} do
    assert {:error, "expected rela version 26.11.2 at /no/such/rela, got " <> _} =
             Rela.check("/no/such/rela", "", Example.__flows__())
  end

  describe "with the pinned rela" do
    @describetag :rela
    setup do: %{bin: Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela")}

    test "the example is valid in its check project and Rela draws it", %{bin: bin} do
      flows = Example.__flows__()

      assert {:ok, [%{"name" => "letter", "version" => v, "mermaid" => m}]} =
               Rela.check(bin, Rela.flows_yaml(flows), flows)

      assert v =~ ~r/^[0-9a-f]{16}$/
      assert m =~ "stateDiagram-v2"
    end

    test "what Rela refuses comes back in Rela's words", %{bin: bin} do
      [flow] = flows = Example.__flows__()
      yaml = String.replace(Rela.flows_yaml(flows), "period: 1d", "period: soon")

      assert {:error, "rela flow validate refused flows.yaml:\n" <> why} =
               Rela.check(bin, yaml, [flow])

      assert why =~ "slow"
      refute why =~ "level=WARN"
    end
  end
end
