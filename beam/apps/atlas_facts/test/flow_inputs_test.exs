defmodule AtlasFacts.FlowInputsTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFacts.{FlowInputs, Rela}
  @now ~U[2026-11-12 00:00:00Z]

  defmodule Description do
    @moduledoc false
    def of do
      fields =
        Map.new(
          ~w(flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason),
          &{&1, &1}
        )

      props =
        Map.new(fields, fn {slot, field} ->
          {field,
           %{
             "type" =>
               if(slot in ~w(entry generation input_cursor), do: "integer", else: "string")
           }}
        end)

      d = %{"entities" => %{"cursor" => %{"properties" => props}}}

      config = %{
        "version" => 1,
        "kind" => "cursor",
        "fields" => fields,
        "writer" => %{"sender" => "flow", "by" => "flow"},
        "selection" => %{}
      }

      config =
        config
        |> Map.put("selection", %{})
        |> Map.put("inputs", %{
          "kind" => "choice",
          "fields" => Map.new(AtlasFacts.FlowInputs.fields(), &{&1, &1}),
          "acl" => %{"clerk" => %{"update" => ["box"]}},
          "roles" => %{"clerk" => "chosen_by"}
        })

      props =
        Map.new(
          AtlasFacts.FlowInputs.fields(),
          &{&1,
           %{"type" => if(&1 in ~w(entry generation position), do: "integer", else: "string")}}
        )

      d
      |> put_in(["entities", "cursor", "plural"], "cursors")
      |> put_in(["entities", "choice"], %{"plural" => "choices", "properties" => props})
      |> put_in(["entities", "box"], %{
        "plural" => "boxes",
        "properties" => %{"choice" => %{"type" => "string"}, "phase" => %{"type" => "string"}}
      })
      |> put_in(["entities", "clerk"], %{"plural" => "clerks", "properties" => %{}})
      |> Map.put("relations", %{"chosen_by" => %{"from" => ["box"], "to" => ["clerk"]}})
      |> Map.put("flows", %{})
      |> Map.put("flow_runtime", config)
    end
  end

  defmodule Inputs do
    @moduledoc "Boxes a clerk chooses on, with the runs (cursors) and choices Facts keeps."
    use AtlasFacts.TestModel, description: AtlasFacts.FlowInputsTest.Description.of()
  end

  def description, do: Description.of()

  defmodule Backend do
    def description(_), do: {:ok, AtlasFacts.FlowInputsTest.Inputs.rela_schema()}

    def get(pid, plural, key) do
      with {:ok, fact} <- AtlasFacts.FakeRela.get(pid, plural, key),
           do: {:ok, %{fact | properties: Map.delete(fact.properties, "title")}}
    end

    def list(pid, plural) do
      with {:ok, facts} <- AtlasFacts.FakeRela.list(pid, plural) do
        {:ok, for(f <- facts, {:ok, own} <- [get(pid, plural, f.key)], do: own)}
      end
    end

    def create(pid, plural, key, values, links),
      do: AtlasFacts.FakeRela.create(pid, plural, key, Map.put(values, "title", "Record"), links)

    def change(pid, plural, key, values, version, links),
      do: AtlasFacts.FakeRela.change(pid, plural, key, values, version, links)

    def check_create(_, _, _, _, _), do: {:ok, []}
    defdelegate incoming(pid, plural, key, relation), to: AtlasFacts.FakeRela
    defdelegate delete(pid, plural, key, version), to: AtlasFacts.FakeRela
  end

  setup do
    pid = AtlasFacts.FakeRela.start()
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    rela = {Backend, pid}
    d = description()
    {:ok, []} = Rela.create(rela, "clerks", "ada", %{}, %{})

    {:ok, []} =
      Rela.create(rela, "boxes", "B-1", %{"choice" => "none"}, %{
        "chosen_by" => {"clerk", ["ada"]}
      })

    {:ok, subject} = Rela.get(rela, "boxes", "B-1")

    run = %{
      "flow" => "sort",
      "subject_kind" => "box",
      "subject_key" => "B-1",
      "generation" => 1,
      "entry" => 1,
      "status" => "active",
      "pending" => JSON.encode!(%{"version" => 1, "writes" => []}),
      "last_input" => JSON.encode!(%{"version" => 1}),
      "input_cursor" => 0
    }

    {:ok, []} = Rela.create(rela, "cursors", "R-1", run, %{})
    counter = start_supervised!({Agent, fn -> 0 end})
    position = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end

    write = fn "box", c, _ ->
      case Rela.change(rela, "boxes", c["key"], c["values"], c["version"], %{}) do
        {:ok, []} -> :ok
        other -> other
      end
    end

    v = %{
      "entry" => 1,
      "request_id" => "choice-1",
      "run" => "R-1",
      "source_version" => subject.version,
      "changed_fields" => %{"choice" => "yes"}
    }

    %{
      rela: rela,
      d: d,
      v: v,
      position: position,
      write: %{authorize: fn _, _, _ -> :ok end, apply: write}
    }
  end

  defp submit(c, v \\ nil, actor \\ "ada", sender \\ "control/session-test", write \\ nil) do
    FlowInputs.write(
      c.rela,
      c.d,
      %{Envelope.new("fact", "choice") | sender: sender},
      %{"op" => "submit", "by" => actor, "values" => v || c.v},
      fn -> @now end,
      c.position,
      if(write, do: %{c.write | apply: write}, else: c.write)
    )
  end

  test "only trusted Control and relation-derived roles under selected ACL authorize inputs", c do
    assert {:error, :input_authority} = submit(c, nil, "ada", "client")
    assert {:error, :input_authority} = submit(c, Map.put(c.v, "roles", ["clerk"]))
    assert {:error, :not_named_to_choose} = submit(c, nil, "stranger")
    empty_acl = put_in(c.d, ["flow_runtime", "inputs", "acl", "clerk", "update"], [])
    assert {:error, :not_named_to_choose} = submit(%{c | d: empty_acl})
    assert {:ok, accepted} = submit(c)
    assert accepted["roles"] == ["clerk"]
    assert accepted["actor"] == "ada"
    assert accepted["status"] == "applied"
    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "yes"
    assert accepted["subject_version"] == subject.version
  end

  test "replay returns original operation and changed payload or stale version refuses", c do
    assert {:ok, first} = submit(c)
    assert {:ok, ^first} = submit(c)
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")
    {:ok, []} = Rela.change(c.rela, "cursors", "R-1", %{"entry" => 2}, current.version, %{})
    assert {:ok, ^first} = submit(c)

    assert {:error, :request_conflict} =
             submit(c, put_in(c.v, ["changed_fields", "choice"], "no"))

    assert {:error, :subject_changed} =
             submit(c, c.v |> Map.put("request_id", "choice-2") |> Map.put("entry", 2))
  end

  test "ordinary Control choices are captured before writing, replayed across entries and bind links",
       c do
    d =
      put_in(c.d, ["flow_runtime", "selection"], %{
        "sort" => %{"subject" => "box", "choices" => ["choice"]}
      })

    e = %{Envelope.new("fact", "box", id: "captured") | sender: "control/session-test"}
    content = %{"op" => "change", "key" => "B-1", "by" => "ada", "values" => %{"choice" => "yes"}}
    assert {:capture, request} = FlowInputs.capture(c.rela, d, e, content)
    assert request["values"]["source_version"] == c.v["source_version"]
    assert {:ok, input} = submit(%{c | d: d}, request["values"])
    assert input["links"] == %{}
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(
        c.rela,
        "cursors",
        "R-1",
        %{"entry" => 2, "status" => "completed"},
        current.version,
        %{}
      )

    assert {:capture, ^request} = FlowInputs.capture(c.rela, d, e, content)

    assert {:error, :request_conflict} =
             FlowInputs.capture(
               c.rela,
               d,
               e,
               Map.put(content, "links", %{"chosen_by" => ["other"]})
             )

    assert {:error, :input_authority} =
             FlowInputs.capture(c.rela, d, %{e | sender: "client"}, content)
  end

  test "a choice after the deadline or outside a waiting state writes nothing", c do
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(
        c.rela,
        "cursors",
        "R-1",
        %{
          "deadlines" =>
            JSON.encode!(%{"version" => 1, "timers" => [%{"due" => "2026-11-11T23:59:59Z"}]})
        },
        current.version,
        %{}
      )

    assert {:error, :answer_too_late} = submit(c)
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(
        c.rela,
        "cursors",
        "R-1",
        %{"deadlines" => JSON.encode!(%{"timers" => []}), "state" => "routing"},
        current.version,
        %{}
      )

    d = put_in(c.d, ["flow_runtime", "selection"], %{"sort" => %{"choice_states" => ["waiting"]}})
    assert {:error, :not_waiting_for_choice} = submit(%{c | d: d})
    assert {:ok, []} = Rela.list(c.rela, "choices")
    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "none"
  end

  test "capture retains optimistic field checks after a separate association write", c do
    d =
      put_in(c.d, ["flow_runtime", "selection"], %{
        "sort" => %{"subject" => "box", "choices" => ["choice"]}
      })

    {:ok, []} =
      Rela.change(c.rela, "boxes", "B-1", %{"phase" => "later"}, c.v["source_version"], %{})

    {:ok, fresh} = Rela.get(c.rela, "boxes", "B-1")
    e = %{Envelope.new("fact", "box") | sender: "control/session-test"}

    content = %{
      "op" => "change",
      "key" => "B-1",
      "by" => "ada",
      "version" => c.v["source_version"],
      "values" => %{"choice" => "yes"},
      "was" => %{"choice" => "none"}
    }

    assert {:capture, request} = FlowInputs.capture(c.rela, d, e, content)
    assert request["values"]["source_version"] == fresh.version

    assert {:capture, stale} =
             FlowInputs.capture(c.rela, d, e, put_in(content, ["was", "choice"], "other"))

    assert stale["values"]["source_version"] == c.v["source_version"]
  end

  test "restart recovers a persisted prepare and refuses ambiguous recovery", c do
    assert {:error, :interrupted} =
             submit(c, nil, "ada", "control/session-test", fn _, _, _ ->
               {:error, :interrupted}
             end)

    assert {:ok, [prepared]} = Rela.list(c.rela, "choices")
    assert prepared.properties["status"] == "prepared"
    assert {:ok, recovered} = submit(c)
    assert recovered["status"] == "applied"
    assert recovered["request_id"] == "choice-1"
    assert recovered["position"] == prepared.properties["position"]
  end

  test "commit before acknowledgement recovers matching prepared request and values", c do
    assert {:error, :lost_ack} =
             submit(c, nil, "ada", "control/session-test", fn kind, content, id ->
               :ok = c.write.apply.(kind, content, id)
               {:error, :lost_ack}
             end)

    assert {:ok, applied} =
             submit(c, nil, "ada", "control/session-test", fn _, _, _ ->
               assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
               assert subject.properties["choice"] == "yes"
               :ok
             end)

    assert applied["status"] == "applied"
  end

  test "consume requires the committed run cursor; applied choices survive a reader restart", c do
    {:ok, applied} = submit(c)
    flow = %{Envelope.new("read", "choice") | sender: "flow"}

    assert {:ok, %{"inputs" => [^applied]}} =
             FlowInputs.read(
               c.rela,
               c.d,
               flow,
               %{"run" => "R-1"},
               fn -> @now end,
               c.position,
               c.write
             )

    content = %{"op" => "consume", "key" => applied["key"], "run" => "R-1"}

    assert {:error, :input_authority} =
             FlowInputs.write(c.rela, c.d, flow, content, fn -> @now end, c.position, c.write)

    {:ok, run} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(
        c.rela,
        "cursors",
        "R-1",
        %{
          "last_input" => JSON.encode!(%{"version" => 1, "input" => applied["key"]}),
          "input_cursor" => applied["position"]
        },
        run.version,
        %{}
      )

    assert {:ok, %{"status" => "consumed"}} =
             FlowInputs.write(c.rela, c.d, flow, content, fn -> @now end, c.position, c.write)
  end

  test "a timeout claim is fenced by an earlier prepared input, including after a restart", c do
    assert {:error, :interrupted} =
             submit(c, nil, "ada", "control/session-test", fn _, _, _ ->
               {:error, :interrupted}
             end)

    claim = %{
      "last_input" =>
        JSON.encode!(%{
          "version" => 1,
          "entry" => 1,
          "name" => "due",
          "due" => "2026-11-12T00:05:00Z"
        })
    }

    assert {:refused, _} = FlowInputs.fence(c.rela, c.d, "cursor", "R-1", claim)
    {:ok, input} = submit(c)
    assert {:refused, _} = FlowInputs.fence(c.rela, c.d, "cursor", "R-1", claim)
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(
        c.rela,
        "cursors",
        "R-1",
        %{"input_cursor" => input["position"]},
        current.version,
        %{}
      )

    assert :ok = FlowInputs.fence(c.rela, c.d, "cursor", "R-1", claim)
  end

  test "every refusal of a choice reads as sentences, naming the relation that gives a role", c do
    for reason <- [
          :input_moved_on,
          :not_waiting_for_choice,
          :answer_too_late,
          :subject_changed,
          :input_authority,
          :request_conflict,
          :prepared_input_needs_reconciliation,
          :some_new_code,
          {:subject_write, :unavailable},
          {:subject_authority, :unavailable},
          {:other, 1}
        ] do
      assert [sentence] = FlowInputs.reasons(reason, c.d)
      refute sentence =~ ~r/:[a-z_]+|\{|_/
      assert sentence =~ ~r/^[A-Z].*\.$/
    end

    assert ["Only the one its chosen_by names may make this choice; " <> _] =
             FlowInputs.reasons(:not_named_to_choose, c.d)

    assert FlowInputs.reasons({:subject_authority, {:refused, ["a clerk decides"]}}, c.d) ==
             ["a clerk decides"]
  end

  test "inputs name the exact entry, and refused subject authority leaves no prepare", c do
    assert {:error, :input_moved_on} = submit(c, Map.put(c.v, "entry", 0))
    callbacks = %{c.write | authorize: fn _, _, _ -> {:error, :subject_authority} end}
    assert {:error, :subject_authority} = submit(%{c | write: callbacks})
    assert {:ok, []} = Rela.list(c.rela, "choices")
  end

  @tag :tmp_dir
  test "Control can list and get input records without recovering or consuming them", c do
    Application.put_env(:atlas_bus, :store, "input-browse-#{System.unique_integer([:positive])}")

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: c.rela, data_dir: c.tmp_dir, model: Inputs, flow_input_clock: fn -> @now end}
      )

    :ok = AtlasBus.attach("control/session-browse")

    request = fn class, content ->
      envelope = Envelope.new(class, c.d["flow_runtime"]["inputs"]["kind"])
      id = envelope.id
      :ok = AtlasBus.send(envelope, content)
      reply_to(id, facts)
    end

    assert {"answer", %{"facts" => []}} = request.("read", %{})

    assert {:error, :interrupted} =
             submit(c, nil, "ada", "control/session-test", fn _, _, _ ->
               {:error, :interrupted}
             end)

    # The private fixture wrote directly to the backend, outside Facts' invalidation.
    :ok = AtlasFacts.Server.flush_collections(facts)

    assert {"answer", %{"facts" => [record]}} = request.("read", %{})
    assert record["values"]["status"] == "prepared"

    assert {"answer", %{"fact" => ^record}} =
             request.("read", %{"key" => record["key"], "plain" => true})

    assert {"answer", %{"fact" => %{"key" => key, "values" => values}}} =
             request.("read", %{"key" => record["key"]})

    assert key == record["key"] and values["status"] == "prepared"
    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "none"
    assert {"answer", %{"error" => ":input_authority"}} = request.("read", %{"run" => "R-1"})

    for op <- ~w(create change delete) do
      assert {"refused", _} =
               request.("fact", %{"op" => op, "key" => record["key"], "values" => %{}})
    end
  end

  @tag :tmp_dir
  test "transition reads bypass a primed collection and return the current version", c do
    Application.put_env(:atlas_bus, :store, "input-reads-#{System.unique_integer([:positive])}")

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: c.rela, data_dir: c.tmp_dir, model: Inputs, flow_input_clock: fn -> @now end}
      )

    :ok = AtlasBus.attach("flow")

    read = fn kind, content ->
      e = Envelope.new("read", kind)
      id = e.id
      :ok = AtlasBus.send(e, content)
      assert {"answer", answer} = reply_to(id, facts)
      answer
    end

    assert %{"facts" => [_]} = read.("cursor", %{})
    {:ok, old} = Rela.get(c.rela, "cursors", "R-1")
    {:ok, []} = Rela.change(c.rela, "cursors", "R-1", %{"state" => "fresh"}, old.version, %{})

    assert %{"fact" => %{"version" => stale}} =
             read.("cursor", %{"key" => "R-1", "incoming" => false})

    assert stale == old.version

    assert %{"fact" => %{"version" => fresh, "values" => %{"state" => "fresh"}}} =
             read.("cursor", %{"key" => "R-1", "plain" => true, "consistency" => "transition"})

    assert fresh != stale
    assert {:ok, accepted} = submit(c)
    assert %{"inputs" => [^accepted]} = read.("choice", %{"run" => "R-1"})
  end

  @tag :tmp_dir
  test "Facts endpoint refuses forged roles and ordinary writes; authorized submit passes real guards",
       c do
    Application.put_env(
      :atlas_bus,
      :store,
      "input-authority-#{System.unique_integer([:positive])}"
    )

    facts =
      start_supervised!(
        {AtlasFacts.Server,
         rela: c.rela, data_dir: c.tmp_dir, model: Inputs, flow_input_clock: fn -> @now end}
      )

    :ok = AtlasBus.attach("client")

    for content <- [
          %{"op" => "create", "key" => "fake", "values" => %{"roles" => "[\"clerk\"]"}},
          %{"op" => "submit", "by" => "ada", "values" => Map.put(c.v, "roles", ["clerk"])},
          %{"op" => "submit", "by" => "ada", "values" => c.v}
        ] do
      e = Envelope.new("fact", "choice")
      id = e.id
      :ok = AtlasBus.send(e, content)
      assert {"refused", _} = reply_to(id, facts)
    end

    Registry.unregister(AtlasBus.Endpoints, "client")
    :ok = AtlasBus.attach("control/session-proof")

    for {actor, class} <- [{"stranger", "refused"}, {"ada", "stored"}] do
      e = Envelope.new("fact", "choice")
      id = e.id
      :ok = AtlasBus.send(e, %{"op" => "submit", "by" => actor, "values" => c.v})
      assert {^class, _} = reply_to(id, facts)
    end
  end

  # Facts answers every fact and read it handles, from its own process. Wait for that reply
  # by id, with no time window to guess; if Facts stops instead, fail rather than hang.
  defp reply_to(id, facts) do
    ref = Process.monitor(facts)

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: class}, content} ->
        Process.demonitor(ref, [:flush])
        {class, content}

      {:DOWN, ^ref, :process, ^facts, reason} ->
        flunk("Facts stopped before answering #{id}: #{inspect(reason)}")
    end
  end
end
