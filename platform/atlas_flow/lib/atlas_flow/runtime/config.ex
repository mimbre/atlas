defmodule AtlasFlow.Runtime.Config do
  @moduledoc """
  The machinery Flow may hand tasks to: one Runtime backend per name, as Flow's
  configuration names it (plan 2026-11-17 §3.1, §3.4).

      config :atlas_flow,
        machinery: %{
          "mac-mini" => %{
            url: "https://mini.example.ts.net",
            token_env: "ATLAS_FLOW_RUNTIME_TOKEN",
            proxy: "http://localhost:1055"
          }
        }

  - `url`: the backend's base URL (`http` or `https`); the client adds `/v1/…`.
  - `token_env`: the name of the environment variable that holds Flow's Bearer token
    (§8.1: one least-rights token per client, never written in configuration).
  - `proxy` (optional): an HTTP CONNECT proxy (`http://host:port`), such as tailscaled's
    `--outbound-http-proxy-listen` on the core (§9). Mint tunnels `https` through it.

  Keys may be atoms or strings (a settings file gives strings). The default is empty, so
  no machinery is reached on test or prod until one is configured (go-live, plan §5.2).
  Flow never names a slot, a model, a vendor or a path on the machinery's machine: those
  are the Runtime's (D44).
  """

  @enforce_keys [:name, :url, :token_env]
  defstruct [:name, :url, :token_env, :proxy]

  @type proxy :: {:http | :https, String.t(), :inet.port_number()}
  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          token_env: String.t(),
          proxy: proxy() | nil
        }

  @doc "Every configured machinery, by name; empty unless configured."
  @spec all() :: %{String.t() => t()}
  def all do
    :atlas_flow
    |> Application.get_env(:machinery, %{})
    |> Map.new(fn {name, entry} ->
      name = to_string(name)
      {name, new!(name, entry)}
    end)
  end

  @doc "The machinery named `name`; `:error` when none is configured under it."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name), do: Map.fetch(all(), to_string(name))

  @doc "A machinery from one configuration entry; raises on a malformed one."
  @spec new!(String.t(), map() | keyword()) :: t()
  def new!(name, entry) do
    entry = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
    url = Map.get(entry, "url")
    token_env = Map.get(entry, "token_env")

    unless is_binary(url) and
             match?(
               %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "",
               URI.parse(url)
             ),
           do:
             raise(
               ArgumentError,
               "machinery #{name}: url must be an http(s) URL, got #{inspect(url)}"
             )

    unless is_binary(token_env) and token_env != "",
      do: raise(ArgumentError, "machinery #{name}: token_env must name an environment variable")

    %__MODULE__{
      name: name,
      url: String.trim_trailing(url, "/"),
      token_env: token_env,
      proxy: proxy!(name, Map.get(entry, "proxy"))
    }
  end

  @doc "The Bearer token, read from the environment at each call; nil when unset."
  @spec token(t()) :: String.t() | nil
  def token(%__MODULE__{token_env: env}) do
    case System.get_env(env) do
      nil -> nil
      "" -> nil
      token -> token
    end
  end

  defp proxy!(_name, nil), do: nil

  defp proxy!(name, proxy) when is_binary(proxy) do
    case URI.parse(proxy) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        {String.to_existing_atom(scheme), host, port}

      _ ->
        raise ArgumentError,
              "machinery #{name}: proxy must be http://host:port, got #{inspect(proxy)}"
    end
  end

  defp proxy!(name, proxy),
    do:
      raise(ArgumentError, "machinery #{name}: proxy must be a URL string, got #{inspect(proxy)}")
end
