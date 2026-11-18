defmodule AtlasFlow.FakeRuntime do
  @moduledoc """
  A fake `AtlasFlow.Runtime.Client` for Flow's task tests: one machinery's Runtime held in
  memory, with what each call was asked.

  By default it answers as the Runtime does (Runtime design §3.2, §8.3): `submit` takes a
  new key while capacity has room (`{:accepted, work}`), answers a known key `{:existing,
  work}`, and is `{:at_capacity, 30}` without room; `find_work` and `get_work` answer
  `{:found, work}`, `{:pruned, id, kind}` or `:not_found`.

  `script(call, answers)` overrides the next answers of one call, in order (then the
  default again). An answer is the outcome to give, `:default`, `{:lose, reason}` (for
  `submit`: the Runtime takes the work, but its answer is lost: `{:unreachable, reason}`),
  or a function of the call's arguments returning one of those.
  """
  @behaviour AtlasFlow.Runtime.Client
  use Agent

  @room %{
    "accepting" => true,
    "slots" => %{"total" => 1, "busy" => 0, "free" => 1},
    "buffer" => %{"size" => 4, "used" => 0, "free" => 4},
    "profiles" => %{
      "deep_coding" => %{"available" => true},
      "independent_review" => %{"available" => true}
    }
  }

  @full %{
    "accepting" => true,
    "slots" => %{"total" => 1, "busy" => 1, "free" => 0},
    "buffer" => %{"size" => 4, "used" => 4, "free" => 0},
    "profiles" => %{"deep_coding" => %{"available" => true}},
    "retry_after" => 30
  }

  def room, do: @room
  def full, do: @full

  def start_link(_ \\ nil),
    do:
      Agent.start_link(
        fn -> %{works: %{}, pruned: %{}, n: 0, capacity: @room, script: %{}, calls: []} end,
        name: __MODULE__
      )

  @doc "Every call so far, oldest first: `{call, args}` (the machinery left out)."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def calls(name), do: for({^name, args} <- calls(), do: args)
  def capacity!(capacity), do: Agent.update(__MODULE__, &%{&1 | capacity: capacity})
  def script(call, answers), do: Agent.update(__MODULE__, &put_in(&1.script[call], answers))
  def work(key), do: Agent.get(__MODULE__, & &1.works[key])

  @doc "The work of `key` moves to `state` (a new revision), its latest attempt with it."
  def move(key, state, result \\ nil) do
    Agent.get_and_update(__MODULE__, fn s ->
      work = s.works[key]
      [attempt | rest] = Enum.reverse(work["attempts"])
      attempt = Map.merge(attempt, %{"state" => state, "result" => result})

      work = %{
        work
        | "revision" => work["revision"] + 1,
          "state" => state,
          "attempts" => Enum.reverse([attempt | rest])
      }

      {work, put_in(s.works[key], work)}
    end)
  end

  @doc "The work of `key` ended `kind`, with `extra` in its result."
  def finish(key, kind, extra \\ %{}),
    do: move(key, kind, Map.merge(%{"kind" => kind, "answer" => "Done."}, extra))

  @doc "A completed work whose check exited `status` (or ended as `check` says)."
  def completed(key, check \\ %{"exit_status" => 0}),
    do:
      finish(key, "completed", %{
        "work_product" => %{
          "check" =>
            Map.merge(
              %{"command" => ["bin/check"], "output" => %{"tail" => "ok", "complete" => true}},
              check
            )
        }
      })

  @doc "The work of `key` is pruned: it ended `kind` and its record is gone."
  def prune(key, kind) do
    Agent.update(__MODULE__, fn s ->
      work = s.works[key]

      %{
        s
        | works: Map.delete(s.works, key),
          pruned: Map.put(s.pruned, key, {work["work_id"], kind})
      }
    end)
  end

  @impl true
  def submit(_machinery, key, request), do: call(:submit, [key, request])
  @impl true
  def find_work(_machinery, key), do: call(:find_work, [key])
  @impl true
  def get_work(_machinery, work_id), do: call(:get_work, [work_id])
  @impl true
  def capacity(_machinery), do: call(:capacity, [])
  @impl true
  def list_work(_machinery, since), do: call(:list_work, [since])
  @impl true
  def retry(_machinery, work_id, resume), do: call(:retry, [work_id, resume])
  @impl true
  def cancel(_machinery, work_id, mode, reason), do: call(:cancel, [work_id, mode, reason])

  defp call(name, args) do
    answer =
      Agent.get_and_update(__MODULE__, fn s ->
        {answer, script} =
          case s.script[name] do
            [answer | rest] -> {answer, Map.put(s.script, name, rest)}
            _ -> {:default, s.script}
          end

        {answer, %{s | script: script, calls: [{name, args} | s.calls]}}
      end)

    answer = if is_function(answer), do: apply(answer, args), else: answer

    case answer do
      :default -> Agent.get_and_update(__MODULE__, &default(name, args, &1))
      {:lose, reason} -> Agent.get_and_update(__MODULE__, &lose(name, args, reason, &1))
      other -> other
    end
  end

  defp lose(:submit, args, reason, s) do
    {_answer, s} = default(:submit, args, s)
    {{:unreachable, reason}, s}
  end

  defp default(:submit, [key, request], s) do
    cond do
      s.works[key] ->
        {{:existing, s.works[key]}, s}

      not AtlasFlow.Activities.Task.room?(s.capacity, request["profile"]) ->
        {{:at_capacity, 30}, s}

      true ->
        n = s.n + 1

        work = %{
          "work_id" => "w-#{n}",
          "client_key" => key,
          "revision" => 1,
          "state" => "buffered",
          "request" => request,
          "attempts" => [%{"attempt" => 1, "state" => "buffered", "result" => nil}]
        }

        {{:accepted, work}, %{s | n: n, works: Map.put(s.works, key, work)}}
    end
  end

  defp default(:find_work, [key], s) do
    case {s.works[key], s.pruned[key]} do
      {%{} = work, _} -> {{:found, work}, s}
      {nil, {id, kind}} -> {{:pruned, id, kind}, s}
      _ -> {:not_found, s}
    end
  end

  defp default(:get_work, [id], s) do
    work = Enum.find_value(s.works, fn {_, w} -> if w["work_id"] == id, do: w end)
    pruned = Enum.find_value(s.pruned, fn {_, {i, kind}} -> if i == id, do: kind end)

    cond do
      work -> {{:found, work}, s}
      pruned -> {{:pruned, id, pruned}, s}
      true -> {:not_found, s}
    end
  end

  defp default(:capacity, [], s), do: {{:capacity, s.capacity}, s}
  defp default(:list_work, _, s), do: {{:works, Map.values(s.works), 0}, s}
  defp default(_call, _args, s), do: {:not_found, s}
end
