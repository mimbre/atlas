defmodule AtlasRuntime.Agent.Stub do
  @moduledoc """
  A stand-in agent, for tests and the end-to-end test: no real agent runs. What it does is
  set from outside, in a file named after the agent in `stub_dir` (the machine's settings),
  read every few hundred milliseconds:

  - `active` (or no file): it shows activity, each time it looks;
  - `idle`: it shows it is there (activity `idle`) and does nothing else, so its turn runs
    until its maximum;
  - `silent`: it shows nothing, as an agent that answers but does nothing;
  - `crash`: it crashes, and the next turn's stub does too;
  - `crash once`: it crashes, and sets its file to `active` first, so the next turn runs;
  - `end`: it ends its turn itself.
  """
  @behaviour AtlasRuntime.Agent

  use GenServer

  @look 300

  @impl AtlasRuntime.Agent
  def start(turn, opts) do
    GenServer.start(__MODULE__, {self(), turn, Keyword.get(opts, :stub_dir)})
  end

  @impl AtlasRuntime.Agent
  def start_monitor(turn, opts) do
    :gen_server.start_monitor(__MODULE__, {self(), turn, Keyword.get(opts, :stub_dir)}, [])
  end

  @impl AtlasRuntime.Agent
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init({turn_pid, turn, dir}) do
    send(self(), :look)
    {:ok, %{turn_pid: turn_pid, turn: turn, dir: dir, n: 0}}
  end

  @impl GenServer
  def handle_info(:look, state) do
    case mode(state) do
      "crash" ->
        exit(:crashed)

      "crash once" ->
        File.write!(Path.join(state.dir, state.turn.agent), "active")
        exit(:crashed)

      "end" ->
        send(state.turn_pid, {:agent, self(), {:ended, "the stub ended its turn"}})
        {:stop, :normal, state}

      "idle" ->
        AtlasRuntime.Agent.emit(state.turn_pid, "idle")
        Process.send_after(self(), :look, @look)
        {:noreply, state}

      "silent" ->
        Process.send_after(self(), :look, @look)
        {:noreply, state}

      _active ->
        n = state.n + 1
        AtlasRuntime.Agent.emit(state.turn_pid, "stub step #{n}")
        Process.send_after(self(), :look, @look)
        {:noreply, %{state | n: n}}
    end
  end

  defp mode(%{dir: nil}), do: "active"

  defp mode(state) do
    case File.read(Path.join(state.dir, state.turn.agent)) do
      {:ok, text} -> String.trim(text)
      _ -> "active"
    end
  end
end
