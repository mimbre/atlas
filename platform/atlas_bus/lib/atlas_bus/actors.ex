defmodule AtlasBus.Actors do
  @moduledoc """
  The actors an environment configures: who fills each role its model names. A model
  names roles, never keys (`actors/0`: `[{role, kind}]`, such as the one who decides);
  the environment's settings give each role the key of a fact of that kind (`"actors":
  {"role": "key"}`, wired as `config :atlas, actors: %{"role" => "key"}`).

  The layers that run the model's owners (Flow, and Control) resolve them when they
  start, and neither starts without them: `resolve/2` refuses a role the settings do not
  fill. There is no default and no fallback to anyone else. Whether the actor's fact
  exists is not checked here: an owner that does not exist yet waits for it (Flow).
  """

  @typedoc "Each role's actor, by role: `%{\"kind\" => kind, \"key\" => key}`."
  @type actors :: %{String.t() => %{String.t() => String.t()}}

  @doc "What this environment's settings configure: `%{role => key}`, or nil."
  def configured, do: Application.get_env(:atlas, :actors)

  @doc """
  The actor of every role in `needed` (`[{role, kind}]`), from `configured` (`%{role =>
  key}`): `{:ok, actors}`, or `{:error, why}` for the first role it does not fill.
  """
  @spec resolve([{atom | String.t(), String.t()}], map | nil) ::
          {:ok, actors} | {:error, String.t()}
  def resolve(needed, configured \\ configured()) do
    configured = if is_map(configured), do: configured, else: %{}

    Enum.reduce_while(needed, {:ok, %{}}, fn {given, kind}, {:ok, acc} ->
      role = to_string(given)

      case Map.get(configured, role, Map.get(configured, given)) do
        key when is_binary(key) and key != "" ->
          {:cont, {:ok, Map.put(acc, role, %{"kind" => to_string(kind), "key" => key})}}

        other ->
          {:halt,
           {:error,
            "the environment's settings give no actors.#{role} (#{inspect(other)}): the key " <>
              "of the #{kind} the model's owners name as #{role}; set it in the settings " <>
              "file this node runs with"}}
      end
    end)
  end
end
