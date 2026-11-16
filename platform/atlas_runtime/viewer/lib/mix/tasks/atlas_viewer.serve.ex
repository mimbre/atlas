defmodule Mix.Tasks.AtlasViewer.Serve do
  @shortdoc "Serves the local read-only Runtime viewer on 127.0.0.1"
  @moduledoc """
  `mix atlas_viewer.serve [--home DIR] [--port N]`

  Serves the viewer for the Runtime at `DIR` (default `$ATLAS_RUNTIME_HOME`, else
  `~/.local/state/atlas-runtime`, as `atlas-runtime` uses). It reads only `DIR/read.sock`
  and does not start, stop or connect to Runtime until the page reads. `--port 0`, the
  default, picks a free port. Prints the URL with this launch's access token in its
  fragment; the token is never written anywhere. Ctrl-C stops the viewer, not Runtime.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [home: :string, port: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix atlas_viewer.serve [--home DIR] [--port N]")

    Mix.Task.run("app.start")

    home =
      Path.expand(
        opts[:home] || System.get_env("ATLAS_RUNTIME_HOME") ||
          Path.join([System.user_home!(), ".local", "state", "atlas-runtime"])
      )

    {:ok, _pid, port, token} = AtlasViewer.start(home: home, port: Keyword.get(opts, :port, 0))
    IO.puts("Atlas Runtime viewer (read-only) for #{AtlasViewer.ReadClient.socket(home)}")
    IO.puts("Open: http://127.0.0.1:#{port}/#token=#{token}")

    IO.puts(
      "The token exists only in this process. Ctrl-C stops the viewer; Runtime is unaffected."
    )

    Process.sleep(:infinity)
  end
end
