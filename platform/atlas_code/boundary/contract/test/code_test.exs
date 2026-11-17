defmodule AtlasCodeBoundary.CodeTest do
  use ExUnit.Case, async: true

  alias AtlasCodeBoundary.Code

  # Flow Engine plan §5 C1.0, C1a and C1b, written out by hand: a change to the contract's shape must
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
      change_entry: [
        f(:path, :string, true),
        f(:op, {:enum, [:write, :delete]}, true),
        f(:kind, {:enum, [:file, :symlink]}),
        f(:mode, :string),
        f(:size, :integer),
        f(:sha256, :string),
        f(:target, :string)
      ],
      problem: [
        f(:message, :string, true),
        f(:repository, :string),
        f(:reference, :string),
        f(:revision, :string),
        f(:path, :string),
        f(:paths, {:list, :string}),
        f(:entries, {:list, :unsupported_entry}),
        f(:snapshot_id, :string),
        f(:sha256, :string),
        f(:successor, :string),
        f(:change_id, :string),
        f(:base_revision, :string),
        f(:entry, :change_entry),
        f(:missing, {:list, :string}),
        f(:review_id, :string),
        f(:update_id, :string),
        f(:fingerprint, :string),
        f(:phase, :string),
        f(:current, :string)
      ],
      resolve_reference_input: [f(:repository, :string, true), f(:reference, :string, true)],
      create_snapshot_input: [f(:repositories, {:list, :snapshot_repository}, true)],
      get_manifest_input: [f(:snapshot_id, :string, true)],
      get_blob_input: [f(:snapshot_id, :string, true), f(:sha256, :string, true)],
      create_change_input: [
        f(:change_id, :string, true),
        f(:snapshot_id, :string, true),
        f(:repository, :string, true),
        f(:base_revision, :string, true),
        f(:entries, {:list, :change_entry}, true)
      ],
      # A blob's bytes as one value: the upload is whole, as the HTTP body is.
      put_change_blob_input: [
        f(:change_id, :string, true),
        f(:sha256, :string, true),
        f(:content, :string, true)
      ],
      seal_change_input: [f(:change_id, :string, true)],
      create_review_input: [
        f(:review_id, :string, true),
        f(:change_id, :string, true),
        f(:target, :string, true),
        f(:title, :string, true),
        f(:body, :string, true),
        f(:fingerprint, :string),
        f(:draft, :boolean)
      ],
      update_review_input: [
        f(:update_id, :string, true),
        f(:review_id, :string, true),
        f(:change_id, :string, true),
        f(:revision, :string, true),
        f(:fingerprint, :string, true)
      ],
      mark_ready_input: [f(:review_id, :string, true)],
      review_report_input: [f(:review_id, :string, true)],
      review_ready: [
        f(:review_id, :string, true),
        f(:revision, :string, true),
        f(:link, :string)
      ],
      review_report: [
        f(:review_id, :string, true),
        f(:revision, :string, true),
        f(:state, {:enum, [:open, :merged, :closed]}, true),
        f(:draft, :boolean, true),
        f(:at_revision, :boolean, true),
        f(:ci, {:enum, [:success, :failure, :pending, :none]}, true),
        f(:failing, {:list, :string}),
        f(:approvals, {:list, :string}, true),
        f(:changes_requested, {:list, :string}, true),
        f(:mergeable, :boolean),
        f(:behind_base, :boolean),
        f(:link, :string)
      ],
      resolved_reference: [
        f(:repository, :string, true),
        f(:reference, :string, true),
        f(:revision, :string, true)
      ],
      snapshot: [
        f(:snapshot_id, :string, true),
        f(:repositories, {:list, :snapshot_repository}, true)
      ],
      manifest_entry: [
        f(:repository, :string, true),
        f(:path, :string, true),
        f(:kind, {:enum, [:file, :symlink]}, true),
        f(:mode, :string, true),
        f(:size, :integer, true),
        f(:sha256, :string, true),
        f(:target, :string)
      ],
      manifest: [
        f(:snapshot_id, :string, true),
        f(:version, :integer, true),
        f(:repositories, {:list, :snapshot_repository}, true),
        f(:entries, {:list, :manifest_entry}, true)
      ],
      # A blob's bytes are a stream, never a field held whole.
      blob: [f(:sha256, :string, true), f(:size, :integer, true), f(:content, :stream, true)],
      change: [
        f(:change_id, :string, true),
        f(:state, {:enum, [:open, :sealed]}, true),
        f(:missing, {:list, :string}, true),
        f(:revision, :string)
      ],
      review: [
        f(:review_id, :string, true),
        f(:change_id, :string, true),
        f(:repository, :string, true),
        f(:target, :string, true),
        f(:revision, :string, true),
        f(:state, {:enum, [:open]}, true),
        f(:link, :string)
      ],
      review_update: [
        f(:update_id, :string, true),
        f(:review_id, :string, true),
        f(:change_id, :string, true),
        f(:repository, :string, true),
        f(:previous_revision, :string, true),
        f(:revision, :string, true),
        f(:state, {:enum, [:open]}, true),
        f(:link, :string)
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
       ]},
    get_manifest:
      {:snapshot, :get_manifest_input,
       [
         manifest: :manifest,
         invalid_request: :problem,
         not_found: :problem,
         snapshot_superseded: :problem
       ]},
    get_blob:
      {:snapshot, :get_blob_input,
       [
         blob: :blob,
         invalid_request: :problem,
         not_found: :problem,
         snapshot_superseded: :problem,
         forbidden: :problem,
         unknown_revision: :problem,
         repository_mismatch: :problem,
         provider_unavailable: :problem
       ]},
    create_change:
      {:change, :create_change_input,
       [
         change: :change,
         invalid_request: :problem,
         forbidden: :problem,
         not_found: :problem,
         snapshot_superseded: :problem,
         base_mismatch: :problem,
         conflict: :problem,
         unsupported_content: :problem
       ]},
    put_change_blob:
      {:change, :put_change_blob_input,
       [change: :change, invalid_request: :problem, not_found: :problem]},
    seal_change:
      {:change, :seal_change_input,
       [
         change: :change,
         invalid_request: :problem,
         not_found: :problem,
         incomplete_upload: :problem,
         forbidden: :problem,
         unknown_revision: :problem,
         repository_mismatch: :problem,
         provider_unavailable: :problem,
         conflict: :problem
       ]},
    create_review:
      {:review, :create_review_input,
       [
         review: :review,
         invalid_request: :problem,
         not_found: :problem,
         change_not_sealed: :problem,
         fingerprint_mismatch: :problem,
         forbidden: :problem,
         unknown_revision: :problem,
         repository_mismatch: :problem,
         conflict: :problem,
         location_taken: :problem,
         provider_unavailable: :problem,
         review_incomplete: :problem
       ]},
    update_review:
      {:review, :update_review_input,
       [
         updated: :review_update,
         invalid_request: :problem,
         not_found: :problem,
         review_not_open: :problem,
         change_not_sealed: :problem,
         repository_mismatch: :problem,
         revision_mismatch: :problem,
         fingerprint_mismatch: :problem,
         forbidden: :problem,
         unknown_revision: :problem,
         conflict: :problem,
         provider_unavailable: :problem,
         location_moved: :problem,
         update_refused: :problem
       ]},
    mark_ready:
      {:review, :mark_ready_input,
       [
         ready: :review_ready,
         invalid_request: :problem,
         not_found: :problem,
         review_not_open: :problem,
         forbidden: :problem,
         provider_unavailable: :problem
       ]},
    review_status:
      {:review, :review_report_input,
       [
         report: :review_report,
         invalid_request: :problem,
         not_found: :problem,
         review_not_open: :problem,
         forbidden: :problem,
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

  test "declares exactly the snapshot, change and review capabilities, each with its right" do
    actual = for c <- schema().capabilities, do: {c.name, {c.right, c.input, outcomes(c)}}
    assert actual == @capabilities
  end

  test "is version 0.4.0: draft, mark_ready and review_status (K2)" do
    assert schema().version == "0.4.0"
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
