defmodule AtlasFacts.GuidanceNativeTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.{Guidance, Rela}
  @moduletag :tmp_dir
  # Needs rela-server and rela/scripts/config.py (Python with PyYAML).
  @moduletag :integration
  @root Path.expand("../../../..", __DIR__)
  @bin System.get_env("ATLAS_E2E_RELA_BIN") || Path.expand("~/.local/share/atlas/test/bin")
  @moduletag skip: not File.exists?(Path.join(@bin, "rela-server"))

  defp start_rela(dir) do
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    process =
      Port.open({:spawn_executable, Path.join(@bin, "rela-server")}, [
        :binary,
        :exit_status,
        args: ["-project", dir, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
      ])

    {:os_pid, pid} = Port.info(process, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) end)
    rela = {Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
    wait(rela, 100)
    {rela, pid, process}
  end

  defp wait(rela, remaining) do
    case Rela.description(rela) do
      {:ok, _} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(20)
        wait(rela, remaining - 1)

      other ->
        flunk("private rela failed to start: #{inspect(other)}")
    end
  end

  defp write(rela, d, role, op, values, sender, extra \\ %{}) do
    e = %{Envelope.new("fact", d["guidance"][role]["kind"]) | sender: sender}

    Guidance.write(rela, d, role, e, Map.merge(%{"op" => op, "values" => values}, extra), fn ->
      System.unique_integer([:positive, :monotonic])
    end)
  end

  test "pinned HTTP store claims once, compares complete payload and replays evidence after restart",
       %{tmp_dir: dir} do
    assert {"rela version 26.11.2\n", 0} = System.cmd(Path.join(@bin, "rela"), ["version"])
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {output, code} =
      System.cmd(
        python,
        [
          Path.join(@root, "rela/scripts/config.py"),
          "copy",
          "--root",
          Path.join(@root, "rela"),
          "--data",
          dir
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output
    {rela, pid, process} = start_rela(dir)
    {:ok, schema} = Rela.description(rela)
    extra = @root |> Path.join("rela/atlas.json") |> File.read!() |> JSON.decode!()
    # The guidance records and the turn, as the model compiles them (here from the proof).
    d = Map.merge(schema, Map.take(extra, ["guidance", "runtime"]))
    turn = d["runtime"]["turn"]
    [worker_kind] = d["relations"][turn["by"]]["to"]
    worker_spec = d["entities"][worker_kind]
    collection = worker_spec["plural"]
    primary = worker_spec["primary"]

    assert {:ok, []} =
             Rela.create(rela, collection, "private-worker", %{primary => "Private"}, %{})

    assert {:ok, []} =
             Rela.create(
               rela,
               d["entities"][turn["kind"]]["plural"],
               "TU-private",
               %{
                 turn["state"] => turn["running"],
                 turn["machine"] => "private",
                 turn["attempt"] => "attempt-1"
               },
               %{turn["by"] => {worker_kind, ["private-worker"]}}
             )

    owner = self()

    claims =
      for name <- ["first payload", "conflicting payload"] do
        Task.async(fn ->
          send(owner, {:claim_ready, self()})

          receive do
            :claim -> Rela.create(rela, collection, "private-claim", %{primary => name}, %{})
          end
        end)
      end

    for _ <- claims, do: assert_receive({:claim_ready, _})
    Enum.each(claims, &send(&1.pid, :claim))
    claims = Enum.map(claims, &Task.await/1)
    assert Enum.count(claims, &(&1 == {:ok, []})) == 1
    assert Enum.count(claims, &(&1 == {:error, :exists})) == 1
    assert {:ok, original_claim} = Rela.get(rela, collection, "private-claim")

    values = %{
      "worker" => "private-worker",
      "turn" => "TU-private",
      "attempt" => "attempt-1",
      "machine" => "private",
      "harness" => "fake",
      "harness_version" => "1",
      "configured_model" => "no-model",
      "capability_version" => "1",
      "queued_input" => true,
      "durable_accept_query" => true,
      "consumption_evidence" => true
    }

    assert {:ok, execution} =
             write(rela, d, "execution", "register_execution", values, "runtime@private")

    input =
      Map.take(values, ~w(worker turn attempt))
      |> Map.merge(%{
        "client_key" => "stable",
        "body" => "/literal",
        "mode" => "queued_guidance",
        "execution" => execution["key"],
        "cause" => "private test"
      })

    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :go ->
              write(
                rela,
                d,
                "interaction",
                "submit_interaction",
                input,
                "control/session-private",
                %{"by" => "reader"}
              )
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    [a, b] = Enum.map(tasks, &Task.await/1)
    assert a == b
    assert {:ok, interaction} = a
    assert {:ok, [_]} = Rela.list(rela, "interactions")

    assert {:error, :immutable_conflict} =
             write(
               rela,
               d,
               "interaction",
               "submit_interaction",
               Map.put(input, "body", "different"),
               "control/session-private",
               %{"by" => "reader"}
             )

    r =
      Map.take(input, ~w(worker turn attempt execution))
      |> Map.merge(%{
        "interaction" => interaction["key"],
        "stage" => "acknowledged",
        "evidence_id" => "evidence-1",
        "admission_id" => "inbox-1",
        "consumption_id" => "context-1",
        "cause" => "synthetic harness"
      })

    assert {:ok, receipt} =
             write(rela, d, "receipt", "record_receipt", r, "runtime@private/TU-private")

    System.cmd("kill", ["-TERM", to_string(pid)])
    assert_receive {^process, {:exit_status, _}}, 2_000
    {fresh, _, _} = start_rela(dir)
    assert {:ok, recovered_claim} = Rela.get(fresh, collection, "private-claim")
    assert recovered_claim.properties == original_claim.properties

    assert {:ok, restored} =
             write(
               fresh,
               d,
               "interaction",
               "submit_interaction",
               input,
               "control/session-private",
               %{"by" => "reader"}
             )

    assert restored["recorded_at"] == interaction["recorded_at"]
    assert restored["receipt_count"] == 1

    assert {:ok, %{"facts" => [^receipt], "more" => false}} =
             Guidance.read(fresh, d, "receipt", %{"interaction" => restored["key"]})

    assert restored["projection"]["proven"] == "acknowledged"
    assert {:ok, ^receipt} = write(fresh, d, "receipt", "record_receipt", r, "runtime@private")
  end
end
