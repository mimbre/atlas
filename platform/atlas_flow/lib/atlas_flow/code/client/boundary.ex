defmodule AtlasFlow.Code.Client.Boundary do
  @moduledoc """
  `AtlasFlow.Code.Client` on Code's boundary facade, `AtlasCode.Boundary` (contract
  `AtlasCodeBoundary.Code`; ADR 0006), which reaches the Code instance registered in this
  BEAM (`AtlasCode.settings/0`). Flow calls it as `flow` with the right `:snapshot` only:
  `resolve_reference`, then `create_snapshot` of that one revision at the input's root.

  No registered instance, and Code's `provider_unavailable`, are `{:unavailable, reason}`;
  every other refusal is `{:refused, name}`, named after Code's outcome.
  """
  @behaviour AtlasFlow.Code.Client

  require Logger

  alias AtlasCode.Boundary
  alias AtlasCode.Boundary.Outcome

  @caller {"flow", [:snapshot]}

  @impl true
  def base(%{"code" => repository, "base" => reference, "root" => root}) do
    with {:ok, revision} <- resolve(repository, reference),
         {:ok, snapshot_id} <- snapshot(repository, revision, root) do
      {:ok, snapshot_id}
    end
  rescue
    # AtlasCode.settings/0 raises while no instance is registered.
    error in RuntimeError -> {:unavailable, Exception.message(error)}
  end

  defp resolve(repository, reference) do
    case Boundary.resolve_reference(@caller, %{
           "repository" => repository,
           "reference" => reference
         }) do
      %Outcome.Resolved{revision: revision} -> {:ok, revision}
      other -> failed(other)
    end
  end

  defp snapshot(repository, revision, root) do
    case Boundary.create_snapshot(@caller, %{
           "repositories" => [
             %{"repository" => repository, "revision" => revision, "path" => root}
           ]
         }) do
      %Outcome.Created{snapshot_id: snapshot_id} -> {:ok, snapshot_id}
      other -> failed(other)
    end
  end

  defp failed(%Outcome.ProviderUnavailable{message: message}),
    do: {:unavailable, {:provider_unavailable, message}}

  defp failed(%{__struct__: module} = outcome) do
    reason = module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
    Logger.info("flow: Code refused a base: #{inspect(outcome)}")
    {:refused, reason}
  end
end
