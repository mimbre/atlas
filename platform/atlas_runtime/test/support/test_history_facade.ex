defmodule AtlasRuntime.Test.HistoryFacade do
  @moduledoc """
  A facade of the history contract for the backend's tests, generated like
  `AtlasRuntime.Boundary.History` but on `AtlasRuntime.Test.FakeHistory`, so the router is
  tested on every outcome without the Runtime's core.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.History,
    implementation: AtlasRuntime.Test.FakeHistory
end

defmodule AtlasRuntime.Test.FakeHistory do
  @moduledoc """
  The test facade's implementation. Each capability answers what the test set with
  `answer/2` (a function of client and input), or a default; then it reports the call to
  the process `owner/1` set (else to the caller) as `{:fake_history, capability, client,
  input}`. It shares `AtlasRuntime.Test.FakeWork`'s `owner/1`.
  """
  @behaviour AtlasRuntime.Test.HistoryFacade.Implementation

  alias AtlasRuntime.Test.HistoryFacade, as: F

  def answer(capability, fun), do: :persistent_term.put({__MODULE__, capability}, fun)

  def reset_all do
    for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  @impl true
  def list_turns(client, input),
    do:
      call(:list_turns, client, input, fn ->
        %F.Outcome.Turns{turns: [a_turn()], cursor: "h:1", more: false}
      end)

  @impl true
  def get_turn(client, input),
    do: call(:get_turn, client, input, fn -> %F.Outcome.Found{turn: a_turn(input.turn_id)} end)

  defp call(capability, client, input, default) do
    outcome =
      case :persistent_term.get({__MODULE__, capability}, nil) do
        nil -> default.()
        fun -> fun.(client, input)
      end

    send(
      :persistent_term.get({AtlasRuntime.Test.FakeWork, :owner}, self()),
      {:fake_history, capability, client, input}
    )

    outcome
  end

  ## Values the tests build outcomes from

  def a_turn(id \\ "turn-0000000000000001") do
    %F.Turn{
      turn_id: id,
      slot: "s1",
      state: :finished,
      native_outcome: :finished,
      started_at: ~U[2026-11-16 10:00:00Z],
      ended_at: ~U[2026-11-16 10:05:00Z],
      harness: "codex",
      configured_model: "m-1"
    }
  end
end
