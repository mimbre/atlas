defmodule AtlasFacts.SlowRela do
  @moduledoc """
  `AtlasFacts.CountingRela`, where every request to rela takes `delay` ms, as one over the
  network does. With `hold/1`, every write also waits until `release/1`, and the holder
  hears `{:write_pending, pid}` while it waits: a write to rela that is still pending.
  Writes are held until `open/1`.
  """
  @behaviour AtlasFacts.Rela

  alias AtlasFacts.CountingRela

  def start(n, opts \\ []) do
    {:ok, backend} = CountingRela.start_link(n, opts)
    delay = Keyword.get(opts, :delay, 0)
    {:ok, gate} = Agent.start_link(fn -> %{delay: delay, holder: nil, waiting: []} end)
    %{backend: backend, gate: gate}
  end

  def backend(%{backend: backend}), do: backend

  def hold(%{gate: gate}) do
    holder = self()
    Agent.update(gate, &%{&1 | holder: holder})
  end

  @doc "Let the writes that wait go on; the next ones wait again."
  def release(%{gate: gate}) do
    waiting = Agent.get_and_update(gate, &{&1.waiting, %{&1 | waiting: []}})
    Enum.each(waiting, &send(&1, {__MODULE__, :released}))
  end

  @doc "Hold no more writes, and let those that wait go on."
  def open(%{gate: gate} = s) do
    Agent.update(gate, &%{&1 | holder: nil})
    release(s)
  end

  defp slow(%{gate: gate}, write?) do
    me = self()

    %{delay: delay, holder: holder} =
      Agent.get_and_update(gate, fn g ->
        if write? and g.holder, do: {g, %{g | waiting: [me | g.waiting]}}, else: {g, g}
      end)

    if delay > 0, do: wait_until(System.monotonic_time(:microsecond) + delay * 1_000)

    if write? and holder do
      send(holder, {:write_pending, me})
      receive do: ({__MODULE__, :released} -> :ok)
    end

    :ok
  end

  # Not Process.sleep/1: a Mac stretches a 30 ms sleep to over 100. The clock is exact.
  defp wait_until(deadline) do
    if System.monotonic_time(:microsecond) < deadline do
      :erlang.yield()
      wait_until(deadline)
    end
  end

  @impl true
  def description(s), do: CountingRela.description(s.backend)

  @impl true
  def list(s, plural) do
    slow(s, false)
    CountingRela.list(s.backend, plural)
  end

  @impl true
  def get(s, plural, key) do
    slow(s, false)
    CountingRela.get(s.backend, plural, key)
  end

  @impl true
  def incoming(s, plural, key, relation) do
    slow(s, false)
    CountingRela.incoming(s.backend, plural, key, relation)
  end

  @impl true
  def check_create(s, plural, key, props, targets) do
    slow(s, false)
    CountingRela.check_create(s.backend, plural, key, props, targets)
  end

  @impl true
  def create(s, plural, key, props, targets) do
    slow(s, true)
    CountingRela.create(s.backend, plural, key, props, targets)
  end

  @impl true
  def change(s, plural, key, props, version, targets) do
    slow(s, true)
    CountingRela.change(s.backend, plural, key, props, version, targets)
  end

  @impl true
  def delete(s, plural, key, version) do
    slow(s, true)
    CountingRela.delete(s.backend, plural, key, version)
  end
end
