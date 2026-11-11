defmodule AtlasRuntime.TestHost do
  @moduledoc """
  What a test may need from the host beyond its own files, found by trying it once per run.

  `missing/1` is `false` where the capability works and otherwise a reason, so a test that
  needs it declares `@tag skip: TestHost.missing(:nested_sandbox)`: in a sandboxed worker
  it reports skipped with that reason instead of failing; on CI and in a normal shell the
  probe succeeds and it runs. `short_dir!/2` gives a directory short enough for a Unix
  socket path without assuming /tmp.
  """

  # sockaddr_un's path, terminating NUL included: 104 bytes on macOS (108 on Linux).
  @socket_path_limit 104

  @doc "`false` if the capability works on this host, else why the test cannot run here."
  def missing(capability) do
    key = {__MODULE__, capability}

    case :persistent_term.get(key, :unprobed) do
      :unprobed ->
        result = probe(capability)
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Each capability probed in this run that is missing here, with its reason."
  def missing_report do
    for {{__MODULE__, capability}, reason} when is_binary(reason) <- :persistent_term.get(),
        do: {capability, reason}
  end

  # Applying a Seatbelt profile; an already-sandboxed process may not apply another.
  defp probe(:nested_sandbox) do
    case run("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)", "/usr/bin/true"]) do
      {_, 0} -> false
      {out, status} -> "needs nested sandbox: sandbox-exec probe failed (#{status}): #{out}"
    end
  end

  # Listing a process by PID: this VM is alive, so `ps` must report it.
  defp probe(:process_listing) do
    case run("ps", ["-p", System.pid(), "-o", "stat="]) do
      {out, 0} when out != "" ->
        false

      {out, status} ->
        "needs process listing: ps could not list this VM's own PID (#{status}): #{out}"
    end
  end

  # Claude's private temp: the host makes HOME/.ac-XXXXXXXX itself, within a 44-byte path.
  defp probe(:home_private_temp) do
    home = System.user_home!()

    probe =
      Path.join(home, ".ac-probe-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}")

    cond do
      byte_size(Path.join(home, ".ac-xxxxxxxx/claude-#{uid()}")) > 44 ->
        "needs a home short enough for Claude's 44-byte private temp: #{home}"

      (result = File.mkdir(probe)) != :ok ->
        {:error, reason} = result
        "needs a writable home for Claude's private temp: mkdir in #{home}: #{reason}"

      true ->
        File.rmdir!(probe)
        false
    end
  end

  defp run(executable, args) do
    case System.find_executable(executable) do
      nil ->
        {"#{executable} not found", :enoent}

      path ->
        {out, status} = System.cmd(path, args, stderr_to_stdout: true)
        {String.trim(out), status}
    end
  rescue
    error -> {Exception.message(error), :error}
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

  @doc """
  A new directory, removed after the test, where `longest` more bytes (such as
  "/runtime.sock") still fit a Unix socket path: under the system temporary directory
  (TMPDIR, so a worker's scratch) when short enough, else under the app's test tmp. It
  raises when neither fits rather than reaching for /tmp.
  """
  def short_dir!(prefix, longest, candidates \\ nil) do
    name = "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    candidates = candidates || [System.tmp_dir!(), Path.join(File.cwd!(), "tmp")]

    base =
      Enum.find(candidates, fn base ->
        byte_size(Path.join(base, name)) + byte_size(longest) + 1 <= @socket_path_limit
      end) ||
        raise "no temporary directory is short enough for a #{byte_size(longest)}-byte " <>
                "socket suffix: #{inspect(candidates)}"

    dir = Path.join(base, name)
    File.mkdir_p!(base)
    File.mkdir!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
