defmodule AtlasFacts.NativeRela do
  @moduledoc """
  A private native rela for integration tests against the pinned rela: its binaries are found
  in ATLAS_E2E_RELA_BIN, ATLAS_RELA_BIN, the `rela-bin` folder beside the checkout when it
  holds rela-server-headless-sqlite (a worker's), else the test instance's (as e2e's
  AtlasE2E.Instance.rela_bin!/0).
  """
  import ExUnit.Assertions, only: [flunk: 1]
  alias AtlasFacts.Rela

  @root Path.expand("../../../..", __DIR__)

  @doc "The checkout's root."
  def root, do: @root

  @doc "The folder with rela's binaries."
  def bin do
    Enum.find(
      [System.get_env("ATLAS_E2E_RELA_BIN"), System.get_env("ATLAS_RELA_BIN")],
      &(&1 not in [nil, ""])
    ) ||
      if(File.exists?(Path.join([@root, "../rela-bin", "rela-server-headless-sqlite"])),
        do: Path.join(@root, "../rela-bin"),
        else: Path.expand("~/.local/share/atlas/test/bin")
      )
  end

  @doc "Whether the pinned rela's server is there."
  def available?, do: File.exists?(Path.join(bin(), "rela-server-headless-sqlite"))

  @doc """
  Starts rela-server-headless-sqlite on the project in `dir`, on a free local port, and
  stops it when the test ends. Returns `{rela, os_pid, port}` once it answers.
  """
  def start(dir) do
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    process =
      Port.open({:spawn_executable, Path.join(bin(), "rela-server-headless-sqlite")}, [
        :binary,
        :exit_status,
        args: ["-project", dir, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
      ])

    {:os_pid, pid} = Port.info(process, :os_pid)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    end)

    rela = {Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
    wait(rela, 100)
    {rela, pid, process}
  end

  defp wait(rela, remaining) do
    case Rela.description(rela) do
      {:ok, _} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(20)
        wait(rela, remaining - 1)

      other ->
        flunk("private rela failed to start: #{inspect(other)}")
    end
  end
end
