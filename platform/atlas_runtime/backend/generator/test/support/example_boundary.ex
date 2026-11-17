defmodule AtlasRuntimeBackend.Generator.Example.Boundary do
  @moduledoc """
  A neutral example boundary contract, given as plain data: what a boundary contract's
  `__schema__/0` gives (models with typed fields; capabilities with an input, a right and
  outcomes). A small lending library: no project values.
  """

  @conditions [:new, :worn, :"badly-worn"]
  @rights [:lend, :browse, :audit]

  @schema %{
    version: "1.0.0",
    file: "example_boundary.ex",
    models: [
      # Who is calling, and the rights a client can hold: what a backend's rights name.
      %{
        name: :client,
        fields: [
          %{name: :id, type: :string, required: true},
          %{name: :rights, type: {:list, {:enum, @rights}}, required: true}
        ]
      },
      %{
        name: :book,
        fields: [
          %{name: :book_id, type: :string, required: true},
          %{name: :title, type: :string, required: true},
          # +1 on every reprint: what a conditional GET tags.
          %{name: :edition, type: :integer, required: true},
          %{name: :condition, type: {:enum, @conditions}, required: true},
          %{name: :place, type: {:one_of, [:shelf, :branch], tag: :kind}, required: false},
          %{name: :due_at, type: :datetime, required: false}
        ]
      },
      %{name: :shelf, fields: [%{name: :row, type: :integer, required: true}]},
      %{name: :branch, fields: [%{name: :city, type: :string, required: true}]},
      %{
        name: :lend_input,
        fields: [
          %{name: :request_key, type: :string, required: false},
          %{name: :title, type: :string, required: true},
          %{name: :place, type: {:one_of, [:shelf, :branch], tag: :kind}, required: false},
          %{name: :until, type: :datetime, required: false}
        ]
      },
      %{name: :find_book_input, fields: [%{name: :book_id, type: :string, required: true}]},
      %{name: :search_input, fields: [%{name: :title, type: :string, required: true}]},
      %{
        name: :list_books_input,
        fields: [
          %{name: :condition, type: {:enum, @conditions}, required: false},
          %{name: :limit, type: :integer, required: false},
          %{name: :lent, type: :boolean, required: false}
        ]
      },
      %{
        name: :give_back_input,
        fields: [
          %{name: :book_id, type: :string, required: true},
          %{name: :note, type: :string, required: false},
          %{name: :hurry, type: :boolean, required: false}
        ]
      },
      %{name: :watch_input, fields: [%{name: :from, type: :integer, required: false}]},
      %{name: :audit_input, fields: []},
      %{
        name: :counts,
        fields: [
          %{name: :total, type: :integer, required: true},
          %{name: :wait, type: :integer, required: false}
        ]
      },
      %{name: :lent, fields: [%{name: :book, type: :book, required: true}]},
      %{name: :found, fields: [%{name: :book, type: :book, required: true}]},
      %{name: :books, fields: [%{name: :books, type: {:list, :book}, required: true}]},
      %{
        name: :busy,
        fields: [
          %{name: :retry_after, type: :integer, required: true},
          %{name: :counts, type: :counts, required: true}
        ]
      },
      %{
        name: :refused,
        fields: [
          %{name: :reason, type: {:enum, [:invalid, :taken, :not_permitted]}, required: true},
          %{name: :detail, type: :string, required: false}
        ]
      },
      %{
        name: :book_changed,
        fields: [
          %{name: :sequence, type: :integer, required: true},
          %{name: :book_id, type: :string, required: true}
        ]
      },
      %{name: :restart, fields: [%{name: :current_sequence, type: :integer, required: true}]},
      %{name: :tick, fields: [%{name: :at, type: :datetime, required: true}]}
    ],
    capabilities: [
      %{
        name: :lend,
        input: :lend_input,
        right: :lend,
        outcomes: [
          %{name: :lent, model: :lent},
          %{name: :busy, model: :busy},
          %{name: :refused, model: :refused}
        ]
      },
      %{
        name: :find_book,
        input: :find_book_input,
        right: :browse,
        outcomes: [%{name: :found, model: :found}, %{name: :missing, model: nil}]
      },
      %{
        name: :search,
        input: :search_input,
        right: :browse,
        outcomes: [%{name: :found, model: :found}, %{name: :missing, model: nil}]
      },
      %{
        name: :list_books,
        input: :list_books_input,
        right: :browse,
        outcomes: [%{name: :listed, model: :books}]
      },
      %{
        name: :give_back,
        input: :give_back_input,
        right: :lend,
        outcomes: [%{name: :returned, model: :found}, %{name: :missing, model: nil}]
      },
      %{name: :count, input: nil, right: :browse, outcomes: [%{name: :counted, model: :counts}]},
      %{
        name: :watch,
        input: :watch_input,
        right: :browse,
        outcomes: [%{name: :watching, model: nil}, %{name: :restart, model: :restart}]
      },
      %{
        name: :audit,
        input: :audit_input,
        right: :audit,
        outcomes: [%{name: :audited, model: nil}]
      }
    ]
  }

  def __schema__, do: @schema
end
