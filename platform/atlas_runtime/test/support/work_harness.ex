defmodule AtlasRuntime.WorkHarness do
  @moduledoc """
  The work core's test bench: a Runtime home with a `policy.json`, a fake Codex and Claude
  on `PATH` (`fake-native work`, which never launches a provider), the real Service and
  `AtlasRuntime.Work`. Callers go through the facade `AtlasRuntime.Boundary.Work` only.

  Timer values: heartbeat 100 ms, cancel grace 300 ms, every wait at most 10 s.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Service

  defmodule SlowStart do
    @moduledoc false
    # In front of the Service, one call at a time as the Service takes them: the first
    # start reaches it only when the test sends `:go`, as a slow repository preparation
    # would hold it; everything else passes straight through.
    use GenServer

    @impl true
    def init({service, test}), do: {:ok, {service, test}}

    @impl true
    def handle_call(%{"command" => "start"} = request, _from, {service, test})
        when is_pid(test) do
      send(test, :start_held)

      receive do
        :go -> {:reply, GenServer.call(service, request, :infinity), {service, nil}}
      end
    end

    def handle_call(request, _from, {service, _} = state),
      do: {:reply, GenServer.call(service, request, :infinity), state}
  end

  @wait 10_000
  @options [heartbeat_ms: 100, cancel_grace_ms: 300]

  @doc "Starts a home, a Service and the core; `policy` overrides policy.json fields."
  def start!(policy \\ %{}, options \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "aw-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)

    for tool <- ["git", "mkfifo"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    for harness <- ["codex", "claude"],
        do: AtlasRuntime.FakeNative.install!(Path.join(bin, harness), "work", [dir])

    previous =
      for name <- ["PATH", "CODEX_HOME", "GIT_CONFIG_GLOBAL"], do: {name, System.get_env(name)}

    # The fakes first; /usr/bin:/bin keep `ps` for the work core's process listing.
    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    System.put_env("CODEX_HOME", Path.join(dir, "codex-home"))
    System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
    write_policy!(dir, policy)

    context = %{dir: dir, workspace: workspace, options: options}
    context = Map.put(context, :service, start_service!(context))
    context = Map.put(context, :work, start_work!(context))

    on_exit(fn ->
      stop_all()
      await_preparers()

      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      remove_home!(dir)
    end)

    context
  end

  @doc "The test policy: slots s1, s2, buffer 1, profile light_work on Codex; `changes` merged in."
  def write_policy!(dir, changes \\ %{}) do
    policy =
      Map.merge(
        %{
          "version" => 1,
          "slots" => ["s1", "s2"],
          "buffer_size" => 1,
          "profiles" => %{
            "light_work" => %{
              "permissions" => ["read-only", "workspace-write", "materialized-folder"],
              "cost_classes" => ["low", "standard"],
              "options" => [
                %{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}
              ]
            }
          }
        },
        changes
      )

    File.write!(Path.join(dir, "policy.json"), JSON.encode!(policy))
  end

  @doc "A Service on the home; `probe` is its restart reconciliation's process check."
  def start_service!(context, probe \\ nil) do
    File.rm(Path.join(context.dir, "runtime.sock"))
    options = if probe, do: [process_probe: probe], else: []
    {:ok, pid} = GenServer.start(Service, {context.dir, nil, [], options})
    pid
  end

  @doc "The work core on the home, following `context.service`."
  def start_work!(context, options \\ []) do
    options =
      @options
      |> Keyword.merge(context.options)
      |> Keyword.merge(options)
      |> Keyword.put(:service, context.service)

    {:ok, pid} = AtlasRuntime.Work.start_link(context.dir, options)
    Process.unlink(pid)
    pid
  end

  @doc """
  Stops the core, the Service and every native execution, as a SIGKILL of the Runtime
  would: the helpers then lose their parent and end their own groups.
  """
  def stop_all do
    for name <- [AtlasRuntime.Work.Server], pid = GenServer.whereis(name), do: kill(pid)

    for pid <- Process.list(),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        dictionary[:"$initial_call"] in [
          {Service, :init, 1},
          {AtlasRuntime.Agent.Native, :init, 1}
        ],
        do: kill(pid)

    :ok
  end

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("#{inspect(pid)} did not stop")
    end
  end

  @doc """
  Waits for every folder preparer (`AtlasRuntime.Work.Folders`) to end. A preparer is not
  linked to the core (F17): a stopped core leaves it to finish its helper, which still writes,
  then seals (0555), the work folder and the snapshot baseline under the home. One still alive
  after `timeout` ms has its helper (the OS process behind its port) and itself killed.
  """
  def await_preparers(timeout \\ @wait) do
    deadline = System.monotonic_time(:millisecond) + timeout

    for pid <- preparers() do
      monitor = Process.monitor(pid)
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        remaining ->
          for port <- links(pid),
              {:os_pid, os_pid} <- [Port.info(port, :os_pid)],
              do:
                System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)],
                  stderr_to_stdout: true
                )

          Process.demonitor(monitor, [:flush])
          kill(pid)
      end
    end

    :ok
  end

  # A preparer is a plain `spawn/1` (initial call `:erlang.apply/2`): it is known by the
  # `Folders` frames on its stack.
  defp preparers do
    for pid <- Process.list(),
        {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(stack, &match?({AtlasRuntime.Work.Folders, _, _, _}, &1)),
        do: pid
  end

  defp links(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.filter(links, &is_port/1)
      nil -> []
    end
  end

  # Removes the home once nothing of the bench writes in it: the write bits back first (sealed
  # folders and snapshot baselines are 0555, and Linux cannot unlink inside them), then
  # `rm_rf`. Native executions end their own groups after `stop_all/0`, asynchronously, so a
  # failed pass is retried until the wait runs out.
  defp remove_home!(dir, deadline \\ System.monotonic_time(:millisecond) + @wait) do
    System.cmd("/bin/chmod", ["-R", "u+w", dir], stderr_to_stdout: true)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          remove_home!(dir, deadline)
        else
          File.rm_rf!(dir)
        end
    end
  end

  @doc "Stops the work core alone (the Service keeps running)."
  def stop_work do
    if pid = GenServer.whereis(AtlasRuntime.Work.Server), do: kill(pid)
    :ok
  end

  @doc """
  A folder work request (a map, as decoded JSON would be), in a folder of its own named
  after the instructions: the Service refuses two turns in overlapping folders.
  """
  def request(context, instructions, extra \\ %{}) do
    folder =
      Path.join(context.workspace, Base.encode16(:crypto.hash(:md5, instructions), case: :lower))

    File.mkdir_p!(folder)

    Map.merge(
      %{
        title: instructions,
        instructions: instructions,
        profile: "light_work",
        cost_class: "standard",
        workspace: %{kind: "folder", path: folder, permissions: "read-only"}
      },
      extra
    )
  end

  @doc """
  A local client with the work rights and choose_path (the harness's requests name a
  folder, D44), without read_all or choose_slot.
  """
  def client(id \\ "c1", extra \\ []), do: {id, [:submit, :cancel, :read, :choose_path | extra]}

  @doc "Submits through the facade and asserts `accepted`."
  def submit!(context, instructions, extra \\ %{}, client \\ client()) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(client, request(context, instructions, extra))

    work
  end

  @doc "Reads a work through the facade."
  def work!(id, client \\ client()) do
    assert %F.Outcome.Found{work: work} = F.get_work(client, %{work_id: id})
    work
  end

  @doc """
  The work once `check` holds for it. `check` should name a fact the work keeps once it
  holds (a terminal state, a quiescent attempt, a held turn): a state the work only passes
  through can be gone before the next look. On timeout the work as it is then is reported.
  """
  def await_work(id, check, client \\ client(), what \\ "the awaited work state") do
    await(
      fn ->
        work = work!(id, client)
        if check.(work), do: work
      end,
      fn -> "#{what} of #{id}; now: #{inspect(seen(work!(id, client)))}" end
    )
  end

  @doc "The work once its current attempt is in `state` (a state it stays in, see `await_work/4`)."
  def await_state(id, state, client \\ client()),
    do: await_work(id, &(&1.state == state), client, "state #{inspect(state)}")

  defp seen(work),
    do: %{
      state: work.state,
      attempts: Enum.map(work.attempts, &Map.take(&1, [:attempt, :state, :turn_id, :quiescent]))
    }

  @doc """
  The value of `fun` once it is truthy; fails after 10 s naming `what` (a string, or a
  function giving one at the failure).
  """
  def await(fun, what \\ "condition"),
    do: await(fun, what, System.monotonic_time(:millisecond) + @wait)

  defp await(fun, what, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("not met in #{@wait} ms: #{if is_function(what), do: what.(), else: what}")

        Process.sleep(20)
        await(fun, what, deadline)
    end
  end

  @doc """
  The records of the bench's JSONL log `name` (the fakes' `work-launches.jsonl`,
  `work-ends.jsonl`, ...): only the complete, newline-terminated lines. A fake appends each
  record with one `write(2)` while the test may be reading, so the bytes after the last
  newline can be a record still being written; they are never decoded.
  """
  def jsonl(context, name) do
    case File.read(Path.join(context.dir, name)) do
      {:ok, bytes} -> bytes |> complete_lines() |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "The newline-terminated lines of `bytes`, without a trailing partial line."
  def complete_lines(bytes) do
    case :binary.matches(bytes, "\n") do
      [] ->
        []

      matches ->
        {last, 1} = List.last(matches)
        bytes |> binary_part(0, last) |> String.split("\n", trim: true)
    end
  end

  @doc "The fake harness's launches: one map per native start."
  def launches(context), do: jsonl(context, "work-launches.jsonl")

  @doc """
  The work once the fake harness has launched its turn: `count` launch records of the goal
  are in the launch log, and the work's current attempt holds the turn the Service admitted
  (`turn_id`). Both only ever become true, so a turn that ends before the next look (a goal
  that completes at once) is still seen as launched; the attempt's state is whatever it is
  by then (`running` for a turn that has not ended). No transient state is waited for.
  """
  def await_launch(context, work, count \\ 1, client \\ client()) do
    goal = work.request.instructions

    await(
      fn ->
        if Enum.count(launches(context), &(&1["goal"] == goal)) >= count do
          current = work!(work.work_id, client)
          if launched?(List.last(current.attempts)), do: current
        end
      end,
      fn ->
        "#{count} launch(es) of #{inspect(goal)} with the attempt's admitted turn; now: " <>
          "#{Enum.count(launches(context), &(&1["goal"] == goal))} launch(es), " <>
          inspect(seen(work!(work.work_id, client)))
      end
    )
  end

  # The current attempt was admitted as a turn and has left the start path.
  defp launched?(%{turn_id: turn}) when is_binary(turn), do: true
  defp launched?(_attempt), do: false

  @doc "A turn's record as the Service wrote it."
  def turn(context, turn_id),
    do: Path.join([context.dir, "turns", turn_id, "turn.json"]) |> File.read!() |> JSON.decode!()

  @doc "Notifications received so far (or within `timeout` for the first), in order."
  def notifications(timeout \\ 0) do
    receive do
      {:atlas_runtime_work, notification} -> [notification | notifications(0)]
    after
      timeout -> []
    end
  end
end
