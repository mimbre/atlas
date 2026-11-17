Code.require_file("support.exs", __DIR__)

defmodule AtlasRuntime.BackendTest.Listener do
  @moduledoc """
  The backend's listener (design §8.1): Bandit on `<home>/backend.sock`, mode 0600,
  removed on stop, every client the socket's owner with all work rights plus `inspect`
  and `operate` (§13.1 Q4). Answers plain `curl --unix-socket` (G10).
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias AtlasRuntime.Backend.{Listener, TestSocket}
  alias AtlasRuntime.Test.{FakeOperations, FakeWork}

  setup do
    FakeWork.reset_all()
    FakeOperations.reset_all()
    FakeWork.owner(self())

    on_exit(fn ->
      FakeWork.reset_all()
      FakeOperations.reset_all()
    end)

    home = TestSocket.home()
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home, path: Path.join(home, "backend.sock")}
  end

  # What the listener must leave alone on a file: everything but the access time.
  defp untouched(path) do
    %File.Stat{} = stat = File.lstat!(path, time: :posix)
    Map.take(stat, [:type, :size, :mode, :inode, :links, :uid, :gid, :mtime, :ctime])
  end

  defp start(home, opts \\ []),
    do:
      start_supervised(
        {Listener, Keyword.merge([home: home, router: AtlasRuntime.Test.WorkRest], opts)}
      )

  @tag :curl
  test "curl --unix-socket answers GET /v1/capacity", %{home: home, path: path} do
    {:ok, _} = start(home)

    {out, 0} =
      System.cmd("curl", ["-sS", "-i", "--unix-socket", path, "http://localhost/v1/capacity"],
        stderr_to_stdout: true
      )

    [head, body] = String.split(out, "\r\n\r\n", parts: 2)
    assert head =~ "HTTP/1.1 200"
    assert head =~ ~r/retry-after: 60/i
    assert head =~ "content-type: application/json"
    assert %{"accepting" => false, "slots" => %{"total" => 2}} = JSON.decode!(body)

    assert_received {:fake_work, :capacity, {"local:" <> _user, rights}, nil}

    assert rights == [
             :submit,
             :cancel,
             :read,
             :read_all,
             :choose_slot,
             :choose_path,
             :inspect,
             :operate
           ]
  end

  @tag :curl
  test "the socket's owner operates: curl POST /v1/control/pause and GET /v1/runtime",
       %{home: home, path: path} do
    {:ok, _} = start(home)

    curl = fn args ->
      {out, 0} =
        System.cmd("curl", ["-sS", "-i", "--unix-socket", path | args], stderr_to_stdout: true)

      [head, body] = String.split(out, "\r\n\r\n", parts: 2)
      {head, JSON.decode!(body)}
    end

    {head, body} = curl.(["-X", "POST", "http://localhost/v1/control/pause"])
    assert head =~ "HTTP/1.1 200"
    assert %{"mode" => "paused", "slots" => [%{"name" => "s1", "busy" => true} | _]} = body
    assert_received {:fake_operations, :pause, {"local:" <> _, rights}, nil}
    assert :operate in rights and :inspect in rights

    {head, body} = curl.(["http://localhost/v1/runtime"])
    assert head =~ "HTTP/1.1 200"
    assert %{"mode" => "open", "incarnation" => "i-1"} = body
  end

  @tag :curl
  test "a capability that raises (the S2b skeletons, before S2c) is a 500 on the socket",
       %{home: home, path: path} do
    FakeOperations.answer(:runtime_info, fn _, _ ->
      raise "runtime_info has no implementation yet"
    end)

    {:ok, _} = start(home)

    ExUnit.CaptureLog.capture_log(fn ->
      {out, 0} =
        System.cmd(
          "curl",
          [
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "--unix-socket",
            path,
            "http://localhost/v1/runtime"
          ],
          stderr_to_stdout: true
        )

      assert out == "500"
    end)
  end

  test "the client is local:<name of the process's uid>, whatever $USER says",
       %{home: home, path: path} do
    {uid, 0} = System.cmd("id", ["-u"])
    {name, 0} = System.cmd("id", ["-un"])
    saved = for var <- ["USER", "LOGNAME"], do: {var, System.get_env(var)}

    on_exit(fn ->
      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    System.put_env("USER", "not-the-owner")
    System.put_env("LOGNAME", "not-the-owner")

    {:ok, _} = start(home)
    assert File.lstat!(path).uid == String.to_integer(String.trim(uid))
    stream = TestSocket.open(path, "/v1/capacity")
    {stream, _} = TestSocket.await(stream, "\r\n\r\n")
    TestSocket.close(stream)

    assert_received {:fake_work, :capacity, {id, _rights}, nil}
    assert id == "local:" <> String.trim(name)
    refute id =~ "not-the-owner"
  end

  test "the socket is backend.sock, mode 0600, and is removed on stop; runtime.sock is untouched",
       %{home: home, path: path} do
    runtime_sock = Path.join(home, "runtime.sock")
    File.write!(runtime_sock, "not ours")
    before = untouched(runtime_sock)

    {:ok, pid} = start(home)
    assert Listener.path(home) == path
    assert %File.Stat{type: :other, mode: mode} = File.lstat!(path)
    assert (mode &&& 0o777) == 0o600

    :ok = stop_supervised(Listener)
    refute Process.alive?(pid)
    refute File.exists?(path)
    # Stat first: the read below updates the access time, which is no change of ours.
    assert untouched(runtime_sock) == before
    assert File.read!(runtime_sock) == "not ours"
  end

  test "a socket left over by a listener that is gone is replaced", %{home: home, path: path} do
    {:ok, left} = :gen_tcp.listen(0, ifaddr: {:local, path})
    :gen_tcp.close(left)
    assert File.exists?(path)

    {:ok, _} = start(home)
    {stream, head} = TestSocket.open(path, "/v1/capacity") |> TestSocket.await("\r\n\r\n")
    assert head =~ "HTTP/1.1 200"
    TestSocket.close(stream)
  end

  test "a socket that still answers is not taken over; nor is a file that is no socket",
       %{home: home, path: path} do
    {:ok, _} = start(home)

    assert {:error, :already_listening} =
             GenServer.start(Listener, home: home, router: AtlasRuntime.Test.WorkRest)

    other = TestSocket.home()
    File.write!(Path.join(other, "backend.sock"), "")

    assert {:error, {:not_a_socket, _, :regular}} =
             GenServer.start(Listener, home: other, router: AtlasRuntime.Test.WorkRest)

    File.rm_rf!(other)
    assert File.exists?(path)
  end

  test "the application starts no listener (it is started from the host service only)" do
    children = tree(AtlasRuntime.Root)
    refute Listener in children
    refute Bandit in children
    source = File.read!(Path.expand("../../lib/atlas_runtime/application.ex", __DIR__))
    refute source =~ "Backend"
  end

  defp tree(supervisor) do
    for {id, pid, type, modules} <- Supervisor.which_children(supervisor),
        item <-
          [id | List.wrap(modules)] ++
            if(type == :supervisor and is_pid(pid), do: tree(pid), else: []),
        do: item
  end
end
