defmodule AtlasRuntimeBackend.Generator.Example.Extended do
  @moduledoc """
  The example contract with what a contract can say beyond it, as `__schema__/0` data, so
  the file targets are tested on it before the DSL writes it: a constant header on an
  outcome (`returned`, `Replayed: true`). The example itself declares a listener's errors
  (`:unauthenticated`, 401, and `:origin_refused`, 403) and an `etag:` field
  (`find_book`, the book's `edition`). The file targets read only this data, so they
  serve the DSL's version of it unchanged.
  """
  alias AtlasRuntimeBackend.Generator.Example.Api

  def __schema__ do
    schema = Api.__schema__()
    [rest] = schema.targets

    statuses =
      Enum.map(rest.statuses, fn
        %{outcome: :returned} = s -> %{s | headers: s.headers ++ [{"replayed", "true"}]}
        s -> s
      end)

    %{schema | targets: [%{rest | statuses: statuses}]}
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.Bare do
  @moduledoc """
  The example contract without its listener errors (`:unauthenticated`,
  `:origin_refused`) and without `etag:`, as `__schema__/0` data: the file targets add
  401, 403 `origin-refused`, `ETag` and 304 only where the contract declares them.
  """
  alias AtlasRuntimeBackend.Generator.Example.Api

  def __schema__ do
    schema = Api.__schema__()
    [rest] = schema.targets

    %{
      schema
      | targets: [
          %{
            rest
            | resources: Enum.map(rest.resources, &%{&1 | etag: nil}),
              errors: Enum.reject(rest.errors, &(&1.kind in [:unauthenticated, :origin_refused]))
          }
        ]
    }
  end
end
