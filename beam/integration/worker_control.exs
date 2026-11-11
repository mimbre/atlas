# MIX_ENV=test mix run integration/worker_control.exs (needs Go on PATH)
# Real Control sockets, Bus, Facts and private durable synthetic storage; no harness.
ExUnit.start(seed: 0)

# Native turns run in the Go host of the launching CLI, named by ATLAS_RUNTIME_EXECUTABLE.
# Build that CLI from this tree, as the Runtime tests do: never an inherited binary.
folder =
  Path.join(
    System.tmp_dir!(),
    "atlas-worker-control-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.mkdir!(folder)
ExUnit.after_suite(fn _ -> File.rm_rf!(folder) end)
executable = Path.join(folder, "atlas-runtime")

case System.cmd("go", ["-C", "tools/runtime", "build", "-o", executable, "."],
       cd: Path.expand("../..", __DIR__),
       stderr_to_stdout: true
     ) do
  {_, 0} -> System.put_env("ATLAS_RUNTIME_EXECUTABLE", executable)
  {output, _} -> raise("Building the Runtime CLI failed:\n#{output}")
end

defmodule WorkerControlTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.{GuidanceStore, Rela}
  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  @moduletag :tmp_dir

  defp description do
    roles = %{
      "execution" =>
        ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position),
      "interaction" =>
        ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position),
      "receipt" =>
        ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)
    }

    mapping =
      Map.new(roles, fn {role, fields} ->
        {role, %{"kind" => "synthetic_" <> role, "fields" => Map.new(fields, &{&1, &1})}}
      end)

    ordinary = %{
      "reader" => {"readers", "H-", ~w(name)},
      "operator" => {"operators", "W-", ~w(name)},
      "run" => {"runs", "R-", ~w(host fence state activity lease outcome why ended_at)},
      "ticket" => {"tickets", "T-", ~w(title step handover)}
    }

    entities =
      Map.new(ordinary, fn {kind, {plural, prefix, fields}} ->
        {kind,
         %{
           "plural" => plural,
           "id_prefix" => prefix,
           "properties" => Map.new(fields, &{&1, %{"type" => "string"}})
         }}
      end)

    entities =
      Enum.reduce(mapping, entities, fn {role, spec}, acc ->
        properties =
          Map.new(spec["fields"], fn {slot, field} ->
            type =
              cond do
                slot in ~w(queued_input durable_accept_query consumption_evidence) -> "boolean"
                slot == "recorded_position" -> "integer"
                true -> "string"
              end

            {field, %{"type" => type}}
          end)

        Map.put(acc, spec["kind"], %{
          "plural" => role <> "s",
          "properties" => properties,
          "top" => false,
          "by_hand" => false
        })
      end)

    %{
      "entities" => entities,
      "shell" => %{
        "title" => "Private workers",
        "tabs" => [%{"id" => "workers", "label" => "Workers", "to" => "/workers"}]
      },
      "relations" => %{
        "performer" => %{"from" => ["run"], "to" => ["operator"]},
        "task" => %{"from" => ["run"], "to" => ["ticket"]},
        "owner" => %{"from" => ["ticket"], "to" => ["operator"]}
      },
      "guidance" =>
        Map.put(mapping, "control", %{
          "read" => %{"actors" => ["H-1", "H-2"]},
          "submit" => %{"actors" => ["H-1"]}
        }),
      "runtime" => %{
        "turn" => %{
          "kind" => "run",
          "machine" => "host",
          "attempt" => "fence",
          "by" => "performer",
          "on" => "task",
          "state" => "state",
          "running" => "running",
          "ended" => "ended",
          "lease" => "lease",
          "activity" => "activity",
          "why" => "why",
          "outcome" => "outcome"
        }
      },
      "flows" => %{
        "work" => %{
          "kinds" => ["ticket"],
          "state_field" => "step",
          "handover_field" => "handover",
          "owner_relation" => "owner",
          "field" => "title",
          "states" => [%{"name" => "work", "owner" => "W-1", "expected" => "work"}]
        }
      }
    }
  end

  setup %{tmp_dir: dir} = context do
    previous_store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :store, "worker-proof-#{System.unique_integer([:positive])}")
    {:ok, backend} = GuidanceStore.start(Path.join(dir, "facts.json"), description())
    rela = {GuidanceStore, backend}

    for actor <- ["H-1", "H-2", "H-3"] do
      {:ok, []} = Rela.create(rela, "readers", actor, %{"name" => actor}, %{})
    end

    {:ok, []} = Rela.create(rela, "operators", "W-1", %{"name" => "Worker"}, %{})

    {:ok, []} =
      Rela.create(rela, "tickets", "T-1", %{"title" => "Private task", "step" => "work"}, %{
        "owner" => {"operator", ["W-1"]}
      })

    {:ok, []} =
      Rela.create(
        rela,
        "runs",
        "R-1",
        %{
          "host" => "box",
          "fence" => "attempt-1",
          "state" => "running",
          "activity" => "private synthetic activity",
          "lease" => DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
        },
        %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
      )

    start_supervised!({AtlasFacts.Server, rela: rela, data_dir: dir})

    {:stored, %{"fact" => execution}} =
      bus("runtime@box", "synthetic_execution", %{
        "op" => "register_execution",
        "values" => %{
          "worker" => "W-1",
          "turn" => "R-1",
          "attempt" => "attempt-1",
          "machine" => "box",
          "harness" => "private-fake",
          "harness_version" => "1",
          "configured_model" => "synthetic",
          "capability_version" => "1",
          "queued_input" => context[:unsupported] != true,
          "durable_accept_query" => true,
          "consumption_evidence" => true
        }
      })

    start_supervised!({AtlasControl.Gateway, port: 0, name: :worker_proof_gateway})
    port = AtlasControl.Gateway.port(:worker_proof_gateway)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      Application.put_env(:atlas_bus, :store, previous_store)
    end)

    %{rela: rela, backend: backend, execution: execution, port: port}
  end

  defp target,
    do: %{
      "worker" => %{"environment" => "test", "machine" => "box", "worker" => "W-1"},
      "turn" => "R-1",
      "attempt" => "attempt-1"
    }

  defp guidance(key \\ "same-key"),
    do: %{
      "client_key" => key,
      "body" => "/stop is literal guidance, not a machine control",
      "cause" => "private proof"
    }

  defp bus(endpoint, kind, content) do
    Task.async(fn ->
      :ok = AtlasBus.attach(endpoint)

      try do
        envelope = Envelope.new("fact", kind)
        :ok = AtlasBus.send(envelope, content)

        receive do
          {:atlas_bus, %Envelope{id: id, class: class}, answer} when id == envelope.id ->
            {String.to_existing_atom(class), answer}
        after
          2000 -> flunk("Facts did not reply")
        end
      after
        Registry.unregister(AtlasBus.Endpoints, endpoint)
      end
    end)
    |> Task.await()
  end

  defp connect(port, actor \\ "H-1", surface \\ nil) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    send_message(socket, %{
      "op" => "hello",
      "env" => "test",
      "client" => "private-proof",
      "as" => actor,
      "spec" => AtlasControl.Blocks.version(),
      "surface" => surface
    })

    assert %{"op" => "welcome"} = next(socket, &(&1["op"] == "welcome"))
    next(socket, &(&1["op"] == "page"))
    socket
  end

  defp send_message(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp next(socket, predicate) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, line} ->
        message = JSON.decode!(line)
        if predicate.(message), do: message, else: next(socket, predicate)

      other ->
        flunk("Control socket failed: #{inspect(other)}")
    end
  end

  defp request(socket, operation, props \\ %{}) do
    id = "request-#{System.unique_integer([:positive])}"
    send_message(socket, Wire.request(operation, Map.put(props, "id", id)))
    reply = next(socket, &(&1["id"] == id))
    assert {:ok, variant, ^reply} = Wire.decode_reply(operation, reply)
    {variant, reply}
  end

  test "native adapter output traverses Control with independent replay and explicit gaps", c do
    alias AtlasRuntime.{Turn, Output, OutputEndpoint}
    command = Path.join(c.tmp_dir, "native-output-fixture")

    File.write!(command, ~S"""
    #!/bin/sh
    root=$(dirname "$0")
    emit() { printf '{"type":"item.completed","item":%s}\n' "$1"; }
    wait_for() {
      tries=0
      until [ -e "$root/$1" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 2000 ]; then
          echo "fixture gate timed out: $1" >&2
          exit 1
        fi
        sleep 0.01
      done
    }
    emit '{"type":"reasoning","text":"PRIVATE_REASONING"}'
    emit '{"type":"command_execution","command":"PRIVATE_COMMAND","aggregated_output":"PRIVATE_RESULT"}'
    emit '{"type":"agent_message","text":"first 界"}'
    batch=0
    while [ "$batch" -lt 11 ]; do
      wait_for "batch-$batch"
      n=$((batch * 100))
      while [ "$n" -lt $(((batch + 1) * 100)) ]; do
        emit "{\"type\":\"agent_message\",\"text\":\"event-$n\"}"
        n=$((n + 1))
      done
      batch=$((batch + 1))
    done
    wait_for epoch
    emit '{"type":"agent_message","text":"after epoch 界"}'
    wait_for finish
    emit '{"type":"agent_message","text":"final 界"}'
    printf '%s\n' '{"type":"turn.completed"}'
    """)

    File.chmod!(command, 0o700)
    start_supervised!({OutputEndpoint, machine: "box"})

    names = %{
      state: "state",
      running: "running",
      ended: "ended",
      machine: "host",
      attempt: "fence",
      lease: "lease",
      activity: "activity",
      why: "why",
      ended_at: "ended_at",
      on: "task",
      by: "performer",
      outcome: "outcome"
    }

    turn =
      start_supervised!(
        Supervisor.child_spec(
          {Turn,
           %{
             key: "R-native",
             item: "T-1",
             kind: "ticket",
             agent: "W-1",
             machine: "box",
             turn_kind: "run",
             names: names,
             cause: "private native output proof",
             port: AtlasRuntime.Agent.Native,
             port_opts: [
               turns_dir: Path.join(c.tmp_dir, "native-turns"),
               agent: %{
                 "command" => command,
                 "workspace" => c.tmp_dir,
                 "goal" => "deterministic proof"
               }
             ],
             silence: 60_000,
             max: 120_000,
             lease: 60_000,
             leave_grace: 0,
             guidance_every: :manual,
             ownership: %{"owner_relation" => "owner"},
             description: description()
           }},
          restart: :temporary
        )
      )

    adapter = Turn.agent(turn)
    assert is_pid(adapter)
    target = :sys.get_state(turn).output_execution
    assert target["turn"] == "R-native"
    assert target["attempt"] != ""
    a = connect(c.port)
    b = connect(c.port, "H-2")
    on_exit(fn -> Enum.each([a, b], &:gen_tcp.close/1) end)
    assert {:result, first} = request(a, :worker_output_subscribe, %{"execution" => target})
    assert {:result, second} = request(b, :worker_output_subscribe, %{"execution" => target})

    {fast, events} =
      output_until(a, first, &Enum.any?(&1["events"], fn e -> e["text"] == "first 界" end))

    {slow, duplicate} =
      output_until(b, second, &Enum.any?(&1["events"], fn e -> e["text"] == "first 界" end))

    assert events == duplicate
    refute JSON.encode!(events) =~ "PRIVATE_"
    assert Enum.any?(events, &(&1["kind"] == "tool"))

    fast =
      Enum.reduce(0..10, fast, fn batch, cursor ->
        File.write!(Path.join(c.tmp_dir, "batch-#{batch}"), "")
        last = "event-#{(batch + 1) * 100 - 1}"

        {next, events} =
          output_until(a, cursor, &Enum.any?(&1["events"], fn e -> e["text"] == last end))

        assert Enum.map(events, & &1["text"]) ==
                 Enum.map((batch * 100)..((batch + 1) * 100 - 1), &"event-#{&1}")

        refute Map.has_key?(next, "reset")
        next
      end)

    assert Process.alive?(adapter)

    assert {:result, lagged} =
             request(b, :worker_output_next, Map.take(slow, ~w(subscription cursor)))

    assert lagged["reset"]["reason"] == "retention_gap"
    assert lagged["view"]["execution"] == target
    assert lagged["reset"]["to_sequence"] >= lagged["reset"]["from_sequence"]
    :gen_tcp.close(a)
    reconnect = connect(c.port)
    on_exit(fn -> :gen_tcp.close(reconnect) end)

    assert {:result, resumed} =
             request(reconnect, :worker_output_subscribe, %{
               "execution" => target,
               "cursor" => fast["cursor"]
             })

    assert {:result, empty} =
             request(reconnect, :worker_output_next, Map.take(resumed, ~w(subscription cursor)))

    assert empty["events"] == []
    assert empty["stream"]["execution"] == target
    # Only this private VM's ephemeral store restarts; the real producer stays alive.
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, Output)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, Output)
    File.write!(Path.join(c.tmp_dir, "epoch"), "")

    # The producer reopens the ring before appending, so the reset may arrive
    # before the event that caused it: assert the first reply, then drain.
    {reset, epoch_events} = output_until(reconnect, empty, &Map.has_key?(&1, "reset"))
    assert reset["reset"] == %{"reason" => "epoch_changed"}
    assert reset["view"]["execution"] == target
    refute reset["stream"]["epoch"] == empty["stream"]["epoch"]

    after_epoch? = &Enum.any?(&1["events"], fn e -> e["text"] == "after epoch 界" end)

    {current, after_epoch} =
      if after_epoch?.(reset),
        do: {reset, epoch_events},
        else: output_until(reconnect, reset, after_epoch?, 300, epoch_events)

    assert Enum.map(after_epoch, & &1["text"]) == ["after epoch 界"]
    turn_ref = Process.monitor(turn)
    adapter_ref = Process.monitor(adapter)
    File.write!(Path.join(c.tmp_dir, "finish"), "")
    {ended, final} = output_until(reconnect, current, & &1["stream"]["ended"])
    assert Enum.any?(final, &(&1["text"] == "final 界"))
    assert_receive {:DOWN, ^turn_ref, :process, ^turn, :normal}, 5_000
    assert_receive {:DOWN, ^adapter_ref, :process, ^adapter, :normal}, 5_000

    assert {:result, _} =
             request(b, :worker_output_unsubscribe, Map.take(second, ["subscription"]))

    assert {:result, retained} = request(b, :worker_output_subscribe, %{"execution" => target})

    assert {:result, replay} =
             request(b, :worker_output_next, Map.take(retained, ~w(subscription cursor)))

    assert replay["stream"]["ended"]

    assert Enum.map(replay["events"], & &1["text"]) == [
             "after epoch 界",
             "final 界",
             "codex: turn completed"
           ]

    assert ended["stream"]["execution"] == target
    refute JSON.encode!(replay) =~ "PRIVATE_"

    IO.puts(
      "SMOKE real Codex subprocess/Turn -> Runtime -> addressed Bus -> Control: Unicode/filtering, two viewers, slow-viewer gap, cursor reconnect, epoch reset and retained closure replay passed"
    )
  end

  defp output_until(socket, cursor, ready, remaining \\ 300, events \\ [])

  defp output_until(_socket, _cursor, _ready, 0, _events),
    do: flunk("native output did not settle")

  defp output_until(socket, cursor, ready, remaining, events) do
    case request(socket, :worker_output_next, Map.take(cursor, ~w(subscription cursor))) do
      {:result, next} ->
        events = events ++ next["events"]

        if ready.(next) do
          {next, events}
        else
          Process.sleep(10)
          output_until(socket, next, ready, remaining - 1, events)
        end

      {:error, %{"error" => %{"code" => "output_unavailable"}}} ->
        Process.sleep(10)
        output_until(socket, cursor, ready, remaining - 1, events)

      other ->
        flunk("unexpected output response: #{inspect(other)}")
    end
  end

  test "real output delivery isolates viewers and preserves retention gaps and authority", c do
    output = start_supervised!({AtlasRuntime.Output, name: nil, max_events: 2})
    start_supervised!({AtlasRuntime.OutputEndpoint, machine: "box", output: output})
    assert :ok = AtlasRuntime.Output.open(target(), self(), output)

    assert :ok =
             AtlasRuntime.Output.append(target(), %{"kind" => "text", "text" => "one"}, output)

    a = connect(c.port)
    b = connect(c.port, "H-2")
    denied = connect(c.port, "H-3")
    console = connect(c.port, "H-1", "console")
    on_exit(fn -> Enum.each([a, b, denied, console], &:gen_tcp.close/1) end)
    send_message(console, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1"})
    page = next(console, &(&1["op"] == "page"))
    assert {:ok, projection} = AtlasBFFContract.Console.compile(page)
    actions = Enum.map(projection.actions, & &1["props"])
    output_action = Enum.find(actions, &(&1["operation"]["name"] == "worker_output_subscribe"))
    assert output_action["available"]
    assert output_action["operation"]["execution"] == target()
    receipt_action = Enum.find(actions, &(&1["operation"]["name"] == "worker_receipts"))
    assert receipt_action["scope"]["on"] == "guidance-history"
    assert receipt_action["operation"]["interaction_source"] == "selected_history"
    assert receipt_action["operation"]["execution"] == target()
    assert {:result, first} = request(a, :worker_output_subscribe, %{"execution" => target()})
    assert {:result, second} = request(b, :worker_output_subscribe, %{"execution" => target()})
    refute first["subscription"] == second["subscription"]
    assert first["view"]["output"]["available"]

    assert {:error, forbidden} =
             request(denied, :worker_output_subscribe, %{"execution" => target()})

    assert forbidden["error"]["code"] == "forbidden"
    refute Map.has_key?(forbidden, "view")

    assert {:error, wrong_owner} =
             request(b, :worker_output_next, Map.take(first, ~w(subscription cursor)))

    assert wrong_owner["error"]["code"] == "invalid_subscription"

    assert {:result, initial} =
             request(a, :worker_output_next, Map.take(first, ~w(subscription cursor)))

    assert Enum.map(initial["events"], & &1["text"]) == ["one"]

    for text <- ["two", "three", "four"] do
      assert :ok =
               AtlasRuntime.Output.append(target(), %{"kind" => "text", "text" => text}, output)
    end

    assert {:result, slow} =
             request(b, :worker_output_next, Map.take(second, ~w(subscription cursor)))

    assert slow["reset"] == %{
             "reason" => "retention_gap",
             "from_sequence" => 1,
             "to_sequence" => 2
           }

    assert slow["view"]["execution"] == target()
    assert Enum.map(slow["events"], & &1["text"]) == ["three", "four"]

    assert {:result, fast} =
             request(a, :worker_output_next, Map.take(initial, ~w(subscription cursor)))

    assert fast["reset"]["from_sequence"] == 2
    assert fast["reset"]["to_sequence"] == 2
    assert fast["stream"]["execution"] == target()

    assert {:result, _} =
             request(a, :worker_output_unsubscribe, Map.take(first, ["subscription"]))

    assert {:result, _} =
             request(a, :worker_output_unsubscribe, Map.take(first, ["subscription"]))

    assert :ok =
             AtlasRuntime.Output.append(
               target(),
               %{"kind" => "text", "text" => "still running"},
               output
             )

    assert Process.alive?(output)

    assert {:result, resumed} =
             request(a, :worker_output_subscribe, %{
               "execution" => target(),
               "cursor" => fast["cursor"]
             })

    assert {:result, tail} =
             request(a, :worker_output_next, Map.take(resumed, ~w(subscription cursor)))

    assert Enum.map(tail["events"], & &1["text"]) == ["still running"]
    assert :ok = AtlasRuntime.Output.finish(target(), output)

    assert {:result, ended} =
             request(a, :worker_output_next, Map.take(tail, ~w(subscription cursor)))

    assert ended["stream"]["ended"]
    assert ended["events"] == []

    assert {:error, invalid} =
             request(a, :worker_output_next, %{
               "subscription" => resumed["subscription"],
               "cursor" => "wrong-scope"
             })

    assert invalid["error"]["code"] == "invalid_cursor"
    refute Map.has_key?(invalid, "reset")

    stop_supervised!(AtlasRuntime.OutputEndpoint)
    stop_supervised!(AtlasRuntime.Output)
    replacement = start_supervised!({AtlasRuntime.Output, name: nil, max_events: 2})
    start_supervised!({AtlasRuntime.OutputEndpoint, machine: "box", output: replacement})
    assert :ok = AtlasRuntime.Output.open(target(), self(), replacement)

    assert :ok =
             AtlasRuntime.Output.append(
               target(),
               %{"kind" => "text", "text" => "new epoch"},
               replacement
             )

    assert {:result, reset} =
             request(a, :worker_output_next, Map.take(ended, ~w(subscription cursor)))

    assert reset["reset"] == %{"reason" => "epoch_changed"}
    assert reset["view"]["execution"] == target()
    refute reset["stream"]["epoch"] == ended["stream"]["epoch"]
    assert Enum.map(reset["events"], & &1["text"]) == ["new epoch"]
  end

  test "two real clients share stored guidance and recover exact same-key submission after closure",
       c do
    a = connect(c.port)
    b = connect(c.port, "H-2")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end)

    assert {:result,
            %{"workers" => [%{"execution" => execution, "guidance" => %{"available" => true}}]}} =
             request(a, :worker_overview)

    assert execution == target()
    send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1"})
    assert %{"title" => "Worker W-1"} = next(a, &(&1["op"] == "page"))
    props = %{"execution" => target(), "guidance" => guidance()}
    assert {:result, %{"interaction" => interaction}} = request(a, :worker_submit, props)
    assert interaction["projection"]["proven"] == "queued"
    assert interaction["actor"] == "H-1"
    assert interaction["body"] == guidance()["body"]

    assert {:result, %{"interactions" => [^interaction]}} =
             request(b, :worker_history, %{"execution" => target()})

    assert {:result, %{"interaction" => ^interaction}} = request(a, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "immutable_conflict"}}} =
             request(a, :worker_submit, put_in(props, ["guidance", "body"], "different"))

    {:ok, []} = Rela.change(c.rela, "runs", "R-1", %{"state" => "ended"}, nil, %{})

    assert {:result, %{"found" => true, "interaction" => ^interaction}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => "same-key"})

    assert {:result, %{"interaction" => ^interaction}} = request(a, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_submit, %{props | "guidance" => guidance("new-key")})

    IO.puts(
      "SMOKE two-client durable history, literal guidance, duplicate/conflict handling and closed-turn lost-reply recovery passed"
    )
  end

  test "foreign identities, missing attempts, actor injection and protocol versions cannot submit",
       c do
    a = connect(c.port)
    denied = connect(c.port, "W-1")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(denied)
    end)

    props = %{"execution" => target(), "guidance" => guidance()}

    assert {:error, %{"error" => %{"code" => "forbidden"}}} =
             request(denied, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "invalid_target"}}} =
             request(
               a,
               :worker_submit,
               put_in(props, ["execution", "worker", "environment"], "foreign")
             )

    assert {:error, %{"error" => %{"code" => "invalid_target"}}} =
             request(
               a,
               :worker_submit,
               update_in(props, ["execution"], &Map.delete(&1, "attempt"))
             )

    for change <- [%{"actor" => "H-2"}, %{"version" => "future"}] do
      message = Wire.request(:worker_submit, Map.put(props, "id", "invalid")) |> Map.merge(change)
      send_message(a, message)
      assert %{"error" => %{"code" => "invalid_request"}} = next(a, &(&1["id"] == "invalid"))
    end

    assert {:result, %{"interactions" => []}} =
             request(a, :worker_history, %{"execution" => target()})
  end

  test "receipts retain evidence and cursor cannot cross viewer or execution", c do
    a = connect(c.port)
    b = connect(c.port, "H-2")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end)

    assert {:result, %{"interaction" => interaction}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    values =
      Map.take(interaction, ~w(worker turn attempt execution))
      |> Map.merge(%{
        "interaction" => interaction["key"],
        "stage" => "delivered",
        "evidence_id" => "proof-1",
        "cause" => "private harness proof",
        "admission_id" => "admission-1"
      })

    assert {:stored, _} =
             bus("runtime@box", "synthetic_receipt", %{
               "op" => "record_receipt",
               "values" => values
             })

    assert {:result, %{"receipts" => [%{"admission_id" => "admission-1"}], "cursor" => cursor}} =
             request(a, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"]
             })

    assert {:error, %{"error" => %{"code" => "invalid_cursor"}}} =
             request(b, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"],
               "cursor" => cursor
             })

    assert {:result, %{"receipts" => [], "more" => false}} =
             request(a, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"],
               "cursor" => cursor
             })

    :gen_tcp.close(a)
    reconnected = connect(c.port)
    on_exit(fn -> :gen_tcp.close(reconnected) end)

    assert {:result,
            %{"found" => true, "interaction" => %{"projection" => %{"proven" => "delivered"}}}} =
             request(reconnected, :worker_query, %{
               "execution" => target(),
               "client_key" => "same-key"
             })

    IO.puts("SMOKE real Control reconnect, receipt projection and scoped cursor passed")
  end

  test "named read grants never imply submit or same-kind access", c do
    reader = connect(c.port, "H-2")
    ungranted = connect(c.port, "H-3")

    on_exit(fn ->
      :gen_tcp.close(reader)
      :gen_tcp.close(ungranted)
    end)

    assert {:result,
            %{"workers" => [%{"guidance" => %{"available" => false, "reason" => "forbidden"}}]}} =
             request(reader, :worker_overview)

    assert {:error, %{"error" => %{"code" => "forbidden"}}} =
             request(reader, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    assert {:error, %{"error" => %{"code" => "forbidden"}}} = request(ungranted, :worker_overview)
  end

  test "blocked reason survives typed inspection and fallback without granting guidance", c do
    a = connect(c.port)
    denied = connect(c.port, "H-3")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(denied)
    end)

    reason = "Permission required — keep literal α"

    {:ok, []} =
      Rela.change(c.rela, "runs", "R-1", %{"state" => "blocked", "why" => reason}, nil, %{})

    assert {:result, %{"view" => view}} =
             request(a, :worker_inspect, %{"execution" => target()})

    assert view["state"] == "blocked"
    assert view["reason"] == reason
    assert view["guidance"] == %{"available" => false, "reason" => "stale_execution"}

    for suffix <- ["", "/guidance"] do
      send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1" <> suffix})
      page = next(a, &(&1["op"] == "page"))
      fields = hd(page["blocks"])["props"]["fields"]
      assert %{"label" => "State", "value" => "blocked"} in fields
      assert %{"label" => "State reason", "value" => reason} in fields
      refute Enum.any?(page["blocks"], &(&1["type"] == "form"))
    end

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    assert {:ok, []} = Rela.list(c.rela, "interactions")

    assert {:error, %{"error" => %{"code" => "forbidden"}}} =
             request(denied, :worker_inspect, %{"execution" => target()})

    send_message(denied, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1"})
    forbidden = next(denied, &(&1["op"] == "page"))
    refute JSON.encode!(forbidden) =~ reason
    refute JSON.encode!(forbidden) =~ "blocked"

    {:ok, []} = Rela.change(c.rela, "runs", "R-1", %{"fence" => "replacement"}, nil, %{})

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_inspect, %{"execution" => target()})

    send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1/guidance"})
    stale = next(a, &(&1["op"] == "page"))
    refute JSON.encode!(stale) =~ reason
  end

  @tag unsupported: true
  test "unsupported adapters expose a view but no send action or interaction", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)

    assert {:result,
            %{"view" => %{"guidance" => %{"available" => false, "reason" => "unsupported"}}}} =
             request(a, :worker_inspect, %{"execution" => target()})

    assert {:error, %{"error" => %{"code" => "unsupported"}}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    assert {:ok, []} = Rela.list(c.rela, "interactions")
  end

  test "a committed write with a lost acknowledgement is unknown then recovered without replay",
       c do
    a = connect(c.port)

    on_exit(fn ->
      :gen_tcp.close(a)
      send(c.backend, :release_commit)
    end)

    GuidanceStore.barrier(c.backend, self())

    send_message(
      a,
      Wire.request(:worker_submit, %{
        "id" => "lost",
        "execution" => target(),
        "guidance" => guidance()
      })
    )

    assert_receive {:committed, backend, key}, 2000

    assert %{"error" => %{"code" => "outcome_unknown", "retryable" => false}} =
             next(a, &(&1["id"] == "lost"))

    send(backend, :release_commit)

    assert {:result, %{"found" => true, "interaction" => %{"key" => ^key}}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => "same-key"})

    assert {:ok, [%{key: ^key}]} = Rela.list(c.rela, "interactions")

    IO.puts(
      "SMOKE actual post-commit lost acknowledgement returns unknown; exact-key query recovers one durable interaction"
    )
  end

  test "handover and replacement cannot transfer guidance authority", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    {:ok, []} = Rela.change(c.rela, "tickets", "T-1", %{"handover" => "pending"}, nil, %{})

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    {:ok, []} = Rela.change(c.rela, "runs", "R-1", %{"fence" => "replacement"}, nil, %{})

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_inspect, %{"execution" => target()})

    assert {:ok, []} = Rela.list(c.rela, "interactions")
  end

  test "generic guidance form carries stable identity and writes literal input", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1/guidance"})
    form_page = next(a, &(&1["op"] == "page"))
    [%{"type" => "form", "props" => form}] = form_page["blocks"]
    key = Enum.find(form["inputs"], &(&1["name"] == "client_key"))["value"]
    call = form["submit_to"]

    send_message(
      a,
      Map.merge(call, %{
        "op" => "submit",
        "values" => %{guidance(key) | "body" => "/stop remains text"}
      })
    )

    assert %{"reason" => "stored", "title" => "Worker W-1"} = next(a, &(&1["op"] == "page"))

    assert {:result, %{"found" => true, "interaction" => %{"body" => "/stop remains text"}}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => key})
  end

  test "worker boot targets remain exact and history pages advance without skipping new facts",
       c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    target_path = "/workers/box/W-1/R-1/attempt-1"
    send_message(a, %{"op" => "boot", "to" => target_path})
    boot = next(a, &(&1["op"] in ["boot", "boot_result", "boot_error"]))
    assert boot["initial_to"] == target_path

    for index <- 1..51 do
      assert {:result, _} =
               request(a, :worker_submit, %{
                 "execution" => target(),
                 "guidance" => guidance("batch-#{index}")
               })
    end

    assert {:result, %{"interactions" => first, "cursor" => cursor, "more" => true}} =
             request(a, :worker_history, %{"execution" => target()})

    assert Enum.map(first, & &1["client_key"]) == Enum.map(1..50, &"batch-#{&1}")

    assert {:result,
            %{
              "interactions" => [%{"client_key" => "batch-51"}],
              "cursor" => final,
              "more" => false
            }} =
             request(a, :worker_history, %{"execution" => target(), "cursor" => cursor})

    assert {:result, _} =
             request(a, :worker_submit, %{
               "execution" => target(),
               "guidance" => guidance("batch-52")
             })

    assert {:result, %{"interactions" => [%{"client_key" => "batch-52"}]}} =
             request(a, :worker_history, %{"execution" => target(), "cursor" => final})
  end
end
