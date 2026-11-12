defmodule Model.GatesTest do
  use ExUnit.Case, async: true

  test "the gates of the composition, in the order of its concepts" do
    assert Enum.map(Model.AtlasEyra.__rela__(:gates), & &1.name) ==
             [:accept_decision, :delivery_evidence, :review, :integrate, :design]
  end

  # Named by the pull request's integrate effect, applied by hand until Code applies it:
  # integrate only when CI is green on the exact head being
  # integrated and the fingerprint approved at review is the one sent at integration.
  test "integrate is a rule gate over named evidence; what it cannot settle goes to a person" do
    gate = Enum.find(Model.AtlasEyra.__rela__(:gates), &(&1.name == :integrate))

    assert Map.drop(gate, [:file]) == %{
             name: :integrate,
             version: 1,
             flavor: :rule,
             purpose: :flow,
             advice: nil,
             evidence: [
               :ci_conclusion,
               :ci_head,
               :integration_head,
               :review_fingerprint,
               :integration_fingerprint
             ],
             rule: [
               all: [
                 {:equals, :ci_conclusion, "success"},
                 {:same, :ci_head, :integration_head},
                 {:same, :review_fingerprint, :integration_fingerprint}
               ]
             ],
             verdicts: [:integrate, :refuse, :person],
             person: :person,
             decide: [
               pass: :integrate,
               changes_required: :refuse,
               uncertain: :person,
               error: :person
             ],
             policy: []
           }
  end

  test "no subflow names integrate yet" do
    named =
      for f <- Model.Issue.__flows__(),
          %{mechanism: {:gate, %{gate: g}}} <- f.states,
          do: g

    refute :integrate in named
  end

  # Gates' evaluate task, on the model's decider gate (the platform's tests have none).
  test "--from-subject derives its request through Control, including with --no-record" do
    import ExUnit.CaptureIO
    # As the umbrella configures Gates: its verdicts are facts of the model's gate_verdict.
    Application.put_env(:atlas_gates, :verdict_kind, "gate_verdict")

    {name, gate} =
      Enum.find(AtlasGates.Definitions.gates(), fn {_, gate} -> gate["purpose"] == "decider" end)

    values = Map.new(gate["fingerprint"]["fields"], &{&1, "sample"})
    subject = %{"key" => "C-7", "values" => values, "links" => %{}}
    path = Path.join(System.tmp_dir!(), "gates-subject-#{System.unique_integer([:positive])}")
    # The executable answers only the read command. A write would fail the test.
    File.write!(
      path,
      "#!/bin/sh\n[ \"$1\" = facts ] || exit 77\nif [ \"$2\" = _ ]; then\ncat <<'FACT'\n#{JSON.encode!(%{"fact" => subject})}\nFACT\nelse\nprintf '%s\\n' '{\"facts\":[]}'\nfi\n"
    )

    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm!(path) end)

    output =
      capture_io(fn ->
        Mix.Tasks.Atlas.Gates.Evaluate.run(
          ~w(--gate #{name} --from-subject C-7 --env test --atlas #{path} --json --no-record)
        )
      end)

    result = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
    assert result["verdict"] == gate["decide"]["advise"]
    assert result["unsettled"] == nil
    assert result["recorded"] == nil
  end
end
