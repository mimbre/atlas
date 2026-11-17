# A model schema of the documented shape (AtlasFlowBoundary.Generator.ModelSchema;
# design §1.7, D36): what a model target's __schema__/0 gives, for a neutral lending
# library's private model. It has both kinds of entity: records stored on their own
# (persistence is a map) and entities held inside another (persistence is nil), and
# every kind of type. test/model_schema_test.exs keeps it in step with the shape.
%{
  version: "1.0.0",
  entities: [
    %{
      name: :shelf_spot,
      fields: [%{name: :row, type: :integer, required: true}],
      persistence: nil
    },
    %{
      name: :branch_spot,
      fields: [
        %{name: :city, type: :string, required: true},
        %{name: :open, type: :boolean, required: false}
      ],
      persistence: nil
    },
    %{
      name: :hold,
      fields: [
        %{name: :member, type: :string, required: true},
        %{name: :reason, type: :string, required: true},
        %{name: :placed_at, type: :datetime, required: true},
        %{name: :desk_note, type: :string, required: false}
      ],
      persistence: nil
    },
    %{
      name: :copy_record,
      fields: [
        %{name: :copy_id, type: :string, required: true},
        %{name: :title, type: :string, required: true},
        %{name: :wear, type: {:enum, [:new, :worn, :badly_worn]}, required: true},
        %{name: :location, type: {:one_of, [:shelf_spot, :branch_spot]}, required: true},
        %{name: :due_at, type: :datetime, required: false},
        %{name: :labels, type: {:list, {:enum, [:large_print, :audio]}}, required: true},
        %{name: :holds, type: {:list, :hold}, required: true},
        %{name: :home, type: :branch_spot, required: false},
        %{name: :lent_count, type: :integer, required: true},
        %{name: :scan_path, type: :string, required: false}
      ],
      persistence: %{form: :json_file, path: "copies/{copy_id}.json", format_version: 1}
    },
    %{
      name: :ledger_entry,
      fields: [
        %{name: :member, type: :string, required: true},
        %{name: :copy_id, type: :string, required: true},
        %{name: :last_wear, type: {:enum, [:new, :worn, :badly_worn]}, required: false},
        %{name: :closed, type: :boolean, required: true}
      ],
      persistence: %{form: :json_file, path: "copies/ledger.json", format_version: 2}
    }
  ]
}
