defmodule AtlasE2E.Pull.Await do
  @moduledoc """
  The pull-e2e's waits: on events only (`AtlasTestAwait`, woken by `AtlasE2E.Pull.Hub`),
  never on the clock. Each wait's cap is what is left of the current step's budget
  (`AtlasE2E.Pull.Bench.remaining/0`): reaching it fails the step with the matcher's name,
  the last value and the last 20 events, and decides nothing else.

  - `event/3`: the first event after a mark that a matcher accepts (it may already be in
    the history).
  - `facts/3`: a read checked now and again after every new event. While idle there is at
    least one event every 5 s (a poll answer every `poll_max`, or a refused connect every
    `retry_ms`), so a fact is re-read at least that often. It answers the value and the
    receive time of the newest event when the check first held (S5's ordering).
  - `polls/3`: the first `n` answered polls (status 200) that began at or after a time:
    a negative check counts these, never elapsed time.
  """
  alias AtlasE2E.Pull.{Bench, Hub}

  @doc "The first event after `since` (a mark or sequence number) that `match` accepts."
  def event(since, match, opts \\ []) do
    hub = opts[:hub] || Hub

    until(fn -> Hub.find(since, match, hub) end, opts)
  end

  @doc """
  `{value, at}` once `check.(read.())` is truthy: `value` is what `read` answered, `at` the
  receive time of the newest event when it held (the mark's time when none came yet).
  """
  def facts(read, check, opts \\ []) do
    hub = opts[:hub] || Hub

    until(
      fn ->
        at =
          case Hub.last(1, hub) do
            [event] -> event.at
            [] -> Hub.mark(hub).at
          end

        value = read.()
        if check.(value), do: {value, at}
      end,
      opts
    )
  end

  @doc """
  The first `n` edge records of answered polls (`status: 200`) whose request began at or
  after `from` (monotonic ms) and that `match` accepts, oldest first.
  """
  def polls(n, from, opts \\ []) do
    hub = opts[:hub] || Hub
    match = opts[:match] || fn _ -> true end

    until(
      fn ->
        polls =
          Hub.select(
            0,
            fn
              %{source: :wire, data: %{route: :poll, status: 200, began: began} = record} ->
                began >= from and match.(record)

              _ ->
                false
            end,
            hub
          )

        if length(polls) >= n, do: Enum.take(polls, n)
      end,
      opts
    )
  end

  defp until(check, opts) do
    hub = opts[:hub] || Hub

    AtlasTestAwait.until(check,
      wake: {:subscribe, fn -> Hub.subscribe(hub) end},
      cap: opts[:within] || Bench.remaining(),
      label: opts[:label] || "an event",
      state: fn -> %{recent: Enum.map(Hub.last(20, hub), &brief/1)} end
    )
  end

  @doc false
  # An event without its bulky parts, for a failure's report.
  def brief(%{data: data} = event) when is_map(data),
    do: %{event | data: Map.drop(data, [:resp_body, :req_body])}

  def brief(event), do: event
end
