defmodule AtlasFacts.Rela do
  @moduledoc """
  What Facts needs from rela: the description and create, read, update and delete of
  facts by kind. rela is CRUD only (Melle: "crud only, no events"); Facts adds the rest.

  A store is `{module, config}`; the module implements these callbacks.
  """

  @type config :: term()
  @type fact :: %{key: String.t(), properties: map(), links: links(), version: String.t() | nil}
  @typedoc "Outgoing relations: relation name to the keys it points at."
  @type links :: %{String.t() => [String.t()]}
  @typedoc "Links to write: relation name to `{target kind, keys}`."
  @type targets :: %{String.t() => {String.t(), [String.t()]}}
  @type failure ::
          :unavailable
          | :not_found
          | :exists
          | :version_mismatch
          | {:invalid, [String.t()]}
          | {:failed, String.t()}

  @callback description(config) :: {:ok, map()} | {:error, failure}
  @callback list(config, plural :: String.t()) :: {:ok, [fact]} | {:error, failure}
  @callback get(config, plural :: String.t(), key :: String.t()) ::
              {:ok, fact} | {:error, failure}
  @doc "The keys of the facts that point at `key` through `relation` (its children)."
  @callback incoming(config, plural :: String.t(), key :: String.t(), relation :: String.t()) ::
              {:ok, [String.t()]} | {:error, failure}
  @doc "Check a create without storing anything; returns rela's warnings."
  @callback check_create(config, String.t(), String.t(), map(), targets) ::
              {:ok, [String.t()]} | {:error, failure}
  @doc """
  Atomically claim a collection/key identity. Exactly one concurrent create may
  succeed; others return `:exists` without changing the original properties/links.
  A lost response is recovered by reading that identity. Guidance relies on this
  backend guarantee, not an in-memory identity registry.
  """
  @callback create(config, String.t(), String.t(), map(), targets) ::
              {:ok, [String.t()]} | {:error, failure}
  @doc "Change properties and, for each relation in `targets`, replace the keys it points at."
  @callback change(config, String.t(), String.t(), map(), version :: String.t() | nil, targets) ::
              {:ok, [String.t()]} | {:error, failure}
  @callback delete(config, String.t(), String.t(), version :: String.t() | nil) ::
              :ok | {:error, failure}

  def description({mod, config}), do: mod.description(config)
  def list({mod, config}, plural), do: mod.list(config, plural)
  def get({mod, config}, plural, key), do: mod.get(config, plural, key)

  def incoming({mod, config}, plural, key, relation),
    do: mod.incoming(config, plural, key, relation)

  def check_create({mod, config}, plural, key, props, targets),
    do: mod.check_create(config, plural, key, props, targets)

  def create({mod, config}, plural, key, props, targets),
    do: mod.create(config, plural, key, props, targets)

  def change({mod, config}, plural, key, props, version, targets),
    do: mod.change(config, plural, key, props, version, targets)

  def delete({mod, config}, plural, key, version), do: mod.delete(config, plural, key, version)
end
