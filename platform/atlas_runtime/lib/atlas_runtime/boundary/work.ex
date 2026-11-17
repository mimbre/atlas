defmodule AtlasRuntime.Boundary.Work do
  @moduledoc """
  The Boundary Elixir target of the Runtime's work contract (design §1.5): the only way in
  for every caller (the backend, tests, any co-located system). It checks the right, builds
  the input, calls `AtlasRuntime.Work` and checks that the answer is a declared outcome.
  `AtlasRuntime.Work` implements `AtlasRuntime.Boundary.Work.Implementation`. The
  translations between the private model (`AtlasRuntime.Model.Work`) and the contract's
  models are checked here against `AtlasRuntimeBoundary.WorkMappings` (§1.5 (c)).

  Refusal details (design §3.2, D44): for a client without `choose_path`, every capability
  drops `detail` from a `refused` outcome and keeps its `reason`, whether the core or the
  facade itself (invalid input) refused. A refusal text that names a path on the Runtime's
  machine therefore never reaches a remote client. A work's paths are cut by the core,
  per field (`AtlasRuntime.Work.Translation`).
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Work,
    implementation: AtlasRuntime.Work,
    mappings: AtlasRuntimeBoundary.WorkMappings,
    model: AtlasRuntime.Model.Work

  # Every capability of the contract, so one added later is covered too.
  for %{name: name, input: takes} <- AtlasRuntimeBoundary.Work.__schema__().capabilities do
    if takes do
      defoverridable [{name, 2}]
      def unquote(name)(client, input), do: for_client(client, super(client, input))
    else
      defoverridable [{name, 1}]
      def unquote(name)(client), do: for_client(client, super(client))
    end
  end

  @doc false
  # An outcome as `client` may receive it: a refusal's detail only with choose_path.
  def for_client({_id, rights}, %__MODULE__.Outcome.Refused{} = refused) do
    if Enum.member?(rights, :choose_path), do: refused, else: %{refused | detail: nil}
  end

  def for_client(_client, outcome), do: outcome
end
