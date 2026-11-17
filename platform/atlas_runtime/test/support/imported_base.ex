defmodule AtlasRuntime.Test.ImportedBase do
  @moduledoc """
  A base imported into a test's Runtime home as a source's puller imports it (M2 A3, W5's
  `AtlasRuntime.Sources.Import`, the real `workspace base-import`), for tests that hand the
  executor a lease directly (`Work.accept_lease/3`): `import!/3` answers what the puller
  passes on, `%{baseline_id, change_set: nil}`, and the base is in the source's own store.
  """

  alias AtlasRuntime.Sources.Import
  alias AtlasRuntime.Test.FakeWorkSource

  @doc "Imports a base of `files` (root `atlas`) for `source` into `home`."
  def import!(home, source, files \\ %{"README.md" => "base\n"}) do
    {manifest, blobs} = FakeWorkSource.base(files)

    fetch = fn sha ->
      case Map.fetch(blobs, sha) do
        {:ok, bytes} -> {:ok, %{sha256: sha, size: byte_size(bytes), content: [bytes]}}
        :error -> :not_found
      end
    end

    lease = %{work: %{input: %{base: %{base_id: "test-base", manifest: manifest}}}}
    policy = %{"name" => source, "max_store_bytes" => 2_147_483_648}
    {:ok, imported} = Import.base(home, policy, lease, fetch)
    imported
  end
end
