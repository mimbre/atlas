defmodule AtlasControl.TaskPagesTest do
  # Flow Engine plan §5 F5 (F5a): Control's task view, read through Flow's `tasks`
  # contract. The pages render what the facade answers (a stand-in with Flow's outcome
  # structs), and a session reads them through the real facade, from its own process, on
  # Flow's records in Facts' stand-in. Read only: no page offers an action on a task.
  use ExUnit.Case, async: false

  alias AtlasControl.{FakeStore, Pages, TaskPages}
  alias AtlasFlow.Boundary.Tasks, as: Flow

  # Stands in for AtlasFlow.Boundary.Tasks: the answers the test put, and who asked.
  defmodule Stand do
    def put(answers), do: Process.put(__MODULE__, answers)

    def list_tasks(client, %{subject: subject}) do
      send(self(), {:asked, :list_tasks, client, subject})
      Process.get(__MODULE__)[:list_tasks]
    end

    def get_task(client, %{task_id: id}) do
      send(self(), {:asked, :get_task, client, id})
      Process.get(__MODULE__)[:get_task]
    end
  end

  defp attempts do
    [
      Flow.TaskAttempt.new!(%{
        attempt: 1,
        state: "crashed",
        result_kind: "crashed",
        harness: "claude",
        started_at: "2026-11-17T10:01:00Z"
      }),
      Flow.TaskAttempt.new!(%{
        attempt: 2,
        state: "completed",
        result_kind: "completed",
        machinery: "mac-mini",
        provider: "anthropic",
        configured_model: "claude-opus-5-5",
        reported_model: "claude-opus-5-5-20261101",
        conversation_id: "conv-2",
        slot: "slot-2",
        started_at: "2026-11-17T10:02:00Z",
        ended_at: "2026-11-17T10:02:30Z"
      })
    ]
  end

  defp author,
    do: %{
      task_id: "TK-PK-7-1",
      subject: "PK-7",
      kind: :author,
      role: :developer,
      profile: "deep_coding",
      state: "completed",
      work_id: "w-1",
      attempt: 2,
      result_kind: "completed",
      check: %{exit_status: 0, output_tail: "bin/check: all 12 job(s) passed"},
      answer: "Done: the boundary is in place.",
      result_fingerprints: ["csf_aaa"],
      based_on: [],
      base_revision: "rev_1",
      attempts: attempts()
    }

  defp tasks do
    [
      Flow.Task.new!(author()),
      Flow.Task.new!(%{
        task_id: "TK-PK-7-2",
        subject: "PK-7",
        kind: :fix,
        state: "completed",
        result_kind: "completed",
        check: %{exit_status: 1},
        result_fingerprints: [],
        based_on: [],
        attempts: []
      }),
      Flow.Task.new!(%{
        task_id: "TK-PK-7-3",
        subject: "PK-7",
        kind: :review,
        state: "waiting",
        result_fingerprints: [],
        based_on: [],
        attempts: []
      })
    ]
  end

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))
  defp pairs(block), do: Map.new(block["props"]["fields"], &{&1["label"], &1["value"]})

  # No item on a page offers an action, and no console action but the Details toggle.
  defp read_only!(page) do
    for block <- page.blocks, do: assert(block["props"]["actions"] in [nil, []], block["id"])
    for action <- Map.get(page, :console_actions, []), do: assert(action.keys == ["d"])
  end

  describe "the tasks of a subject" do
    test "an overview, then one row per task in Flow's order, opening the task" do
      Stand.put(list_tasks: Flow.Outcome.Tasks.new!(subject: "PK-7", tasks: tasks()))

      page =
        TaskPages.render(
          {:task_page, :tasks, %{kind: "package", key: "PK-7"}},
          %{key: "melle"},
          Stand
        )

      assert_received {:asked, :list_tasks, {"melle", [:read]}, "PK-7"}
      assert %{title: "Tasks of PK-7", back: "/k/package/PK-7"} = page

      # The fix's check failed: it needs attention; the review waits.
      assert pairs(block(page, "summary")) ==
               %{"Tasks" => "3", "Waiting" => "1", "Needs attention" => "1"}

      assert [
               %{
                 "label" => "TK-PK-7-1",
                 "detail" => "Author · completed · check passed",
                 "to" => "/tasks/TK-PK-7-1"
               },
               %{"label" => "TK-PK-7-2", "detail" => "Fix · completed · check failed (exit 1)"},
               %{
                 "label" => "TK-PK-7-3",
                 "detail" => "Review · waiting",
                 "to" => "/tasks/TK-PK-7-3"
               }
             ] = block(page, "tasks")["props"]["rows"]

      assert pairs(block(page, "details"))["TK-PK-7-1"] ==
               "profile deep_coding · attempt 2 · work w-1 · base rev_1 · attempts 2"

      read_only!(page)
    end

    test "a subject without tasks says so" do
      Stand.put(list_tasks: Flow.Outcome.Tasks.new!(subject: "PK-9", tasks: []))
      page = TaskPages.render({:task_page, :tasks, %{kind: "package", key: "PK-9"}}, %{}, Stand)
      assert_received {:asked, :list_tasks, {"control", [:read]}, "PK-9"}
      assert block(page, "tasks")["props"]["empty"] == "Flow has defined no task for PK-9."
      assert block(page, "tasks")["props"]["rows"] == []
    end

    test "Flow unavailable: the page says why, and shows no list" do
      Stand.put(list_tasks: Flow.Outcome.Unavailable.new!(message: "Facts did not answer"))
      page = TaskPages.render({:task_page, :tasks, %{kind: "package", key: "PK-7"}}, %{}, Stand)
      assert page.title == "Tasks unavailable"
      assert pairs(block(page, "task")) == %{"Reason" => "Facts did not answer"}
      assert block(page, "tasks") == nil
    end
  end

  describe "one task" do
    test "what it is and how it ended, every attempt, and the provenance in Details" do
      Stand.put(get_task: Flow.Outcome.Found.new!(author()))
      page = TaskPages.render({:task_page, :task, %{task: "TK-PK-7-1"}}, %{key: "melle"}, Stand)

      assert_received {:asked, :get_task, {"melle", [:read]}, "TK-PK-7-1"}
      # Back to the subject's tasks; Control finds the kind of PK-7 from its key.
      assert %{title: "Task TK-PK-7-1", back: "/k/_/PK-7/tasks"} = page

      assert block(page, "task")["props"]["title"] == "Author task TK-PK-7-1"

      assert pairs(block(page, "task")) == %{
               "State" => "completed",
               "Result" => "completed",
               "Check" => "check passed",
               "Attempt" => "2",
               "For" => "PK-7",
               "Role" => "developer",
               "Profile" => "deep_coding"
             }

      assert pairs(block(page, "task-attempts")) == %{
               "Attempt 1" => "crashed · started 17 Nov 2026 10:01:00 UTC",
               "Attempt 2" =>
                 "completed · claude-opus-5-5-20261101 · started 17 Nov 2026 10:02:00 UTC"
             }

      assert pairs(block(page, "task-answer")) == %{"Answer" => "Done: the boundary is in place."}

      assert pairs(block(page, "task-check")) == %{
               "Output tail" => "bin/check: all 12 job(s) passed"
             }

      record = pairs(block(page, "task-record"))
      assert record["Work"] == "w-1"
      assert record["Result fingerprints"] == "csf_aaa"
      assert record["Attempt 2 machinery"] == "mac-mini"
      assert record["Attempt 2 configured model"] == "claude-opus-5-5"
      assert record["Attempt 2 reported model"] == "claude-opus-5-5-20261101"
      assert record["Attempt 2 ended"] == "17 Nov 2026 10:02:30 UTC"
      refute Map.has_key?(record, "Based on")

      assert Enum.any?(page.markup, &(&1["props"]["title"] == "Details"))
      read_only!(page)
    end

    test "a task without attempts says none has started" do
      Stand.put(
        get_task:
          Flow.Outcome.Found.new!(%{
            task_id: "TK-PK-7-3",
            subject: "PK-7",
            kind: :review,
            state: "waiting",
            result_fingerprints: [],
            based_on: [],
            attempts: []
          })
      )

      page = TaskPages.render({:task_page, :task, %{task: "TK-PK-7-3"}}, %{}, Stand)
      assert pairs(block(page, "task-attempts")) == %{"Attempts" => "No attempt has started yet."}
      assert block(page, "task-answer") == nil
      assert block(page, "task-check") == nil
    end

    test "a task Flow has no record of" do
      Stand.put(get_task: %Flow.Outcome.NotFound{})
      page = TaskPages.render({:task_page, :task, %{task: "TK-PK-7-99"}}, %{}, Stand)
      assert page.title == "Task not found"
      assert pairs(block(page, "task")) == %{"Task" => "Flow has no task TK-PK-7-99."}
    end

    test "Flow unavailable" do
      Stand.put(get_task: Flow.Outcome.Unavailable.new!(message: "Facts did not answer"))
      page = TaskPages.render({:task_page, :task, %{task: "TK-PK-7-1"}}, %{}, Stand)
      assert page.title == "Tasks unavailable"
    end
  end

  test "the routes are the contract's pages" do
    assert Pages.route("/k/package/PK-7/tasks") ==
             {:task_page, :tasks, %{kind: "package", key: "PK-7"}}

    assert Pages.route("/tasks/TK-PK-7-1") == {:task_page, :task, %{task: "TK-PK-7-1"}}
    assert Pages.path({:task_page, :task, %{task: "TK-PK-7-1"}}) == "/tasks/TK-PK-7-1"
    assert Pages.kind_of({:task_page, :task, %{task: "TK-PK-7-1"}}) == nil
    refute Pages.form?({:task_page, :task, %{task: "TK-PK-7-1"}})
    assert Pages.reads({:task_page, :tasks, %{kind: "package", key: "PK-7"}}, nil) == []
  end

  test "Control names no part of Flow but its boundary facade (ADR 0006)" do
    for file <- Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__)),
        [name] <- Regex.scan(~r/AtlasFlow(?:Boundary)?\.[A-Za-z.]+/, File.read!(file)) do
      assert String.starts_with?(name, "AtlasFlow.Boundary.Tasks"), "#{file}: #{name}"
    end
  end

  describe "through a session and Flow's facade" do
    setup do
      Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
      start_supervised!(FakeStore)
      start_supervised!(AtlasControl.FakeFlow)

      start_supervised!(
        {AtlasControl.Gateway, port: 0, name: :tasks_gateway, model: AtlasControl.Shop}
      )

      on_exit(fn ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
            do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
      end)

      # Flow's records of a widget handed to machinery: one author task with one attempt.
      FakeStore.put("W-1", %{"title" => "A widget"}, "widget")

      FakeStore.put(
        "TK-W-1-1",
        %{"kind" => "author", "state" => "completed", "check_exit_status" => 0},
        "task",
        %{"task_of" => ["W-1"]}
      )

      FakeStore.put(
        "TA-TK-W-1-1-1",
        %{"state" => "completed", "reported_model" => "claude-opus-5-5"},
        "task_attempt",
        %{"attempt_of" => ["TK-W-1-1"], "ran_on" => ["mac-mini"]}
      )

      %{port: AtlasControl.Gateway.port(:tasks_gateway)}
    end

    defp connect(port) do
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [
          :binary,
          packet: :line,
          active: false,
          buffer: 4_194_304
        ])

      send_line(socket, %{
        "op" => "hello",
        "env" => "test",
        "client" => "test",
        "spec" => AtlasControl.Blocks.version()
      })

      socket
    end

    defp send_line(socket, message),
      do: :ok = :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

    defp page(socket, path) do
      {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
      message = JSON.decode!(line)

      if message["op"] == "page" and message["path"] == path,
        do: message,
        else: page(socket, path)
    end

    test "opening a subject's tasks and a task reads them from Flow", %{port: port} do
      socket = connect(port)
      on_exit(fn -> :gen_tcp.close(socket) end)

      send_line(socket, %{"op" => "open", "to" => "/k/widget/W-1/tasks"})
      tasks = page(socket, "/k/widget/W-1/tasks")

      assert [%{"label" => "TK-W-1-1", "detail" => "Author · completed · check passed"}] =
               Enum.find(tasks["blocks"], &(&1["id"] == "tasks"))["props"]["rows"]

      send_line(socket, %{"op" => "open", "to" => "/tasks/TK-W-1-1"})
      task = page(socket, "/tasks/TK-W-1-1")
      attempts = Enum.find(task["blocks"], &(&1["id"] == "task-attempts"))

      assert [%{"label" => "Attempt 1", "value" => "completed · claude-opus-5-5"}] =
               attempts["props"]["fields"]

      # Control wrote nothing: the view only reads.
      assert FakeStore.sent() == []
    end
  end
end
