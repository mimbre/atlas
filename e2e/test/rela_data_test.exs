defmodule AtlasE2E.RelaDataTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @bin AtlasE2E.Instance.rela_bin!()
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  defp schema do
    %{
      "version" => "1.0",
      "namespace" => "https://example.invalid/compatibility#",
      "entities" => %{
        "note" => %{
          "label" => "Note",
          "plural" => "notes",
          "id_type" => "manual",
          "properties" => %{"title" => %{"type" => "string"}, "count" => %{"type" => "integer"}}
        }
      },
      "relations" => %{
        "related" => %{"label" => "Related", "from" => ["note"], "to" => ["note"]}
      }
    }
  end

  defp project(dir, schema) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "schema.yaml"), JSON.encode!(schema))
    File.write!(Path.join(dir, "data-entry.yaml"), "app:\n  name: Private compatibility proof\n")
    dir
  end

  defp fits(proposed, data) do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {yaml, 0} =
      System.cmd(python, [Path.join(@root, "rela/scripts/config.py"), "flat", "--root", proposed])

    File.write!(Path.join(proposed, "schema.yaml"), yaml)

    System.cmd("bash", [Path.join(@root, "rela/scripts/fits.sh"), proposed, data],
      env: [{"ATLAS_RELA_BIN", @bin}],
      stderr_to_stdout: true
    )
  end

  defp api(url, method, path, body \\ nil) do
    args = ["-fsS", "-X", method, "-H", "content-type: application/json"]
    args = if body, do: args ++ ["-d", JSON.encode!(body)], else: args
    {json, 0} = System.cmd("curl", args ++ [url <> path])
    JSON.decode!(json)
  end

  test "SQLite snapshot preserves fields, IDs and links and destructive schemas refuse", c do
    data = project(Path.join(c.tmp_dir, "source"), schema())
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, number} = :inet.port(socket)
    :gen_tcp.close(socket)
    log = Path.join(c.tmp_dir, "server.log")

    server =
      Port.open({:spawn_executable, Path.join(@bin, "rela-server-headless-sqlite")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-project", data, "-bind", "127.0.0.1", "-port", "#{number}", "-quiet"]
      ])

    {:os_pid, pid} = Port.info(server, :os_pid)
    File.write!(Path.join(c.tmp_dir, "rela-server.pid"), "#{pid}\n")

    on_exit(fn ->
      System.cmd("bash", [Path.join(@root, "rela/scripts/stop.sh")],
        env: [
          {"ATLAS_TEST_ROOT", c.tmp_dir},
          {"ATLAS_RELA_PORT", "#{number}"},
          {"PATH", System.get_env("PATH") <> ":/usr/sbin:/sbin"}
        ],
        stderr_to_stdout: true
      )
    end)

    url = "http://127.0.0.1:#{number}/api/v1"

    try do
      await(server, url, log, 200)
      assert File.regular?(Path.join([data, ".rela", "rela.db"]))
      api(url, "POST", "/notes", %{id: "one", properties: %{title: "Populated", count: 7}})
      api(url, "POST", "/notes", %{id: "two", properties: %{title: "Target", count: 9}})

      api(url, "PATCH", "/notes/one", %{
        relations: %{related: %{data: [%{type: "note", id: "two"}]}}
      })

      before = Enum.map(["one", "two"], &api(url, "GET", "/notes/#{&1}"))
      # Existing DB must win over stale markdown, as upstream selects the backend.
      File.mkdir_p!(Path.join(data, "entities/notes"))
      File.write!(Path.join(data, "entities/notes/shadow.md"), "stale markdown is not the store")
      snapshot = Path.join(c.tmp_dir, "snapshot")

      {out, status} =
        System.cmd("bash", [Path.join(@root, "rela/scripts/data.sh"), "snapshot", data, snapshot],
          env: [{"ATLAS_RELA_BIN", @bin}],
          stderr_to_stdout: true
        )

      assert status == 0, out
      one = File.read!(Path.join(snapshot, "markdown/entities/notes/one.md"))
      two = File.read!(Path.join(snapshot, "markdown/entities/notes/two.md"))
      assert one =~ "id: one"
      assert one =~ "title: Populated"
      assert one =~ "count: 7"
      assert two =~ "id: two"
      assert two =~ "title: Target"
      assert two =~ "count: 9"
      refute File.exists?(Path.join(snapshot, "markdown/entities/notes/shadow.md"))
      assert File.regular?(Path.join(snapshot, "markdown/relations/one--related--two.md"))
      link = File.read!(Path.join(snapshot, "markdown/relations/one--related--two.md"))
      assert link =~ "from: one"
      assert link =~ "relation: related"
      assert link =~ "to: two"

      proposed = project(Path.join(c.tmp_dir, "proposed"), schema())
      assert {_, 0} = fits(proposed, data)

      for changed <- [
            put_in(schema(), ["entities", "note", "properties"], %{}),
            Map.put(schema(), "entities", %{}),
            Map.put(schema(), "relations", %{})
          ] do
        project(proposed, changed)
        {out, status} = fits(proposed, data)
        assert status != 0, "destructive description was accepted: #{out}"
        assert Enum.map(["one", "two"], &api(url, "GET", "/notes/#{&1}")) == before
      end
    after
      System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
      assert_receive {^server, {:exit_status, 0}}, 10_000
    end
  end

  defp await(_server, _url, _log, 0), do: flunk("private SQLite server did not answer")

  defp await(server, url, log, remaining) do
    receive do
      {^server, {:data, data}} ->
        File.write!(log, data, [:append])
        await(server, url, log, remaining)

      {^server, {:exit_status, status}} ->
        flunk("private server exited #{status}: #{File.read(log) |> inspect()}")
    after
      25 ->
        case :httpc.request(String.to_charlist(url <> "/_schema")) do
          {:ok, {{_, 200, _}, _, _}} -> :ok
          _ -> await(server, url, log, remaining - 1)
        end
    end
  end
end
