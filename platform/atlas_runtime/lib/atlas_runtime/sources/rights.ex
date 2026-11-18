defmodule AtlasRuntime.Sources.Rights do
  @moduledoc """
  The fixed rights of a work source's client (decision §3 "What the local policy bounds";
  M2 plan C1). They are code, never policy: no source configuration can widen them.

  - The built-in `local` source acts for the socket's owner, so its client holds the work
    rights of `backend.sock` (`AtlasRuntimeBackend.Work`'s `:socket` listener):
    `choose_slot` and `choose_path` included. Only it may name a `slot`, a `folder`, a
    `repository` or `resume_from`.
  - Every other source's client is `{"source:<name>", [:submit, :cancel, :read]}`: it may
    submit, cancel and read its own work, and nothing that names this machine.

  The executor (`AtlasRuntime.Work.Server`) refuses a request that needs a right the client
  does not hold (`not_permitted`), before anything is admitted or prepared.
  """

  @source_rights [:submit, :cancel, :read]

  @typedoc "A work contract client: `{client_id, rights}`."
  @type client :: {String.t(), [atom()]}

  @doc "The client a source `name` acts as."
  @spec client(String.t()) :: client()
  def client("local"), do: {client_id("local"), socket_rights()}
  def client(name) when is_binary(name) and name != "", do: {client_id(name), @source_rights}

  @doc "The client id of source `name`: `source:<name>`."
  @spec client_id(String.t()) :: String.t()
  def client_id(name) when is_binary(name), do: "source:" <> name

  @doc "Whether `client_id` is a work source's client (any source, `local` included)."
  @spec source?(String.t()) :: boolean()
  def source?(client_id) when is_binary(client_id), do: String.starts_with?(client_id, "source:")
  def source?(_), do: false

  # The work rights of the socket listener, as the backend contract declares them.
  defp socket_rights do
    %{rights: rights} =
      Enum.find(AtlasRuntimeBackend.Work.__schema__().rights, &(&1.listener == :socket))

    rights
  end
end
