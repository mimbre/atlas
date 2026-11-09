defmodule AtlasFlow.Faults do
  @moduledoc """
  The failure Flow can be made to have, in the test environment (IS-Atlas-23), so that its
  recovery can be seen: `kill-process`, kill the process of an open fact (`AtlasFlow.Item`).
  Its supervisor starts it again at once, and the new one reads Facts: it keeps nothing of
  its own. Control asks over the Bus (class `fault`, which a prod Bus refuses).

  The fact is named by its key only; its kind is the one Flow runs a process for it under.
  """

  @back 2_000

  @doc "What Flow offers for the fact `key`: `[%{fault, label, text}]`."
  def offers(key) do
    case process(key) do
      nil ->
        []

      _ ->
        [
          %{
            "fault" => "kill-process",
            "label" => "Kill its process",
            "text" =>
              "Flow kills the process that keeps #{key} moving. Its supervisor starts a new " <>
                "one at once, which reads #{key} from Facts again."
          }
        ]
    end
  end

  @doc "Cause `fault` on `key`: `{:ok, what happened}` or `{:error, why}`."
  def run("kill-process", key) do
    case process(key) do
      nil ->
        {:error, "Flow runs no process for #{key} (any more)."}

      {name, pid} ->
        Process.exit(pid, :kill)

        case back(name, pid, System.monotonic_time(:millisecond) + @back) do
          nil ->
            {:ok, "Killed Flow's process for #{key} (#{inspect(pid)}); not back yet."}

          new ->
            {:ok,
             "Killed Flow's process for #{key}; back as a new one (#{inspect(pid)} → " <>
               "#{inspect(new)}), which read Facts again."}
        end
    end
  end

  def run(fault, key), do: {:error, "Flow does not offer #{fault} on #{key}."}

  # The process Flow runs for `key`, under whichever kind: `{registry name, pid}`.
  defp process(key) do
    case Registry.select(AtlasFlow.Items, [
           {{{:"$1", :"$2"}, :"$3", :_}, [{:==, :"$2", key}], [{{{{:"$1", :"$2"}}, :"$3"}}]}
         ]) do
      [{name, pid} | _] -> if Process.alive?(pid), do: {name, pid}
      [] -> nil
    end
  end

  # Its new process, once the supervisor started it.
  defp back(name, old, until) do
    case Registry.lookup(AtlasFlow.Items, name) do
      [{pid, _}] when pid != old ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(25)
          back(name, old, until)
        end
    end
  end
end
