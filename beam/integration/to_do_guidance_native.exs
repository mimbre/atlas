# Real automatic Flow, Facts, Control, Console and agent proof of terminal/reopened work.
# MIX_ENV=test mix run integration/to_do_guidance_native.exs PRIVATE_DIR RELA_BIN_DIR
import ExUnit.Assertions
alias AtlasFlow.Talk

[dir, bin] = System.argv()
root = Path.expand("../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)

assert {:ok, _, _} =
         Kernel.ParallelCompiler.compile(
           Path.wildcard(Path.join(root, "clients/{agent,tui}/lib/**/*.ex"))
         )

{out, status} =
  System.cmd(
    System.fetch_env!("ATLAS_CONFIG_PYTHON"),
    [
      Path.join(root, "rela/scripts/config.py"),
      "copy",
      "--root",
      Path.join(root, "rela"),
      "--data",
      data
    ],
    stderr_to_stdout: true
  )

assert status == 0, out
{:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)

server =
  Port.open({:spawn_executable, Path.join(bin, "rela-server")}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: ["-project", data, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
  ])

{:os_pid, os_pid} = Port.info(server, :os_pid)

try do
  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "ada"})

  {:ok, facts} =
    AtlasFacts.Server.start_link(
      rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
      data_dir: Path.join(dir, "facts")
    )

  :ok = AtlasBus.attach("control/session-guidance-proof")
  until = System.monotonic_time(:millisecond) + 30_000

  ready = fn ready ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}}} ->
        :ok

      other ->
        assert System.monotonic_time(:millisecond) < until, inspect(other)
        Process.sleep(10)
        ready.(ready)
    end
  end

  ready.(ready)
  put = fn kind, content -> assert {:stored, _} = Talk.put(kind, content) end

  read = fn kind, key ->
    %{"fact" => fact} = Talk.transition_read(kind, %{"key" => key, "presentation" => true})
    fact
  end

  for {kind, key} <- [{"person", "ada"}, {"person", "bo"}, {"agent", "helper"}] do
    put.(kind, %{"op" => "create", "key" => key, "values" => %{"name" => key}})
  end

  # All progression is production Engine processing hints and its own timer. This
  # fixture calls neither Store.reconcile nor Engine.round and presets no run state.
  {:ok, engine} =
    AtlasFlow.Engine.start_link(model: Model.AtlasEyra, environment: :test, every: 100)

  {:ok, gateway} = AtlasControl.Gateway.start_link(model: Model.AtlasEyra, port: 0)
  control_port = AtlasControl.Gateway.port(gateway)
  environment = AtlasBus.environment()

  settings = %{
    "env" => environment,
    "control" => %{"host" => "127.0.0.1", "port" => control_port}
  }

  send_tui = fn socket, effects ->
    for {:send, message} <- effects,
        do: :ok = :gen_tcp.send(socket, JSON.encode!(message) <> "\n")
  end

  receive_tui = fn receive_tui, socket, model, ready? ->
    if ready?.(model) do
      model
    else
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
      {model, effects} = AtlasTui.Console.receive(model, JSON.decode!(line))
      send_tui.(socket, effects)
      receive_tui.(receive_tui, socket, model, ready?)
    end
  end

  page_ready = fn model ->
    model.console.phase == :ready and model.console.in_flight == nil and not model.waiting
  end

  navigate = fn socket, model, path ->
    {model, effects} = AtlasTui.Console.open(model, path)
    send_tui.(socket, effects)
    receive_tui.(receive_tui, socket, model, &(page_ready.(&1) and &1.path == path))
  end

  refresh = fn socket, model, path ->
    {model, effects} = AtlasTui.Console.navigate(model, path)
    send_tui.(socket, effects)
    receive_tui.(receive_tui, socket, model, &(page_ready.(&1) and &1.path == path))
  end

  raw_runs = fn key ->
    mapping = Model.AtlasEyra.run_mapping()
    %{"facts" => runs} = Talk.transition_read(mapping["kind"], %{})
    Enum.filter(runs, &(get_in(&1, ["values", mapping["fields"]["subject_key"]]) == key))
  end

  runs_summary = fn key ->
    fields = Model.AtlasEyra.run_mapping()["fields"]

    for run <- raw_runs.(key) do
      {run["key"], run["values"][fields["generation"]], run["values"][fields["status"]],
       run["values"][fields["state"]]}
    end
  end

  due = "2026-12-01T10:00:00Z"

  note =
    "  Finished this work through the actual Console and retained the complete note, even when its display wraps across several terminal rows.  "

  for {owner, owner_kind, ending, shortcut} <- [
        {"ada", "person", "done", "x"},
        {"ada", "person", "wont_do", "n"},
        {"helper", "agent", "done", "x"},
        {"helper", "agent", "wont_do", "n"}
      ] do
    System.put_env("ATLAS_AS", owner)
    assert {:ok, client} = AtlasAgent.Client.connect(environment, settings)
    instructions = "Check the actual result before closing this work."

    assert {:ok, key} =
             AtlasAgent.put(client, "to_do", %{
               "title" => "Terminal guidance #{owner} #{ending}",
               "instructions" => instructions
             })

    put.("assignment", %{
      "op" => "change",
      "key" => "AS-#{key}",
      "by" => "ada",
      "values" => %{"deadline" => due},
      "links" => %{"assigned_to" => [owner]}
    })

    subject = read.("to_do", key)
    assignment = read.("assignment", "AS-#{key}")
    viewer = %{key: owner, kind: owner_kind}
    parts = %{"assignment" => assignment}
    assert Model.AtlasEyra.todo("to_do", subject, parts, viewer).section.text == instructions
    assert assignment["values"]["deadline"] == due
    refute Map.has_key?(subject["values"], "deadline")

    assert {:refuse, _} =
             Model.AtlasEyra.answer("to_do", shortcut, %{"fact" => subject, "parts" => parts}, %{
               key: "bo",
               kind: "person"
             })

    assert {:refused, [_ | _]} =
             Talk.put("to_do", %{
               "op" => "change",
               "key" => key,
               "by" => owner,
               "values" => %{"status" => ending, "note" => " \t\n "}
             })

    Application.put_env(:atlas_control, :tui_user, owner)

    assert {:ok, socket} =
             :gen_tcp.connect(~c"127.0.0.1", control_port, [
               :binary,
               packet: :line,
               active: false,
               buffer: 4_194_304
             ])

    tui = AtlasTui.Model.new(environment)
    send_tui.(socket, [{:send, AtlasTui.Console.hello(tui)}])
    tui = receive_tui.(receive_tui, socket, tui, page_ready)
    path = "/k/to_do/#{key}"
    tui = navigate.(socket, tui, path)
    assert "todo" in tui.ids
    {tui, effects} = AtlasTui.Model.key(tui, {:char, shortcut})
    send_tui.(socket, effects)

    tui =
      receive_tui.(
        receive_tui,
        socket,
        tui,
        &(page_ready.(&1) and &1.path == path <> "/answer/" <> shortcut)
      )

    {tui, effects} = AtlasTui.Model.key(tui, {:char, note})
    send_tui.(socket, effects)
    assert tui.values["note"] == note
    {tui, effects} = AtlasTui.Model.key(tui, :ctrl_s)
    send_tui.(socket, effects)
    tui = receive_tui.(receive_tui, socket, tui, &(page_ready.(&1) and &1.path == path))
    subject = read.("to_do", key)
    assignment = read.("assignment", "AS-#{key}")
    assert subject["values"]["status"] == ending
    assert subject["values"]["note"] == String.trim(note)
    assert assignment["values"]["deadline"] == due
    view = assignment["presentation"]
    assert view["status"] == "completed"
    refute view["actionable"]
    refute view["reopened"]
    assert view["owner"] == []
    assert is_nil(Model.AtlasEyra.todo("to_do", subject, %{"assignment" => assignment}, viewer))
    refute "todo" in tui.ids
    assert {:ok, agent} = AtlasAgent.get(client, key)
    refute Map.has_key?(agent, "todo")
    history = runs_summary.(key)
    assert [{_, 1, "completed", ^ending}] = history

    File.write!(
      Path.join(dir, "#{key}.closed.json"),
      JSON.encode!(%{
        "subject" => subject,
        "assignment" => assignment,
        "agent" => agent,
        "runs" => Enum.map(history, &Tuple.to_list/1)
      })
    )

    File.write!(
      Path.join(dir, "#{key}.closed.console.txt"),
      tui |> AtlasTui.View.render(110, 80, 5) |> AtlasTui.View.plain()
    )

    assert {:ok, ^key} = AtlasAgent.set(client, key, %{"status" => "open"})
    subject = read.("to_do", key)
    assignment = read.("assignment", "AS-#{key}")
    assert subject["values"]["status"] == "open"
    assert subject["values"]["note"] == String.trim(note)
    assert assignment["values"]["deadline"] == due
    assert assignment["presentation"]["reopened"]
    refute assignment["presentation"]["actionable"]
    assert assignment["presentation"]["owner"] == []
    todo = Model.AtlasEyra.todo("to_do", subject, %{"assignment" => assignment}, viewer)
    assert todo.answers == []
    assert is_nil(todo.section)
    assert is_nil(todo.instructions)

    assert {:refuse, _} =
             Model.AtlasEyra.answer(
               "to_do",
               shortcut,
               %{"fact" => subject, "parts" => %{"assignment" => assignment}},
               viewer
             )

    assert {:ok, agent} = AtlasAgent.get(client, key)
    assert Map.has_key?(agent, "todo")
    tui = refresh.(socket, tui, path)
    assert "todo" in tui.ids
    Process.sleep(250)
    assert runs_summary.(key) == history

    File.write!(
      Path.join(dir, "#{key}.reopened.json"),
      JSON.encode!(%{
        "subject" => subject,
        "assignment" => assignment,
        "agent" => agent,
        "runs" => Enum.map(history, &Tuple.to_list/1)
      })
    )

    File.write!(
      Path.join(dir, "#{key}.reopened.console.txt"),
      tui |> AtlasTui.View.render(110, 80, 5) |> AtlasTui.View.plain()
    )

    :gen_tcp.close(socket)
    AtlasAgent.Client.close(client)

    IO.puts(
      "#{key}: #{owner_kind} #{ending}, terminal guidance, genuine reopen, unchanged history"
    )
  end

  GenServer.stop(engine)
  Process.unlink(gateway)
  GenServer.stop(gateway, :shutdown)
  GenServer.stop(facts)
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^server, {:exit_status, _}} -> :ok
      after
        1_000 -> raise "private Rela did not stop"
      end
  end

  if Port.info(server), do: Port.close(server)
end
