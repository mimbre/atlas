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

    # A test that asks (`:rela_reads` in its process) is told of each read it makes.
    def get(pid, plural, key) do
      if Process.get(:rela_reads), do: send(self(), {:rela_get, plural, key})

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

  test "a role may come through a fact made with the subject, as it is stored", c do
    # A box is made with its slip (a component); whoever the slip is held by may choose.
    d =
      c.d
      |> put_in(["entities", "slip"], %{"plural" => "slips", "properties" => %{}})
      |> put_in(["relations", "slip"], %{
        "from" => ["box"],
        "to" => ["slip"]
      })
      |> put_in(["flow_runtime", "inputs", "components"], %{
        "slip" => %{
          "from" => ["box"],
          "to" => ["slip"],
          "component" => %{"key" => "SL-{key}"}
        }
      })
      |> put_in(["relations", "held_by"], %{"from" => ["slip"], "to" => ["clerk"]})
      |> put_in(["flow_runtime", "inputs", "roles"], %{"holder" => "held_by"})
      |> put_in(["flow_runtime", "inputs", "acl"], %{"holder" => %{"update" => ["box"]}})

    {:ok, []} = Rela.create(c.rela, "clerks", "bo", %{}, %{})
    {:ok, []} = Rela.create(c.rela, "slips", "SL-B-1", %{}, %{"held_by" => {"clerk", ["bo"]}})
    c = %{c | d: d}
    Process.put(:rela_reads, true)

    # Ada is no holder, not even naming herself there in the same choice.
    assert {:error, :not_named_to_choose} = submit(c)

    assert {:error, :not_named_to_choose} =
             submit(c, Map.put(c.v, "links", %{"held_by" => ["ada"]}))

    assert {:ok, accepted} = submit(c, nil, "bo")
    assert accepted["roles"] == ["holder"]
    assert_received {:rela_get, "slips", "SL-B-1"}
    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "yes"
  end

  test "a kind whose roles all lead from itself reads none of its components", c do
    # A box is made with its slip. The role a box gives (clerk) comes through chosen_by,
    # which leads from the box; the one through the slip (holder) its ACL gives on no box.
    # Deciding who may choose reads no slip.
    d =
      c.d
      |> put_in(["entities", "slip"], %{"plural" => "slips", "properties" => %{}})
      |> put_in(["relations", "slip"], %{
        "from" => ["box"],
        "to" => ["slip"]
      })
      |> put_in(["flow_runtime", "inputs", "components"], %{
        "slip" => %{
          "from" => ["box"],
          "to" => ["slip"],
          "component" => %{"key" => "SL-{key}"}
        }
      })
      |> put_in(["relations", "held_by"], %{"from" => ["slip"], "to" => ["clerk"]})
      |> put_in(["flow_runtime", "inputs", "roles", "holder"], "held_by")
      |> put_in(["flow_runtime", "inputs", "acl", "holder"], %{"update" => ["slip"]})

    {:ok, []} = Rela.create(c.rela, "slips", "SL-B-1", %{}, %{"held_by" => {"clerk", ["ada"]}})
    Process.put(:rela_reads, true)

    assert {:ok, %{"roles" => ["clerk"]}} = submit(%{c | d: d})
    assert_received {:rela_get, "boxes", "B-1"}
    refute_received {:rela_get, "slips", _}
  end

  defp restart(c, id, actor \\ "ada", sender \\ "control/session-test", target \\ "R-1") do
    FlowInputs.write(
      c.rela,
      c.d,
      %{Envelope.new("fact", "choice") | sender: sender},
      %{"op" => "restart", "by" => actor, "values" => %{"run" => target, "request_id" => id}},
      fn -> @now end,
      c.position,
      c.write
    )
  end

  defp restart_context(c) do
    selection = %{
      "sort" => %{
        "subject" => "box",
        "restart_by" => ["owner", "checker"],
        "projection" => %{"owner_relation" => "chosen_by"}
      }
    }

    d =
      c.d
      |> put_in(["flow_runtime", "selection"], selection)
      |> Map.put("actors", %{"checker" => "bea"})

    %{c | d: d}
  end

  test "restart requires a completed run and trusted owner or configured actor", c do
    c = restart_context(c)
    assert {:error, :not_completed} = restart(c, "restart-1")
    {:ok, old} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(c.rela, "cursors", "R-1", %{"status" => "completed"}, old.version, %{})

    assert {:error, :input_authority} = restart(c, "restart-1", "ada", "client")
    assert {:error, :not_named_to_restart} = restart(c, "restart-1", "stranger")
    assert {:ok, []} = Rela.list(c.rela, "choices")
    assert {:ok, owner} = restart(c, "restart-1")
    assert owner["roles"] == ["restart"] and owner["status"] == "applied"
    assert {:ok, _} = restart(c, "restart-2", "bea")

    assert {:ok, _} =
             restart(%{c | d: Map.put(c.d, "actors", %{checker: "bea"})}, "restart-3", "bea")

    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "none"
  end

  test "completed restart reads retain obsolete prepared choices without applying them", c do
    c = restart_context(c)

    assert {:error, :interrupted} =
             submit(c, nil, "ada", "control/session-test", fn _, _, _ ->
               {:error, :interrupted}
             end)

    assert {:ok, [prepared]} = Rela.list(c.rela, "choices")
    {:ok, old} = Rela.get(c.rela, "cursors", "R-1")

    assert {:ok, []} =
             Rela.change(c.rela, "cursors", "R-1", %{"status" => "completed"}, old.version, %{})

    assert {:ok, intent} = restart(c, "restart-after-choice")

    assert {:ok, %{"inputs" => [obsolete, ^intent]}} =
             FlowInputs.read(
               c.rela,
               c.d,
               %{sender: "flow"},
               %{"run" => "R-1"},
               fn -> @now end,
               c.position,
               c.write
             )

    assert obsolete["key"] == prepared.key
    assert obsolete["status"] == "prepared"
    assert obsolete["actor"] == "ada" and obsolete["roles"] == ["clerk"]
    assert {:ok, ^prepared} = Rela.get(c.rela, "choices", prepared.key)
    assert {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.properties["choice"] == "none"
  end

  test "completed reads preserve applied and consumed actor and role history", c do
    assert {:ok, first} = submit(c)
    {:ok, run} = Rela.get(c.rela, "cursors", "R-1")

    assert {:ok, []} =
             Rela.change(
               c.rela,
               "cursors",
               "R-1",
               %{
                 "last_input" => JSON.encode!(%{"version" => 1, "input" => first["key"]}),
                 "input_cursor" => first["position"]
               },
               run.version,
               %{}
             )

    assert {:ok, consumed} =
             FlowInputs.write(
               c.rela,
               c.d,
               %{sender: "flow"},
               %{"op" => "consume", "key" => first["key"], "run" => "R-1"},
               fn -> @now end,
               c.position,
               c.write
             )

    {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    next = Map.merge(c.v, %{"request_id" => "choice-2", "source_version" => subject.version})
    assert {:ok, applied} = submit(c, next)
    assert consumed["status"] == "consumed" and applied["status"] == "applied"
    assert consumed["actor"] == "ada" and consumed["roles"] == ["clerk"]
    assert applied["actor"] == "ada" and applied["roles"] == ["clerk"]
    {:ok, current} = Rela.get(c.rela, "cursors", "R-1")

    assert {:ok, []} =
             Rela.change(
               c.rela,
               "cursors",
               "R-1",
               %{"status" => "completed"},
               current.version,
               %{}
             )

    assert {:ok, %{"inputs" => [^consumed, ^applied], "run" => "R-1"}} =
             FlowInputs.read(
               c.rela,
               c.d,
               %{sender: "flow"},
               %{"run" => "R-1"},
               fn -> @now end,
               c.position,
               %{c.write | apply: fn _, _, _ -> flunk("completed read applied a choice") end}
             )
  end

  test "restart replay stays bound to its original generation after the next one starts", c do
    c = restart_context(c)
    {:ok, old} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.change(c.rela, "cursors", "R-1", %{"status" => "completed"}, old.version, %{})

    assert {:ok, first} = restart(c, "restart-1")

    {:ok, []} =
      Rela.create(c.rela, "cursors", "R-2", Map.put(old.properties, "generation", 2), %{})

    assert {:ok, ^first} = restart(c, "restart-1")
    assert {:error, :input_moved_on} = restart(c, "new-request")
    assert {:error, :request_conflict} = restart(c, "restart-1", "bea")

    assert {:error, :request_conflict} =
             restart(c, "restart-1", "ada", "control/session-test", "R-2")
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

  test "the run writer's own change of a choice field is no input; anyone else's still is", c do
    d =
      put_in(c.d, ["flow_runtime", "selection"], %{
        "sort" => %{"subject" => "box", "choices" => ["choice"]}
      })

    # A pass's answer, written by Flow for the owner it names: the output of a transition
    # its run took, left to the kind's rules (who may set the relation) as any change is.
    content = %{
      "op" => "change",
      "key" => "B-1",
      "by" => "flow",
      "values" => %{"choice" => "yes"},
      "links" => %{"chosen_by" => ["ada"]}
    }

    e = %{Envelope.new("fact", "box", id: "answered") | sender: "flow"}
    assert FlowInputs.capture(c.rela, d, e, content) == :ordinary

    # The writer's name is no authority from another sender, nor is the sender's from
    # another configured writer.
    assert {:error, :input_authority} =
             FlowInputs.capture(c.rela, d, %{e | sender: "flow/passes"}, content)

    other = put_in(d, ["flow_runtime", "writer", "sender"], "elsewhere")
    assert {:error, :input_authority} = FlowInputs.capture(c.rela, other, e, content)
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

    # The private fixture wrote directly to the backend, past Facts.
    :ok = AtlasFacts.Server.reload(facts)

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

  # -- Pickup and hand-over (work acquisition design 2026-11-17, §5.6) ------------------
  # A clerk supervises a sort run (`watched_by`, cursor → clerk) while it is at `open`, the
  # one state of its span. Facts keeps the request; Flow alone moves the link.

  @supervision_record ~w(flow subject_kind subject_key generation entry run request_id actor source_version subject_version operation roles changed_fields links payload_digest status position prepared_at applied_at key)

  defp supervised(c, opts \\ []) do
    d =
      c.d
      |> put_in(["relations", "watched_by"], %{
        "from" => ["cursor"],
        "to" => ["clerk"],
        "max_outgoing" => 1
      })
      |> put_in(
        ["flow_runtime", "inputs", "fields"],
        Map.new(FlowInputs.fields() ++ ~w(operation hand_to), &{&1, &1})
      )
      |> put_in(["flow_runtime", "supervision"], %{
        "version" => 1,
        "relation" => "watched_by",
        "inputs" => %{
          "operation" => "operation",
          "operations" => ~w(pickup hand_over),
          "hand_to" => "hand_to"
        },
        "spans" => %{
          "sort" => [%{"name" => "desk", "label" => "Desk", "states" => ["open"], "with" => []}]
        }
      })

    {:ok, []} = Rela.create(c.rela, "clerks", "bea", %{}, %{})
    put_run(c, "R-1", Keyword.get(opts, :state, "open"), Keyword.get(opts, :supervisor, []))
    %{c | d: d}
  end

  defp put_run(c, key, state, supervisor, values \\ %{}) do
    {:ok, run} = Rela.get(c.rela, "cursors", key)

    {:ok, []} =
      Rela.change(c.rela, "cursors", key, Map.put(values, "state", state), run.version, %{
        "watched_by" => {"clerk", supervisor}
      })
  end

  defp acquire(c, op, values, actor \\ "ada", sender \\ "control/session-test") do
    FlowInputs.write(
      c.rela,
      c.d,
      %{Envelope.new("fact", "choice") | sender: sender},
      %{"op" => op, "by" => actor, "values" => values},
      fn -> @now end,
      c.position,
      c.write
    )
  end

  defp pickup(c, id \\ "pick-1", actor \\ "ada", sender \\ "control/session-test"),
    do: acquire(c, "pickup", %{"run" => "R-1", "request_id" => id}, actor, sender)

  defp hand_over(c, to, id \\ "hand-1", actor \\ "ada"),
    do: acquire(c, "hand_over", %{"run" => "R-1", "request_id" => id, "hand_to" => to}, actor)

  defp stored(c),
    do: for(f <- elem(Rela.list(c.rela, "choices"), 1), do: f.key)

  test "a pickup is kept applied with the full record, bound to the run; nothing else moves",
       c do
    c = supervised(c)
    {:ok, before} = Rela.get(c.rela, "boxes", "B-1")
    {:ok, run_before} = Rela.get(c.rela, "cursors", "R-1")

    assert {:ok, input} = pickup(c)
    assert Enum.sort(Map.keys(input)) == Enum.sort(@supervision_record)
    {:ok, run} = Rela.get(c.rela, "cursors", "R-1")

    for slot <- ~w(flow subject_kind subject_key generation entry),
        do: assert(input[slot] == run.properties[slot])

    assert input["run"] == "R-1" and input["actor"] == "ada"
    assert input["operation"] == "pickup" and input["roles"] == ["pickup"]
    assert input["changed_fields"] == %{} and input["links"] == %{}
    assert input["status"] == "applied"
    assert input["source_version"] == before.version
    assert input["subject_version"] == before.version
    assert is_binary(input["payload_digest"]) and is_integer(input["position"])
    assert is_binary(input["prepared_at"]) and is_binary(input["applied_at"])

    # As stored, as Flow reads it.
    flow = %{Envelope.new("read", "choice") | sender: "flow"}

    {:ok, %{"inputs" => [read]}} =
      FlowInputs.read(c.rela, c.d, flow, %{"run" => "R-1"}, nil, nil, nil)

    assert Map.take(read, @supervision_record) == input

    # No subject write, no link: the subject and the run are as they were.
    {:ok, subject} = Rela.get(c.rela, "boxes", "B-1")
    assert subject.version == before.version and subject.properties == before.properties
    assert run.version == run_before.version and run.links == run_before.links
  end

  test "an agent picks up on behalf of whom it assists; the input stays the agent's", c do
    c = supervised(c)
    assert {:error, :not_a_person} = pickup(c, "pick-1", "helper")
    Application.put_env(:atlas, :assists, %{"helper" => "ada"})
    on_exit(fn -> Application.delete_env(:atlas, :assists) end)

    assert {:ok, %{"actor" => "helper", "operation" => "pickup"}} = pickup(c, "pick-1", "helper")
  end

  test "a hand-over by the supervisor is kept with whom it is handed to", c do
    c = supervised(c, supervisor: ["ada"])
    assert {:ok, input} = hand_over(c, "bea")

    assert Enum.sort(Map.keys(input)) == Enum.sort(["hand_to" | @supervision_record])
    assert input["operation"] == "hand_over" and input["roles"] == ["hand_over"]
    assert input["hand_to"] == "bea" and input["actor"] == "ada"
    assert input["changed_fields"] == %{} and input["status"] == "applied"
    {:ok, run} = Rela.get(c.rela, "cursors", "R-1")
    assert run.links["watched_by"] == ["ada"]
  end

  test "each guard of a pickup refuses with its own reason, storing nothing", c do
    c = supervised(c)
    v = %{"run" => "R-1", "request_id" => "pick-1"}

    assert {:error, :input_authority} = pickup(c, "pick-1", "ada", "client")
    assert {:error, :input_authority} = pickup(c, "pick-1", "ada", "control/other")
    assert {:error, :input_authority} = pickup(c, "pick-1", "")
    assert {:error, :input_shape} = acquire(c, "pickup", Map.put(v, "hand_to", "bea"))
    assert {:error, :input_shape} = acquire(c, "pickup", Map.delete(v, "request_id"))
    assert {:error, :input_shape} = acquire(c, "pickup", %{v | "request_id" => ""})

    assert {:error, :input_shape} =
             FlowInputs.write(
               c.rela,
               c.d,
               %{Envelope.new("fact", "choice") | sender: "control/session-test"},
               %{"op" => "pickup", "by" => "ada", "values" => v, "extra" => 1},
               fn -> @now end,
               c.position,
               c.write
             )

    assert {:error, :unknown_run} = acquire(c, "pickup", %{v | "run" => "R-9"})
    assert {:error, :not_a_person} = pickup(c, "pick-1", "nobody")
    assert {:error, :not_a_person} = pickup(c, "pick-1", "B-1")

    undeclared = %{c | d: Map.update!(c.d, "flow_runtime", &Map.delete(&1, "supervision"))}
    assert {:error, :supervision_undeclared} = pickup(undeclared)

    put_run(c, "R-1", "shut", [])
    assert {:error, :outside_span} = pickup(c)

    other =
      put_in(c.d, ["flow_runtime", "supervision", "spans"], %{"pack" => [%{"states" => ["open"]}]})

    put_run(c, "R-1", "open", [])
    assert {:error, :outside_span} = pickup(%{c | d: other})

    put_run(c, "R-1", "open", [], %{"status" => "completed"})
    assert {:error, :not_active} = pickup(c)
    put_run(c, "R-1", "open", [], %{"status" => "active"})

    put_run(c, "R-1", "open", ["bea"])
    assert {:error, :already_supervised} = pickup(c)
    put_run(c, "R-1", "open", [])

    {:ok, []} =
      Rela.create(
        c.rela,
        "cursors",
        "R-2",
        %{"flow" => "sort", "subject_kind" => "box", "subject_key" => "B-1", "generation" => 2},
        %{}
      )

    assert {:error, :input_moved_on} = pickup(c)
    assert stored(c) == []
  end

  test "a second pickup of the same run waits for the first to be consumed", c do
    c = supervised(c)
    assert {:ok, first} = pickup(c, "pick-1")
    assert {:error, :pickup_pending} = pickup(c, "pick-2", "bea")
    assert stored(c) == [first["key"]]
  end

  test "a pending pickup holds back only its own run, and only until it is consumed", c do
    c = supervised(c)

    # A second active run, in its span, on another subject.
    {:ok, []} = Rela.create(c.rela, "boxes", "B-2", %{"choice" => "none"}, %{})
    {:ok, r1} = Rela.get(c.rela, "cursors", "R-1")

    {:ok, []} =
      Rela.create(c.rela, "cursors", "R-2", %{r1.properties | "subject_key" => "B-2"}, %{})

    assert {:ok, first} = pickup(c, "pick-1")
    assert {:ok, other} = acquire(c, "pickup", %{"run" => "R-2", "request_id" => "pick-2"})
    assert other["run"] == "R-2"
    assert {:error, :pickup_pending} = pickup(c, "pick-3", "bea")

    # Flow consumes the first pickup without linking (a refusal); R-1 is still unsupervised.
    status = c.d["flow_runtime"]["inputs"]["fields"]["status"]
    {:ok, fact} = Rela.get(c.rela, "choices", first["key"])

    {:ok, []} =
      Rela.change(c.rela, "choices", fact.key, %{status => "consumed"}, fact.version, %{})

    assert {:ok, again} = pickup(c, "pick-3", "bea")
    assert again["run"] == "R-1" and again["status"] == "applied"
    assert Enum.sort(stored(c)) == Enum.sort([first["key"], other["key"], again["key"]])
  end

  test "each guard of a hand-over refuses with its own reason, storing nothing", c do
    c = supervised(c, supervisor: ["ada"])
    v = %{"run" => "R-1", "request_id" => "hand-1", "hand_to" => "bea"}

    assert {:error, :input_shape} = acquire(c, "hand_over", Map.delete(v, "hand_to"))
    assert {:error, :input_shape} = acquire(c, "hand_over", Map.put(v, "note", "x"))
    assert {:error, :not_supervisor} = hand_over(c, "ada", "hand-1", "bea")
    assert {:error, :hand_to_self} = hand_over(c, "ada")
    assert {:error, :hand_to_not_a_person} = hand_over(c, "nobody")
    assert {:error, :hand_to_not_a_person} = hand_over(c, "B-1")
    assert {:error, :not_a_person} = hand_over(c, "bea", "hand-1", "nobody")
    put_run(c, "R-1", "shut", ["ada"])
    assert {:error, :outside_span} = hand_over(c, "bea")
    assert stored(c) == []
  end

  test "a retry is kept for the supervisor, or an agent that assists them; anyone else is refused",
       c do
    c = supervised(c, supervisor: ["ada"])
    retry = &acquire(c, "retry", %{"run" => "R-1", "request_id" => &1}, &2)

    assert {:error, :not_supervising} = retry.("retry-1", "bea")
    assert {:error, :not_a_person} = retry.("retry-1", "helper")
    Application.put_env(:atlas, :assists, %{"helper" => "ada"})
    on_exit(fn -> Application.delete_env(:atlas, :assists) end)

    assert {:ok, input} = retry.("retry-1", "helper")
    assert input["operation"] == "retry" and input["roles"] == ["retry"]
    assert input["actor"] == "helper" and input["status"] == "applied"
    put_run(c, "R-1", "shut", ["ada"])
    assert {:error, :outside_span} = retry.("retry-2", "ada")
    assert stored(c) == [input["key"]]
  end

  test "the same request is kept once; the same id with other content is a conflict", c do
    c = supervised(c)
    assert {:ok, first} = pickup(c, "pick-1")
    assert {:ok, again} = pickup(c, "pick-1")
    assert Map.take(again, Map.keys(first)) == first
    assert {:error, :request_conflict} = pickup(c, "pick-1", "bea")
    assert {:error, :request_conflict} = hand_over(c, "bea", "pick-1")
    assert stored(c) == [first["key"]]
  end

  test "restart and submit refuse what a pickup carries, as before", c do
    c = supervised(c)

    assert {:error, :input_authority} =
             acquire(c, "restart", %{"run" => "R-1", "request_id" => "r", "hand_to" => "bea"})

    assert {:error, :protected_operation_required} =
             acquire(c, "pick_up", %{"run" => "R-1", "request_id" => "r"})
  end

  test "every refusal of a pickup, hand-over or retry reads as sentences", c do
    for reason <-
          ~w(input_shape supervision_undeclared unknown_run not_active outside_span not_a_person already_supervised pickup_pending not_supervisor not_supervising hand_to_self hand_to_not_a_person)a do
      assert [sentence] = FlowInputs.reasons(reason, c.d)
      assert is_binary(sentence)
      refute sentence =~ Atom.to_string(reason)
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
