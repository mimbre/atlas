# Run in the umbrella with MIX_ENV=test against the pinned rela-server, without Python:
#   ATLAS_E2E_RELA_BIN=<dir with rela-server> mix run integration/work_anchors.exs
# (without it, rela is looked for as AtlasE2E.Instance.rela_bin!/0 does)
# Proves, on the real description, the compiled model and a real rela store, the three ways work hangs from the
# records it is based on: an accepted one with no work waits for it (its follow_through
# run, which Flow reconciles and projects through Facts: the tally of the work based on
# it, kept on the frozen record, ends it, and so does its no_work); work based on a
# replaced one is to be reviewed; and a worker reads them first.
ExUnit.start(seed: 0)

defmodule WorkAnchorsTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.Rela

  @moduletag :tmp_dir
  @root Path.expand("../..", __DIR__)
  # rela's binaries: ATLAS_E2E_RELA_BIN, ATLAS_RELA_BIN, the `rela-bin` folder beside the
  # checkout when it holds rela-server (a worker's), else the test instance's (as e2e's
  # AtlasE2E.Instance.rela_bin!/0).
  @bin Enum.find(
         [System.get_env("ATLAS_E2E_RELA_BIN"), System.get_env("ATLAS_RELA_BIN")],
         &(&1 not in [nil, ""])
       ) ||
         if(File.exists?(Path.join([@root, "../rela-bin", "rela-server"])),
           do: Path.join(@root, "../rela-bin"),
           else: Path.expand("~/.local/share/atlas/test/bin")
         )

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "anchors-#{System.unique_integer([:positive])}")
    project = Path.join(dir, "rela")
    File.mkdir_p!(project)
    # rela 26.11.2 resolves the includes natively: the selected files are the whole project.
    for name <- ["schema.yaml", "data-entry.yaml", "modules", "compositions"],
        do: File.cp_r!(Path.join([@root, "rela", name]), Path.join(project, name))

    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    server =
      Port.open({:spawn_executable, Path.join(@bin, "rela-server")}, [
        :binary,
        :exit_status,
        args: ["-project", project, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
      ])

    {:os_pid, pid} = Port.info(server, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) end)
    rela = {Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
    wait(rela, 200)

    # Facts stores by the compiled model; rela must serve the schema it was built with.
    start_supervised!(
      {AtlasFacts.Server, rela: rela, data_dir: Path.join(dir, "beam"), model: Model.AtlasEyra}
    )

    :ok = AtlasBus.attach("control/session-anchors-#{System.unique_integer([:positive])}")
    :ok
  end

  defp wait(rela, n) do
    case Rela.description(rela) do
      {:ok, _} -> :ok
      _ when n > 0 -> Process.sleep(25) && wait(rela, n - 1)
      other -> flunk("rela-server did not start: #{inspect(other)}")
    end
  end

  defp ask(kind, content) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 5_000
    answer
  end

  defp put(kind, content) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, Map.put_new(content, "version", nil))
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 5_000
    assert reply.class == "stored", inspect({content["key"], answer})
  end

  defp record(key, values, links \\ %{}) do
    put("decision", %{
      "op" => "create",
      "key" => key,
      "by" => "melle",
      "values" =>
        Map.merge(
          %{
            "title" => "Title #{key}",
            "decision" => "Rule of #{key}.",
            "consequences" => "What #{key} changes.",
            "category" => "architecture",
            "scope" => "platform",
            "reversibility" => "two_way",
            "force" => "direction",
            "status" => "accepted"
          },
          values
        ),
      "links" => Map.merge(%{"decided_by" => ["melle"]}, links)
    })
  end

  # Flow's runs of follow_through reconciled and each record projected, as Flow's engine
  # does, from a process of its own on the Bus (`flow`, the writer Facts takes runs and
  # tallies from); only follow_through runs here (decide would ask Gates). The record's
  # run, `{state, status}`, and what its Assignment says is expected.
  defp follow_through(key) do
    runner =
      AtlasFlow.Model.load(Model.AtlasEyra, AtlasFlow.Model.environment(), %{
        "decider" => "melle"
      })

    runner = update_in(runner.config["selection"], &Map.take(&1, ["follow_through"]))

    {run, assignment} =
      Task.async(fn ->
        :ok = AtlasBus.attach("flow")
        {:ok, _} = AtlasFlow.Runs.Store.reconcile(runner.config, runner.flows, DateTime.utc_now())

        for %{"key" => k} <- ask("decision", %{})["facts"],
            do: assert({:ok, _} = AtlasFlow.Runs.Projection.project(runner, "decision", k))

        {:ok, run} = AtlasFlow.Runs.Store.latest(runner.config, "follow_through", "decision", key)
        {run, ask("assignment", %{"key" => "AS-" <> key, "plain" => true})["fact"]}
      end)
      |> Task.await(30_000)

    {{run["state"], run["status"]}, assignment["values"]["expected"]}
  end

  test "an accepted record waits for work, flags replaced work, and is read first" do
    # Facts answers rela's schema; what Flow walks is the model's (its relations, with
    # the parent and component marks). The flows are compiled and checked with the model.
    %{"description" => served} = ask("_description", %{})
    assert served["entities"]["decision"]["plural"] == "decisions"

    put("person", %{"op" => "create", "key" => "melle", "values" => %{"name" => "Melle"}})

    put("agent", %{
      "op" => "create",
      "key" => "coordinator",
      "values" => %{"name" => "Coordinator"}
    })

    record("D-0024", %{"force" => "direction"})
    record("D-0025", %{})

    record("D-0030", %{
      "force" => "guideline",
      "title" => "Test low",
      "decision" => "Test at the lowest level."
    })

    record("D-0031", %{"force" => "guardrail", "scope" => "instance", "title" => "Elsewhere"})

    record("D-0032", %{
      "force" => "principle",
      "scope" => "instance",
      "title" => "Never alone",
      "enforced_by" => "the gate"
    })

    record(
      "D-0033",
      %{
        "force" => "principle",
        "status" => "proposed",
        "title" => "Not yet",
        "enforced_by" => "x"
      },
      %{"decided_by" => []}
    )

    # 1. Accepted, nothing based on it: waiting, with its consequences as what is expected.
    assert {{"waiting", "active"}, expected} = follow_through("D-0024")
    assert expected =~ "What D-0024 changes."
    assert ask("decision", %{"key" => "D-0024", "plain" => true})["fact"]["values"]["work"] == 0

    put("scene", %{
      "op" => "create",
      "key" => "SC-Atlas-01",
      "values" => %{"title" => "Carry it out"},
      "links" => %{"based_on" => ["D-0024"]},
      "by" => "melle"
    })

    # The tally of its work, kept on the frozen record, ends its run; nothing is expected.
    assert {{"carried_out", "completed"}, nil} = follow_through("D-0024")
    assert ask("decision", %{"key" => "D-0024", "plain" => true})["fact"]["values"]["work"] == 1

    # Or it says no work is needed: accepted records still take that one value.
    assert {{"waiting", "active"}, _} = follow_through("D-0025")

    put("decision", %{
      "op" => "change",
      "key" => "D-0025",
      "values" => %{"no_work" => true},
      "by" => "melle"
    })

    assert {{"no_work", "completed"}, nil} = follow_through("D-0025")

    # 3. Read first: what it is based on, then what applies to all work of its scopes, as
    # the model compiled it (what `atlas turn` and Runtime give a worker).
    read = fn kind, content -> ask(kind, content) end

    read_first = fn ->
      %{"fact" => scene} = read.("scene", %{"key" => "SC-Atlas-01", "plain" => true})
      Model.AtlasEyra.read_first(scene, read)
    end

    text = read_first.()
    # Accepted principles, whatever their scope, before anything else; a proposed one not.
    assert [
             "Read these decisions first.",
             "Principles, never broken:",
             "- D-0032 Never alone (principle, Accepted)" <> _ | _
           ] =
             String.split(text, "\n")

    refute text =~ "D-0033"
    assert text =~ "Read these decisions first."
    assert text =~ "- D-0024 Title D-0024 (direction, Accepted): Rule of D-0024."

    assert text =~
             "Guidelines and guardrails that apply:\n- D-0030 Test low (guideline, Accepted)"

    refute text =~ "D-0031"
    refute text =~ "D-0025"

    # 2. Superseded: the work based on it is to be reviewed, worked out on every read.
    refute Map.has_key?(ask("scene", %{"key" => "SC-Atlas-01"})["fact"], "review")
    record("D-0026", %{}, %{"supersedes" => ["D-0024"]})

    assert ask("decision", %{"key" => "D-0024", "plain" => true})["fact"]["values"]["status"] ==
             "superseded"

    assert %{
             "label" => "Review: based on a superseded decision",
             "key" => "D-0024",
             "value" => "superseded"
           } =
             ask("scene", %{"key" => "SC-Atlas-01"})["fact"]["review"]

    assert [%{"review" => %{"key" => "D-0024"}}] = ask("scene", %{})["facts"]

    assert read_first.() =~ "(direction, Superseded)"
  end
end
