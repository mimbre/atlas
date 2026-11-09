defmodule AtlasFlowGenerator.Limits do
  @moduledoc "Resolve gate limits into concrete periods before hashing an environment's pair."
  def resolve(flows, gates, environment) do
    Enum.map(flows, fn flow ->
      Map.update!(flow, :states, fn states ->
        Enum.map(states, fn state ->
          Map.update!(state, :timers, fn timers ->
            Enum.map(timers, fn timer ->
              case timer.period do
                {:gate_limit, name} ->
                  gate =
                    Enum.find(gates, &(&1.name == name)) ||
                      raise ArgumentError, "unknown gate limit #{name}"

                  period = (gate[:answer_within] || [])[environment]

                  unless is_binary(period) and
                           Regex.match?(~r/\A[1-9][0-9]*(ms|s|m|h|d)\z/, period),
                         do:
                           raise(
                             ArgumentError,
                             "missing or invalid #{environment} limit for #{name}"
                           )

                  %{timer | period: period}

                period when is_binary(period) ->
                  timer

                _ ->
                  raise ArgumentError, "unresolved timer period"
              end
            end)
          end)
        end)
      end)
    end)
  end
end
