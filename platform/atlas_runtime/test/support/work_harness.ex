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

      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(dir)
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

  @doc "The work once `check` holds for it."
  def await_work(id, check, client \\ client()) do
    await(fn ->
      work = work!(id, client)
      if check.(work), do: work
    end)
  end

  @doc "The work once its current attempt is in `state`."
  def await_state(id, state, client \\ client()), do: await_work(id, &(&1.state == state), client)

  @doc "The value of `fun` once it is truthy; fails after 10 s."
  def await(fun, deadline \\ System.monotonic_time(:millisecond) + @wait) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
        Process.sleep(20)
        await(fun, deadline)
    end
  end

  @doc "The fake harness's launches: one map per native start."
  def launches(context) do
    case File.read(Path.join(context.dir, "work-launches.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "The work, running, once the fake harness has launched its turn (`count` launches of the goal)."
  def await_launch(context, work, count \\ 1, client \\ client()) do
    running = await_state(work.work_id, :running, client)
    goal = work.request.instructions
    await(fn -> Enum.count(launches(context), &(&1["goal"] == goal)) >= count end)
    running
  end

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
