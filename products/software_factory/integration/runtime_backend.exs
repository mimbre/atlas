# MIX_ENV=test mix run --no-start integration/runtime_backend.exs
#
# The Runtime backend end to end (design 2026-11-16-runtime-backend §13 S1d, cases 1–9),
# with a stub harness: the real Service, `AtlasRuntime.Work` and the backend listener run
# as a separate OS process (`mix run platform/atlas_runtime/host/service.exs HOME`, in a
# session of its own, as `atlas-runtime service start` runs it), with the host built from
# this tree as `ATLAS_RUNTIME_EXECUTABLE` and a fake `codex` and `claude` on `PATH`
# (`fake-native work`, test/support/fake_native, which never launches a provider). Every
# case is driven over plain HTTP/1.1 on `$ATLAS_RUNTIME_HOME/backend.sock`, and cases 1–4,
# 6 and 8 also through the CLI's work commands (D3), tagged `:cli`.
#
# Proof that a work never started, or started once, comes from the fake harness's launch
# log (`work-launches.jsonl`), never from the Runtime's own records.
#
# Environment: ATLAS_E2E_SEED (ExUnit seed, default 0), ATLAS_E2E_INCLUDE (comma
# separated tags to include, e.g. "process_listing") and ATLAS_E2E_TRACE=1 (per-test times).
#
# `host/service.exs` starts the backend listener itself. The boot wrapper below would start
# one only for a service script that does not; every boot asserts it did not, so the run
# tests the product's own wiring.

seed = String.to_integer(System.get_env("ATLAS_E2E_SEED", "0"))

include =
  System.get_env("ATLAS_E2E_INCLUDE", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

# The restart probe needs a process listing (`ps`); where it is denied (a sandboxed worker),
# the probe can never prove a process gone, so the case that needs it cannot run.
ps? =
  case System.find_executable("ps") do
    nil ->
      false

    ps ->
      try do
        match?({_, 0}, System.cmd(ps, ["-A", "-o", "pid="], stderr_to_stdout: true))
      rescue
        _ -> false
      end
  end

exclude = if(ps?, do: [], else: [:process_listing]) -- include
# ATLAS_E2E_EXCLUDE_ALL=1 runs only the tests whose tags are included.
exclude = if System.get_env("ATLAS_E2E_EXCLUDE_ALL") == "1", do: [:test], else: exclude

ExUnit.start(
  seed: seed,
  exclude: exclude,
  include: include,
  timeout: 120_000,
  trace: System.get_env("ATLAS_E2E_TRACE") == "1"
)

defmodule RuntimeBackendE2E do
  @moduledoc false
  # The bench: build, homes, the Runtime process, HTTP and SSE on backend.sock, the CLI.
  import ExUnit.Assertions

  @root Path.expand("../../..", __DIR__)
  @project Path.join(@root, "products/software_factory")
  @service Path.join(@root, "platform/atlas_runtime/host/service.exs")
  @terminal ~w(completed failed crashed interrupted cancelled returned)
  @wait 20_000

  def root, do: @root
  def terminal, do: @terminal

  ## Build (once per run)

  def build! do
    dir = Path.join(System.tmp_dir!(), "rbe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Path.join(dir, "atlas-runtime")
    fake = Path.join(dir, "fake-native")

    go!(["-C", "platform/atlas_runtime/host", "build", "-o", host, "."], @root)

    go!(
      ["build", "-o", fake, "main.go"],
      Path.join(@root, "platform/atlas_runtime/test/support/fake_native")
    )

    :persistent_term.put({__MODULE__, :build}, %{dir: dir, host: host, fake: fake})
    ExUnit.after_suite(fn _ -> File.rm_rf(dir) end)
  end

  defp go!(args, cd) do
    case System.cmd("go", args, cd: cd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise "go #{Enum.join(args, " ")} failed:\n#{out}"
    end
  end

  def build, do: :persistent_term.get({__MODULE__, :build})

  ## A Runtime

  @doc """
  A run folder with a Runtime home (policy.json: slots s1, s2, buffer 1), a fake harness
  on PATH, and the Runtime booted. Short paths: backend.sock must fit a Unix socket path.
  """
  def runtime!(policy \\ %{}) do
    run = Path.join(System.tmp_dir!(), "rb#{System.pid()}-#{System.unique_integer([:positive])}")
    File.rm_rf!(run)
    home = Path.join(run, "h")
    bin = Path.join(run, "bin")
    for d <- [home, bin, Path.join(run, "ws"), Path.join(run, "codex-home")], do: File.mkdir_p!(d)

    for tool <- ["git", "mkfifo"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    for harness <- ["codex", "claude"] do
      words = Enum.map_join([build().fake, "work", run], " ", &sh_quote/1)
      File.write!(Path.join(bin, harness), "#!/bin/sh\nexec #{words} \"$0\" \"$@\"\n")
      File.chmod!(Path.join(bin, harness), 0o700)
    end

    File.write!(Path.join(home, "policy.json"), JSON.encode!(policy(policy)))
    File.write!(Path.join(run, "boot.exs"), boot_script())

    rt = %{run: run, home: home, bin: bin, sock: Path.join(home, "backend.sock"), boots: 0}

    # Never a real provider: on the Runtime's PATH, as the native host looks them up,
    # `codex` and `claude` are the fakes.
    for harness <- ["codex", "claude"] do
      {found, _} =
        System.cmd("/bin/sh", ["-c", "command -v " <> harness], env: [{"PATH", path(rt)}])

      assert String.trim(found) == Path.join(bin, harness),
             "#{harness} resolves to #{inspect(found)}, not the fake in #{bin}"
    end

    boot!(rt)
  end

  defp sh_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  @doc "The fixture policy; `changes` are merged into it."
  def policy(changes) do
    options = fn harness, model ->
      [%{"provider" => provider(harness), "harness" => harness, "model" => model}]
    end

    folder = ["read-only", "workspace-write", "materialized-folder"]

    Map.merge(
      %{
        "version" => 1,
        "slots" => ["s1", "s2"],
        "buffer_size" => 1,
        "profiles" => %{
          "light_work" => %{
            "permissions" => folder,
            "cost_classes" => ["low", "standard"],
            "options" => options.("codex", "gpt-test")
          },
          "claude_work" => %{
            "permissions" => folder,
            "cost_classes" => ["standard"],
            "options" => options.("claude", "claude-test")
          },
          "timed_work" => %{
            "permissions" => folder,
            "cost_classes" => ["standard"],
            "options" => options.("codex", "gpt-test"),
            "limits" => %{"max_duration" => 1}
          }
        }
      },
      changes
    )
  end

  defp provider("codex"), do: "openai"
  defp provider("claude"), do: "anthropic"

  # Runs the host's service script unchanged. Until service.exs starts the backend listener
  # (D3), a waiter started first starts it once the work core is registered.
  defp boot_script do
    """
    [dir] = System.argv()
    run = Path.dirname(dir)
    File.write!(Path.join(run, "beam.pid"), System.pid())

    spawn(fn ->
      wait = fn wait, check, left ->
        cond do
          check.() -> true
          left <= 0 -> false
          true -> Process.sleep(50); wait.(wait, check, left - 50)
        end
      end

      listener? = fn ->
        Enum.any?(Process.list(), fn pid ->
          case Process.info(pid, :dictionary) do
            {:dictionary, d} -> d[:"$initial_call"] == {AtlasRuntime.Backend.Listener, :init, 1}
            _ -> false
          end
        end)
      end

      # Once service.exs starts the listener itself (D3), the harness leaves it alone.
      if not (File.read!(#{inspect(@service)}) =~ "Backend.Listener") and
           wait.(wait, fn -> Process.whereis(AtlasRuntime.Work.Server) end, 120_000) and
           not listener?.() do
        router =
          if Code.ensure_loaded?(AtlasRuntime.Backend.Rest) do
            AtlasRuntime.Backend.Rest
          else
            Code.eval_string(\"\"\"
            defmodule AtlasRuntimeE2E.Router do
              use AtlasRuntimeBackend.Generator.Targets.Rest,
                contract: AtlasRuntimeBackend.Work,
                facade: AtlasRuntime.Boundary.Work,
                stream: AtlasRuntime.Backend.Events
            end
            \"\"\")

            AtlasRuntimeE2E.Router
          end

        {:ok, _} = Application.ensure_all_started(:bandit)
        {:ok, _} = GenServer.start(AtlasRuntime.Backend.Listener, home: dir, router: router)
        File.write!(Path.join(run, "listener-by-harness"), inspect(router))
        IO.puts("e2e: backend listener started by the harness on \#{inspect(router)}")
      end
    end)

    Code.eval_file(#{inspect(@service)})
    """
  end

  @doc "Boots the Runtime on `rt.home` and waits until backend.sock answers."
  def boot!(rt) do
    # As `atlas-runtime service start` does: only runtime.sock is removed (host/main.go).
    File.rm(Path.join(rt.home, "runtime.sock"))
    File.rm(Path.join(rt.run, "beam.pid"))
    boots = rt.boots + 1
    log = Path.join(rt.run, "service-#{boots}.log")

    path = path(rt)

    env =
      for {k, v} <- [
            {"MIX_ENV", "test"},
            {"ATLAS_RUNTIME_EXECUTABLE", build().host},
            {"ATLAS_RUNTIME_HOME", rt.home},
            {"PATH", path},
            {"CODEX_HOME", Path.join(rt.run, "codex-home")},
            {"ELIXIR_ERL_OPTIONS", "+S 2:2"}
          ],
          do: {String.to_charlist(k), String.to_charlist(v)}

    args = [
      "detach",
      mix(),
      "run",
      "--no-start",
      "--no-compile",
      "--no-deps-check",
      Path.join(rt.run, "boot.exs"),
      rt.home
    ]

    parent = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, build().fake}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            cd: @project,
            env: env
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:booted, self(), pid})
        {:ok, file} = File.open(log, [:append, :binary])
        output(port, file)
      end)

    pgid =
      receive(do: ({:booted, ^owner, pid} -> pid), after: (10_000 -> flunk("no Runtime process")))

    rt = Map.merge(rt, %{boots: boots, owner: owner, pgid: pgid, log: log})

    await(
      fn ->
        if File.read!(log) =~ "[e2e: Runtime exited",
          do: flunk("the Runtime exited at boot; #{log}:\n#{File.read!(log)}")

        match?({:ok, %{status: 200}}, try_request(rt, "GET", "/v1/capacity"))
      end,
      120_000,
      fn ->
        "backend.sock did not answer; #{log}:\n#{File.read!(log)}"
      end
    )

    refute File.exists?(Path.join(rt.run, "listener-by-harness")),
           "the harness, not host/service.exs, started the backend listener; #{log}"

    Map.put(rt, :beam, File.read!(Path.join(rt.run, "beam.pid")) |> String.trim())
  end

  # The Runtime's PATH: the fakes first, then Elixir, Erlang and the system.
  defp path(rt) do
    Enum.join(
      [rt.bin, Path.dirname(elixir()), Path.dirname(erl()), "/usr/bin:/bin:/usr/sbin:/sbin"],
      ":"
    )
  end

  defp output(port, file) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(file, data)
        output(port, file)

      {^port, {:exit_status, status}} ->
        IO.binwrite(file, "\n[e2e: Runtime exited #{status}]\n")
        File.close(file)
    end
  end

  defp mix, do: Path.join(Path.dirname(elixir()), "mix")
  defp elixir, do: Path.join(:code.lib_dir(:elixir), "../../bin/elixir") |> Path.expand()
  defp erl, do: Path.join(:code.root_dir(), "bin/erl")

  @doc "SIGKILL of the Runtime's BEAM alone: its helpers lose their parent (M1c)."
  def kill_beam!(rt) do
    signal!(["-KILL", rt.beam])
    await_exit!(rt)
  end

  @doc """
  SIGKILL of the Runtime's BEAM and of the host helper that owns `launch` (its parent), at
  once: nothing is left to end the turn's process group, which survives.
  """
  def kill_with_helper!(rt, launch) do
    signal!(["-KILL", rt.beam, "#{launch["ppid"]}"])
    await_exit!(rt)
  end

  @doc "A graceful stop (SIGTERM to the BEAM)."
  def stop!(rt) do
    signal!(["-TERM", rt.beam])
    await_exit!(rt)
  end

  def signal!(args) do
    {out, status} = System.cmd("kill", args, stderr_to_stdout: true)
    assert status == 0, "kill #{Enum.join(args, " ")}: #{out}"
  end

  defp await_exit!(rt) do
    await(fn -> File.read!(rt.log) =~ "[e2e: Runtime exited" end, @wait, fn ->
      "Runtime did not exit"
    end)

    rt
  end

  @doc "Ends everything this run started: the Runtime group and any turn still alive."
  def cleanup(rt) do
    System.cmd("kill", ["-KILL", "-#{rt.pgid}"], stderr_to_stdout: true)

    for %{"pid" => pid} <- launches(rt),
        do: System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)

    for %{"pid" => pid} <- launches(rt),
        do: System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)

    :ok
  end

  def alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  ## HTTP/1.1 on backend.sock (plain: no client library)

  def request(rt, method, path, body \\ nil, headers \\ []) do
    case try_request(rt, method, path, body, headers) do
      {:ok, response} -> response
      {:error, reason} -> flunk("#{method} #{path}: #{inspect(reason)}")
    end
  end

  def try_request(rt, method, path, body \\ nil, headers \\ []) do
    payload = if body, do: JSON.encode!(body), else: ""

    head =
      [{"host", "localhost"}, {"connection", "close"}, {"content-length", byte_size(payload)}] ++
        if(body, do: [{"content-type", "application/json"}], else: []) ++ headers

    with {:ok, socket} <- :gen_tcp.connect({:local, rt.sock}, 0, [:binary, active: false], 5_000) do
      :ok =
        :gen_tcp.send(socket, [
          method,
          " ",
          path,
          " HTTP/1.1\r\n",
          for({k, v} <- head, do: [k, ": ", to_string(v), "\r\n"]),
          "\r\n",
          payload
        ])

      result = recv_all(socket, "", System.monotonic_time(:millisecond) + 60_000)
      :gen_tcp.close(socket)
      with {:ok, raw} <- result, do: {:ok, parse(raw)}
    end
  end

  defp recv_all(socket, acc, deadline) do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 1)) do
      {:ok, data} -> recv_all(socket, acc <> data, deadline)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, {reason, acc}}
    end
  end

  defp parse(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ", parts: 3)

    headers =
      for line <- lines,
          [k, v] = String.split(line, ":", parts: 2),
          do: {String.downcase(k), String.trim(v)}

    body = if {"transfer-encoding", "chunked"} in headers, do: dechunk(body, ""), else: body
    type = header(%{headers: headers}, "content-type") || ""
    json = if body != "" and type =~ "json", do: JSON.decode!(body)
    %{status: String.to_integer(status), headers: headers, body: body, json: json}
  end

  defp dechunk(data, acc) do
    case String.split(data, "\r\n", parts: 2) do
      [size, rest] ->
        case Integer.parse(size, 16) do
          {0, _} ->
            acc

          {n, _} ->
            dechunk(
              binary_part(rest, n, byte_size(rest) - n) |> String.trim_leading("\r\n"),
              acc <> binary_part(rest, 0, n)
            )

          :error ->
            acc
        end

      _ ->
        acc
    end
  end

  def header(%{headers: headers}, name),
    do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

  ## The work API

  @doc "A folder work request, in a folder of its own named after the instructions."
  def work_request(rt, instructions, extra \\ %{}) do
    folder =
      Path.join([rt.run, "ws", Base.encode16(:crypto.hash(:md5, instructions), case: :lower)])

    File.mkdir_p!(folder)

    Map.merge(
      %{
        "title" => instructions,
        "instructions" => instructions,
        "profile" => "light_work",
        "cost_class" => "standard",
        "workspace" => %{"kind" => "folder", "path" => folder, "permissions" => "read-only"}
      },
      extra
    )
  end

  def submit(rt, instructions, opts \\ []) do
    headers = if key = opts[:key], do: [{"idempotency-key", key}], else: []

    request(
      rt,
      "POST",
      "/v1/work",
      work_request(rt, instructions, Map.new(opts[:extra] || %{})),
      headers
    )
  end

  @doc "Submits and asserts 201 Created; returns the work."
  def submit!(rt, instructions, opts \\ []) do
    response = submit(rt, instructions, opts)
    assert response.status == 201, "submit #{instructions}: #{response.status} #{response.body}"
    response.json
  end

  def get(rt, id), do: request(rt, "GET", "/v1/work/#{id}")

  def work!(rt, id) do
    response = get(rt, id)
    assert response.status == 200, "GET /v1/work/#{id}: #{response.status} #{response.body}"
    response.json
  end

  def cancel(rt, id, mode \\ "graceful"),
    do: request(rt, "POST", "/v1/work/#{id}/cancel", %{"mode" => mode})

  def retry(rt, id, body \\ %{}), do: request(rt, "POST", "/v1/work/#{id}/attempts", body)
  def capacity(rt), do: request(rt, "GET", "/v1/capacity")

  def current(work), do: List.last(work["attempts"])
  def terminal?(work), do: work["state"] in @terminal

  @doc "The work once `check` holds for it (bounded)."
  def await_work(rt, id, check, timeout \\ @wait) do
    await(fn -> (work = work!(rt, id)) && check.(work) && work end, timeout, fn ->
      "work #{id} never satisfied the condition; last: #{inspect(work!(rt, id), limit: :infinity)}"
    end)
  end

  def await_state(rt, id, state, timeout \\ @wait),
    do: await_work(rt, id, &(&1["state"] == state), timeout)

  @doc "The work, running, once the fake harness has launched its goal `count` times."
  def await_launch(rt, work, count \\ 1) do
    goal = work["request"]["instructions"]

    await(fn -> Enum.count(launches(rt), &(&1["goal"] == goal)) >= count end, @wait, fn ->
      "#{goal} not launched #{count} time(s); log: #{inspect(launches(rt))}"
    end)

    await_state(rt, work["work_id"], "running")
  end

  @doc "Every turn this run's Runtime launched, from the fake harness's log."
  def launches(rt), do: log(rt, "work-launches.jsonl")
  def launches(rt, goal), do: Enum.filter(launches(rt), &(&1["goal"] == goal))

  @doc "Every end the fake harness saw itself (a result, a failure, a signal; never SIGKILL)."
  def ends(rt), do: log(rt, "work-ends.jsonl")

  defp log(rt, name) do
    case File.read(Path.join(rt.run, name)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "Ends every live work (force) and waits for both slots and the buffer to be free."
  def quiesce(rt) do
    %{status: 200, json: %{"works" => works}} = request(rt, "GET", "/v1/work")

    for work <- works, not terminal?(work), do: cancel(rt, work["work_id"], "force")

    await(
      fn ->
        %{json: %{"works" => works}} = request(rt, "GET", "/v1/work")
        %{json: capacity} = capacity(rt)

        Enum.all?(works, &(terminal?(&1) and current(&1)["quiescent"])) and
          capacity["slots"]["free"] == 2 and capacity["buffer"]["used"] == 0
      end,
      40_000,
      fn -> "the Runtime did not become idle: #{inspect(request(rt, "GET", "/v1/work").json)}" end
    )
  end

  ## Server-Sent Events on GET /v1/events

  @doc "Opens the event stream; each frame arrives as `{:sse, ref, %{event, id, data}}`."
  def subscribe(rt, headers \\ []) do
    ref = make_ref()
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.connect({:local, rt.sock}, 0, [:binary, active: false], 5_000)
        lines = for {k, v} <- headers, do: [k, ": ", to_string(v), "\r\n"]

        :ok =
          :gen_tcp.send(socket, ["GET /v1/events HTTP/1.1\r\nhost: localhost\r\n", lines, "\r\n"])

        send(parent, {:sse_open, ref})
        sse(socket, parent, ref, :head, "")
      end)

    receive(do: ({:sse_open, ^ref} -> :ok), after: (5_000 -> flunk("event stream did not open")))

    # The router subscribes before it answers: once the head is in, no change is missed.
    receive do
      {:sse_status, ^ref, 200} -> :ok
      {:sse_status, ^ref, status} -> flunk("GET /v1/events answered #{status}")
    after
      5_000 -> flunk("GET /v1/events did not answer")
    end

    {pid, ref}
  end

  defp sse(socket, parent, ref, phase, buffer) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        {phase, buffer} = sse_data(parent, ref, phase, buffer <> data)
        sse(socket, parent, ref, phase, buffer)

      {:error, _} ->
        send(parent, {:sse_closed, ref})
    end
  end

  defp sse_data(parent, ref, :head, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [_, status | _] = String.split(head, " ", parts: 3)
        send(parent, {:sse_status, ref, String.to_integer(status)})
        sse_data(parent, ref, {:body, ""}, rest)

      [_] ->
        {:head, buffer}
    end
  end

  # Chunked transfer: decode whole chunks, then cut whole frames out of the text.
  defp sse_data(parent, ref, {:body, text}, buffer) do
    with [size, rest] <- String.split(buffer, "\r\n", parts: 2),
         {n, _} <- Integer.parse(size, 16),
         true <- byte_size(rest) >= n + 2 do
      text = text <> binary_part(rest, 0, n)
      buffer = binary_part(rest, n + 2, byte_size(rest) - n - 2)
      parts = String.split(text, "\n\n")
      {frames, [text]} = Enum.split(parts, -1)
      for frame <- frames, frame != "", do: send(parent, {:sse, ref, frame(frame)})
      sse_data(parent, ref, {:body, text}, buffer)
    else
      _ -> {{:body, text}, buffer}
    end
  end

  defp frame(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, frame ->
      case String.split(line, ":", parts: 2) do
        ["event", v] -> Map.put(frame, "event", String.trim(v))
        ["id", v] -> Map.put(frame, "id", String.to_integer(String.trim(v)))
        ["data", v] -> Map.put(frame, "data", JSON.decode!(String.trim(v)))
        _ -> frame
      end
    end)
  end

  @doc "The first frame of `event` matching `check` within `timeout`, skipping the others."
  def await_frame(events, event, check \\ fn _ -> true end, timeout \\ @wait) do
    {frame, _earlier} = await_frame_after(events, event, check, timeout)
    frame
  end

  @doc "As `await_frame/4`, together with every frame that arrived before it, in order."
  def await_frame_after({_pid, ref}, event, check \\ fn _ -> true end, timeout \\ @wait) do
    deadline = System.monotonic_time(:millisecond) + timeout
    next_frame(ref, event, check, deadline, [])
  end

  defp next_frame(ref, event, check, deadline, seen) do
    receive do
      {:sse, ^ref, %{"event" => ^event} = frame} ->
        if check.(frame),
          do: {frame, Enum.reverse(seen)},
          else: next_frame(ref, event, check, deadline, [frame | seen])

      {:sse, ^ref, frame} ->
        next_frame(ref, event, check, deadline, [frame | seen])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("no #{event} event on GET /v1/events; frames seen: #{inspect(Enum.reverse(seen))}")
    end
  end

  def close({pid, _ref}) do
    unlink(pid)
    Process.exit(pid, :kill)
  end

  defp unlink(pid), do: Process.unlink(pid)

  ## The CLI (the host built from this tree)

  def cli(rt, args) do
    {out, status} =
      System.cmd(build().host, args,
        env: [{"ATLAS_RUNTIME_HOME", rt.home}, {"PATH", rt.bin <> ":/usr/bin:/bin"}],
        stderr_to_stdout: true
      )

    json =
      case JSON.decode(out) do
        {:ok, value} -> value
        _ -> nil
      end

    %{status: status, out: out, json: json}
  end

  ## Waiting

  def await(fun, timeout \\ @wait, message \\ fn -> "condition not met in time" end) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline, message)
  end

  defp do_await(fun, deadline, message) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk(message.())
        Process.sleep(50)
        do_await(fun, deadline, message)
    end
  end

  def iso(text), do: text && DateTime.from_iso8601(text) |> elem(1)
end

:persistent_term.put({RuntimeBackendE2E, :ps}, ps?)
RuntimeBackendE2E.build!()

defmodule RuntimeBackendE2E.HTTPTest do
  @moduledoc """
  Design cases 1–5 and 7–9 that need no restart, over plain HTTP on one Runtime: each test
  starts and ends with both slots and the buffer free.
  """
  use ExUnit.Case, async: false
  import RuntimeBackendE2E

  setup_all do
    rt = runtime!()
    on_exit(fn -> cleanup(rt) end)
    %{rt: rt}
  end

  setup %{rt: rt} do
    quiesce(rt)
    on_exit(fn -> quiesce(rt) end)
    :ok
  end

  test "case 1: submit gives 201, SSE work events, then completed with provenance and stage timestamps",
       %{rt: rt} do
    events = subscribe(rt)
    response = submit(rt, "complete case-1", key: "case-1")
    assert response.status == 201
    work = response.json
    id = work["work_id"]
    assert header(response, "location") == "/v1/work/#{id}"
    assert work["client_key"] == "case-1"
    assert work["state"] in ["buffered", "starting", "running"]

    done = await_state(rt, id, "completed")
    attempt = current(done)
    assert attempt["quiescent"]
    assert attempt["result"]["kind"] == "completed"
    assert attempt["result"]["answer"] == "done: complete case-1"
    assert attempt["result"]["retryable"] == false
    assert attempt["result"]["never_started"] == false

    provenance = attempt["provenance"]
    assert provenance["executor_kind"] == "agent"
    assert provenance["provider"] == "openai"
    assert provenance["harness"] == "codex"
    assert provenance["configured_model"] == "gpt-test"
    assert provenance["slot"] in ["s1", "s2"] and provenance["slot"] == attempt["slot"]
    assert provenance["turn_id"] == attempt["turn_id"]
    assert provenance["selection"]["profile"] == "light_work"
    assert provenance["selection"]["reason"] == "preferred"

    assert provenance["selection"]["option"] == %{
             "provider" => "openai",
             "harness" => "codex",
             "model" => "gpt-test"
           }

    stamps = attempt["timestamps"]
    order = ~w(received_at accepted_at started_at running_at ended_at)
    times = Enum.map(order, &iso(stamps[&1]))
    assert Enum.all?(times), "missing stage timestamps: #{inspect(stamps)}"

    assert times == Enum.sort(times, DateTime),
           "stage timestamps out of order: #{inspect(stamps)}"

    # Exactly one native start.
    assert [%{"backend" => "codex", "resumed" => false}] = launches(rt, "complete case-1")

    # The stream signalled the work's changes with a rising revision, up to completed.
    first = await_frame(events, "work", &(&1["data"]["work_id"] == id))

    last =
      await_frame(
        events,
        "work",
        &(&1["data"]["work_id"] == id and &1["data"]["state"] == "completed")
      )

    assert last["data"]["revision"] > first["data"]["revision"]
    assert last["id"] == last["data"]["sequence"]
    close(events)
  end

  test "case 2: the same Idempotency-Key gives 200 with the same work; a different body gives 409",
       %{rt: rt} do
    first = submit(rt, "complete case-2", key: "case-2")
    assert first.status == 201
    again = submit(rt, "complete case-2", key: "case-2")
    assert again.status == 200
    assert again.json["work_id"] == first.json["work_id"]

    other = submit(rt, "complete case-2", key: "case-2", extra: %{"title" => "another title"})
    assert other.status == 409
    assert header(other, "content-type") =~ "application/problem+json"
    assert other.json["type"] == "idempotency-conflict"

    await_state(rt, first.json["work_id"], "completed")
    assert [_one] = launches(rt, "complete case-2"), "nothing starts twice"
  end

  test "case 3: with slots and buffer full, 503 at-capacity with Retry-After, then SSE capacity",
       %{rt: rt} do
    events = subscribe(rt)
    a = submit!(rt, "hang case-3 a")
    b = submit!(rt, "hang case-3 b")
    await_launch(rt, a)
    await_launch(rt, b)
    c = submit!(rt, "complete case-3 c")
    assert work!(rt, c["work_id"])["state"] == "buffered"

    full = submit(rt, "complete case-3 d")
    assert full.status == 503
    assert header(full, "content-type") =~ "application/problem+json"
    assert full.json["type"] == "at-capacity"
    assert full.json["reason"] == "full"
    assert header(full, "retry-after") == "60"
    assert full.json["retry_after"] == 60
    assert %{"slots" => %{"free" => 0}, "buffer" => %{"free" => 0}} = full.json["capacity"]

    room = capacity(rt)
    assert room.status == 200
    assert header(room, "retry-after") == "60"

    assert %{"accepting" => true, "retry_after" => 60, "slots" => %{"total" => 2, "busy" => 2}} =
             room.json

    # A slot frees: c starts from the buffer and the Runtime takes new work again.
    assert cancel(rt, a["work_id"], "force").status == 202
    await_state(rt, c["work_id"], "completed")
    assert [_] = launches(rt, "complete case-3 c")
    assert launches(rt, "complete case-3 d") == [], "a refused submit never starts"
    assert header(capacity(rt), "retry-after") == nil

    frame = await_frame(events, "capacity")
    assert frame["id"] == frame["data"]["sequence"]
    assert frame["data"]["capacity"]["accepting"]
    close(events)
  end

  test "case 4: cancelled buffered work never starts", %{rt: rt} do
    a = submit!(rt, "hang case-4a a")
    b = submit!(rt, "hang case-4a b")
    await_launch(rt, a)
    await_launch(rt, b)
    buffered = submit!(rt, "complete case-4a buffered")

    ended = cancel(rt, buffered["work_id"])
    assert ended.status in [200, 202]
    work = await_state(rt, buffered["work_id"], "cancelled")
    assert current(work)["result"]["never_started"] == true
    assert current(work)["quiescent"]

    # Both slots free; a later work runs to completed, so the buffer was served.
    for w <- [a, b], do: cancel(rt, w["work_id"], "force")
    sentinel = submit!(rt, "complete case-4a sentinel")
    await_state(rt, sentinel["work_id"], "completed")
    assert launches(rt, "complete case-4a buffered") == [], "the cancelled buffered work started"
  end

  test "case 4: cancelling running work answers 202, then the work ends cancelled", %{rt: rt} do
    work = submit!(rt, "hang case-4b")
    running = await_launch(rt, work)
    [launch] = launches(rt, "hang case-4b")

    response = cancel(rt, work["work_id"])
    assert response.status == 202
    assert response.json["state"] == "cancelling"
    assert current(response.json)["cancel_stage"] in ["requested", "signalled"]
    assert current(response.json)["cancel_reason"] == "cancel"

    done = await_state(rt, work["work_id"], "cancelled")
    attempt = current(done)
    assert attempt["result"]["kind"] == "cancelled"
    assert attempt["result"]["never_started"] == false
    assert attempt["quiescent"]
    assert attempt["timestamps"]["cancel_requested_at"] && attempt["timestamps"]["signalled_at"]
    assert attempt["turn_id"] == current(running)["turn_id"]

    # The harness saw the signal; cancelling it again answers 200 with the ended work.
    assert Enum.any?(ends(rt), &(&1["pid"] == launch["pid"] and &1["how"] =~ "signal"))
    assert cancel(rt, work["work_id"]).status == 200
  end

  test "case 4: a result that arrives while the cancel is still requested ends completed",
       %{rt: rt} do
    # The Runtime's BEAM is stopped (SIGSTOP) while the harness delivers its result, and the
    # cancel is queued behind it. When the BEAM resumes, the core may take the cancel before
    # it learns of the turn's end, and then rightly signals: the race did not happen, and the
    # round is repeated (at most 3). A repeated round must still have ended as a signalled
    # cancel does.
    {reply, done} =
      Enum.reduce_while(1..3, [], fn round, inconclusive ->
        {reply, done} = race = result_during_cancel(rt, "wait case-4c-gate-#{round}")
        assert reply.status in [200, 202], "cancel answered #{reply.status}: #{reply.body}"
        stage = if reply.status == 202, do: current(reply.json)["cancel_stage"], else: "requested"

        if stage == "requested" do
          {:halt, race}
        else
          signalled_cancel!(done)
          {:cont, [{stage, done["state"]} | inconclusive]}
        end
      end)
      |> case do
        {_, _} = race ->
          race

        inconclusive ->
          flunk("the core signalled before the result in 3 rounds: #{inspect(inconclusive)}")
      end

    if reply.status == 200, do: assert(reply.json["state"] == "completed", inspect(reply.json))

    assert done["state"] == "completed",
           "cancel answered #{reply.status} at stage #{inspect(current(reply.json)["cancel_stage"])}; " <>
             "the work ended #{done["state"]}: #{inspect(current(done)["result"])}"

    # The cancel reached the attempt before its end was taken (else this proves no race).
    ended = current(done)
    assert ended["cancel_stage"] == "requested", inspect(ended)
    assert ended["timestamps"]["cancel_requested_at"], inspect(ended)
    assert ended["result"]["answer"] == "done: #{done["request"]["instructions"]}"
  end

  # A cancel the core signalled ends cancelled (reason cancel), never completed or failed.
  defp signalled_cancel!(done) do
    attempt = current(done)
    assert done["state"] == "cancelled", inspect(attempt)
    assert attempt["result"]["kind"] == "cancelled", inspect(attempt)
    assert attempt["result"]["never_started"] == false, inspect(attempt)
    assert attempt["quiescent"], inspect(attempt)
    assert attempt["cancel_reason"] == "cancel", inspect(attempt)
    assert attempt["cancel_stage"] in ["signalled", "forced"], inspect(attempt)
    stamps = attempt["timestamps"]
    assert stamps["cancel_requested_at"], inspect(attempt)
    assert stamps["signalled_at"] || stamps["forced_at"], inspect(attempt)
  end

  # One round of case 4's race: the cancel's reply and the work once ended.
  defp result_during_cancel(rt, goal) do
    gate = Path.join(rt.run, String.split(goal) |> Enum.at(1))
    File.write!(gate, "")
    work = submit!(rt, goal)
    await_launch(rt, work)

    signal!(["-STOP", rt.beam])

    reply =
      try do
        File.rm!(gate)
        await(fn -> Enum.any?(ends(rt), &(&1["goal"] == goal)) end)
        task = Task.async(fn -> cancel(rt, work["work_id"]) end)
        Process.sleep(300)
        signal!(["-CONT", rt.beam])
        Task.await(task, 30_000)
      after
        System.cmd("kill", ["-CONT", rt.beam])
      end

    {reply, await_work(rt, work["work_id"], &(terminal?(&1) and current(&1)["quiescent"]))}
  end

  test "case 5: retry while n is buffered cancels n with never_started", %{rt: rt} do
    a = submit!(rt, "hang case-5a a")
    b = submit!(rt, "hang case-5a b")
    await_launch(rt, a)
    await_launch(rt, b)
    work = submit!(rt, "complete case-5a")

    response = retry(rt, work["work_id"])
    assert response.status == 201
    assert [first, second] = response.json["attempts"]
    assert first["state"] == "cancelled"
    assert first["result"]["never_started"] == true
    assert first["cancel_reason"] == "superseded"
    assert second["state"] == "buffered"

    for w <- [a, b], do: cancel(rt, w["work_id"], "force")
    done = await_state(rt, work["work_id"], "completed")
    assert current(done)["attempt"] == 2
    assert [_only_n_plus_1] = launches(rt, "complete case-5a")
  end

  test "case 5: retry while n is running supersedes n; n+1 starts only once n is quiescent",
       %{rt: rt} do
    work = submit!(rt, "hang case-5b")
    await_launch(rt, work)

    response = retry(rt, work["work_id"])
    assert response.status == 201
    assert [first, second] = response.json["attempts"]
    assert first["cancel_reason"] == "superseded"
    assert second["state"] == "buffered"

    running = await_launch(rt, work, 2)
    assert [n, n1] = running["attempts"]
    assert n["state"] == "cancelled" and n["quiescent"]
    assert n["result"]["never_started"] == false

    # From the harness's own logs: n's process ended before n+1's was launched.
    [first_launch, second_launch] = launches(rt, "hang case-5b")
    ended = Enum.find(ends(rt), &(&1["pid"] == first_launch["pid"]))
    assert ended, "n's end is not in the log: #{inspect(ends(rt))}"

    assert DateTime.compare(iso(ended["at"]), iso(second_launch["at"])) == :lt,
           "n+1 launched at #{second_launch["at"]}, before n ended at #{ended["at"]}"

    assert iso(n["timestamps"]["ended_at"])
           |> DateTime.compare(iso(n1["timestamps"]["started_at"])) != :gt

    cancel(rt, work["work_id"], "force")
  end

  test "case 5: retry while full answers 503 and leaves n untouched", %{rt: rt} do
    a = submit!(rt, "hang case-5d a")
    b = submit!(rt, "hang case-5d b")
    running = await_launch(rt, a)
    await_launch(rt, b)
    submit!(rt, "hang case-5d buffered")

    response = retry(rt, a["work_id"])
    assert response.status == 503
    assert response.json["type"] == "at-capacity"
    assert response.json["reason"] == "full"
    assert header(response, "retry-after") == "60"

    after_retry = work!(rt, a["work_id"])
    assert after_retry["revision"] == running["revision"]
    assert [%{"state" => "running"}] = after_retry["attempts"]
    assert [_] = launches(rt, "hang case-5d a")
  end

  test "case 5: retry on completed work is accepted and runs a new attempt", %{rt: rt} do
    work = submit!(rt, "complete case-5e")
    await_state(rt, work["work_id"], "completed")

    response = retry(rt, work["work_id"])
    assert response.status == 201
    assert length(response.json["attempts"]) == 2

    done =
      await_work(
        rt,
        work["work_id"],
        &(&1["state"] == "completed" and current(&1)["attempt"] == 2)
      )

    assert [first, _] = done["attempts"]
    assert first["state"] == "completed"
    assert length(launches(rt, "complete case-5e")) == 2
  end

  test "case 7: Last-Event-ID inside the window replays the missed changes", %{rt: rt} do
    %{status: 200, json: %{"sequence" => before}} = request(rt, "GET", "/v1/work")
    work = submit!(rt, "complete case-7a")
    await_state(rt, work["work_id"], "completed")

    events = subscribe(rt, [{"last-event-id", before}])

    {frame, earlier} =
      await_frame_after(
        events,
        "work",
        &(&1["data"]["work_id"] == work["work_id"] and &1["data"]["state"] == "completed")
      )

    assert frame["id"] > before
    # A reset would come first, before any replayed change.
    assert [] = for(%{"event" => "reset"} = reset <- earlier, do: reset)
    close(events)
  end

  test "case 7: a Last-Event-ID outside the window opens with reset", %{rt: rt} do
    %{status: 200, json: %{"sequence" => current}} = request(rt, "GET", "/v1/work")

    # Before the window: the window starts at the boot's sequence, so 0 is outside it (the
    # 10 000-change limit is not configurable from outside the process). After it: unknown.
    for from <- [0, current + 1_000] do
      events = subscribe(rt, [{"last-event-id", from}])
      frame = await_frame(events, "reset", fn _ -> true end, 5_000)
      assert frame["data"]["current_sequence"] >= current
      close(events)
    end
  end

  test "case 8: a top-level model change fails the turn with model_changed", %{rt: rt} do
    work = submit!(rt, "model_change case-8a", extra: %{"profile" => "claude_work"})
    done = await_work(rt, work["work_id"], &terminal?/1)
    attempt = current(done)
    assert done["state"] == "failed", inspect(attempt)
    assert attempt["result"]["reason"] == "model_changed"
    assert attempt["provenance"]["harness"] == "claude"
    assert attempt["provenance"]["configured_model"] == "claude-test"
    assert attempt["provenance"]["reported_model"] == "claude-test"

    assert [%{"backend" => "claude", "model" => "claude-test"}] =
             launches(rt, "model_change case-8a")
  end

  test "case 8: a subagent record with another model does not fail the turn", %{rt: rt} do
    work = submit!(rt, "subagent_model case-8b", extra: %{"profile" => "claude_work"})
    done = await_work(rt, work["work_id"], &terminal?/1)
    attempt = current(done)
    assert done["state"] == "completed", inspect(attempt)
    assert attempt["provenance"]["reported_model"] == "claude-test"
    assert [_] = launches(rt, "subagent_model case-8b")
  end

  test "case 9: a key never used gives 404", %{rt: rt} do
    response = request(rt, "GET", "/v1/work?key=never-used")
    assert response.status == 404
    assert response.json["type"] == "not-found"
  end
end

defmodule RuntimeBackendE2E.RestartTest do
  @moduledoc """
  The cases that kill or restart the Runtime (5 with an unknown n, 6, 7 after a restart,
  9, and the history read): each test has a Runtime of its own.
  """
  use ExUnit.Case, async: false
  import RuntimeBackendE2E

  setup do
    rt = runtime!()
    # The test's own reboots replace the Runtime; cleanup reads the latest one.
    :persistent_term.put({__MODULE__, :rt}, rt)
    on_exit(fn -> cleanup(:persistent_term.get({__MODULE__, :rt})) end)
    %{rt: rt}
  end

  defp reboot!(rt) do
    rt = boot!(rt)
    :persistent_term.put({__MODULE__, :rt}, rt)
    rt
  end

  # A turn left alive by a SIGKILL of the whole Runtime (BEAM and helpers): its own process
  # group survives, so after the restart the core cannot prove it gone (`unknown`).
  defp unknown_n!(rt, goal) do
    File.write!(Path.join(rt.run, String.split(goal) |> Enum.at(1)), "")
    work = submit!(rt, goal)
    running = await_launch(rt, work)
    [launch] = launches(rt, goal)

    kill_with_helper!(rt, launch)
    Process.sleep(500)
    assert alive?(launch["pid"]), "the stub child did not survive the Runtime's SIGKILL"
    rt = reboot!(rt)

    n = await_state(rt, work["work_id"], "interrupted")
    assert current(n)["quiescent"] == false, inspect(current(n))

    response = retry(rt, work["work_id"])
    assert response.status == 201
    assert [_, %{"state" => "buffered"}] = response.json["attempts"]

    # Both slots are free, yet n+1 waits for n (I1), also across a heartbeat: its probe
    # (every 15 s, before the heartbeat is sent) cannot prove n's live process gone.
    events = subscribe(rt)
    await_frame(events, "heartbeat", fn _ -> true end, 20_000)
    close(events)
    Process.sleep(500)
    assert [_, %{"state" => "buffered"}] = work!(rt, work["work_id"])["attempts"]
    assert [_] = launches(rt, goal)
    {rt, work, current(running)["slot"], launch}
  end

  test "case 5: retry after a restart with n unknown waits until release, then starts", %{rt: rt} do
    goal = "wait case-5c-release"
    {rt, work, slot, _launch} = unknown_n!(rt, goal)

    released = cli(rt, ["release", "--worker", slot])
    assert released.status == 0, released.out

    running = await_launch(rt, work, 2)
    assert [%{"quiescent" => true}, %{"state" => "running"}] = running["attempts"]
    File.rm(Path.join(rt.run, "case-5c-release"))
    await_state(rt, work["work_id"], "completed")
  end

  @tag :process_listing
  test "case 5: retry after a restart with n unknown waits until the probe sees n gone", %{rt: rt} do
    goal = "wait case-5c-probe"
    {rt, work, _slot, launch} = unknown_n!(rt, goal)

    # n's process ends by itself; the heartbeat's probe (every 15 s) then proves it gone.
    # n+1 shares n's goal, and its gate is gone too: it completes as soon as it runs, so it
    # is awaited by its launch and its end, not in `running`.
    File.rm!(Path.join(rt.run, "case-5c-probe"))
    await(fn -> not alive?(launch["pid"]) end)

    await(fn -> length(launches(rt, goal)) >= 2 end, 40_000, fn ->
      "n+1 not launched; log: #{inspect(launches(rt))}"
    end)

    done = await_work(rt, work["work_id"], &(terminal?(&1) and current(&1)["attempt"] == 2))
    assert [%{"state" => "interrupted", "quiescent" => true}, n1] = done["attempts"]
    assert done["state"] == "completed", inspect(n1)
    assert n1["result"]["answer"] == "done: #{goal}", inspect(n1)

    # From the harness's own logs: n's process ended before n+1's was launched.
    [_, second] = launches(rt, goal)
    ended = Enum.find(ends(rt), &(&1["pid"] == launch["pid"]))
    assert ended, "n's end is not in the log: #{inspect(ends(rt))}"

    assert DateTime.compare(iso(ended["at"]), iso(second["at"])) == :lt,
           "n+1 launched at #{second["at"]}, before n ended at #{ended["at"]}"
  end

  # The restart proves the turn's process gone (its helper ended it on losing its parent),
  # which needs a process listing.
  @tag :process_listing
  test "case 6: killing the Runtime mid-turn gives interrupted; retry with resume continues the conversation",
       %{rt: rt} do
    {rt, work, attempt, first} = interrupted_mid_turn!(rt, "resume case-6a")
    assert attempt["quiescent"], "the restart did not prove the ended turn gone"
    resumes!(rt, work, attempt, first)
  end

  test "case 6: an interrupted work whose turn stayed unknown resumes after release", %{rt: rt} do
    # The helper dies with the BEAM, so the turn outlives the Runtime and stays unknown,
    # also where a process listing works.
    {rt, work, attempt, first} = interrupted_mid_turn!(rt, "resume case-6r", :with_helper)
    refute attempt["quiescent"], inspect(attempt)

    # Without proof the turn is gone, only a human release makes n quiescent (I1). The
    # human ends the orphaned turn's process group, then releases its slot.
    System.cmd("kill", ["-KILL", "-#{first["pid"]}"], stderr_to_stdout: true)
    await(fn -> not alive?(first["pid"]) end)
    released = cli(rt, ["release", "--worker", attempt["slot"]])
    assert released.status == 0, released.out
    await_work(rt, work["work_id"], &current(&1)["quiescent"])

    resumes!(rt, work, attempt, first)
  end

  # Runs `goal` (a "resume" goal: it hangs until it is resumed), SIGKILLs the BEAM mid-turn
  # and reboots. With `:beam` the host helper survives and ends the orphaned turn first;
  # with `:with_helper` it is killed too, and the turn's process outlives the Runtime.
  defp interrupted_mid_turn!(rt, goal, kill \\ :beam) do
    work = submit!(rt, goal)
    running = await_launch(rt, work)
    [first] = launches(rt, goal)

    case kill do
      :beam ->
        kill_beam!(rt)

        await(fn ->
          Enum.any?(ends(rt), &(&1["pid"] == first["pid"])) and not alive?(first["pid"])
        end)

      :with_helper ->
        kill_with_helper!(rt, first)
        Process.sleep(500)
        assert alive?(first["pid"]), "the stub child did not survive the Runtime's SIGKILL"
    end

    rt = reboot!(rt)

    n = await_state(rt, work["work_id"], "interrupted")
    attempt = current(n)
    assert attempt["result"]["kind"] == "interrupted"
    assert attempt["result"]["retryable"] == true
    assert %{"turn_id" => turn, "conversation_id" => conversation} = attempt["resume_point"]
    assert turn == current(running)["turn_id"]
    assert conversation == first["session_id"]
    {rt, work, attempt, first}
  end

  defp resumes!(rt, work, attempt, first) do
    goal = work["request"]["instructions"]
    response = retry(rt, work["work_id"], %{"resume" => true})
    assert response.status == 201

    done = await_work(rt, work["work_id"], &(terminal?(&1) and current(&1)["attempt"] == 2))
    resumed = current(done)
    assert done["state"] == "completed", "the resumed attempt: #{inspect(resumed)}"
    assert resumed["slot"] == attempt["slot"]
    assert resumed["result"]["answer"] == "resumed: #{first["session_id"]}"
    assert resumed["provenance"]["selection"]["reason"] == "continuation"
    assert [_, %{"resumed" => true, "session_id" => session}] = launches(rt, goal)
    assert session == first["session_id"]
  end

  test "case 6: a restart during a time_limit cancel ends failed: time_limit", %{rt: rt} do
    work = submit!(rt, "stubborn case-6b", extra: %{"profile" => "timed_work"})
    await_launch(rt, work)

    # max_duration 1 s: the core cancels with time_limit; the harness ignores SIGINT, so the
    # attempt stays cancelling (cancel_grace 30 s) while the Runtime is killed.
    cancelling = await_work(rt, work["work_id"], &(&1["state"] == "cancelling"), 10_000)
    assert current(cancelling)["cancel_reason"] == "time_limit"

    kill_beam!(rt)
    rt = reboot!(rt)

    done = await_work(rt, work["work_id"], &terminal?/1)
    assert done["state"] == "failed", inspect(current(done))
    assert current(done)["result"]["reason"] == "time_limit"
    assert current(done)["result"]["retryable"] == false
  end

  test "case 7: a Last-Event-ID from before a restart opens with reset", %{rt: rt} do
    work = submit!(rt, "complete case-7c")
    await_state(rt, work["work_id"], "completed")
    %{json: %{"sequence" => before}} = request(rt, "GET", "/v1/work")
    %{json: %{"incarnation" => incarnation}} = capacity(rt)

    stop!(rt)
    rt = reboot!(rt)
    assert capacity(rt).json["incarnation"] != incarnation

    events = subscribe(rt, [{"last-event-id", before}])
    frame = await_frame(events, "reset", fn _ -> true end, 5_000)
    assert frame["data"]["current_sequence"] > before
    close(events)

    # The client re-reads what changed: the work is still there, completed.
    %{status: 200, json: %{"works" => works}} = request(rt, "GET", "/v1/work?changed_since=0")
    assert Enum.any?(works, &(&1["work_id"] == work["work_id"] and &1["state"] == "completed"))
  end

  test "case 9: a pruned work answers 410 pruned by key and by id", %{rt: rt} do
    work = submit!(rt, "complete case-9", key: "case-9")
    id = work["work_id"]
    await_state(rt, id, "completed")
    stop!(rt)

    # The retention (30 days) is not configurable from outside the process: the record's end
    # is moved 31 days back while the Runtime is stopped.
    age!(rt, id, 31 * 24 * 3600)
    rt = reboot!(rt)

    # Pruning runs with the heartbeat (15 s).
    pruned =
      await(
        fn -> (r = request(rt, "GET", "/v1/work?key=case-9")) && r.status == 410 && r end,
        40_000,
        fn ->
          "not pruned: #{inspect(request(rt, "GET", "/v1/work?key=case-9"))}"
        end
      )

    assert header(pruned, "content-type") =~ "application/problem+json"
    assert %{"type" => "pruned", "work_id" => ^id, "kind" => "completed"} = pruned.json
    assert %{status: 410, json: %{"type" => "pruned"}} = get(rt, id)
    assert %{status: 404} = request(rt, "GET", "/v1/work?key=never-used")
    refute File.exists?(Path.join([rt.home, "work", "#{id}.json"]))
  end

  test "turns from before a restart are still listed by atlas-runtime turns", %{rt: rt} do
    work = submit!(rt, "complete history")
    turn = current(await_state(rt, work["work_id"], "completed"))["turn_id"]
    stop!(rt)
    rt = reboot!(rt)

    listed = cli(rt, ["turns"])
    assert listed.status == 0, listed.out
    assert listed.out =~ turn
  end

  defp age!(rt, id, seconds) do
    path = Path.join([rt.home, "work", "#{id}.json"])
    record = path |> File.read!() |> JSON.decode!()

    shift = fn
      nil -> nil
      text -> text |> iso() |> DateTime.add(-seconds) |> DateTime.to_iso8601()
    end

    attempts =
      for attempt <- record["attempts"] do
        update_in(attempt, ["timestamps"], fn stamps ->
          Map.new(stamps, fn {k, v} -> {k, shift.(v)} end)
        end)
      end

    File.write!(path, JSON.encode!(%{record | "attempts" => attempts}))
  end
end

defmodule RuntimeBackendE2E.CLI do
  @moduledoc """
  The CLI's work commands, an HTTP client of backend.sock (D3, `host/work.go`:
  start/continue → `POST /v1/work`, stop/kill → cancel graceful/force, status →
  `GET /v1/work`, output → `/v1/turns/{id}/output`). The argv of each command is built
  here only. A reply is the
  command's JSON on stdout; `work/1` takes the work from it.
  """
  import RuntimeBackendE2E

  def start(rt, instructions, opts \\ []) do
    folder = work_request(rt, instructions)["workspace"]["path"]

    [
      "start",
      "--profile",
      opts[:profile] || "light_work",
      "--cost-class",
      opts[:cost_class] || "standard"
    ] ++
      ["--cwd", folder, "--permissions", "read-only"] ++
      if(opts[:key], do: ["--key", opts[:key]], else: []) ++
      if(opts[:slot], do: ["--slot", opts[:slot]], else: []) ++ [instructions]
  end

  def continue(rt, turn, instructions) do
    folder = work_request(rt, instructions)["workspace"]["path"]

    [
      "continue",
      "--resume-from",
      turn,
      "--profile",
      "light_work",
      "--cost-class",
      "standard",
      "--cwd",
      folder,
      instructions
    ]
  end

  def stop(id), do: ["stop", "--work", id]
  def kill(id), do: ["kill", "--work", id]
  def status, do: ["status"]
  def output(turn), do: ["output", "--turn", turn]

  def work(%{json: %{"work_id" => _} = work}), do: work
  def work(%{json: %{"work" => %{"work_id" => _} = work}}), do: work

  def work(reply),
    do: ExUnit.Assertions.flunk("no work in the CLI's reply (#{reply.status}): #{reply.out}")
end

defmodule RuntimeBackendE2E.CLITest do
  @moduledoc """
  The design cases through the CLI (the host built from this tree), checked over HTTP.
  Cases 5 (retry), 7 (the event stream) and 9 (a key lookup) are covered over HTTP only,
  and `turns` (history, read.sock until S2) in RestartTest.
  """
  use ExUnit.Case, async: false
  import RuntimeBackendE2E
  alias RuntimeBackendE2E.CLI

  @moduletag :cli

  setup_all do
    rt = runtime!()
    on_exit(fn -> cleanup(rt) end)
    %{rt: rt}
  end

  setup %{rt: rt} do
    quiesce(rt)
    on_exit(fn -> quiesce(rt) end)
    :ok
  end

  test "case 1 (CLI): start, then status and output show the completed work", %{rt: rt} do
    started = cli(rt, CLI.start(rt, "complete cli-1"))
    assert started.status == 0, started.out
    id = CLI.work(started)["work_id"]

    done = await_state(rt, id, "completed")
    status = cli(rt, CLI.status())
    assert status.status == 0, status.out
    assert status.out =~ id and status.out =~ "completed"

    output = cli(rt, CLI.output(current(done)["turn_id"]))
    assert output.status == 0, output.out
    assert output.out =~ "done: complete cli-1"
    assert [_] = launches(rt, "complete cli-1")
  end

  test "case 2 (CLI): the same key gives the same work; another request with it is refused", %{
    rt: rt
  } do
    first = cli(rt, CLI.start(rt, "complete cli-2", key: "cli-2"))
    assert first.status == 0, first.out
    again = cli(rt, CLI.start(rt, "complete cli-2", key: "cli-2"))
    assert again.status == 0, again.out
    assert CLI.work(again)["work_id"] == CLI.work(first)["work_id"]

    conflict = cli(rt, CLI.start(rt, "complete cli-2 other", key: "cli-2"))
    assert conflict.status != 0
    assert conflict.out =~ "idempotency-conflict" or conflict.out =~ "conflict"

    await_state(rt, CLI.work(first)["work_id"], "completed")
    assert [_] = launches(rt, "complete cli-2")
  end

  test "case 3 (CLI): with slots and buffer full, start reports at-capacity and the retry time",
       %{rt: rt} do
    for goal <- ["hang cli-3 a", "hang cli-3 b", "complete cli-3 buffered"] do
      reply = cli(rt, CLI.start(rt, goal))
      assert reply.status == 0, reply.out
    end

    full = cli(rt, CLI.start(rt, "complete cli-3 refused"))
    assert full.status != 0
    assert full.out =~ "at-capacity" or full.out =~ "at_capacity"
    assert full.out =~ "60"
    assert launches(rt, "complete cli-3 refused") == []
  end

  test "case 4 (CLI): stop cancels running work gracefully; kill forces a harness that ignores it",
       %{rt: rt} do
    graceful = CLI.work(cli(rt, CLI.start(rt, "hang cli-4 graceful")))
    await_launch(rt, graceful)
    stop = cli(rt, CLI.stop(graceful["work_id"]))
    assert stop.status == 0, stop.out

    assert current(await_state(rt, graceful["work_id"], "cancelled"))["timestamps"][
             "signalled_at"
           ]

    stubborn = CLI.work(cli(rt, CLI.start(rt, "stubborn cli-4 force")))
    await_launch(rt, stubborn)
    kill = cli(rt, CLI.kill(stubborn["work_id"]))
    assert kill.status == 0, kill.out
    done = await_state(rt, stubborn["work_id"], "cancelled")
    assert current(done)["timestamps"]["forced_at"]
  end

  test "case 6 (CLI): continue --resume-from continues the turn's conversation", %{rt: rt} do
    first = CLI.work(cli(rt, CLI.start(rt, "complete cli-6")))
    done = await_state(rt, first["work_id"], "completed")
    turn = current(done)["turn_id"]
    [launch] = launches(rt, "complete cli-6")

    next = cli(rt, CLI.continue(rt, turn, "resume cli-6 next"))
    assert next.status == 0, next.out
    resumed = await_state(rt, CLI.work(next)["work_id"], "completed")
    assert current(resumed)["provenance"]["selection"]["reason"] == "continuation"
    assert [%{"resumed" => true, "session_id" => session}] = launches(rt, "resume cli-6 next")
    assert session == launch["session_id"]
  end

  test "case 8 (CLI): a top-level model change fails the started work with model_changed", %{
    rt: rt
  } do
    work = CLI.work(cli(rt, CLI.start(rt, "model_change cli-8", profile: "claude_work")))
    done = await_work(rt, work["work_id"], &terminal?/1)
    assert done["state"] == "failed"
    assert current(done)["result"]["reason"] == "model_changed"
    assert cli(rt, CLI.status()).out =~ "model_changed"
  end
end
