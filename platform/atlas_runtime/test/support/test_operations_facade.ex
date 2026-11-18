defmodule AtlasRuntime.Test.OperationsFacade do
  @moduledoc """
  A facade of the operations contract for the backend's tests, generated like
  `AtlasRuntime.Boundary.Operations` but on `AtlasRuntime.Test.FakeOperations`, so the
  router is tested on every outcome without the Runtime's core.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Operations,
    implementation: AtlasRuntime.Test.FakeOperations
end

defmodule AtlasRuntime.Test.FakeOperations do
  @moduledoc """
  The test facade's implementation. Each capability answers what the test set with
  `answer/2` (a function of client and input), or a default; then it reports the call to
  the process `owner/1` set (else to the caller) as `{:fake_operations, capability,
  client, input}`. It shares `AtlasRuntime.Test.FakeWork`'s `owner/1` and `reset_all/0`.
  """
  @behaviour AtlasRuntime.Test.OperationsFacade.Implementation

  alias AtlasRuntime.Test.OperationsFacade, as: F

  def answer(capability, fun), do: :persistent_term.put({__MODULE__, capability}, fun)

  def reset_all do
    for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  @impl true
  def runtime_info(client),
    do: call(:runtime_info, client, nil, fn -> outcome(F.Outcome.RuntimeInfo) end)

  @impl true
  def policy(client),
    do: call(:policy, client, nil, fn -> outcome(F.Outcome.Policy, a_policy()) end)

  @impl true
  def pause(client),
    do: call(:pause, client, nil, fn -> outcome(F.Outcome.RuntimeInfo, mode: :paused) end)

  @impl true
  def resume(client), do: call(:resume, client, nil, fn -> outcome(F.Outcome.RuntimeInfo) end)

  @impl true
  def drain(client),
    do: call(:drain, client, nil, fn -> outcome(F.Outcome.RuntimeInfo, mode: :draining) end)

  @impl true
  def stop(client, input),
    do: call(:stop, client, input, fn -> outcome(F.Outcome.Stopping, mode: :stopping) end)

  @impl true
  def release_slot(client, input),
    do: call(:release_slot, client, input, fn -> %F.Outcome.Released{slot: input.slot} end)

  @impl true
  def clear_quota_mark(client, input),
    do: call(:clear_quota_mark, client, input, fn -> %F.Outcome.Cleared{} end)

  defp call(capability, client, input, default) do
    outcome =
      case :persistent_term.get({__MODULE__, capability}, nil) do
        nil -> default.()
        fun -> fun.(client, input)
      end

    send(
      :persistent_term.get({AtlasRuntime.Test.FakeWork, :owner}, self()),
      {:fake_operations, capability, client, input}
    )

    outcome
  end

  ## Values the tests build outcomes from

  @doc "An outcome struct carrying the fields of `value` (default: a runtime info)."
  def outcome(module, value \\ []) do
    value = if is_list(value), do: a_runtime_info(value), else: value
    struct(module, Map.from_struct(value))
  end

  def a_runtime_info(fields \\ []) do
    struct(
      %F.RuntimeInfo{
        runtime_build: "test",
        incarnation: "i-1",
        mode: :open,
        policy_version: 4,
        slots: [%F.Slot{name: "s1", busy: true}, %F.Slot{name: "s2", busy: false}]
      },
      fields
    )
  end

  def a_policy do
    %F.Policy{
      version: 4,
      buffer_size: 1,
      profiles: [
        %F.ProfilePolicy{
          profile: "deep_coding",
          permissions: [:"dedicated-repository"],
          cost_classes: [:standard],
          limits: %F.ProfileLimits{max_duration: 3600},
          options: [
            %F.PolicyOption{
              provider: "anthropic",
              harness: "claude",
              model: "m-1",
              availability: %F.OptionAvailability{available: true}
            }
          ]
        }
      ]
    }
  end
end
