defmodule AtlasFacts.Connector.GitHub do
  @moduledoc """
  The source of `AtlasFacts.Connector` for GitHub: reads one of GitHub's pulls by its web
  address, read-only, over GitHub's REST API (`GET /repos/<owner>/<repo>/pulls/<n>`), and
  answers its fields as `gh` names them: `title`, `state` (`open`, `closed` or `merged`),
  `isDraft`, `url`.

  `config` (`github` in `env/<env>.json`):

  - `api`: the API's base URL, `https://api.github.com`; the end-to-end test points it at
    a stand-in.
  - `token_command`: the command that prints the token, `["gh", "auth", "token"]`. It runs
    once per read; the token stays in memory for that read only. Atlas never writes it to
    disk and never logs it. Without a command, GitHub is read anonymously.
  - `token_env`: instead of a command, the environment variable that holds the token; on
    Fly it is a secret of the core's app (`fly/prod/core.json`). Read once per read too.

  Only GET requests: nothing is ever written to GitHub.
  """
  @behaviour AtlasFacts.Connector

  @address ~r{^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$}

  @impl true
  def label(_config), do: "GitHub"

  @impl true
  def read(_config, []), do: %{}

  def read(config, addresses) do
    case token(config) do
      {:ok, token} -> Map.new(addresses, &{&1, read_one(config, token, &1)})
      {:error, reason} -> Map.new(addresses, &{&1, {:error, reason}})
    end
  end

  # A crash here would print its arguments, the token among them; so it becomes a reason.
  defp read_one(config, token, address) do
    case Regex.run(@address, address) do
      [_, owner, repo, number] ->
        url = "#{String.trim_trailing(config["api"], "/")}/repos/#{owner}/#{repo}/pulls/#{number}"
        get(url, token)

      nil ->
        {:error, "#{address} is not the address of a GitHub pull"}
    end
  rescue
    error -> {:error, "reading GitHub failed (#{inspect(error.__struct__)})"}
  end

  defp get(url, token) do
    headers =
      [
        {~c"accept", ~c"application/vnd.github+json"},
        {~c"x-github-api-version", ~c"2022-11-28"},
        {~c"user-agent", ~c"atlas-facts"}
      ] ++ if(token, do: [{~c"authorization", String.to_charlist("Bearer " <> token)}], else: [])

    options = [timeout: 10_000, connect_timeout: 5_000] ++ ssl(url)

    case :httpc.request(:get, {String.to_charlist(url), headers}, options, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case JSON.decode(body) do
          {:ok, %{"title" => title, "state" => state} = pull} ->
            {:ok,
             %{
               "title" => title,
               "state" => if(pull["merged"] == true, do: "merged", else: state),
               "isDraft" => pull["draft"] == true,
               "url" => pull["html_url"]
             }}

          _ ->
            {:error, "GitHub answered something that is not a pull"}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "GitHub answered #{status}#{why(status)}"}

      {:error, reason} ->
        {:error, "GitHub is not reachable (#{inspect(reason)})"}
    end
  end

  defp why(401), do: " (the token was refused)"
  defp why(403), do: " (rate limit, or no access)"
  defp why(404), do: " (no such pull, or no access)"
  defp why(429), do: " (rate limit)"
  defp why(_), do: ""

  defp ssl("https:" <> _) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl(_url), do: []

  # The token for one read. What the command prints is never logged: a failure says only
  # which command failed and its exit status.
  defp token(%{"token_env" => name}) when is_binary(name) do
    case System.get_env(name) do
      token when token in [nil, ""] -> {:error, "no token: #{name} is not set"}
      token -> {:ok, String.trim(token)}
    end
  end

  defp token(config), do: command_token(config["token_command"])

  defp command_token(nil), do: {:ok, nil}
  defp command_token([]), do: {:ok, nil}

  defp command_token([command | args]) do
    case System.find_executable(command) do
      nil ->
        {:error, "no token: #{command} is not installed"}

      path ->
        case System.cmd(path, args, stderr_to_stdout: false) do
          {out, 0} when out != "" ->
            {:ok, String.trim(out)}

          {_, 0} ->
            {:error, "no token: #{Enum.join([command | args], " ")} printed nothing"}

          {_, status} ->
            {:error, "no token: #{Enum.join([command | args], " ")} exited #{status}"}
        end
    end
  rescue
    _ -> {:error, "no token: #{command} could not run"}
  end
end
