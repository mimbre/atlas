# Disposable actual PR196 -> current admission -> reviewed maintenance migration.
# mix run integration/flow_refused_tally_recovery_native.exs EVIDENCE PR196_WRITES
import ExUnit.Assertions
alias AtlasFacts.Rela
alias AtlasFlow.{Talk, Engine}
alias AtlasFlow.Runs.Store

defmodule RecoveryNativeModel do
  defdelegate subflows(e), to: Model.AtlasEyra
  defdelegate runs(), to: Model.AtlasEyra
  def selection("follow_through"), do: Model.AtlasEyra.selection("follow_through")
  def selection(_), do: nil
  defdelegate migrations(), to: Model.AtlasEyra
  defdelegate composition(), to: Model.AtlasEyra
  defdelegate actors(), to: Model.AtlasEyra
  defdelegate relations(), to: Model.AtlasEyra
  defdelegate turn(), to: Model.AtlasEyra
end

# Test-only backend fault boundary, with a real native backend throughout.
defmodule RecoveryNativeRela do
  alias AtlasFacts.Rela.Http

  for {name, arity} <- [
        description: 1,
        list: 2,
        incoming: 4,
        check_create: 5,
        create: 5,
        delete: 4
      ] do
    args = Macro.generate_arguments(arity - 1, __MODULE__)

    def unquote(name)({base, _}, unquote_splicing(args)),
      do: apply(Http, unquote(name), [base, unquote_splicing(args)])
  end

  def get({base, faults}, plural, key) do
    if Agent.get(faults, &(&1.deny_reads and plural == &1.plural)),
      do: {:error, :unavailable},
      else: Http.get(base, plural, key)
  end

  def change({base, faults}, plural, key, values, version, targets) do
    mode =
      Agent.get_and_update(faults, fn s ->
        cond do
          s.deny_reads and plural == s.plural ->
            {:before_commit, s}

          plural == s.plural ->
            writes = if values["pending"], do: JSON.decode!(values["pending"])["writes"], else: []
            {s.mode, %{s | mode: :normal, issued: s.issued ++ writes}}

          true ->
            {:normal, s}
        end
      end)

    result =
      case mode do
        :before_commit ->
          {:error, :unavailable}

        :lost_ack ->
          {:ok, []} = Http.change(base, plural, key, values, version, targets)
          {:error, :unavailable}

        :conflict ->
          {:ok, []} =
            Http.change(base, plural, key, %{"blocked_reason" => "concurrent cursor"}, nil, %{})

          {:error, :version_mismatch}

        :crash_after_cursor ->
          result = Http.change(base, plural, key, values, version, targets)
          Agent.update(faults, &%{&1 | deny_reads: true})
          result

        _ ->
          Http.change(base, plural, key, values, version, targets)
      end

    if match?({:ok, []}, result) and Map.has_key?(values, "work") do
      Agent.update(faults, fn s ->
        %{s | successful: s.successful + 1, deny_reads: s.deny_reads or s.after_effect}
      end)
    end

    result
  end
end

[evidence_path, historical_path] = System.argv()

assert Base.encode16(:crypto.hash(:sha256, File.read!(historical_path)), case: :lower) ==
         "39bd10a082325ab316480982caffea4229722d12f0fb779d821d60c820a95659"

evidence = evidence_path |> File.read!() |> JSON.decode!()
{module, corrected, filename} = :code.get_object_code(RelaDSL.Facts.Writes)
root = Path.expand("../..", __DIR__)
runner = AtlasFlow.Model.load(RecoveryNativeModel, :test, %{"decider" => "melle"})
plural = fn kind -> Model.AtlasEyra.rela_schema()["entities"][kind]["plural"] end

as_flow = fn fun ->
  Task.async(fn ->
    :ok = AtlasBus.attach("flow")
    fun.()
  end)
  |> Task.await(30_000)
end

now = ~U[2026-11-14 17:00:00Z]

for mode <- [
      :normal,
      :lost_ack,
      :before_commit,
      :conflict,
      :crash_after_cursor,
      :crash_after_effect,
      :positive,
      :already_current,
      :pending_input
    ] do
  dir =
    Path.join(
      System.tmp_dir!(),
      "refusal-recovery-#{mode}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )

  project = Path.join(dir, "rela")
  File.mkdir_p!(project)

  for name <- ["schema.yaml", "data-entry.yaml", "modules", "compositions"],
      do: File.cp_r!(Path.join([root, "rela", name]), Path.join(project, name))

  {:ok, socket} = :gen_tcp.listen(0, active: false, ip: {127, 0, 0, 1})
  {:ok, port} = :inet.port(socket)
  :gen_tcp.close(socket)

  server =
    Port.open(
      {:spawn_executable, Path.join(System.fetch_env!("ATLAS_RELA_BIN"), "rela-server")},
      [
        :binary,
        :exit_status,
        args: ["-project", project, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
      ]
    )

  {:os_pid, pid} = Port.info(server, :os_pid)
  base = "http://127.0.0.1:#{port}/api/v1"

  {:ok, faults} =
    Agent.start_link(fn ->
      %{
        plural: plural.(runner.config["kind"]),
        mode: :normal,
        deny_reads: false,
        after_effect: false,
        successful: 0,
        issued: []
      }
    end)

  rela = {RecoveryNativeRela, {base, faults}}

  try do
    deadline = System.monotonic_time(:millisecond) + 10_000

    await = fn await ->
      case Rela.description(rela) do
        {:ok, _} ->
          :ok

        _ ->
          assert(System.monotonic_time(:millisecond) < deadline)
          Process.sleep(25)
          await.(await)
      end
    end

    await.(await)
    assert {:ok, []} = Rela.create(rela, plural.("person"), "melle", %{"name" => "Melle"}, %{})

    assert {:ok, []} =
             Rela.create(rela, plural.("agent"), "coordinator", %{"name" => "Coordinator"}, %{})

    assert {:ok, []} =
             Rela.create(rela, plural.("assignment"), "AS-D-0025", %{"of" => "D-0025"}, %{})

    d = evidence["decision"]

    assert {:ok, []} =
             Rela.create(rela, plural.("decision"), d["key"], d["values"], %{
               "decided_by" => {"agent", d["links"]["decided_by"]},
               "delegated_by" => {"person", d["links"]["delegated_by"]},
               "assignment" => {"assignment", d["links"]["assignment"]}
             })

    for fact <- evidence["runs"],
        do:
          assert(
            {:ok, []} ==
              Rela.create(rela, plural.(runner.config["kind"]), fact["key"], fact["values"], %{})
          )

    raw_run = Enum.find(evidence["runs"], &(&1["values"]["flow"] == "follow_through"))
    {:ok, original_run} = Store.decode(runner.config, raw_run)
    [write] = original_run["pending"]["writes"]
    {:ok, original} = Rela.get(rela, plural.("decision"), d["key"])
    assert original.properties == d["values"] and original.links == d["links"]
    refute Map.has_key?(original.properties, "work")

    # The exact supplied evaluator, original payload and ID; never seed a receipt.
    Code.compile_file(historical_path)

    {:ok, old_facts} =
      AtlasFacts.Server.start_link(
        rela: rela,
        model: Model.AtlasEyra,
        data_dir: Path.join(dir, "facts")
      )

    refusal = as_flow.(fn -> Talk.put(write["kind"], write["content"], write["id"]) end)

    assert {:refused,
            ["a person decides unless a fresh accept_decision verdict permits an agent"]} =
             refusal

    assert {:error, :recovery_ineligible} =
             as_flow.(fn -> Talk.recovery_evidence(write, runner.config["writer"]) end)

    GenServer.stop(old_facts)
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, corrected)

    {:ok, facts} =
      AtlasFacts.Server.start_link(
        rela: rela,
        model: Model.AtlasEyra,
        data_dir: Path.join(dir, "facts")
      )

    try do
      assert as_flow.(fn -> Talk.put(write["kind"], write["content"], write["id"]) end) == refusal

      assert {:error, {:pending, ^refusal}} =
               as_flow.(fn ->
                 Store.reconcile_subjects(runner.config, runner.flows, now, [original_run], [
                   {"decision", d["key"]}
                 ])
               end)

      assert {:ok, original} == Rela.get(rela, plural.("decision"), d["key"])

      assert {:ok, receipt} =
               as_flow.(fn -> Talk.recovery_evidence(write, runner.config["writer"]) end)

      assert receipt["content"] == %{
               "by" => "flow",
               "key" => d["key"],
               "op" => "change",
               "reasons" => elem(refusal, 1)
             }

      plan = %{
        "id" => "reviewed-native-recovery",
        "reason" => "Admission correction",
        "run" => original_run
      }

      # Binding failures do not touch the old outbox or receipt.
      assert {:error, :recovery_snapshot_changed} =
               as_flow.(fn ->
                 Store.recover_refused_tally(
                   runner.config,
                   runner.flows,
                   put_in(plan, ["run", "entry"], 99),
                   now
                 )
               end)

      for field <- ~w(generation definition_sha256) do
        assert {:error, :recovery_snapshot_changed} =
                 as_flow.(fn ->
                   Store.recover_refused_tally(
                     runner.config,
                     runner.flows,
                     put_in(plan, ["run", field], "changed"),
                     now
                   )
                 end)
      end

      for config <- [
            put_in(runner.config, ["selection", "follow_through", "choices"], ["answer"]),
            put_in(runner.config, ["composition", "tallies"], [])
          ] do
        assert {:error, :recovery_ineligible_or_conflicted} =
                 as_flow.(fn -> Store.recover_refused_tally(config, runner.flows, plan, now) end)
      end

      if mode == :positive do
        assert {:ok, []} =
                 Rela.create(rela, plural.("scene"), "SC-native", %{"title" => "Current work"}, %{
                   "based_on" => {"decision", [d["key"]]}
                 })
      end

      if mode == :already_current,
        do:
          assert(
            {:ok, []} ==
              Rela.change(rela, plural.("decision"), d["key"], %{"work" => 0}, nil, %{})
          )

      if mode == :pending_input do
        c = runner.config["inputs"]

        values =
          Map.new(c["fields"], fn {logical, field} ->
            {field,
             case logical do
               "run" -> original_run["key"]
               "status" -> "prepared"
               x when x in ~w(roles changed_fields links) -> "{}"
               _ -> nil
             end}
          end)

        assert {:ok, []} = Rela.create(rela, plural.(c["kind"]), "prepared-native", values, %{})
      end

      effects_before = Agent.get(faults, & &1.successful)

      Agent.update(
        faults,
        &%{
          &1
          | mode:
              if(mode in [:lost_ack, :before_commit, :conflict, :crash_after_cursor],
                do: mode,
                else: :normal
              ),
            after_effect: mode == :crash_after_effect
        }
      )

      result =
        if mode == :normal do
          {:ok, engine} =
            Engine.start_link(
              model: RecoveryNativeModel,
              actors: %{"decider" => "melle"},
              environment: :test
            )

          try do
            Engine.recover_refused_tally(engine, plan)
          after
            GenServer.stop(engine)
          end
        else
          as_flow.(fn -> Store.recover_refused_tally(runner.config, runner.flows, plan, now) end)
        end

      result =
        if mode in [:crash_after_cursor, :crash_after_effect] do
          assert {:error, _} = result

          assert {:ok, persisted} =
                   Rela.Http.get(base, plural.(runner.config["kind"]), original_run["key"])

          assert {:ok, interrupted} =
                   Store.decode(runner.config, %{
                     "key" => persisted.key,
                     "values" => persisted.properties
                   })

          assert interrupted["entry"] == original_run["entry"] + 1
          assert [_] = interrupted["pending"]["writes"]
          Agent.update(faults, &%{&1 | deny_reads: false, after_effect: false})
          as_flow.(fn -> Store.recover_refused_tally(runner.config, runner.flows, plan, now) end)
        else
          result
        end

      case mode do
        :pending_input ->
          assert result == {:error, :recovery_pending_input}

        m when m in [:before_commit, :conflict] ->
          assert {:error, _} = result

        _ ->
          assert {:ok, recovered} = result
          assert recovered["entry"] >= original_run["entry"] + 1
          assert recovered["generation"] == original_run["generation"]
          assert recovered["definition_sha256"] == original_run["definition_sha256"]
          [audit] = recovered["pending"]["migrations"]
          assert audit["retired"]["writes"] == [write] and audit["receipt"] == receipt
          assert audit["retired"]["synthetic"] == original_run["pending"]["synthetic"]
          assert recovered["pending"]["writes"] == []

          assert Agent.get(faults, & &1.successful) - effects_before ==
                   if(mode == :already_current, do: 0, else: 1)

          assert {:ok, final} = Rela.get(rela, plural.("decision"), d["key"])
          assert final.properties["work"] == if(mode == :positive, do: 1, else: 0)

          assert Map.delete(final.properties, "work") == original.properties and
                   final.links == original.links

          assert {:ok, ^recovered} =
                   as_flow.(fn ->
                     Store.recover_refused_tally(runner.config, runner.flows, plan, now)
                   end)

          assert {:error, :recovery_plan_conflict} =
                   as_flow.(fn ->
                     Store.recover_refused_tally(
                       runner.config,
                       runner.flows,
                       Map.put(plan, "reason", "changed"),
                       now
                     )
                   end)

          successor = Agent.get(faults, &List.first(&1.issued))

          if successor do
            assert successor["id"] != write["id"]

            assert {:stored, position} =
                     as_flow.(fn ->
                       Talk.put(successor["kind"], successor["content"], successor["id"])
                     end)

            assert {:error, :recovery_ineligible} =
                     as_flow.(fn ->
                       Talk.recovery_evidence(successor, runner.config["writer"])
                     end)

            GenServer.stop(facts)

            {:ok, restarted} =
              AtlasFacts.Server.start_link(
                rela: rela,
                model: Model.AtlasEyra,
                data_dir: Path.join(dir, "facts")
              )

            try do
              assert {:stored, ^position} =
                       as_flow.(fn ->
                         Talk.put(successor["kind"], successor["content"], successor["id"])
                       end)

              assert {:ok, ^recovered} =
                       as_flow.(fn ->
                         Store.recover_refused_tally(runner.config, runner.flows, plan, now)
                       end)

              assert {:ok, ^receipt} =
                       as_flow.(fn -> Talk.recovery_evidence(write, runner.config["writer"]) end)

              assert Agent.get(faults, & &1.successful) - effects_before == 1
            after
              GenServer.stop(restarted)
            end
          end

          # A local Engine call remains usable after a prior failed round; same plan
          # resumes its committed entry, never schedules another migration.
          # When the receipt restart above stopped Facts, reopen it for Engine's
          # duplicate call and the final unchanged-history checks.
          if not Process.alive?(facts) do
            {:ok, _} =
              AtlasFacts.Server.start_link(
                rela: rela,
                model: Model.AtlasEyra,
                data_dir: Path.join(dir, "facts"),
                name: :native_reopened_facts
              )
          end

          {:ok, engine} =
            Engine.start_link(
              model: RecoveryNativeModel,
              actors: %{"decider" => "melle"},
              environment: :test
            )

          try do
            assert {:ok, ^recovered} = Engine.recover_refused_tally(engine, plan)
          after
            GenServer.stop(engine)
          end
      end

      assert {:ok, ^receipt} =
               as_flow.(fn -> Talk.recovery_evidence(write, runner.config["writer"]) end)

      history = Enum.find(evidence["runs"], &(&1["values"]["flow"] == "decide"))
      assert {:ok, prior} = Rela.get(rela, plural.(runner.config["kind"]), history["key"])
      assert prior.properties == history["values"]

      if mode in [:before_commit, :conflict, :pending_input] do
        assert {:ok, unchanged} = Rela.get(rela, plural.("decision"), d["key"])
        assert unchanged.properties == original.properties
      end

      IO.puts(
        "PASS #{mode}: actual PR196 exact refusal, corrected replay stuck, bounded migration boundary verified, old receipt/history preserved"
      )
    after
      if Process.alive?(facts), do: GenServer.stop(facts)
      if Process.whereis(:native_reopened_facts), do: GenServer.stop(:native_reopened_facts)
    end
  after
    :code.purge(module)
    :code.load_binary(module, filename, corrected)
    Agent.stop(faults)
    {_, status} = System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    IO.puts("CLEANUP native_pid=#{pid} TERM_exit=#{status}")

    receive do
      {^server, {:exit_status, native_status}} ->
        IO.puts("EXIT native_pid=#{pid} status=#{native_status}")
    after
      5_000 -> flunk("native server did not exit after cleanup")
    end
  end
end
