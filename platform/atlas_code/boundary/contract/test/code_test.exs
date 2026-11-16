defmodule AtlasCodeBoundary.CodeTest do
  use ExUnit.Case, async: true

  alias AtlasCodeBoundary.Code

  # Flow Engine plan §5 C1.0, written out by hand: a change to the contract's shape must
  # change this file too.

  defp f(name, type, required \\ false), do: %{name: name, type: type, required: required}

  defp expected_models do
    %{
      snapshot_repository: [
        f(:repository, :string, true),
        f(:revision, :string, true),
        f(:path, :string, true)
      ],
      unsupported_entry: [
        f(:repository, :string, true),
        f(:path, :string, true),
        f(
          :reason,
          {:enum, [:unsafe_path, :symlink_target, :submodule, :unsupported_mode]},
          true
        )
      ],
      problem: [
        f(:message, :string, true),
        f(:repository, :string),
        f(:reference, :string),
        f(:revision, :string),
        f(:path, :string),
        f(:paths, {:list, :string}),
        f(:entries, {:list, :unsupported_entry})
      ],
      resolve_reference_input: [f(:repository, :string, true), f(:reference, :string, true)],
      create_snapshot_input: [f(:repositories, {:list, :snapshot_repository}, true)],
      resolved_reference: [
        f(:repository, :string, true),
        f(:reference, :string, true),
        f(:revision, :string, true)
      ],
      snapshot: [
        f(:snapshot_id, :string, true),
        f(:repositories, {:list, :snapshot_repository}, true)
      ]
    }
  end

  @capabilities [
    resolve_reference:
      {:snapshot, :resolve_reference_input,
       [
         resolved: :resolved_reference,
         invalid_request: :problem,
         forbidden: :problem,
         unknown_reference: :problem,
         provider_unavailable: :problem
       ]},
    create_snapshot:
      {:snapshot, :create_snapshot_input,
       [
         created: :snapshot,
         invalid_request: :problem,
         forbidden: :problem,
         unknown_revision: :problem,
         repository_mismatch: :problem,
         not_found: :problem,
         unsupported_content: :problem,
         provider_unavailable: :problem
       ]}
  ]

  defp schema, do: Code.__schema__()
  defp models, do: Map.new(schema().models, &{&1.name, &1.fields})
  defp outcomes(capability), do: for(o <- capability.outcomes, do: {o.name, o.model})

  test "declares exactly its models, each field with its type and requiredness" do
    actual = models()
    assert Enum.sort(Map.keys(actual)) == Enum.sort(Map.keys(expected_models()))
    for {name, fields} <- expected_models(), do: assert(actual[name] == fields, "model #{name}")
  end

  test "starts with exactly resolve_reference and create_snapshot" do
    actual = for c <- schema().capabilities, do: {c.name, {c.right, c.input, outcomes(c)}}
    assert actual == @capabilities
  end

  test "refusals are outcomes; the facade answers malformed input itself" do
    assert schema().invalid_input == nil
  end

  test "the contract stays in Code's vocabulary: no transport, no Git internals" do
    atoms =
      for {model, fields} <- models(), field <- fields, atom <- [model, field.name], do: atom

    atoms = atoms ++ for c <- schema().capabilities, {n, _} <- outcomes(c), do: n
    forbidden = ~r/http|status|json|token|header|commit|remote|url|branch|sha\b|oid|git/i
    for atom <- Enum.uniq(atoms), do: refute(Atom.to_string(atom) =~ forbidden, "#{atom}")
  end
end
