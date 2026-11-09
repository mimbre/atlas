defmodule AtlasRuntime.Faults do
  @moduledoc """
  The failures Runtime can be made to have, in the test environment (IS-Atlas-23), so
  that its recovery can be seen. Control asks over the Bus (class `fault`, which a prod Bus
  refuses) what Runtime offers for a fact, and causes one:

  - on a turn it runs: `kill-agent`, kill the agent's process; the turn ends as a crash and
    the owner's next turn starts after the crash pause;
  - on an agent it runs through the stand-in (`stub`), never another port: `idle` (it shows
    it is there and does nothing, so its turn runs to its maximum), `silent` (it shows
    nothing, so its turn ends at the silence limit), `empty` (it ends each turn at once,
    without a change), and `active` (back to work).

  The fact is named by its key only: no kind.
  """

  alias AtlasRuntime.Turn

  # {fault, the stub's mode, label, what will be seen, what it is now}
  @modes [
    {"idle", "idle", "Make it idle",
     "It shows it is there and does nothing: its turn runs to its maximum, then it gets a new one.",
     "is idle"},
    {"silent", "silent", "Make it silent",
     "It shows nothing: its turn ends at the silence limit, then it gets a new one.",
     "is silent"},
    {"empty", "end", "Make it end its turns empty",
     "It ends each turn at once, without a change: a new turn follows each one.",
     "ends its turns empty"},
    {"active", "active", "Put it back to work", "It shows activity again, as before.",
     "is back at work"}
  ]

  @doc "What Runtime offers for the fact `key`: `[%{fault, label, text}]`."
  def offers(key, opts) do
    agent_offers(key, opts) ++ turn_offers(key)
  end

  @doc "Cause `fault` on the fact `key`: `{:ok, what happened}` or `{:error, why}`."
  def run(fault, key, opts) do
    if Enum.any?(offers(key, opts), &(&1["fault"] == fault)),
      do: cause(fault, key, opts),
      else: {:error, "Runtime does not offer #{fault} on #{key} (any more)."}
  end

  defp turn_offers(key) do
    case Registry.lookup(AtlasRuntime.Turns, key) do
      [{_pid, {agent, item}}] ->
        [
          offer(
            "kill-agent",
            "Kill its agent",
            "Runtime kills #{agent}'s process for this turn on #{item}. The turn ends as a " <>
              "crash, and #{agent}'s next turn starts after the crash pause."
          )
        ]

      [] ->
        []
    end
  end

  defp agent_offers(key, opts) do
    agents = Keyword.get(opts, :agents, %{})

    if stub?(agents[key], opts),
      do: for({fault, _mode, label, text, _now} <- @modes, do: offer(fault, label, text)),
      else: []
  end

  # Only the stand-in has modes; a real agent (claude) never gets one from here.
  defp stub?(%{"port" => "stub"}, opts), do: is_binary(Keyword.get(opts, :stub_dir))
  defp stub?(_settings, _opts), do: false

  defp offer(fault, label, text), do: %{"fault" => fault, "label" => label, "text" => text}

  defp cause("kill-agent", key, _opts) do
    with [{turn, {agent, _item}}] <- Registry.lookup(AtlasRuntime.Turns, key),
         pid when is_pid(pid) <- Turn.agent(turn) do
      Process.exit(pid, :kill)
      {:ok, "Killed #{agent}'s process for #{key}. Runtime ends the turn as a crash."}
    else
      _ -> {:error, "#{key} has no agent running any more."}
    end
  catch
    :exit, _ -> {:error, "#{key} ended meanwhile."}
  end

  defp cause(fault, key, opts) do
    {_, mode, _, _, now} = List.keyfind(@modes, fault, 0)
    File.write!(Path.join(Keyword.fetch!(opts, :stub_dir), key), mode)
    {:ok, "#{key} #{now} now."}
  end
end
