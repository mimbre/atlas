defmodule AtlasE2E.PageFreshnessTest do
  @moduledoc """
  Page freshness end to end (docs/design/page-freshness.md §5, slice F8), on the stack the
  e2e suite runs: a private rela, the core and two real TUIs in tmux. The core runs as
  `atlas-ops up` runs it (`mix run` in beam, Mix's dev environment, the private
  settings), with `page_freshness/proof.exs` run inside its node, so the proof can hold
  Control's and Flow's time (§2.1, §2.2) and watch what each session sends its TUI. rela
  is this test's port: it stops with the test, and so does the core.

  The proof shows:

  1. precision: a session whose pages do not depend on a write gets no push for it; a
     page that depends on it is pushed by hint, within the suite's second;
  2. read-your-writes: after `a` on a decision, the first page the TUI gets is the stored
     one, and it already shows what Flow did (the decision handed on, the count down);
     the core logs no settle timeout;
  3. the marker: after `f`, while Flow has not settled, every list page shows the
     answered row `⋯ being processed`, and none shows it gone; once Flow settles, the
     row has left and nothing is marked;
  4. selection: after `a` and after `f`, the row that left was selected, and the row now
     at its index is.
  """
  use ExUnit.Case, async: false

  alias AtlasE2E.{Instance, Tui}

  @bin Instance.rela_bin()
  @moduletag skip:
               if(@bin == nil, do: "set ATLAS_E2E_RELA_BIN to pinned Rela 26.11.2", else: false)
  @moduletag timeout: 900_000
  @proof Path.expand("page_freshness/proof.exs", __DIR__)

  test "a submit is read once Flow settled; its rows are pending till then; pushes go only where they depend" do
    :ok = Instance.compile()
    instance = Instance.prepare()
    socket = "atlas-freshness-#{System.os_time(:millisecond)}"
    rela = start_rela(instance)

    on_exit(fn ->
      Tui.kill_server(socket)
      stop_rela(rela)
      if Process.whereis(AtlasE2E.GitHub), do: Agent.stop(AtlasE2E.GitHub)
      File.rm_rf!(instance.dir)
    end)

    File.write!(
      Path.join(instance.dir, "proof.json"),
      JSON.encode!(%{
        root: instance.root,
        socket: socket,
        env: Enum.map(instance.env, &Tuple.to_list/1)
      })
    )

    {out, status} =
      System.cmd("mix", ["run", @proof, instance.dir],
        cd: Path.join(instance.root, "beam"),
        env: instance.env ++ [{"ATLAS_ENV", "test"}, {"ATLAS_ROOT", instance.root}],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^  [✓✗] |proof:/))
    |> Enum.each(&IO.puts/1)

    assert status == 0, out
    assert out =~ "page freshness proof: 3 steps passed", out
    # The core's log (what `atlas-ops` writes to core.log) has no settle timeout.
    refute out =~ "settle timeout", out
  end

  # rela as `atlas-ops` starts it (rela/scripts/start-test.sh), in the foreground, under a
  # shell that stops it when this test's port closes.
  defp start_rela(instance) do
    rela = instance.settings["rela"]

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~s|"$0" & pid=$!; echo "rela-pid $pid"; read _; kill "$pid"|,
          Path.join(instance.root, "rela/scripts/start-test.sh")
        ],
        env: [
          {~c"ATLAS_ENV", ~c"test"},
          {~c"ATLAS_RELA_PORT", ~c"#{rela["port"]}"},
          {~c"ATLAS_RELA_DATA", String.to_charlist(rela["data"])},
          {~c"ATLAS_RELA_BIN", String.to_charlist(rela["bin"])}
        ]
      ])

    pid = rela_pid(port, "")
    :ok = answers(rela["url"] <> "/_schema", System.monotonic_time(:millisecond) + 120_000, port)
    %{port: port, pid: pid}
  end

  defp rela_pid(port, seen) do
    receive do
      {^port, {:data, chunk}} ->
        case Regex.run(~r/rela-pid (\d+)/, seen <> chunk) do
          [_, pid] -> pid
          nil -> rela_pid(port, seen <> chunk)
        end

      {^port, {:exit_status, status}} ->
        flunk("rela did not start (#{status}): #{seen}")
    after
      30_000 -> flunk("rela did not start: #{seen}")
    end
  end

  defp answers(url, deadline, port) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 2_000], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      _ ->
        receive do
          {^port, {:exit_status, status}} -> flunk("rela stopped (#{status})")
        after
          0 -> :ok
        end

        if System.monotonic_time(:millisecond) > deadline, do: flunk("rela did not answer #{url}")
        Process.sleep(200)
        answers(url, deadline, port)
    end
  end

  defp stop_rela(%{port: port, pid: pid}) do
    if Port.info(port), do: Port.close(port)
    System.cmd("/bin/kill", ["-TERM", pid], stderr_to_stdout: true)
  end
end
