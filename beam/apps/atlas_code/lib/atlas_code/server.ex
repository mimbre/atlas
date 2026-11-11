defmodule AtlasCode.Server do
  @moduledoc """
  Runs the local Code service in this OS process until it is stopped. `mix atlas_code.server`
  (development) and the `atlas_code` release (`bin/atlas_code eval "AtlasCode.Server.run()"`)
  both start Code through `serve/1`, so a home behaves the same under either.
  """

  @doc """
  Release entry point: serves `$ATLAS_CODE_HOME` and never returns.
  """
  def run do
    home =
      System.get_env("ATLAS_CODE_HOME") ||
        raise "Set ATLAS_CODE_HOME to the Code home directory"

    {:ok, _pid, _port} = serve(home)
    Process.sleep(:infinity)
  end

  @doc """
  Starts the `:atlas_code` application and `AtlasCode.start/1` for `home`, makes SIGTERM stop
  the server, release the home and stop the VM, and prints `Code ready on 127.0.0.1:PORT`.
  """
  def serve(home) do
    {:ok, _} = Application.ensure_all_started(:atlas_code)
    {:ok, pid, port} = AtlasCode.start(home)

    # SIGTERM stops the server, then the home is released and the VM stops. Ctrl-C aborts the
    # VM without either, leaving the home owned until the next start recovers it.
    {:ok, _} =
      System.trap_signal(:sigterm, :atlas_code, fn ->
        AtlasCode.stop(pid)
        System.stop()
        :ok
      end)

    IO.puts("Code ready on 127.0.0.1:#{port}")
    {:ok, pid, port}
  end
end
