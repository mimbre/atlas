defmodule AtlasFlow.Landing do
  @moduledoc """
  Landing (F2/F3 plan rev 3 §3.2, F3-L): Flow's third process beside Dispatch and
  Delivery. It publishes a task's checked result as a Code draft review, and marks the
  draft ready once the review loop approved exactly the revision the draft is at and its
  CI is green. It is attached to the Bus as `flow/landing`, talks to Code through the
  publishing client (`AtlasFlow.Code.Client.publishing/0`), writes only task fields of
  its own (and a review task's `reviewed_revision`), and never writes a run.

  **Triggers.** The Engine casts `{:publish, task_key}` once a run stores a task result
  whose check passed (`publish/2`: a cast, so the Engine never waits on Landing or on
  Code; lesson 1). Landing also reads Facts at boot, and on its own timer (`every`, on the
  injected clock) while a draft of its is open, to read CI again. Each trigger reads Facts
  afresh (a sweep): what Landing knows of the packages is in Facts, and what it knows of
  a review is what Code answers, so a restarted Landing rebuilds from Facts alone.

  **What it works on.** The runs of every subflow with a task whose input is a Code
  repository (an author's: `input.repository`, and the reference its base is resolved
  from, `input.base`, which is also the branch the draft asks to land on). A subject's
  tasks are the facts its task spec records (`records`: kind and relation to the subject).

  **A sweep**, for each such subject:

  1. *Publish.* The newest author or fix task with a complete result, its check passed
     and no `published_revision`, newer than the last published one, goes to
     `AtlasFlow.Publish`: a draft review for the subject's first, or an update of its
     open review from the last published revision. The answer is recorded on the task:
     `code_change_id`, `review_id`, `review_url` (the review's link exactly as Code gave
     it), `published_revision` (N1) and `published_fingerprint`. A refusal writes
     nothing, and the next trigger tries again.
  2. *Back-fill (a12).* Every ended review task without a `reviewed_revision`, whose
     `based_on` is a published task's `result_fingerprints`, gets that task's
     `published_revision`.
  3. *Status.* The subject's open review is read (`review_status`). A review that is
     merged or closed is read no more.
  4. *CI.* On the last published task, `review_ci` records the review's CI while the
     review is at that task's revision, also while a review task is in flight, so its
     verdict sees it (`AtlasFlow.Ladder`: a review that ends on red CI leads to a fix
     that carries both). Red CI is one fix signal: `{:reconcile, kind, key}` is cast to
     the Engine, once per published revision, and only with no review task in flight
     (created, not ended): during a review the signal waits for its verdict. The Engine
     turns it into a fix (`AtlasFlow.Activities.Task`, `AtlasFlow.Ladder`'s
     `{:ci_failed, key}`).
  5. *Ready.* A draft is ready when the newest ended review task approved it, at a
     `reviewed_revision` equal to the revision Code reports, and Code reports it `open`,
     `at_revision` (nobody else moved it) and CI `success`. At most one Flow review is
     ready (not a draft, still open) at a time; the others wait in the order they became
     ready (FIFO; after a restart, by subject key). `mark_ready` is recorded as
     `marked_ready_at` on the published task.

  Options of `start_link/1`: `name`, `model`, `actors`, `clock`, `every` (ms, 60 000),
  `engine` (default `AtlasFlow.Engine`), `client` (default the publishing client),
  `snapshot_client` (Bases' client, for a snapshot's revision) and `results`.
  """
  use GenServer

  require Logger

  alias AtlasFlow.{Publish, Results, Talk}
  alias AtlasFlow.Code.Client
  alias AtlasFlow.Runs.{Clock, Store}
  alias AtlasFlow.WorkSource.Leases

  @endpoint "flow/landing"
  @published ~w(code_change_id review_id review_url published_revision published_fingerprint)

  ## Interface

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "A task result whose check passed is stored: the Engine's cast, never a call."
  def publish(task_key, server \\ __MODULE__) when is_binary(task_key),
    do: GenServer.cast(server, {:publish, task_key})

  @doc "The Bus endpoint Landing writes from."
  def endpoint, do: @endpoint

  ## Server

  @impl true
  def init(opts) do
    model = Keyword.get_lazy(opts, :model, &AtlasFlow.Model.configured!/0)
    :ok = AtlasBus.attach(@endpoint)
    send(self(), :boot)

    {:ok,
     %{
       runner:
         AtlasFlow.Model.load(
           model,
           AtlasFlow.Model.environment(),
           Keyword.get_lazy(opts, :actors, &AtlasBus.Actors.configured/0)
         ),
       clock: opts[:clock],
       every: Keyword.get(opts, :every, 60_000),
       engine: Keyword.get(opts, :engine, AtlasFlow.Engine),
       client: Keyword.get_lazy(opts, :client, &Client.publishing/0),
       snapshot_client: Keyword.get_lazy(opts, :snapshot_client, &Client.default/0),
       results: Keyword.get(opts, :results, Results),
       timer: nil,
       # What Code last answered of each review Landing published: `review_id => report`.
       reviews: %{},
       # The reviews ready to be marked, in the order they became so.
       queue: [],
       # The published revisions whose red CI was signalled: `{task_key, revision}`.
       signalled: MapSet.new()
     }}
  end

  @impl true
  def handle_info(:boot, state), do: {:noreply, sweep(state)}
  def handle_info(:tick, state), do: {:noreply, sweep(%{state | timer: nil})}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:publish, _task_key}, state), do: {:noreply, sweep(state)}
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Clock.cancel(state.clock, state.timer)

  ## A sweep

  defp sweep(state) do
    case subjects(state) do
      {:ok, subjects} ->
        subjects = Enum.map(subjects, &publish_latest(state, &1))
        subjects = Enum.map(subjects, &back_fill/1)
        state = Enum.reduce(subjects, state, &status/2)
        state = Enum.reduce(subjects, state, &ci/2)

        state
        |> ready(subjects)
        |> timer()

      {:error, why} ->
        Logger.warning("flow landing could not read the runs: #{inspect(why)}")
        timer(state)
    end
  end

  # The subjects of the runs Landing works on, each with its tasks: `%{kind, key, title,
  # repository, target, tasks}` (tasks as facts, oldest first), by subject.
  defp subjects(%{runner: %{config: config, flows: flows}}) when is_map(config) do
    case Talk.read(config["kind"], %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        for(
          fact <- facts,
          {:ok, run} <- [Store.decode(config, fact)],
          flow = flows[run["flow"]],
          flow != nil,
          spec = repository_spec(flow),
          spec != nil,
          do: {run["subject_kind"], run["subject_key"], spec}
        )
        |> Enum.uniq_by(fn {kind, key, _} -> {kind, key} end)
        |> Enum.sort_by(fn {kind, key, _} -> {kind, key} end)
        |> Enum.reduce_while({:ok, []}, fn {kind, key, spec}, {:ok, acc} ->
          case subject(kind, key, spec) do
            {:ok, subject} -> {:cont, {:ok, acc ++ [subject]}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      other ->
        {:error, {:unreadable, config["kind"], other}}
    end
  end

  defp subjects(_state), do: {:ok, []}

  # The flow's task spec whose input names a Code repository (its author's).
  defp repository_spec(flow) do
    Enum.find_value(flow.states(), fn state ->
      case flow.mechanism(state) do
        {:task, %{"input" => %{"repository" => r, "base" => b}, "records" => %{}} = spec}
        when is_binary(r) and is_binary(b) ->
          spec

        _ ->
          nil
      end
    end)
  end

  defp subject(kind, key, spec) do
    %{"kind" => records, "relation" => relation} = spec["records"]

    with %{"facts" => tasks} when is_list(tasks) <-
           Talk.read(records, %{"linked" => %{relation => key}, "plain" => true}),
         %{"fact" => fact} <- Talk.read(kind, %{"key" => key, "plain" => true}) do
      {:ok,
       %{
         kind: kind,
         key: key,
         title: title(fact, key),
         repository: spec["input"]["repository"],
         target: spec["input"]["base"],
         tasks: Enum.sort_by(tasks, &number(key, &1["key"]))
       }}
    else
      other -> {:error, {:unreadable, kind, key, other}}
    end
  end

  defp title(%{"values" => %{"title" => title}}, _key) when is_binary(title) and title != "",
    do: title

  defp title(_fact, key), do: key

  # `TK-<subject>-<n>`'s n (0 for any other key).
  defp number(subject, task_key) do
    prefix = "TK-#{subject}-"

    with ^prefix <> n <- task_key, {i, ""} <- Integer.parse(n), do: i, else: (_ -> 0)
  end

  ## 1. Publish

  defp publish_latest(state, subject) do
    last = last_published(subject)
    after_n = if last, do: number(subject.key, last["key"]), else: 0

    candidate =
      subject.tasks
      |> Enum.filter(&(publishable?(&1) and number(subject.key, &1["key"]) > after_n))
      |> List.last()

    if candidate, do: publish_task(state, subject, candidate, last), else: subject
  end

  defp publishable?(task) do
    value(task, "kind") in ["author", "fix"] and value(task, "result_state") == "complete" and
      value(task, "check_exit_status") == 0 and value(task, "published_revision") == nil
  end

  defp last_published(subject), do: subject.tasks |> Enum.filter(&published?/1) |> List.last()

  defp published?(task), do: is_binary(value(task, "published_revision"))

  defp publish_task(state, subject, task, last) do
    open =
      if last,
        do: %{review_id: value(last, "review_id"), revision: value(last, "published_revision")}

    request = %{
      task_key: task["key"],
      task: task["values"],
      repository: subject.repository,
      target: subject.target,
      title: subject.title,
      why_now: nil,
      provenance: nil,
      review: open
    }

    opts = [client: state.client, snapshot_client: state.snapshot_client, results: state.results]

    with {:ok, pub} <- Publish.publish(request, opts),
         values = published_values(pub),
         :ok <- write(task["key"], values) do
      put_values(subject, task["key"], values)
    else
      error ->
        Logger.warning("flow landing could not publish #{task["key"]}: #{inspect(error)}")
        subject
    end
  end

  defp published_values(pub) do
    @published
    |> Enum.zip([
      pub.change_id,
      pub.review_id,
      pub.link,
      pub.published_revision,
      pub.fingerprint
    ])
    |> Map.new()
    |> Map.reject(fn {_, v} -> v == nil end)
  end

  ## 2. Back-fill (a12)

  defp back_fill(subject) do
    published =
      for t <- subject.tasks,
          published?(t),
          f = value(t, "result_fingerprints"),
          is_binary(f),
          into: %{},
          do: {f, value(t, "published_revision")}

    Enum.reduce(subject.tasks, subject, fn t, subject ->
      revision = published[value(t, "based_on")]

      if value(t, "kind") == "review" and ended?(t) and value(t, "reviewed_revision") == nil and
           is_binary(revision) and write(t["key"], %{"reviewed_revision" => revision}) == :ok,
         do: put_values(subject, t["key"], %{"reviewed_revision" => revision}),
         else: subject
    end)
  end

  ## 3. Status

  defp status(subject, state) do
    review_id = open_review(subject)

    cond do
      review_id == nil or closed?(state.reviews[review_id]) ->
        state

      true ->
        case Client.review_status(state.client, review_id) do
          {:ok, report} ->
            put_in(state.reviews[review_id], report)

          {:error, why} ->
            Logger.warning("flow landing could not read review #{review_id}: #{inspect(why)}")
            %{state | reviews: Map.delete(state.reviews, review_id)}
        end
    end
  end

  defp open_review(subject) do
    case last_published(subject) do
      nil -> nil
      task -> value(task, "review_id")
    end
  end

  defp closed?(%{state: state}), do: state != :open
  defp closed?(_none), do: false

  ## 4. CI

  defp ci(subject, state) do
    with %{} = task <- last_published(subject),
         %{state: :open, at_revision: true, revision: revision, ci: ci} <-
           state.reviews[value(task, "review_id")],
         true <- revision == value(task, "published_revision"),
         text = Atom.to_string(ci),
         :ok <-
           if(text == value(task, "review_ci"),
             do: :ok,
             else: write(task["key"], %{"review_ci" => text})
           ),
         true <- ci == :failure,
         false <- reviewing?(subject),
         signal = {task["key"], revision},
         false <- MapSet.member?(state.signalled, signal) do
      # Red CI: one fix signal for this revision (the Engine reconciles the subject).
      GenServer.cast(state.engine, {:reconcile, subject.kind, subject.key})
      %{state | signalled: MapSet.put(state.signalled, signal)}
    else
      _ -> state
    end
  end

  # A review task created and not ended.
  defp reviewing?(subject),
    do: Enum.any?(subject.tasks, &(value(&1, "kind") == "review" and not ended?(&1)))

  defp ended?(task), do: value(task, "state") not in [nil, "", "waiting"]

  ## 5. Ready

  defp ready(state, subjects) do
    eligible = for s <- subjects, ready?(state, s), do: open_review(s)
    queue = Enum.filter(state.queue, &(&1 in eligible)) ++ (eligible -- state.queue)
    state = %{state | queue: queue}

    case {marked?(state), queue} do
      {false, [review_id | rest]} ->
        subject = Enum.find(subjects, &(open_review(&1) == review_id))
        mark(state, subject, review_id, rest)

      _ ->
        state
    end
  end

  # A Flow review ready already: not a draft any more, and still open.
  defp marked?(state),
    do: Enum.any?(state.reviews, fn {_, r} -> r.state == :open and r.draft == false end)

  defp ready?(state, subject) do
    review = newest_review(subject)

    with %{} = task <- last_published(subject),
         %{state: :open, draft: true, at_revision: true, ci: :success, revision: revision} <-
           state.reviews[value(task, "review_id")],
         %{} <- review do
      value(review, "verdict") == "approved" and value(review, "reviewed_revision") == revision
    else
      _ -> false
    end
  end

  # The newest ended review task: its verdict is the loop's last word.
  defp newest_review(subject),
    do:
      subject.tasks
      |> Enum.filter(&(value(&1, "kind") == "review" and ended?(&1)))
      |> List.last()

  defp mark(state, subject, review_id, rest) do
    with {:ok, _ready} <- Client.mark_ready(state.client, review_id),
         task = last_published(subject),
         at = DateTime.to_iso8601(Clock.now(state.clock)),
         :ok <- write(task["key"], %{"marked_ready_at" => at}) do
      %{state | queue: rest, reviews: put_in(state.reviews, [review_id, :draft], false)}
    else
      error ->
        Logger.warning("flow landing could not mark #{review_id} ready: #{inspect(error)}")
        state
    end
  end

  ## The CI timer: only while a draft of Landing's is open

  defp timer(state) do
    draft? = Enum.any?(state.reviews, fn {_, r} -> r.state == :open and r.draft == true end)

    cond do
      draft? and state.timer == nil ->
        %{state | timer: Clock.schedule(state.clock, self(), :tick, state.every)}

      not draft? and state.timer != nil ->
        Clock.cancel(state.clock, state.timer)
        %{state | timer: nil}

      true ->
        state
    end
  end

  ## Facts

  # A change of the task's own fields, fenced on what it read (`AtlasFlow.WorkSource.Leases`).
  defp write(task_key, values) do
    decide = fn
      nil -> {:reply, {:error, :no_task}}
      _fact -> {:write, values, %{}, :ok}
    end

    case Leases.update(task_key, decide) do
      :ok ->
        :ok

      other ->
        Logger.warning("flow landing could not write #{task_key}: #{inspect(other)}")
        other
    end
  end

  defp put_values(subject, key, values) do
    tasks =
      Enum.map(subject.tasks, fn
        %{"key" => ^key} = t -> Map.update(t, "values", values, &Map.merge(&1, values))
        t -> t
      end)

    %{subject | tasks: tasks}
  end

  defp value(task, field), do: (task["values"] || %{})[field]
end
