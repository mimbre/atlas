# Private native acceptance. Run with the supported Elixir from products/software_factory (its test config):
# MIX_ENV=test mix run --no-start e2e/decision_choices_native.exs SCRATCH RELA_BIN
#
# CHOICE_PROOF_INPUT=terminal (the default) types digits into the real TUI under tmux.
# CHOICE_PROOF_INPUT=control is for a host that cannot allocate a pseudo-terminal: it
# submits the exact call Control projects for each key, over the same Control gateway,
# and ends PARTIAL, never PASS, since no keyboard input reached a real terminal.
import ExUnit.Assertions
alias AtlasFlow.Talk

[dir, bin] = System.argv()
input = System.get_env("CHOICE_PROOF_INPUT", "terminal")
assert input in ~w(terminal control), "CHOICE_PROOF_INPUT is terminal or control"
root = Path.expand("../../..", __DIR__)
File.mkdir_p!(dir)
System.put_env("TMPDIR", dir)

for app <- [:atlas_facts, :atlas_flow, :atlas_gates, :atlas_control, :atlas_runtime],
    do: Application.put_env(app, :start, false)

Application.put_env(:atlas, :model, Model.AtlasEyra)
Application.put_env(:atlas, :actors, %{"decider" => "choice-tester"})
Application.put_env(:atlas_bus, :environment, "test")
Application.put_env(:atlas_bus, :store, "state")
Application.put_env(:atlas_control, :tui_user, "choice-tester")
Application.put_env(:atlas_gates, :verdict_kind, "gate_verdict")

for app <- [:atlas_bus, :atlas_facts, :atlas_flow, :atlas_gates, :atlas_control],
    do: assert({:ok, _} = Application.ensure_all_started(app))

client_beams = Path.join(dir, "client-beams")
File.mkdir_p!(client_beams)

assert {:ok, _, _} =
         Kernel.ParallelCompiler.compile_to_path(
           Path.wildcard(Path.join(root, "platform/clients/{agent,tui}/lib/**/*.ex")),
           client_beams
         )

data = Path.join(dir, "rela")
refute File.exists?(data), "use a new owned private project; preserve prior failed projects"
File.mkdir_p!(data)
# The selected runtime closure, as integration/work_anchors.exs documents for
# Rela 26.11.2. Generated ACL/Flow files are validation inputs, not runtime inputs.
for name <- ["schema.yaml", "data-entry.yaml", "modules", "compositions"],
    do:
      File.cp_r!(
        Path.join([root, "products/software_factory/model/targets/rela", name]),
        Path.join(data, name)
      )

refute File.exists?(Path.join(data, "acl.yaml"))
refute File.exists?(Path.join(data, "flows.yaml"))
{:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
{:ok, port} = :inet.port(listen)
:gen_tcp.close(listen)
server_log = Path.join(dir, "rela-server.log")

server_args = [
  Path.join(bin, "rela-server"),
  "-project",
  data,
  "-bind",
  "127.0.0.1",
  "-port",
  to_string(port),
  "-quiet"
]

shell_quote = fn arg -> "'" <> String.replace(arg, "'", "'\\''") <> "'" end

server_command =
  "exec " <>
    Enum.map_join(server_args, " ", shell_quote) <> " > " <> shell_quote.(server_log) <> " 2>&1"

server =
  Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", server_command]])

{:os_pid, server_pid} = Port.info(server, :os_pid)
Process.put(:choice_proof_server, {server, server_pid})
tmux_socket = Path.join(dir, "choices.tmux")

defmodule ChoiceProof do
  import ExUnit.Assertions

  def await(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 20_000

    case fun.() do
      false ->
        assert System.monotonic_time(:millisecond) < deadline, "private native proof timed out"
        Process.sleep(30)
        await(fun, deadline)

      value ->
        value
    end
  end

  def tmux(socket, args) do
    {out, code} = System.cmd("tmux", ["-S", socket | args], stderr_to_stdout: true)
    assert code == 0, out
    out
  end

  def screen(socket, name), do: tmux(socket, ["capture-pane", "-p", "-t", name])
  def quote_arg(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  def select_row(socket, key, attempts \\ 30) do
    screen = screen(socket, "choices")
    rows = screen |> String.split("\n") |> Enum.filter(&String.contains?(&1, "D-private-"))
    selected = Enum.find_index(rows, &String.starts_with?(String.trim_leading(&1), "›"))
    target = Enum.find_index(rows, &String.contains?(&1, key))
    assert is_integer(selected) and is_integer(target), inspect(rows)

    if selected != target do
      assert attempts > 0, screen
      tmux(socket, ["send-keys", "-t", "choices", if(target > selected, do: "Down", else: "Up")])
      previous = Enum.at(rows, selected)

      await(fn ->
        screen(socket, "choices")
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(String.trim_leading(&1), "›")) != previous
      end)

      select_row(socket, key, attempts - 1)
    end
  end

  def stop_server(server, pid) do
    Process.delete(:choice_proof_server)

    if Port.info(server) do
      {out, code} = System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
      assert code == 0, out

      receive do
        {^server, {:exit_status, status}} -> status
      after
        5_000 -> flunk("owned private Rela did not exit after TERM")
      end
    end
  end
end

try do
  opts = [
    rela: {AtlasFacts.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
    data_dir: Path.join(dir, "facts")
  ]

  {:ok, facts} = AtlasFacts.Server.start_link(opts)
  :ok = AtlasBus.attach("control/session-choice-proof")

  ChoiceProof.await(fn ->
    receive do
      {^server, {:exit_status, code}} ->
        flunk("private Rela exited #{code}: #{File.read!(server_log)}")
    after
      0 -> match?(%{"description" => %{}}, Talk.read("_description", %{}))
    end
  end)

  assert {:ok, served} = AtlasFacts.Rela.Http.description("http://127.0.0.1:#{port}/api/v1")
  assert Map.take(served, ~w(entities relations types)) == Model.AtlasEyra.rela_schema()
  # The bytes Rela served, unchanged, for the served-schema golden.
  schema_url = ~c"http://127.0.0.1:#{port}/api/v1/_schema"

  assert {:ok, {{_, 200, _}, _, raw}} =
           :httpc.request(:get, {schema_url, []}, [], body_format: :binary)

  assert JSON.decode!(raw) == served
  File.write!(Path.join(dir, "served-schema.json"), raw)

  put = fn kind, content -> assert {:stored, _} = Talk.put(kind, content) end

  read = fn key ->
    %{"fact" => fact} = Talk.read("decision", %{"key" => key, "presentation" => true})
    fact
  end

  runs = fn key ->
    mapping = Model.AtlasEyra.run_mapping()
    %{"facts" => all} = Talk.read(mapping["kind"], %{})
    Enum.filter(all, &(get_in(&1, ["values", mapping["fields"]["subject_key"]]) == key))
  end

  for {kind, key} <- [
        {"person", "choice-tester"},
        {"person", "choice-other"},
        {"agent", "coordinator"}
      ] do
    put.(kind, %{"op" => "create", "key" => key, "values" => %{"name" => key}})
  end

  {:ok, gates} = AtlasGates.Endpoint.start_link([])

  {:ok, engine} =
    AtlasFlow.Engine.start_link(model: Model.AtlasEyra, environment: :test, every: 100)

  {:ok, gateway} = AtlasControl.Gateway.start_link(model: Model.AtlasEyra, port: 0)
  control_port = AtlasControl.Gateway.port(gateway)

  text =
    File.read!(Path.join(root, "products/software_factory/e2e/fixtures/decision-options.json"))

  # The model's own single-choice rule: its field names, statuses and wording.
  rule =
    Model.AtlasEyra.__rela__(:description).extension["entities"]["decision"]["decision_options"]

  {:ok, definition} = RelaDSL.DecisionOptions.decode(rule, text)

  # Two imported legacy rules, accepted below before any choice: adopting memory
  # supersedes one, declining leaves the other accepted.
  priors = ~w(D-private-prior-two D-private-prior-three)

  for key <- priors do
    put.("decision", %{
      "op" => "create",
      "key" => key,
      "by" => "migration",
      "values" => %{
        "title" => key,
        "decision" => "Prior private storage rule",
        "status" => "proposed",
        "category" => "product"
      }
    })
  end

  supersedes = %{
    "D-private-two" => ["D-private-prior-two"],
    "D-private-three" => ["D-private-prior-three"]
  }

  for key <- ~w(D-private-zero D-private-one D-private-two D-private-three D-private-stale) do
    put.("decision", %{
      "op" => "create",
      "key" => key,
      "by" => "choice-tester",
      "links" => %{"supersedes" => Map.get(supersedes, key, [])},
      "values" => %{
        "title" => key,
        "decision" => "A private storage question",
        "status" => "proposed",
        "options" => text,
        "category" => "product",
        "scope" => "software",
        "reversibility" => "two_way",
        "force" => "direction"
      }
    })
  end

  # No invented options or selected IDs are added to an imported legacy decision.
  put.("decision", %{
    "op" => "create",
    "key" => "D-private-legacy",
    "by" => "migration",
    "values" => %{
      "title" => "Legacy private question",
      "decision" => "Original legacy rule",
      "status" => "proposed",
      "category" => "product"
    }
  })

  ChoiceProof.await(fn ->
    Enum.all?(
      ~w(D-private-zero D-private-one D-private-two D-private-three D-private-stale D-private-legacy) ++
        priors,
      fn key ->
        case Enum.find(runs.(key), &(&1["values"]["flow"] == "decide")) do
          %{"values" => %{"state" => "for_person", "pending" => pending}} ->
            JSON.decode!(pending)["writes"] == []

          _ ->
            false
        end
      end
    )
  end)

  for key <- priors do
    put.("decision", %{
      "op" => "change",
      "key" => key,
      "by" => "choice-tester",
      "links" => %{"decided_by" => ["choice-tester"]},
      "values" => %{
        "status" => "accepted",
        "decided_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    })

    assert read.(key)["values"]["status"] == "accepted"
  end

  # Showing an offer decides nothing: no decision carries a selection before input.
  for key <-
        ~w(D-private-zero D-private-one D-private-two D-private-three D-private-stale D-private-legacy),
      do: refute(Map.has_key?(read.(key)["values"], "selected_option"))

  # Control connections as a person at a TUI; Control fixes the actor at hello.
  connect_as = fn user ->
    previous = Application.get_env(:atlas_control, :tui_user)
    Application.put_env(:atlas_control, :tui_user, user)

    try do
      control = %{"control" => %{"host" => "127.0.0.1", "port" => control_port}}
      assert {:ok, client} = AtlasAgent.Client.connect("test", control, "tui")
      client
    after
      Application.put_env(:atlas_control, :tui_user, previous)
    end
  end

  # The page Control serves for a decision, and the call it binds to each answer key; an
  # answer given with a note (decline) binds its key to the form that asks for the note.
  offer = fn client, key ->
    assert {:ok, page} = AtlasAgent.Client.open(client, "/k/decision/" <> key)

    # What each option's own answer does, on its key; `0` is the recommended one's again
    # (Control binds it for a Console client, `Model.DecisionOptionsTest`).
    calls =
      page
      |> AtlasAgent.Client.blocks("option")
      |> Enum.flat_map(fn option ->
        bound =
          case option["answer"] do
            %{"submit_to" => %{} = call} -> call
            %{"to" => to} -> %{"note_form" => to}
          end

        keys = [option["answer"]["key"] | if(option["tone"] == "success", do: ["0"], else: [])]
        for shortcut <- keys, do: {shortcut, bound}
      end)
      |> Map.new()

    {page, calls}
  end

  note = "Neither storage rule fits this private example."
  decline? = fn number -> number == "3" end

  # The offer once Control serves its answer calls; any page served without them is kept.
  served = fn client, key ->
    ChoiceProof.await(fn ->
      {page, calls} = offer.(client, key)

      if Map.has_key?(calls, "1") do
        {page, calls}
      else
        File.write!(
          Path.join(dir, key <> ".no-calls.txt"),
          inspect(page, limit: :infinity, printable_limit: :infinity)
        )

        Process.sleep(200)
        false
      end
    end)
  end

  tester = connect_as.("choice-tester")
  {offer_page, calls} = served.(tester, "D-private-zero")

  File.write!(
    Path.join(dir, "control-offer-page.txt"),
    inspect(offer_page, limit: :infinity, printable_limit: :infinity)
  )

  File.write!(Path.join(dir, "control-offer-calls.json"), JSON.encode!(calls))

  # Every offered option, in order and word for word, the recommendation first with its
  # rationale; 0 is the same call as 1, and 1/2/3 are three different calls.
  options = AtlasAgent.Client.blocks(offer_page, "option")
  assert length(options) == length(definition["options"])
  assert [%{"title" => question}] = AtlasAgent.Client.blocks(offer_page, "header")
  assert question == definition["question"]

  assert Enum.any?(
           AtlasAgent.Client.blocks(offer_page, "text"),
           &(&1["text"] == definition["rationale"])
         )

  # Every option shows what it means: its rule and consequences, a decline its details.
  for {shown, offered} <- Enum.zip(options, definition["options"]) do
    assert shown["text"] == offered["text"]

    assert shown["fields"] ==
             if(offered["effect"] == "decline",
               do: [%{"label" => "Details", "value" => offered["details"]}],
               else: [
                 %{"label" => "Rule", "value" => offered["rule"]},
                 %{"label" => "Consequences", "value" => offered["consequences"]}
               ]
             )
  end

  assert hd(definition["options"])["id"] == definition["recommended"]
  assert hd(options)["badge"] == "★ Recommended"
  assert calls["0"] == calls["1"]
  assert length(Enum.uniq([calls["1"], calls["2"], calls["3"]])) == 3
  refute Map.has_key?(calls, "9") or Map.has_key?(calls, "4")

  # Each option's own answer is what its key does; declining, as the a/f Reject, is given
  # with a note: its key opens the note form.
  for {o, n} <- Enum.with_index(options, 1),
      do: assert(o["answer"]["key"] == Integer.to_string(n))

  assert Enum.map(options, &(&1["answer"]["note"] == true)) == [false, false, true]
  assert decline?.("3") and List.last(definition["options"])["effect"] == "decline"
  assert calls["3"] == %{"note_form" => List.last(options)["answer"]["to"]}

  settings = Path.join(dir, "settings.json")

  if input == "terminal" do
    File.write!(
      settings,
      JSON.encode!(%{
        "env" => "test",
        "escape_ms" => 250,
        "control" => %{"host" => "127.0.0.1", "port" => control_port}
      })
    )

    # Run the actual terminal application, with the same compiled contract and client.
    elixir =
      :code.lib_dir(:elixir) |> to_string() |> Path.join("../../bin/elixir") |> Path.expand()

    paths =
      :code.get_path() |> Enum.map(&to_string/1) |> Enum.filter(&String.contains?(&1, "/lib/"))

    runner = Path.join(dir, "terminal.exs")
    File.write!(runner, "AtlasTui.CLI.main([\"--env\", \"test\"])\n")

    command =
      Enum.map_join(
        [
          "env",
          "ATLAS_ENV_FILE=" <> settings,
          "TMPDIR=" <> dir,
          "ERL_ROOTDIR=" <> System.fetch_env!("ERL_ROOTDIR"),
          "/bin/sh",
          "-P",
          elixir,
          "-pa",
          client_beams
        ] ++ Enum.flat_map(paths, &["-pa", &1]) ++ [runner],
        " ",
        &ChoiceProof.quote_arg/1
      )

    # As `bin/atlas tui` does: Ctrl+S saves a form, and with flow control on the terminal
    # takes it as XOFF ("pause output"), so the TUI would never receive it.
    command = "stty -ixon && exec " <> command

    ChoiceProof.tmux(tmux_socket, [
      "new-session",
      "-d",
      "-s",
      "choices",
      "-x",
      "140",
      "-y",
      "55",
      command
    ])

    ChoiceProof.await(fn ->
      String.contains?(ChoiceProof.screen(tmux_socket, "choices"), "D-private-zero")
    end)

    # The pane's terminal passes Ctrl+S through to the TUI.
    tty =
      ChoiceProof.tmux(tmux_socket, ["display-message", "-p", "-t", "choices", "\#{pane_tty}"])
      |> String.trim()

    {modes, 0} = System.cmd("/bin/sh", ["-c", "stty -a < " <> ChoiceProof.quote_arg(tty)])
    assert modes =~ ~r/(^|\s)-ixon(\s|$)/, "flow control is on in the TUI's terminal: " <> modes
  end

  # Navigate through the real terminal's assigned list; find the exact displayed row.
  open = fn
    _key when input == "control" ->
      :ok

    key ->
      ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", "Escape"])

      ChoiceProof.await(fn ->
        String.contains?(ChoiceProof.screen(tmux_socket, "choices"), "│ Assigned to you ·")
      end)

      ChoiceProof.select_row(tmux_socket, key)

      ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", "Enter"])

      ChoiceProof.await(fn ->
        screen = ChoiceProof.screen(tmux_socket, "choices")

        String.contains?(screen, "YOUR DECISION") and
          String.contains?(screen, key)
      end)
  end

  # Invalid input and showing a recommendation never decide anything.
  # Control mode submits exactly what Control binds to the key on the page it serves now.
  press = fn
    key, number when input == "control" ->
      {page, now} = served.(tester, key)

      case now[number] do
        %{"note_form" => to} ->
          # Without a note the semantic decline call itself is refused, as Reject's is.
          assert List.last(AtlasAgent.Client.blocks(page, "option"))["answer"]["to"] == to
          assert {:ok, form_page} = AtlasAgent.Client.open(tester, to)

          assert [%{"submit_to" => call, "inputs" => [%{"name" => "note"}]}] =
                   AtlasAgent.Client.blocks(form_page, "form")

          assert {:refused, without} = AtlasAgent.Client.submit(tester, call, %{})

          File.write!(
            Path.join(dir, key <> ".call.json"),
            JSON.encode!(%{key: number, form: to, call: call, without_note_refused: without})
          )

          assert {:stored, _} = AtlasAgent.Client.submit(tester, call, %{"note" => note})

        %{} = call ->
          File.write!(
            Path.join(dir, key <> ".call.json"),
            JSON.encode!(%{key: number, call: call})
          )

          assert {:stored, _} = AtlasAgent.Client.submit(tester, call, %{})
      end

    _key, number ->
      ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", number])

      if decline?.(number) do
        # The note form opens; type why, then save it with Ctrl+S.
        ChoiceProof.await(fn ->
          String.contains?(ChoiceProof.screen(tmux_socket, "choices"), "Note")
        end)

        ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", "-l", note])

        ChoiceProof.await(fn ->
          String.contains?(ChoiceProof.screen(tmux_socket, "choices"), note)
        end)

        ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", "C-s"])
      end
  end

  open.("D-private-zero")
  before = read.("D-private-zero")

  if input == "terminal" do
    screen = ChoiceProof.screen(tmux_socket, "choices")
    assert String.contains?(screen, "1 Use files")
    assert String.contains?(screen, definition["rationale"])
    File.write!(Path.join(dir, "offered-terminal.txt"), screen)
    ChoiceProof.tmux(tmux_socket, ["send-keys", "-t", "choices", "9", "4"])
  else
    # 9 and 4 have no projected call, so there is nothing a client could submit.
    {_, now} = offer.(tester, "D-private-zero")
    refute Map.has_key?(now, "9") or Map.has_key?(now, "4")
  end

  Process.sleep(300)
  assert read.("D-private-zero")["values"] == before["values"]

  for {key, number, id} <- [
        {"D-private-zero", "0", "files"},
        {"D-private-one", "1", "files"},
        {"D-private-two", "2", "memory"},
        {"D-private-three", "3", "decline"}
      ] do
    if key != "D-private-zero", do: open.(key)
    press.(key, number)

    fact =
      ChoiceProof.await(fn ->
        fact = read.(key)
        if fact["values"]["selected_option"] == id, do: fact, else: false
      end)

    assert fact["values"]["selected_definition"] == text
    assert fact["links"]["decided_by"] == ["choice-tester"]
    assert is_binary(fact["values"]["decided_at"])
    assert fact["values"]["status"] == if(id == "decline", do: "rejected", else: "accepted")
    option = Enum.find(definition["options"], &(&1["id"] == id))

    if option["effect"] == "adopt" do
      assert fact["values"]["decision"] == option["rule"]
      assert fact["values"]["consequences"] == option["consequences"]
    else
      assert fact["values"]["decision"] == "A private storage question"
    end

    File.write!(Path.join(dir, key <> ".json"), JSON.encode!(fact))

    settled_runs =
      ChoiceProof.await(fn ->
        all = runs.(key)
        decided = Enum.find(all, &(&1["values"]["flow"] == "decide"))
        follow = Enum.find(all, &(&1["values"]["flow"] == "follow_through"))

        if (decided && decided["values"]["status"] == "completed") and
             decided["values"]["state"] == fact["values"]["status"] and
             (id == "decline" or follow != nil),
           do: all,
           else: false
      end)

    follow = Enum.find(settled_runs, &(&1["values"]["flow"] == "follow_through"))

    if id == "decline",
      do: assert(follow == nil),
      else: assert(follow["values"]["state"] == "waiting")

    File.write!(Path.join(dir, key <> ".runs.json"), JSON.encode!(settled_runs))

    # Only adoption supersedes: the linked prior rule follows the selected effect.
    for prior <- Map.get(supersedes, key, []) do
      status = read.(prior)["values"]["status"]
      assert status == if(option["effect"] == "adopt", do: "superseded", else: "accepted")
      File.write!(Path.join(dir, prior <> ".json"), JSON.encode!(read.(prior)))
    end

    if input == "terminal" do
      ChoiceProof.await(fn ->
        not String.contains?(
          ChoiceProof.screen(tmux_socket, "choices"),
          "YOUR DECISION"
        )
      end)
    end
  end

  # Capture an old semantic action, then change its offer. Its old revision cannot
  # select an option under the new wording/order, through Control or direct Facts.
  stale = read.("D-private-stale")
  old_name = RelaDSL.DecisionOptions.name(rule, text, "files", stale)
  changed_text = String.replace(text, "Use files", "Use local files")
  {_, stale_calls} = served.(tester, "D-private-stale")

  put.("decision", %{
    "op" => "change",
    "key" => "D-private-stale",
    "by" => "choice-tester",
    "values" => %{"options" => changed_text}
  })

  # The call Control served for the old offer is refused through Control itself.
  assert {:refused, stale_reasons} = AtlasAgent.Client.submit(tester, stale_calls["1"], %{})
  refute Map.has_key?(read.("D-private-stale")["values"], "selected_option")

  # Another person submitting the current call, through Control, is refused too.
  {_, current_calls} = served.(tester, "D-private-stale")
  assert current_calls["1"] != stale_calls["1"]
  other = connect_as.("choice-other")
  {_, other_calls} = offer.(other, "D-private-stale")
  assert {:refused, other_reasons} = AtlasAgent.Client.submit(other, current_calls["1"], %{})
  AtlasAgent.Client.close(other)
  refute Map.has_key?(read.("D-private-stale")["values"], "selected_option")

  File.write!(
    Path.join(dir, "control-refusals.json"),
    JSON.encode!(%{
      stale_call: stale_calls["1"],
      stale_refused: stale_reasons,
      current_call: current_calls["1"],
      other_offered_keys: Map.keys(other_calls),
      other_refused: other_reasons
    })
  )

  values =
    RelaDSL.DecisionOptions.values(
      rule,
      text,
      hd(definition["options"]),
      stale
    )
    |> Map.put("decided_at", DateTime.to_iso8601(DateTime.utc_now()))

  assert {:refused, _} =
           Talk.put("decision", %{
             "op" => "change",
             "key" => "D-private-stale",
             "by" => "choice-tester",
             "values" => values
           })

  assignment = fn key ->
    %{"fact" => fact} =
      Talk.read("assignment", %{"key" => "AS-" <> key, "presentation" => true})

    %{"assignment" => fact}
  end

  assert {:refuse, _} =
           Model.AtlasEyra.answer(
             "decision",
             old_name,
             %{"fact" => read.("D-private-stale"), "parts" => assignment.("D-private-stale")},
             %{key: "choice-tester", kind: "person"}
           )

  assert {:refuse, _} =
           Model.AtlasEyra.answer(
             "decision",
             RelaDSL.DecisionOptions.name(rule, changed_text, "files", read.("D-private-stale")),
             %{"fact" => read.("D-private-stale"), "parts" => assignment.("D-private-stale")},
             %{key: "choice-other", kind: "person"}
           )

  assert stale["values"]["options"] == text

  assert {:refused, _} =
           Talk.put("decision", %{
             "op" => "change",
             "key" => "D-private-stale",
             "by" => "coordinator",
             "values" => Map.put(values, "selected_definition", changed_text)
           })

  # Existing accepted-record maintenance preserves every offered word and selected ID.
  put.("decision", %{
    "op" => "change",
    "key" => "D-private-zero",
    "by" => "choice-tester",
    "values" => %{"no_work" => true}
  })

  legacy = read.("D-private-legacy")
  refute Map.has_key?(legacy["values"], "options")

  put.("decision", %{
    "op" => "change",
    "key" => "D-private-legacy",
    "by" => "choice-tester",
    # As the existing a/f answer does: the decider names themself in the same change.
    "links" => %{"decided_by" => ["choice-tester"]},
    "values" => %{"status" => "accepted", "decided_at" => DateTime.to_iso8601(DateTime.utc_now())}
  })

  legacy = read.("D-private-legacy")
  assert legacy["values"]["decision"] == "Original legacy rule"
  assert legacy["values"]["status"] == "accepted"
  refute Map.has_key?(legacy["values"], "selected_option")
  refute Map.has_key?(legacy["values"], "options")

  # Restart both owned native Rela and Facts, retaining the same filesystem data.
  AtlasAgent.Client.close(tester)
  GenServer.stop(gateway)
  GenServer.stop(engine)
  GenServer.stop(gates)
  GenServer.stop(facts)
  initial_exit = ChoiceProof.stop_server(server, server_pid)
  reloaded_log = Path.join(dir, "rela-server-reloaded.log")

  reload_command =
    String.replace(server_command, shell_quote.(server_log), shell_quote.(reloaded_log))

  reload_server =
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      args: ["-c", reload_command]
    ])

  {:os_pid, reload_pid} = Port.info(reload_server, :os_pid)
  assert reload_pid != server_pid
  Process.put(:choice_proof_server, {reload_server, reload_pid})

  File.write!(
    Path.join(dir, "rela-reload.json"),
    JSON.encode!(%{before_pid: server_pid, before_exit: initial_exit, after_pid: reload_pid})
  )

  {:ok, reloaded} = AtlasFacts.Server.start_link(opts)
  ChoiceProof.await(fn -> match?(%{"description" => %{}}, Talk.read("_description", %{})) end)

  for {key, id} <- [
        {"D-private-zero", "files"},
        {"D-private-one", "files"},
        {"D-private-two", "memory"},
        {"D-private-three", "decline"}
      ] do
    fact = read.(key)
    assert fact["values"]["selected_option"] == id
    assert fact["values"]["selected_definition"] == text
    stored = Path.join(dir, key <> ".json") |> File.read!() |> JSON.decode!()
    assert fact["values"]["selected_revision"] == stored["values"]["selected_revision"]
    assert fact["values"]["decided_at"] == stored["values"]["decided_at"]
    history = JSON.decode!(fact["values"]["option_history"])

    assert Enum.any?(
             history,
             &(&1["revision"] == fact["values"]["selected_revision"] and &1["definition"] == text)
           )

    assert {:ok, ^definition} =
             RelaDSL.DecisionOptions.decode(rule, fact["values"]["selected_definition"])

    assert fact["links"]["decided_by"] == ["choice-tester"]
    File.write!(Path.join(dir, key <> ".reloaded.json"), JSON.encode!(fact))
  end

  reloaded_legacy = read.("D-private-legacy")
  assert Map.take(reloaded_legacy["values"], Map.keys(legacy["values"])) == legacy["values"]
  refute Map.has_key?(reloaded_legacy["values"], "options")
  refute Map.has_key?(reloaded_legacy["values"], "selected_option")
  File.write!(Path.join(dir, "D-private-legacy.reloaded.json"), JSON.encode!(reloaded_legacy))

  assert [prior | _] = JSON.decode!(read.("D-private-stale")["values"]["option_history"])
  assert prior["definition"] == text
  assert prior["revision"] == RelaDSL.DecisionOptions.revision(rule, text, stale)

  GenServer.stop(reloaded)

  if input == "terminal" do
    IO.puts(
      "PASS private terminal 0/1/2/3, invalid input, typed choice, stale/unauthorized refusal, legacy, persisted complete offers and reload"
    )
  else
    IO.puts(
      "PARTIAL control-projected 0/1/2/3 calls, typed choice, stale/unauthorized refusal, legacy, persisted complete offers and reload; no real terminal input"
    )
  end
after
  tmux_result =
    if input == "terminal" do
      {last_screen, _} =
        System.cmd("tmux", ["-S", tmux_socket, "capture-pane", "-p", "-t", "choices"],
          stderr_to_stdout: true
        )

      File.write!(Path.join(dir, "last-terminal.txt"), last_screen)
      System.cmd("tmux", ["-S", tmux_socket, "kill-server"], stderr_to_stdout: true)
    else
      :no_terminal
    end

  rela_exit =
    case Process.get(:choice_proof_server) do
      {owned, pid} -> ChoiceProof.stop_server(owned, pid)
      nil -> :already_stopped
    end

  File.write!(Path.join(dir, "teardown.txt"), inspect(%{tmux: tmux_result, rela_exit: rela_exit}))
end
