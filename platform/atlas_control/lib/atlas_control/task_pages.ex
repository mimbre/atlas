defmodule AtlasControl.TaskPages do
  @moduledoc """
  The task view (Flow Engine plan §5 F5, F5a): where work handed to machinery is, read
  from Flow through its `tasks` contract (`AtlasFlow.Boundary.Tasks`, the facade Flow
  generates; ADR 0006: co-located systems call each other's boundary target). Control reads
  no task fact itself and names none of Flow's internals.

  - **Tasks of a subject** (`/k/:kind/:key/tasks`): an Overview of the counts, then one row
    per task in the order Flow defined it: what it is, where it is and how its check ended,
    opening the task. Each task's profile, work and base are in its technical details.
  - **A task** (`/tasks/:task`): what the task is and how its current attempt ended (its
    check, its verdict, its answer), then every attempt with what ran it; the full
    provenance is in the Details section.

  Read only: the pages offer no action on a task. Cancelling and retrying come with Flow's
  `steer` capabilities (F5b). When Flow cannot answer (Facts did not answer), the page says
  so, with the reason, and nothing else.

  `render/3` takes the facade as its last argument (default `AtlasFlow.Boundary.Tasks`), so
  a test can put a stand-in with the same functions and outcomes in its place.
  """
  alias AtlasControl.Pages
  alias AtlasFlow.Boundary.Tasks, as: Flow
  require AtlasControl.Blocks, as: Blocks

  @kinds %{
    plan: "Plan",
    author: "Author",
    review: "Review",
    fix: "Fix",
    diagnose: "Diagnose",
    native_check: "Native check"
  }

  def render(route, actor, flow \\ Flow)

  def render({:task_page, :tasks, %{kind: kind, key: key}}, actor, flow) do
    back = Pages.path({:item, kind, key})

    case flow.list_tasks(client(actor), %{subject: key}) do
      %Flow.Outcome.Tasks{tasks: tasks} ->
        summary =
          Pages.summary([
            {"Tasks", length(tasks)},
            {"Waiting", Enum.count(tasks, &(&1.state == "waiting"))},
            {"Needs attention", Enum.count(tasks, &attention?/1)}
          ])

        {details, markup} = Pages.technical_details(Enum.map(tasks, &technical_pair/1))

        page(
          "Tasks of #{key}",
          back,
          [
            {"summary", summary},
            {"tasks",
             Blocks.list(
               title: "Tasks",
               rows: Enum.map(tasks, &task_row/1),
               empty: "Flow has defined no task for #{key}."
             )}
          ] ++ details,
          markup
        )
        |> then(
          &if details == [], do: &1, else: Map.put(&1, :console_actions, [Pages.details_action()])
        )

      other ->
        error(other, back)
    end
  end

  def render({:task_page, :task, %{task: id}}, actor, flow) do
    case flow.get_task(client(actor), %{task_id: id}) do
      %Flow.Outcome.Found{} = task ->
        detail(task)

      %Flow.Outcome.NotFound{} ->
        page("Task not found", "/", [
          {"task",
           Blocks.item(
             title: "Task not found",
             fields: [Blocks.pair(label: "Task", value: "Flow has no task #{id}.")]
           )}
        ])

      other ->
        error(other, "/")
    end
  end

  # Flow is asked as the session's actor, to read.
  defp client(%{key: key}) when is_binary(key), do: {key, [:read]}
  defp client(_actor), do: {"control", [:read]}

  # -- Tasks of a subject ------------------------------------------------------------------

  defp task_row(task) do
    Blocks.row(
      label: task.task_id,
      detail: Enum.join(Enum.reject([kind(task), task.state, ending(task)], &is_nil/1), " · "),
      to: Pages.path({:task_page, :task, %{task: task.task_id}})
    )
  end

  defp technical_pair(task) do
    value =
      [
        {"profile", task.profile},
        {"attempt", task.attempt && Integer.to_string(task.attempt)},
        {"work", task.work_id},
        {"base", task.base_revision || task.base_id},
        {"attempts", Integer.to_string(length(task.attempts))}
      ]
      |> Enum.reject(fn {_, value} -> value in [nil, ""] end)
      |> Enum.map_join(" · ", fn {label, value} -> "#{label} #{value}" end)

    Blocks.pair(label: task.task_id, value: value)
  end

  # A task needs attention when its work ended otherwise than completed, or its check did
  # not pass.
  defp attention?(task),
    do: task.result_kind not in [nil, "completed"] or check_failed?(task.check)

  defp check_failed?(nil), do: false
  defp check_failed?(%{ending: ending}) when ending != nil, do: true
  defp check_failed?(%{exit_status: status}), do: status not in [nil, 0]

  # -- A task ------------------------------------------------------------------------------

  defp detail(task) do
    content =
      Blocks.item(
        title: "#{kind(task)} task #{task.task_id}",
        fields:
          fields([
            {"State", task.state},
            {"Result", task.result_kind},
            {"Reason", task.reason},
            {"Check", check(task.check)},
            {"Verdict", verdict(task.verdict)},
            {"Attempt", task.attempt && Integer.to_string(task.attempt)},
            {"For", task.subject},
            {"Role", task.role && Atom.to_string(task.role)},
            {"Profile", task.profile}
          ])
      )

    attempts =
      Blocks.item(
        title: "Attempts",
        fields:
          case task.attempts do
            [] -> [Blocks.pair(label: "Attempts", value: "No attempt has started yet.")]
            attempts -> Enum.map(attempts, &attempt_pair/1)
          end
      )

    answer =
      if present(task.answer),
        do: [
          {"task-answer",
           Blocks.item(
             title: "Answer",
             fields: [Blocks.pair(label: "Answer", value: task.answer)]
           )}
        ],
        else: []

    output =
      case task.check do
        %{output_tail: tail} when is_binary(tail) and tail != "" ->
          [
            {"task-check",
             Blocks.item(
               title: "Check output",
               fields: [Blocks.pair(label: "Output tail", value: tail)]
             )}
          ]

        _ ->
          []
      end

    record =
      Blocks.item(
        title: "Record",
        fields:
          fields(
            [
              {"Work", task.work_id},
              {"Base", task.base_id},
              {"Base snapshot", task.base_snapshot},
              {"Base revision", task.base_revision},
              {"Result fingerprints", list(task.result_fingerprints)},
              {"Based on", list(task.based_on)}
            ] ++ Enum.flat_map(task.attempts, &provenance/1)
          )
      )

    page(
      "Task #{task.task_id}",
      Pages.path({:task_page, :tasks, %{kind: "_", key: task.subject}}),
      [{"task", content}, {"task-attempts", attempts}] ++
        answer ++ output ++ [{"task-record", record}],
      [
        Blocks.part("task", "task-attempts", title: "Task", role: "main"),
        Blocks.section("task-record", "task-record", title: "Details", collapsible: true)
      ]
    )
    |> Map.put(:console_actions, [Pages.details_action()])
  end

  # One attempt in plain words: how it is, what ran it and when it started.
  defp attempt_pair(attempt) do
    model = attempt.reported_model || attempt.configured_model

    value =
      [
        attempt.state,
        attempt.result_kind != attempt.state && attempt.result_kind,
        model,
        moment(attempt.started_at) && "started #{moment(attempt.started_at)}"
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join(" · ")

    Blocks.pair(label: "Attempt #{attempt.attempt}", value: value)
  end

  # Every provenance field of an attempt, labelled with its number.
  defp provenance(attempt) do
    n = "Attempt #{attempt.attempt}"

    [
      {"#{n} machinery", attempt.machinery},
      {"#{n} provider", attempt.provider},
      {"#{n} harness", attempt.harness},
      {"#{n} harness version", attempt.harness_version},
      {"#{n} configured model", attempt.configured_model},
      {"#{n} reported model", attempt.reported_model},
      {"#{n} selection", attempt.selection_reason},
      {"#{n} conversation", attempt.conversation_id},
      {"#{n} machine", attempt.machine},
      {"#{n} slot", attempt.slot},
      {"#{n} turn", attempt.turn_id},
      {"#{n} started", moment(attempt.started_at)},
      {"#{n} ended", moment(attempt.ended_at)}
    ]
  end

  # -- Words -------------------------------------------------------------------------------

  defp kind(task), do: Map.get(@kinds, task.kind, Atom.to_string(task.kind))

  # How the check ended: "passed", "failed (exit 1)", "timed out".
  defp ending(%{check: check}), do: check(check)

  defp check(nil), do: nil
  defp check(%{ending: :timed_out}), do: "check timed out"
  defp check(%{ending: :cancelled}), do: "check cancelled"
  defp check(%{ending: :interrupted}), do: "check interrupted"
  defp check(%{exit_status: 0}), do: "check passed"
  defp check(%{exit_status: status}) when is_integer(status), do: "check failed (exit #{status})"
  defp check(_), do: nil

  defp verdict(:approved), do: "approved"
  defp verdict(:changes_required), do: "changes required"
  defp verdict(_), do: nil

  defp list([]), do: nil
  defp list(values), do: Enum.join(values, ", ")

  # A moment as a reader reads it, in UTC: 17 Nov 2026 10:02:00 UTC.
  defp moment(%DateTime{} = at),
    do: Calendar.strftime(DateTime.truncate(at, :second), "%-d %b %Y %H:%M:%S UTC")

  defp moment(_), do: nil

  defp present(value) when is_binary(value), do: String.trim(value) != ""
  defp present(_), do: false

  defp fields(pairs),
    do: for({label, value} <- pairs, value != nil, do: Blocks.pair(label: label, value: value))

  # Flow could not answer: why, in its words. Anything else (the facade refusing the
  # request) is no answer either.
  defp error(%Flow.Outcome.Unavailable{message: message}, back), do: unavailable(message, back)
  defp error(_refused, back), do: unavailable("Flow did not take the request", back)

  defp unavailable(reason, back),
    do:
      page("Tasks unavailable", back, [
        {"task",
         Blocks.item(
           title: "Tasks unavailable",
           fields: [Blocks.pair(label: "Reason", value: reason)]
         )}
      ])

  defp page(title, back, blocks, markup \\ []),
    do: Map.merge(%{title: title, back: back}, Blocks.view_model(blocks, markup))
end
