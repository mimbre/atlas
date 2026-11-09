defmodule AtlasAgent.SteerTest do
  # `atlas steer` behind the TUI's `:` (UC-Atlas-17/18/19), against an in-process Control
  # and a planner command that answers what the test wrote. ATLAS_ENV_FILE is global.
  use ExUnit.Case, async: false

  alias AtlasAgent.FakeControl

  @kinds [
    %{
      kind: "scene",
      title: "Scene",
      prefix: "SC-",
      asks: ~w(title description),
      required: ["title"],
      list_title: "Scenes"
    },
    %{
      kind: "use_case",
      title: "Use case",
      prefix: "UC-",
      under: "scene",
      asks: ~w(title description),
      required: ["title"],
      list_title: "Use cases"
    },
    %{
      kind: "agent_request",
      title: "Agent request",
      prefix: "RQ-",
      asks: ~w(title page planner outcome summary before overrules),
      list_title: "Agent requests",
      record: "request"
    },
    %{
      kind: "agent_step",
      title: "Agent step",
      prefix: "ST-",
      under: "agent_request",
      asks: ~w(title n tool state detail made values was),
      list_title: "Steps",
      record: "step"
    }
  ]

  setup context do
    control = FakeControl.start(context[:kinds] || @kinds, refuse: context[:refuse])
    tmp = Path.join(System.tmp_dir!(), "atlas-steer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    script = Path.join(tmp, "planner.sh")

    # The first plan from plan.json; a plan after a refusal (its input has "before") from
    # after.json.
    File.write!(script, """
    #!/bin/sh
    if grep -q '"before"'; then cat '#{tmp}/after.json'; else cat '#{tmp}/plan.json'; fi
    """)

    File.chmod!(script, 0o755)

    agent =
      Map.merge(%{"planner" => [script], "name" => "a test planner"}, context[:agent] || %{})

    FakeControl.use_env_file(control, %{"agent" => agent})
    %{control: control, tmp: tmp}
  end

  defp planner(tmp, steps, file \\ "plan.json"),
    do:
      File.write!(
        Path.join(tmp, file),
        JSON.encode!(%{"summary" => "as asked", "steps" => steps})
      )

  defp put_uc(scene, title),
    do: %{"tool" => "put", "kind" => "use_case", "in" => scene, "values" => %{"title" => title}}

  # Starts the agent with a fake stdin/stdout: lines go in with `say/2`, what it prints
  # arrives as {:steer, message}.
  defp steer do
    test = self()
    io = spawn_link(fn -> device(test, [], nil) end)

    agent =
      spawn_link(fn ->
        Process.group_leader(self(), io)
        send(test, {:exit, AtlasAgent.Steer.main("test")})
      end)

    %{io: io, agent: agent}
  end

  defp say(steer, message), do: send(steer.io, {:input, JSON.encode!(message) <> "\n"})

  # The next plan block in `state`; earlier ones are passed over, and kept in order in
  # the process dictionary under :seen.
  defp plan(state) do
    receive do
      {:steer, %{"op" => "plan", "block" => %{"props" => %{"state" => ^state} = props}}} ->
        seen(props)
        props

      {:steer, %{"op" => "plan", "block" => %{"props" => %{"title" => "No plan"} = props}}} ->
        flunk("no plan: #{props["summary"]}")

      {:steer, %{"op" => "plan", "block" => %{"props" => props}}} ->
        seen(props)
        plan(state)

      {:steer, %{"op" => "notice"} = notice} ->
        flunk("notice: #{inspect(notice)}")
    after
      5_000 -> flunk("no #{state} plan; seen: #{inspect(Process.get(:seen))}")
    end
  end

  defp seen(props), do: Process.put(:seen, (Process.get(:seen) || []) ++ [props["title"]])

  defp step(props, n), do: Enum.find(props["steps"], &(&1["n"] == n))

  # A minimal IO server: get_line answers the next input line (waiting for one). When the
  # reader asks again, the line it got before is with the agent: the test is told
  # {:consumed, line}.
  defp device(test, lines, waiting, last \\ nil) do
    receive do
      {:io_request, from, ref, request} ->
        case request do
          {:put_chars, _enc, chars} ->
            emit(test, chars)
            send(from, {:io_reply, ref, :ok})
            device(test, lines, waiting, last)

          get when elem(get, 0) == :get_line ->
            if last, do: send(test, {:consumed, last})

            case lines do
              [line | rest] ->
                send(from, {:io_reply, ref, line})
                device(test, rest, nil, line)

              [] ->
                device(test, [], {from, ref}, nil)
            end

          _ ->
            send(from, {:io_reply, ref, {:error, :request}})
            device(test, lines, waiting, last)
        end

      {:input, line} ->
        case waiting do
          {from, ref} ->
            send(from, {:io_reply, ref, line})
            device(test, lines, nil, line)

          nil ->
            device(test, lines ++ [line], nil, last)
        end
    end
  end

  defp emit(test, chars) do
    for line <- chars |> IO.chardata_to_string() |> String.split("\n", trim: true),
        do: send(test, {:steer, JSON.decode!(line)})
  end

  # The writes other than the agent's own record.
  defp written(control), do: Enum.reject(FakeControl.writes(control), &record?/1)

  defp record?(%{"params" => %{"kind" => kind}}), do: kind in ~w(agent_request agent_step)
  defp record?(%{"params" => %{"key" => "RQ-" <> _}}), do: true
  defp record?(_write), do: false

  defp request(control), do: control |> FakeControl.facts("agent_request") |> List.last()

  describe "asking" do
    test "a step a form does not ask for is flagged, and cannot run", %{control: c, tmp: tmp} do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})

      planner(tmp, [
        %{
          "tool" => "put",
          "kind" => "use_case",
          "in" => scene,
          "values" => %{"title" => "Red", "colour" => "red"}
        }
      ])

      s = steer()
      say(s, %{"op" => "ask", "request" => "colour it red", "on" => "/k/scene/#{scene}"})

      plan = plan("proposed")
      assert plan["title"] == "Proposed: 1 step"
      assert %{"state" => "blocked", "detail" => detail} = step(plan, 1)
      assert detail =~ "does not ask for colour"

      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})

      assert_receive {:steer,
                      %{
                        "op" => "notice",
                        "tone" => "error",
                        "text" => "Step 1 cannot run; drop it first."
                      }}

      assert written(c) == []
    end

    test "a plan without steps says so and writes nothing", %{control: c, tmp: tmp} do
      planner(tmp, [])
      s = steer()
      say(s, %{"op" => "ask", "request" => "hello", "on" => "/"})
      assert plan("proposed")["title"] == "No steps proposed"
      assert written(c) == []
    end

    test "one step runs without asking; three steps ask", %{control: c, tmp: tmp} do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})

      planner(tmp, [
        %{"tool" => "set", "key" => scene, "values" => %{"title" => "A renamed scene"}}
      ])

      s = steer()
      say(s, %{"op" => "ask", "request" => "rename it", "on" => scene})

      assert plan("done")["title"] == "Done: 1 of 1 stored, without asking"
      assert FakeControl.fact(c, scene).values["title"] == "A renamed scene"
      assert request(c).values["outcome"] == "done_without_asking"

      planner(tmp, for(t <- ~w(One Two Three), do: put_uc(scene, t)))
      say(s, %{"op" => "ask", "request" => "add three", "on" => scene})
      assert plan("proposed")["title"] == "Proposed: 3 steps"
      assert FakeControl.facts(c, "use_case") == []
    end

    @tag agent: %{"ask_above" => 3}
    test "a delete always asks, even of one step within the limit", %{control: c, tmp: tmp} do
      scene = FakeControl.put(c, "scene", %{"title" => "Gone soon"})
      planner(tmp, [%{"tool" => "delete", "key" => scene}])
      s = steer()
      say(s, %{"op" => "ask", "request" => "delete it", "on" => scene})

      assert plan("proposed")["title"] == "Proposed: 1 step"
      assert FakeControl.fact(c, scene)

      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})
      assert plan("done")["title"] == "Done: 1 of 1 stored"
      assert FakeControl.fact(c, scene) == nil
    end
  end

  describe "running" do
    test "each step shows as it runs; the plan ends done", %{control: c, tmp: tmp} do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "two", "on" => scene})
      plan("proposed")
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}, %{"n" => 2}]})

      done = plan("done")
      assert done["title"] == "Done: 2 of 2 stored"
      assert "Running: 0 of 2 stored" in Process.get(:seen)
      assert "Running: 1 of 2 stored" in Process.get(:seen)
      assert step(done, 1)["detail"] == "Stored as UC-01."
      assert Enum.map(FakeControl.facts(c, "use_case"), & &1.parent) == [scene, scene]
    end

    test "a stop ends the run before its next step; what was stored stays", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two"), put_uc(scene, "Three")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "three", "on" => scene})
      plan("proposed")

      # Step 1 is held in Control until the stop is with the agent.
      FakeControl.hold(c, "One")
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]})
      assert_receive {:held, server}, 5_000
      say(s, %{"op" => "stop"})
      assert_receive {:consumed, ~s|{"op":"stop"}\n|}, 5_000
      FakeControl.release(server)

      stopped = plan("stopped")
      assert stopped["title"] == "Stopped: 1 of 3 stored"
      assert step(stopped, 1)["state"] == "stored"
      assert %{"state" => "not_run", "detail" => "Not run: stopped before it."} = step(stopped, 2)
      assert step(stopped, 3)["state"] == "not_run"
      assert Enum.map(FakeControl.facts(c, "use_case"), & &1.values["title"]) == ["One"]
      assert request(c).values["outcome"] == "stopped"
    end

    @tag refuse: &__MODULE__.refuse_two/1
    test "a refused step stops the run; the new plan says what was stored and not run", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two"), put_uc(scene, "Three")])
      planner(tmp, [put_uc(scene, "Three")], "after.json")
      s = steer()
      say(s, %{"op" => "ask", "request" => "three", "on" => scene})
      plan("proposed")
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]})

      failed = plan("failed")
      assert failed["title"] == "Refused: 1 of 3 stored"
      assert step(failed, 2)["state"] == "refused"
      assert step(failed, 3)["detail"] == "Not run: an earlier step was refused."

      again = plan("proposed")
      assert again["title"] == "Proposed: 1 step"
      assert again["before"] =~ ~r/^Step 2 \(.*\) was refused: title is required\./
      assert again["before"] =~ "Stored before it: step 1."
      assert again["before"] =~ "Not run: step 3."
      # Never retried by itself: only step 1 was stored.
      assert Enum.map(FakeControl.facts(c, "use_case"), & &1.values["title"]) == ["One"]

      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})
      assert plan("done")["title"] == "Done: 1 of 1 stored"
      assert Enum.map(FakeControl.facts(c, "use_case"), & &1.values["title"]) == ["One", "Three"]
    end

    test "a target gone before the run: nothing stored, and the new plan says it is no scene", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One")], "after.json")
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "two", "on" => "/"})
      plan("proposed")
      # Another client deletes the scene after the plan was checked.
      FakeControl.delete(c, scene)
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}, %{"n" => 2}]})

      assert step(plan("failed"), 1)["detail"] == "#{scene} does not exist"
      again = plan("proposed")
      assert again["before"] =~ "was refused: #{scene} does not exist."
      assert again["before"] =~ "Nothing was stored."
      assert step(again, 1)["detail"] == "#{scene} is not a scene in Atlas"
      assert step(again, 1)["state"] == "blocked"
      assert FakeControl.facts(c, "use_case") == []
    end
  end

  def refuse_two(%{"endpoint" => "create", "values" => %{"title" => "Two"}}),
    do: ["title is required"]

  def refuse_two(_), do: nil

  describe "the record" do
    test "the request and each step are kept: what it made, the values, dropped steps", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "Kept"), put_uc(scene, "Dropped")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "two\nplease", "on" => "/k/scene/#{scene}"})
      plan("proposed")
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})
      assert plan("done")["title"] == "Done: 1 of 1 stored"

      request = request(c)
      assert request.values["title"] == "two"
      assert request.values["planner"] == "a test planner"
      assert request.values["page"] == "/k/scene/#{scene}"
      assert request.values["outcome"] == "done"

      assert [^request] = FakeControl.facts(c, "agent_request")
      steps = FakeControl.facts(c, "agent_step")
      assert length(steps) == 2
      assert Enum.all?(steps, &(&1.parent == request.key))

      [stored] = for st <- steps, st.values["state"] == "stored", do: st
      assert stored.values["made"] == "UC-01"
      assert stored.values["tool"] == "put"
      assert JSON.decode!(stored.values["values"]) == %{"title" => "Kept"}

      [dropped] = for st <- steps, st.values["state"] == "dropped", do: st
      assert dropped.values["made"] == ""
      assert dropped.values["n"] == "2"
    end

    test "a cancelled request is kept as cancelled, and nothing else is written", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "two", "on" => scene})
      plan("proposed")
      say(s, %{"op" => "cancel"})

      assert plan("cancelled")["title"] == "Cancelled; nothing was written"
      assert request(c).values["outcome"] == "cancelled"
      assert written(c) == []
    end

    test "an overrule always asks, undoes the step and names the request it overrules", %{
      control: c,
      tmp: tmp
    } do
      scene = FakeControl.put(c, "scene", %{"title" => "A scene"})
      planner(tmp, [put_uc(scene, "One"), put_uc(scene, "Two")])
      s = steer()
      say(s, %{"op" => "ask", "request" => "two", "on" => scene})
      plan("proposed")
      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})
      plan("done")

      [first] = FakeControl.facts(c, "agent_request")

      [stored] =
        for st <- FakeControl.facts(c, "agent_step"), st.values["state"] == "stored", do: st

      say(s, %{
        "op" => "ask",
        "intent" => "overrule",
        "request" => "overrule",
        "on" => "/k/agent_step/#{stored.key}"
      })

      overrule = plan("proposed")
      assert overrule["title"] == "Proposed: 1 step"
      assert step(overrule, 1)["label"] =~ "UC-01"

      say(s, %{"op" => "run", "steps" => [%{"n" => 1}]})
      assert plan("done")["title"] == "Done: 1 of 1 stored"
      assert FakeControl.fact(c, "UC-01") == nil

      [_first, second] = FakeControl.facts(c, "agent_request")
      assert second.values["overrules"] == first.key
    end
  end
end
