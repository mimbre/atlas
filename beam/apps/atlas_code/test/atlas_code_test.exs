defmodule AtlasCodeTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @token "runtime-secret-token"

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-qm", "base"])
    commit = source |> git(["rev-parse", "HEAD"]) |> String.trim()

    home = Path.join(dir, "home")
    File.mkdir!(home)
    config = %{"port" => 0, "repositories" => %{"github.com/test/fixture" => "file://" <> source}}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    token = Path.join(home, "runtime.token")
    File.write!(token, @token <> "\n")
    File.chmod!(token, 0o600)

    {:ok, pid, port} = AtlasCode.start(home)
    on_exit(fn -> AtlasCode.stop(pid) end)
    %{home: home, port: port, commit: commit, source: source}
  end

  test "health reports the service with the runtime token", %{port: port} do
    assert {200, %{"service" => "atlas-code", "version" => "0.1.0"}} = request(port, :get, "/v1/health")
  end

  test "resolve returns the exact branch commit", %{port: port, commit: commit, source: source} do
    assert {200, %{"repository" => "github.com/test/fixture", "ref" => "develop", "commit" => ^commit}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "develop"})

    # Only refs/heads/<ref> counts, not a longer name ending in it.
    git(source, ["branch", "nested/develop"])
    git(source, ["branch", "-m", "develop", "main"])

    assert {404, %{"error" => %{"code" => "unknown_ref"}}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "develop"})
  end

  test "unknown ref, forbidden repository and invalid requests are refused", %{port: port} do
    assert {404, %{"error" => %{"code" => "unknown_ref", "details" => %{"ref" => "missing"}}}} =
             resolve(port, %{"repository" => "github.com/test/fixture", "ref" => "missing"})

    assert {403, %{"error" => %{"code" => "forbidden"}}} =
             resolve(port, %{"repository" => "github.com/test/other", "ref" => "develop"})

    for body <- [
          "not json",
          "[]",
          JSON.encode!(%{"repository" => "github.com/test/fixture"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "develop", "extra" => 1}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => 1}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "../x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "-x"}),
          JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "a\u0000b"})
        ] do
      assert {400, %{"error" => %{"code" => "invalid_request", "details" => %{}}}} = raw(port, :post, "/v1/revisions/resolve", body)
    end

    assert {404, %{"error" => %{"code" => "not_found"}}} = request(port, :get, "/v1/other")
    assert {405, %{"error" => %{"code" => "method_not_allowed"}}} = request(port, :get, "/v1/revisions/resolve")
  end

  test "unreachable remotes are provider failures without Git output", %{tmp_dir: dir, home: home} do
    config = %{"port" => 0, "repositories" => %{"github.com/test/gone" => "file://" <> Path.join(dir, "gone")}}
    other = Path.join(dir, "other-home")
    File.mkdir!(other)
    File.write!(Path.join(other, "config.json"), JSON.encode!(config))
    File.cp!(Path.join(home, "runtime.token"), Path.join(other, "runtime.token"))
    File.chmod!(Path.join(other, "runtime.token"), 0o600)
    {:ok, pid, port} = AtlasCode.start(other)

    assert {503, %{"error" => %{"code" => "provider_unavailable", "message" => message}}} =
             resolve(port, %{"repository" => "github.com/test/gone", "ref" => "develop"})

    refute message =~ dir
    AtlasCode.stop(pid)
  end

  test "missing or wrong bearer tokens are unauthorized without echoing them", %{port: port} do
    body = JSON.encode!(%{"repository" => "github.com/test/fixture", "ref" => "develop"})

    for headers <- [[], [{~c"authorization", ~c"Bearer wrong-token"}], [{~c"authorization", ~c"Basic " ++ String.to_charlist(@token)}]] do
      for {method, path} <- [{:get, "/v1/health"}, {:post, "/v1/revisions/resolve"}, {:get, "/v1/other"}] do
        {status, reply} = send_request(port, method, path, body, headers)
        assert status == 401
        assert reply =~ ~s("unauthorized")
        refute reply =~ "wrong-token"
        refute reply =~ @token
      end
    end
  end

  test "start refuses a token file readable by others", %{home: home} do
    File.chmod!(Path.join(home, "runtime.token"), 0o644)
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
    File.rm!(Path.join(home, "runtime.token"))
    assert_raise RuntimeError, ~r/owner-only/, fn -> AtlasCode.start(home) end
  end

  defp resolve(port, body), do: raw(port, :post, "/v1/revisions/resolve", JSON.encode!(body))
  defp request(port, method, path), do: raw(port, method, path, "")

  defp raw(port, method, path, body) do
    {status, reply} = send_request(port, method, path, body, [{~c"authorization", ~c"Bearer " ++ String.to_charlist(@token)}])
    {status, JSON.decode!(reply)}
  end

  defp send_request(port, method, path, body, headers) do
    url = ~c"http://127.0.0.1:#{port}#{path}"
    request = if method == :post, do: {url, headers, ~c"application/json", body}, else: {url, headers}
    {:ok, {{_, status, _}, _, reply}} = :httpc.request(method, request, [timeout: 10_000, ssl: []], body_format: :binary)
    {status, reply}
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
