defmodule AtlasRuntime.Test.WorkFacade do
  @moduledoc """
  A facade of the work contract for the backend's tests, generated like
  `AtlasRuntime.Boundary.Work` but on `AtlasRuntime.Test.FakeWork`, so the router is
  tested on every outcome without the Runtime's work core.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Work,
    implementation: AtlasRuntime.Test.FakeWork
end

defmodule AtlasRuntime.Test.WorkRest do
  @moduledoc """
  The backend's one router, generated as `AtlasRuntime.Backend.Rest` is but on the test
  facades: the work contract (with the event stream), the operations contract and the
  history contract.
  """
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contracts: [
      work:
        {AtlasRuntimeBackend.Work,
         facade: AtlasRuntime.Test.WorkFacade, stream: AtlasRuntime.Backend.Events},
      operations: {AtlasRuntimeBackend.Operations, facade: AtlasRuntime.Test.OperationsFacade},
      history: {AtlasRuntimeBackend.History, facade: AtlasRuntime.Test.HistoryFacade}
    ]
end

defmodule AtlasRuntime.Test.FakeWork do
  @moduledoc """
  The test facade's implementation. Each capability answers what the test set with
  `answer/2` (a function of client and input), or a default; then it reports the call to
  the process `owner/1` set (else to the caller) as `{:fake_work, capability, client,
  input}`.

  `subscribe` is backed by a small notification window (`start_window/1`): `notify/2`
  appends a change visible to one client id (or to all), sends it to the subscribers that
  may see it (their own work, or `read_all`), and a subscriber resumes inside the window
  or gets `reset`; `restart/0` starts a new incarnation, after which an older id resets.
  The decisions a real core makes; here only so the backend's plumbing can be driven.
  """
  @behaviour AtlasRuntime.Test.WorkFacade.Implementation

  alias AtlasRuntime.Test.WorkFacade, as: F

  @window __MODULE__.Window

  ## Driving it

  def answer(capability, fun), do: :persistent_term.put({__MODULE__, capability}, fun)
  def owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

  def reset_all do
    for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  @doc "A notification window of `size` changes, as a child spec for `start_supervised!/1`."
  def window(size) do
    %{
      id: @window,
      start:
        {Agent, :start_link,
         [
           fn -> %{sequence: 0, boot: 0, size: size, changes: [], subscribers: []} end,
           [name: @window]
         ]}
    }
  end

  @doc "A change of a work owned by `owner` (a client id, or `:all`); `build` gets its sequence."
  def notify(owner, build) do
    Agent.get_and_update(@window, fn state ->
      sequence = state.sequence + 1
      value = build.(sequence)
      changes = Enum.take([{sequence, owner, value} | state.changes], state.size)

      for {pid, client} <- state.subscribers,
          visible?(client, owner),
          do: send(pid, {:atlas_runtime_work, value})

      {sequence, %{state | sequence: sequence, changes: changes}}
    end)
  end

  @doc "Send `build.(client)` to every subscriber now (a heartbeat, filtered per client)."
  def broadcast(build) do
    for {pid, client} <- Agent.get(@window, & &1.subscribers),
        do: send(pid, {:atlas_runtime_work, build.(client)})

    :ok
  end

  @doc "A new incarnation: the window is empty, the sequence goes on."
  def restart,
    do: Agent.update(@window, &%{&1 | boot: &1.sequence, changes: [], subscribers: []})

  def subscribers, do: Agent.get(@window, & &1.subscribers)

  ## The capabilities

  @impl true
  def submit(client, input),
    do: call(:submit, client, input, fn -> %F.Outcome.Accepted{work: a_work()} end)

  @impl true
  def retry(client, input), do: call(:retry, client, input, fn -> %F.Outcome.NotFound{} end)

  @impl true
  def cancel(client, input), do: call(:cancel, client, input, fn -> %F.Outcome.NotFound{} end)

  @impl true
  def get_work(client, input), do: call(:get_work, client, input, fn -> %F.Outcome.NotFound{} end)

  @impl true
  def find_work(client, input),
    do: call(:find_work, client, input, fn -> %F.Outcome.NotFound{} end)

  @impl true
  def list_work(client, input),
    do: call(:list_work, client, input, fn -> %F.Outcome.Works{works: [], sequence: 0} end)

  @impl true
  def capacity(client) do
    call(:capacity, client, nil, fn ->
      struct(F.Outcome.Capacity, Map.from_struct(a_capacity(accepting: false, retry_after: 60)))
    end)
  end

  @impl true
  def turn_output(client, input),
    do: call(:turn_output, client, input, fn -> %F.Outcome.NotFound{} end)

  @impl true
  def subscribe(client, input) do
    call(:subscribe, client, input, fn ->
      if Process.whereis(@window),
        do: subscribe_window(client, input.from),
        else: %F.Outcome.Subscribed{}
    end)
  end

  # The changes a resuming subscriber missed are sent from here, the subscriber's process.
  defp subscribe_window(client, from) do
    caller = self()

    {outcome, missed} =
      Agent.get_and_update(@window, fn state ->
        oldest = state.changes |> List.last() |> then(&(&1 && elem(&1, 0)))
        floor = max(state.boot, if(oldest, do: oldest - 1, else: state.sequence))

        resumable =
          is_nil(from) or
            (from >= floor and from <= state.sequence and (state.boot == 0 or from > state.boot))

        state = %{state | subscribers: [{caller, client} | state.subscribers]}

        if resumable do
          missed =
            for {seq, owner, value} <- Enum.reverse(state.changes),
                from && seq > from,
                visible?(client, owner),
                do: value

          {{%F.Outcome.Subscribed{}, missed}, state}
        else
          {{%F.Outcome.Reset{current_sequence: state.sequence}, []}, state}
        end
      end)

    for value <- missed, do: send(self(), {:atlas_runtime_work, value})
    outcome
  end

  defp visible?(_client, :all), do: true
  defp visible?({id, rights}, owner), do: id == owner or :read_all in rights

  # Answers, then reports the call (so a subscriber is registered before the test hears).
  defp call(capability, client, input, default) do
    outcome =
      case :persistent_term.get({__MODULE__, capability}, nil) do
        nil -> default.()
        fun -> fun.(client, input)
      end

    send(
      :persistent_term.get({__MODULE__, :owner}, self()),
      {:fake_work, capability, client, input}
    )

    outcome
  end

  ## Values the tests build outcomes from

  def a_work(fields \\ []) do
    struct(
      %F.Work{
        work_id: "w-1",
        client: "local:test",
        client_key: "k-1",
        idempotency_key: "k-1",
        revision: 1,
        sequence: 7,
        request: %F.WorkRequest{
          client_key: "k-1",
          title: "Fix it",
          instructions: "Fix the bug.",
          profile: "deep_coding",
          cost_class: :standard,
          workspace: %F.Repository{
            url: "https://example.test/r.git",
            branch: "fix",
            base: "develop"
          }
        },
        state: :buffered,
        attempts: [
          %F.Attempt{
            attempt: 1,
            state: :buffered,
            timestamps: %F.AttemptTimestamps{received_at: ~U[2026-11-16 10:00:00Z]},
            quiescent: true
          }
        ]
      },
      fields
    )
  end

  def a_capacity(fields \\ []) do
    struct(
      %F.Capacity{
        slots: %F.SlotCounts{total: 2, busy: 2, free: 0},
        buffer: %F.BufferCounts{size: 1, used: 1, free: 0},
        profiles: [%F.ProfileAvailability{profile: "deep_coding", available: true}],
        accepting: true,
        policy_version: 4,
        runtime_build: "test",
        incarnation: "i-1"
      },
      fields
    )
  end
end
