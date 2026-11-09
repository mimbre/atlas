# Isolated real model/Facts/Flow/Control/Rela proof. Never uses an environment service.
# MIX_ENV=test mix run integration/to_do_native.exs PRIVATE_DIR RELA_BIN_DIR BASE_DIGESTS
# BASE_DIGESTS is the unchanged slice14 model/targets/proof/digests.json.
import ExUnit.Assertions
alias AtlasFlow.{ManualClock, Talk}
alias AtlasFlow.Runs.{Projection, Store}
alias AtlasControl.{Answers, Pages}
alias AtlasControl.Model, as: Catalog

[dir, bin, base_path] = System.argv()
root = Path.expand("../..", __DIR__)
data = Path.join(dir, "rela")
File.mkdir_p!(data)

# Compile the real clients against the same generated BFF contract, in memory only.
client_sources = Path.wildcard(Path.join(root, "clients/{agent,tui}/lib/**/*.ex"))
assert {:ok, _, _} = Kernel.ParallelCompiler.compile(client_sources)

# Compare the generated proof structurally, including every prior history entry.
base = base_path |> File.read!() |> JSON.decode!()
proof = Path.join(root, "model/targets/proof/digests.json") |> File.read!() |> JSON.decode!()
assert Map.delete(proof["subflows"], "to_do") == base["subflows"]

{out, status} =
  System.cmd(
    System.get_env("ATLAS_CONFIG_PYTHON") || "python3",
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
  now = ~U[2026-11-13 00:00:00Z]
  {:ok, clock} = ManualClock.start_link(now)
  Application.put_env(:atlas, :model, Model.AtlasEyra)
  Application.put_env(:atlas, :actors, %{"decider" => "ada"})

  {:ok, facts} =
    AtlasFacts.Server.start_link(
      rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
      data_dir: Path.join(dir, "facts"),
      flow_input_clock: fn -> ManualClock.now(clock) end
    )

  :ok = AtlasBus.attach("control/session-to-do-proof")
  deadline = System.monotonic_time(:millisecond) + 30_000

  await = fn await ->
    case Talk.read("_description", %{}) do
      %{"description" => %{"entities" => %{}} = d} ->
        d

      other ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(other)
        await.(await)
    end
  end

  served = await.(await)
  assert Map.take(served, ~w(entities relations types)) == Model.AtlasEyra.rela_schema()
  File.write!(Path.join(dir, "served-schema.json"), JSON.encode!(served))

  %{config: config, flows: flows, refusal: nil} =
    runner = AtlasFlow.Model.load(Model.AtlasEyra, :test)

  assert map_size(config["selection"]) == 10
  refute Map.has_key?(config["selection"]["to_do"], "legacy")

  reconcile = fn ->
    Task.async(fn ->
      :ok = AtlasBus.attach("flow")

      try do
        with {:ok, runs} <- Store.reconcile(config, flows, ManualClock.now(clock)) do
          subjects = Enum.uniq(for run <- runs, do: {run["subject_kind"], run["subject_key"]})

          for {kind, key} <- subjects do
            assert {:ok, _} = Projection.project(runner, kind, key)
          end

          {:ok, runs}
        end
      after
        Registry.unregister(AtlasBus.Endpoints, "flow")
      end
    end)
    |> Task.await(30_000)
  end

  put = fn kind, content ->
    assert {:stored, _} = Talk.put(kind, content), inspect(content)
  end

  read = fn kind, key ->
    %{"fact" => fact} = Talk.read(kind, %{"key" => key, "presentation" => true})
    fact
  end

  for {kind, key} <- [{"person", "ada"}, {"person", "bo"}, {"agent", "helper"}] do
    put.(kind, %{"op" => "create", "key" => key, "values" => %{"name" => key}})
  end

  {:ok, gateway} = AtlasControl.Gateway.start_link(port: 0, model: Model.AtlasEyra)
  control_port = AtlasControl.Gateway.port(gateway)
  environment = AtlasBus.environment()

  settings = %{
    "env" => environment,
    "control" => %{"host" => "127.0.0.1", "port" => control_port}
  }

  env_file = Path.join(dir, "environment.json")
  File.write!(env_file, JSON.encode!(settings))
  System.put_env("ATLAS_ENV_FILE", env_file)

  # Consume the real Console handshake, boot and page stream over a private socket.
  # No page, projection, action or field is supplied by a test double.
  send_tui = fn socket, effects ->
    for {:send, message} <- effects do
      :ok = :gen_tcp.send(socket, JSON.encode!(message) <> "\n")
    end
  end

  receive_tui = fn receive_tui, socket, model ->
    if model.console.phase == :ready and model.console.in_flight == nil do
      model
    else
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
      {model, effects} = AtlasTui.Console.receive(model, JSON.decode!(line))
      send_tui.(socket, effects)
      receive_tui.(receive_tui, socket, model)
    end
  end

  for values <- [%{"title" => "Missing instructions"}, %{"instructions" => "Missing title"}] do
    assert {:refused, [_ | _]} =
             Talk.put("to_do", %{"op" => "create", "key" => "TD-99", "values" => values})
  end

  instructions = "Open the account.\nKeep the receipt in the shared folder."
  due = "2026-11-14T12:00:00Z"
  catalog = Catalog.catalog(Model.AtlasEyra)
  form = Model.AtlasEyra.form("to_do", :create)
  assert form.ask == ["title", "instructions"]
  assert form.defaults == %{"status" => "open"}
  kind = Enum.find(Model.AtlasEyra.kinds(), &(&1.name == "to_do"))
  assert %{prefix: "TD-", digits: 2} = kind.id
  assert Pages.next_key(kind, []) == {"TD-01", 1}
  assert Pages.next_key(kind, ["TD-01", "TD-07"]) == {"TD-08", 8}

  for {key, owner, owner_kind, status, answer_key} <- [
        {"TD-01", "ada", "person", "done", "x"},
        {"TD-02", "ada", "person", "wont_do", "n"},
        {"TD-03", "helper", "agent", "done", "x"},
        {"TD-04", "helper", "agent", "wont_do", "n"}
      ] do
    System.put_env("ATLAS_AS", owner)
    assert {:ok, client} = AtlasAgent.Client.connect(environment, settings)

    assert {:ok, ^key} =
             AtlasAgent.put(client, "to_do", %{
               "title" => "Account",
               "instructions" => instructions
             })

    put.("assignment", %{
      "op" => "change",
      "key" => "AS-#{key}",
      "by" => "ada",
      "values" => %{"deadline" => due},
      "links" => %{"assigned_to" => [owner]}
    })

    assert {:ok, runs} = reconcile.()
    run = Enum.find(runs, &(&1["subject_key"] == key))
    assert {run["state"], run["status"]} == {"open", "active"}
    subject = read.("to_do", key)
    assignment = read.("assignment", "AS-#{key}")
    assert assignment["values"]["deadline"] == due
    refute Map.has_key?(subject["values"], "deadline")
    assert assignment["links"]["assigned_to"] == [owner]
    item = %{"fact" => subject, "parts" => %{"assignment" => assignment}}
    viewer = %{key: owner, kind: owner_kind}
    todo = Model.AtlasEyra.todo("to_do", subject, item["parts"], viewer)
    assert todo.section.text == instructions
    assert Enum.map(todo.answers, & &1.key) == ~w(x n)
    assert Enum.all?(todo.answers, & &1.note)

    # Real Facts reads feed Control's renderer: the shared section is visible to the
    # owner on the page used by both Console detail and agent get/guidance.
    route = {:item, "to_do", key}
    answers = Enum.map(Pages.reads(route, catalog), fn {k, content} -> Talk.read(k, content) end)
    page = Pages.render(route, catalog, answers, %{by: owner, by_kind: owner_kind})
    todo_block = Enum.find(page.blocks, &(&1["id"] == "todo"))
    assert Enum.any?(todo_block["props"]["fields"], &(&1["value"] == instructions))

    fields =
      for block <- page.blocks, field <- get_in(block, ["props", "fields"]) || [], do: field

    {:ok, due_at, _} = DateTime.from_iso8601(due)
    shown_due = Calendar.strftime(due_at, "%Y-%m-%d %H:%M UTC")
    assert Enum.any?(fields, &String.starts_with?(&1["value"] || "", shown_due))

    # The agent's real guidance API carries the complete instruction section.
    assert {:ok, guidance} = AtlasAgent.get(client, key)
    assert Enum.any?(guidance["todo"]["fields"], fn [_label, value] -> value == instructions end)

    assert Enum.any?(guidance["fields"], fn [_label, value] ->
             String.starts_with?(value || "", shown_due)
           end)

    File.write!(Path.join(dir, "#{key}.agent.json"), JSON.encode!(guidance))

    # Exercise the CLI's plain guidance rendering too, capturing its genuine output.
    {:ok, output} = StringIO.open("")
    leader = Process.group_leader()

    try do
      Process.group_leader(self(), output)
      assert AtlasAgent.CLI.main(["get", key, "--env", environment]) == 0
    after
      Process.group_leader(self(), leader)
    end

    {_, agent_text} = StringIO.contents(output)
    StringIO.close(output)
    for line <- String.split(instructions, "\n"), do: assert(String.contains?(agent_text, line))
    assert String.contains?(agent_text, shown_due)
    File.write!(Path.join(dir, "#{key}.agent.txt"), agent_text)

    Application.put_env(:atlas_control, :tui_user, owner)

    assert {:ok, tui_socket} =
             :gen_tcp.connect(~c"127.0.0.1", control_port, [
               :binary,
               packet: :line,
               active: false,
               buffer: 4_194_304
             ])

    tui = AtlasTui.Model.new(environment)
    send_tui.(tui_socket, [{:send, AtlasTui.Console.hello(tui)}])
    tui = receive_tui.(receive_tui, tui_socket, tui)
    {tui, effects} = AtlasTui.Console.open(tui, "/k/to_do/#{key}")
    send_tui.(tui_socket, effects)
    tui = receive_tui.(receive_tui, tui_socket, tui)
    assert tui.path == "/k/to_do/#{key}"
    screen = tui |> AtlasTui.View.render(110, 80, 5) |> AtlasTui.View.plain()
    for line <- String.split(instructions, "\n"), do: assert(String.contains?(screen, line))
    assert String.contains?(screen, shown_due)
    File.write!(Path.join(dir, "#{key}.console.txt"), screen)
    :gen_tcp.close(tui_socket)

    assert {:refuse, _} =
             Model.AtlasEyra.answer("to_do", answer_key, item, %{key: "bo", kind: "person"})

    assert {:write, answer} = Model.AtlasEyra.answer("to_do", answer_key, item, viewer)
    assert {:error, _} = Answers.change(answer, key, owner, "  ", now)

    assert {:refused, [_ | _]} =
             Talk.put("to_do", %{
               "op" => "change",
               "key" => key,
               "by" => owner,
               "values" => %{"status" => status}
             })

    assert {:refused, [_ | _]} =
             Talk.put("to_do", %{
               "op" => "change",
               "key" => key,
               "by" => "bo",
               "values" => %{"status" => status, "note" => "not the owner"}
             })

    assert {:refused, [_ | _]} =
             Talk.put("to_do", %{
               "op" => "change",
               "key" => key,
               "by" => "bo",
               "values" => %{"status" => status, "note" => "forged"},
               "links" => %{"assigned_to" => ["bo"]}
             })

    assert read.("to_do", key)["values"]["status"] == "open"

    # Direct Facts writes cannot bypass Control's trimmed-note validation. Each
    # owner/status case must remain unchanged after whitespace-only closing notes.
    for blank <- ["  \t\n  ", "\u00A0"] do
      before_blank = read.("to_do", key)

      assert {:refused, [_ | _]} =
               Talk.put("to_do", %{
                 "op" => "change",
                 "key" => key,
                 "by" => owner,
                 "values" => %{"status" => status, "note" => blank}
               })

      assert read.("to_do", key) == before_blank
    end

    assert {:ok, content, cause} =
             Answers.change(answer, key, owner, "  Kept the receipt.  ", now)

    assert content["values"]["note"] == cause

    assert {:ok, answer_page} =
             AtlasAgent.Client.open(client, "/k/to_do/#{key}/answer/#{answer_key}")

    [answer_form] = AtlasAgent.Client.blocks(answer_page, "form")

    assert {:refused, [_ | _]} =
             AtlasAgent.Client.submit(client, answer_form["submit_to"], %{"note" => "  "})

    assert {:stored, _} =
             AtlasAgent.Client.submit(client, answer_form["submit_to"], %{
               "note" => "  Kept the receipt.  "
             })

    assert {:ok, closed} = reconcile.()
    finished = Enum.find(closed, &(&1["key"] == run["key"]))
    assert {finished["state"], finished["status"]} == {status, "completed"}
    assert read.("to_do", key)["values"]["note"] == "Kept the receipt."
    assert read.("assignment", "AS-#{key}")["values"]["deadline"] == due

    File.write!(
      Path.join(dir, "#{key}.closed.json"),
      JSON.encode!(%{
        "run" => finished,
        "subject" => read.("to_do", key),
        "assignment" => read.("assignment", "AS-#{key}")
      })
    )

    AtlasAgent.Client.close(client)
  end

  Process.unlink(gateway)
  GenServer.stop(gateway, :shutdown)
  GenServer.stop(facts)

  IO.puts(
    "to_do_native: real create/open, Console detail, agent guidance, Assignment deadline, person/agent done/wont_do, owner/note refusals, existing identities/history: pass"
  )
after
  System.cmd("/bin/kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

  receive do
    {^server, {:exit_status, _}} -> :ok
  after
    5_000 ->
      System.cmd("/bin/kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
  end

  if Port.info(server), do: Port.close(server)
end
