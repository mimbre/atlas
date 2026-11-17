defmodule AtlasFlow.Code.Client do
  @moduledoc """
  What Flow asks of Code before it hands work to a machinery (plan 2026-11-17 §5.1, §6
  F1.5a): the base a task starts from, as a Code snapshot. Flow codes against this
  behaviour only: `config :atlas_flow, :code_client, module` (default
  `AtlasFlow.Code.Client.Boundary`, Code's facade in the same BEAM).

  `base(input)` takes a task's input, `%{"code" => repository, "base" => reference,
  "root" => path}` (Code's repository name, a branch of it, and where that repository is
  placed in the work's folder), resolves the reference to its current revision and
  snapshots it. Outcomes:

  - `{:ok, snapshot_id}`: the `sha256:` snapshot ID, which the task sends as its
    workspace's `base_id` (the Runtime's declared S5a exception, Runtime §3.9, D41);
  - `{:refused, reason}`: Code refused the input (`reason` is the refusal's name, such as
    `:forbidden` for a repository it is not configured for, or `:unknown_reference`); the
    same input will be refused again;
  - `{:unavailable, reason}`: no answer from Code (none registered, or its provider
    failed); asking again later may succeed.

  Each call is one fresh snapshot of the reference: there is no cache, so a task starts on
  the reference as it is when its intent is made.
  """

  @type input :: %{required(String.t()) => String.t()}
  @type outcome ::
          {:ok, String.t()} | {:refused, atom()} | {:unavailable, term()}

  @callback base(input()) :: outcome()

  @doc "The Code client Flow calls."
  def client, do: Application.get_env(:atlas_flow, :code_client, AtlasFlow.Code.Client.Boundary)

  @doc "The base `input` starts from, through the configured client."
  def base(input), do: client().base(input)
end
