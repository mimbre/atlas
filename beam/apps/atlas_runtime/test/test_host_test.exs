defmodule AtlasRuntime.TestHostTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.TestHost

  @moduletag :tmp_dir
  @socket "/runtime.sock"

  # TMPDIR may carry a trailing slash or pass through a symlink (/var -> /private/var);
  # short_dir! keeps the path as given, so compare without the trailing slash.
  defp normal(path), do: Path.expand(path)

  # The contract: a new directory directly under one of the candidates, whose socket path
  # fits sockaddr_un and binds.
  defp assert_socket_dir(dir, candidates) do
    assert normal(Path.dirname(dir)) in Enum.map(candidates, &normal/1)
    assert File.dir?(dir)
    assert byte_size(dir <> @socket) + 1 <= 104
    {:ok, listener} = :gen_tcp.listen(0, ifaddr: {:local, dir <> @socket})
    :gen_tcp.close(listener)
  end

  test "a socket directory lies under TMPDIR or the app's test tmp, never a hardcoded /tmp" do
    dir = TestHost.short_dir!("ths", @socket)
    assert_socket_dir(dir, [System.tmp_dir!(), Path.join(File.cwd!(), "tmp")])

    # /tmp only where it is the system temporary directory itself (Linux without TMPDIR).
    if normal(System.tmp_dir!()) not in ["/tmp", "/private/tmp"],
      do: refute(String.starts_with?(normal(dir), ["/tmp/", "/private/tmp/"]))
  end

  test "a temp directory too long for a socket path falls back to the next, else refuses",
       %{tmp_dir: tmp_dir} do
    long = Path.join(tmp_dir, String.duplicate("x", 100))
    short = System.tmp_dir!()
    dir = TestHost.short_dir!("ths", @socket, [long, short])
    # Only the short candidate fits, so it is the one chosen.
    assert_socket_dir(dir, [short])
    refute File.exists?(long)

    assert_raise RuntimeError, ~r/no temporary directory is short enough/, fn ->
      TestHost.short_dir!("ths", @socket, [long])
    end
  end
end
