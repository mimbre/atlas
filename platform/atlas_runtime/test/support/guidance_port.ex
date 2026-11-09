defmodule AtlasRuntime.GuidancePort do
  @moduledoc "Private injected proof port; deliberately absent from machine settings/catalogue."
  @behaviour AtlasRuntime.Agent
  alias AtlasRuntime.Agent.FakeInbox
  @impl true
  def describe(t, o), do: FakeInbox.describe(t, o)
  @impl true
  def start(turn, opts) do
    # Read through the Bus before the fake is started, proving ordering at the boundary.
    ex =
      AtlasRuntime.Talk.read("synthetic_execution", %{
        "turn" => turn.key,
        "attempt" => turn.attempt
      })

    send(opts[:observer], {:starting, turn, ex})
    result = FakeInbox.start(turn, inbox_opts(turn, opts) ++ [initialize: true])

    case result do
      {:ok, pid} ->
        :ets.insert(__MODULE__, {pid, opts})
        send(opts[:observer], {:started, pid, turn})

      _ ->
        :ok
    end

    result
  end

  @impl true
  def recover_input(turn, opts) do
    send(opts[:observer], {:recovering, turn})
    send(opts[:observer], {:recovery_options, opts})

    case FakeInbox.recover_input(turn, inbox_opts(turn, opts)) do
      {:ok, pid} = ok ->
        :ets.insert(__MODULE__, {pid, opts})
        ok

      error ->
        error
    end
  end

  defp inbox_opts(turn, opts),
    do: [inbox_dir: Path.join(opts[:inbox_root], turn.key), barrier: opts[:barrier]]

  @impl true
  def stop(pid), do: FakeInbox.stop(pid)
  @impl true
  def close_input(pid), do: FakeInbox.close_input(pid)
  @impl true
  def capabilities(pid), do: FakeInbox.capabilities(pid)
  @impl true
  def query(pid, id) do
    opts = :ets.lookup_element(__MODULE__, pid, 2)

    case :ets.lookup(__MODULE__, :query_fault) do
      [{:query_fault, reason}] ->
        {:error, reason}

      _ ->
        result = FakeInbox.query(pid, id)
        send(opts[:observer], {:queried, pid, id, result})
        result
    end
  end

  @impl true
  def accept(pid, request), do: FakeInbox.accept(pid, request)
  @impl true
  def accept(pid, request, deadline) do
    opts = :ets.lookup_element(__MODULE__, pid, 2)
    send(opts[:observer], {:accepting, pid, request})
    result = FakeInbox.accept(pid, request, deadline)
    if :ets.member(__MODULE__, :lose_accept_ack), do: {:error, :uncertain}, else: result
  end
end
