defmodule AtlasControl.MachinesPage do
  @moduledoc """
  The Machines tab (`/machines`, contract 0.41.0): the environment's Runtimes, each a fact
  of the kind the model's `machines/0` names (its key the Runtime's id). Users call them
  machines; the code and the docs for developers say Runtime.

  With one machine the tab is that machine's page; with more, a list of them, each opening
  its page (`/machines/:machine`). The compact overview per machine, grouped, comes once a
  second Runtime exists (docs/design/clients.md). A machine's page is a stack of blocks:

  1. `header` (MACHINE, its key, its name, its kind's icon) and `text` `state`: open,
     draining or upgrading (an upgrade that has not ended), not seen; and its build;
  2. `item` `health`: when it last polled, how long a poll waits, since when it runs this
     incarnation, and whether a newer Runtime release exists; a `text` `health-error`
     (role error) says what to do when it is not seen;
  3. `list` `slots`: one row per configured slot (and any busy one the configuration no
     longer names): what it works on, its stage and since when, or Free;
  4. `list` `queue`: the work waiting for a Runtime, oldest first;
  5. `list` `finished`: the last #{10} attempts that ended, each with its subject, outcome
     and duration; one whose subject cannot be found is left out (no hash-only row);
  6. `list` `upgrades`: its upgrades, newest first, each with its step;
  7. `answers`: Upgrade to the newest build (`upgrade_offer/3`), when a newer one exists;
  8. `actions`: Edit configuration;
  9. `item` `details` in a part of role details: its incarnation, machine name, installed
     version and policy version, each only when known.

  Where a value comes from: the facts (the machine, its upgrades and the attempts that ran
  on it, read through `read`), Flow's health answer (`flow`: each Runtime's last poll with
  its build and incarnation, and the queue; memory only, so a restarted core knows a
  Runtime again from its first poll) and the newest Runtime release, the build the core
  itself was released with (`newest_build/0`): CI publishes the Runtime of the same push.
  """

  alias AtlasControl.{HealthPage, Pages}
  require AtlasControl.Blocks, as: Blocks

  @finished 10
  @upgrades 5

  @doc """
  The newest Runtime release, as its build is named (`develop-0123456789ab`): the one CI
  published with the core's own build (`config :atlas_control, :runtime_release`); nil when
  the core does not know its build (off Fly).
  """
  def newest_build, do: Application.get_env(:atlas_control, :runtime_release)

  @doc """
  The page of `route` (`{:machine_page, page, params}`): `read.(kind, query)` reads Facts,
  `flow` is Flow's `_health` answer (nil when Flow did not answer).
  """
  def render(route, m, read, flow, now \\ DateTime.utc_now(), newest \\ newest_build()) do
    with {:ok, c} <- context(m, read, flow, now, newest) do
      cleared(c, fn -> page(route, c) end)
    else
      {:error, why} -> unavailable(why, "/")
    end
  end

  @doc """
  What the confirm of Upgrade to the newest build creates for machine `machine`:
  `{:ok, kind, values, links}`, the upgrade as submitted under the machine
  (its build the newest), or `{:refuse, why}` when none is offered now.
  """
  def upgrade(m, machine, read, flow, newest \\ newest_build()) do
    with {:ok, c} <- context(m, read, flow, DateTime.utc_now(), newest) do
      cleared(c, fn ->
        with {:ok, fact} <- machine(c, machine),
             upgrades = upgrades(c, fact["key"]),
             {:ok, _from, to} <- upgrade_offer(runtime(c, fact["key"]), upgrades, c) do
          u = c.n["upgrades"]
          {:ok, u["kind"], %{u["build"] => to}, %{u["of"] => [fact["key"]]}}
        else
          {:none, why} -> {:refuse, why}
          {:error, why} -> {:refuse, why}
        end
      end)
    else
      {:error, why} -> {:refuse, why}
    end
  end

  # The facts read by key for one page are kept while it is made, then dropped.
  defp cleared(c, fun) do
    fun.()
  after
    for {{__MODULE__, ref, _} = k, _} <- Process.get(), ref == c.cache, do: Process.delete(k)
  end

  @doc """
  Whether Upgrade to the newest build is offered: `{:ok, from, to}` when the Runtime's
  last poll named a build, a newest one is known and differs, and no upgrade of the
  machine is under way; else `{:none, why}`.
  """
  def upgrade_offer(runtime, upgrades, %{newest: newest, n: n}) do
    build = runtime && runtime["build"]

    cond do
      not is_binary(newest) ->
        {:none, "The core does not know the newest Runtime release."}

      not is_binary(build) ->
        {:none, "Its build is not known: it has not polled since the core started."}

      build == newest ->
        {:none, "It runs the newest build, #{newest}."}

      upgrade = Enum.find(upgrades, &open?(&1, n)) ->
        {:none, "Upgrade #{upgrade["key"]} is under way."}

      true ->
        {:ok, build, newest}
    end
  end

  # -- The pages ---------------------------------------------------------------------

  defp page({:machine_page, :machines, _}, c) do
    case machines(c) do
      {:ok, [one]} -> machine_page(one, "/", c)
      {:ok, many} -> list_page(many, c)
      {:error, why} -> unavailable(why, "/")
    end
  end

  defp page({:machine_page, :machine, %{machine: key}}, c) do
    case machine(c, key) do
      {:ok, fact} -> machine_page(fact, Pages.path({:machine_page, :machines, %{}}), c)
      {:error, why} -> unavailable(why, Pages.path({:machine_page, :machines, %{}}))
    end
  end

  defp page({:machine_page, :machine_upgrade, %{machine: key}} = route, c) do
    case machine(c, key) do
      {:ok, fact} -> upgrade_page(route, fact, c)
      {:error, why} -> unavailable(why, Pages.path({:machine_page, :machines, %{}}))
    end
  end

  # More than one machine: a simple list, each opening its page.
  defp list_page(facts, c) do
    rows =
      for fact <- facts do
        runtime = runtime(c, fact["key"])

        Blocks.row(
          id: fact["key"],
          label: name(fact, c),
          detail:
            Enum.join(Enum.reject([state(fact, runtime, c), build(runtime)], &is_nil/1), " · "),
          to: machine_path(fact["key"]),
          kind: "Machine",
          icon: Pages.kind_icon(c.m, c.n["kind"])
        )
      end

    view("Machines", "/", [
      {"machines", Blocks.list(title: "Machines", rows: rows, empty: "No machine is set up yet.")}
    ])
  end

  defp machine_page(fact, back, c) do
    key = fact["key"]
    runtime = runtime(c, key)
    upgrades = upgrades(c, key)
    attempts = attempts(c, key)
    late = late(runtime, c)

    head = [
      {"header",
       Blocks.header(
         eyebrow: "MACHINE",
         key: key,
         title: name(fact, c),
         icon: Pages.kind_icon(c.m, c.n["kind"])
       )},
      {"state",
       Blocks.text(
         text:
           Enum.join(
             Enum.reject([state(fact, runtime, c, upgrades), build(runtime)], &is_nil/1),
             " · "
           )
       )}
    ]

    health = [
      {"health",
       Blocks.item(
         title: "Health",
         fields: fields(health_fields(runtime, c)),
         actions: [
           Blocks.action(label: "Health", key: "h", to: Pages.path({:worker_page, :health, %{}}))
         ]
       )}
      | health_error(key, runtime, late, c)
    ]

    lists = [
      {"slots",
       Blocks.list(
         title: "Slots",
         rows: slot_rows(fact, attempts, c),
         empty: "No slot is configured."
       )},
      {"queue", Blocks.list(title: "Queue", rows: queue_rows(c), empty: "No work is waiting.")},
      {"finished",
       Blocks.list(
         title: "Recently finished",
         rows: finished_rows(attempts, c),
         empty: "Nothing has finished here yet."
       )},
      {"upgrades",
       Blocks.list(title: "Upgrades", rows: upgrade_rows(upgrades, c), empty: "No upgrade yet.")}
    ]

    answers =
      case upgrade_offer(runtime, upgrades, c) do
        {:ok, from, to} ->
          [
            {"answers",
             Blocks.answers(
               answers: [
                 Blocks.panel_answer(
                   label: "Upgrade to the newest build",
                   key: "u",
                   to: Pages.path({:machine_page, :machine_upgrade, %{machine: key}}),
                   weight: "main",
                   icon: "upgrade",
                   detail: "#{from} → #{to}"
                 )
               ]
             )}
          ]

        {:none, _} ->
          []
      end

    actions = [
      {"actions",
       Blocks.actions(
         actions: [
           Blocks.action(
             label: "Edit configuration",
             key: "e",
             to: Pages.path({:edit, c.n["kind"], key}),
             icon: "edit"
           )
         ]
       )}
    ]

    details =
      fields([
        {"Incarnation", runtime && runtime["incarnation"]},
        {"Machine name", machine_name(attempts, c)},
        {"Installed version", runtime && runtime["build"]},
        {"Policy version", text(fact["values"][c.n["policy_version"]])}
      ])

    {details_block, markup} =
      case details do
        [] ->
          {[], []}

        fields ->
          {[{"details", Blocks.item(title: "", fields: fields)}],
           [Blocks.part("details", "details", title: "Details", role: "details")]}
      end

    view(
      name(fact, c),
      back,
      head ++ health ++ lists ++ answers ++ actions ++ details_block,
      markup ++
        if(late, do: [Blocks.highlight("health", "health-error", tone: "error")], else: [])
    )
  end

  defp upgrade_page(route, fact, c) do
    key = fact["key"]
    back = machine_path(key)
    name = name(fact, c)

    confirm =
      case upgrade_offer(runtime(c, key), upgrades(c, key), c) do
        {:ok, from, to} ->
          Blocks.confirm(
            title: "Upgrade #{name} to the newest build?",
            text:
              "#{name} runs #{from}; the newest build is #{to}. It stops taking new work, " <>
                "lets what runs finish, installs the build, restarts and checks that it " <>
                "runs it, then takes work again.",
            confirm_label: "Upgrade",
            confirm_to: Pages.call_to(route),
            cancel_to: back
          )

        {:none, why} ->
          Blocks.confirm(title: "No upgrade for #{name}", text: why, cancel_to: back)
      end

    view("Upgrade #{name}", back, [{"confirm", confirm}])
  end

  # -- Blocks' content ---------------------------------------------------------------

  # Open, draining or upgrading (an upgrade that has not ended), or not seen.
  defp state(fact, runtime, c, upgrades \\ nil) do
    upgrades = upgrades || upgrades(c, fact["key"])
    u = c.n["upgrades"]

    case Enum.find(upgrades, &open?(&1, c.n)) do
      %{} = open ->
        case open["values"][u["step"]] do
          step when step in [nil, "requested", "draining", "waiting"] ->
            "Draining for upgrade #{open["key"]}"

          _ ->
            "Upgrading (#{open["key"]})"
        end

      nil ->
        if runtime && not late(runtime, c), do: "Open", else: "Not seen"
    end
  end

  defp build(%{"build" => build}) when is_binary(build), do: "build " <> build
  defp build(_), do: nil

  defp health_fields(runtime, c) do
    polled = at(runtime && runtime["polled_at"])
    since = at(runtime && runtime["incarnation_since"])

    [
      {"Last seen",
       cond do
         c.flow == nil -> "unknown: Flow did not answer"
         polled -> "#{HealthPage.span(seconds(polled, c.now))} ago, #{HealthPage.moment(polled)}"
         true -> "not since the core started"
       end},
      {"Polls",
       case runtime && runtime["poll_max"] do
         n when is_integer(n) -> "each poll waits up to #{n} s for work"
         _ -> nil
       end},
      {"Running since", since && HealthPage.moment(since)},
      {"Newest build", newest_text(runtime, c)}
    ]
  end

  defp newest_text(runtime, %{newest: newest}) do
    build = runtime && runtime["build"]

    cond do
      not is_binary(newest) -> "unknown: the core does not know its own build"
      build == newest -> "#{newest}, which it runs"
      is_binary(build) -> "#{newest}, newer than its #{build}"
      true -> newest
    end
  end

  # Not seen within the limit: what is wrong, and what to do, in the error tone.
  defp health_error(_key, _runtime, false, _c), do: []

  defp health_error(key, runtime, true, c) do
    polled = at(runtime && runtime["polled_at"])
    limit = HealthPage.span(HealthPage.limits().runtime)

    what =
      cond do
        c.flow == nil ->
          "Flow did not answer, so whether #{key} polls is not known. Open Health to see what is behind."

        polled ->
          "#{key} has not polled for #{HealthPage.span(seconds(polled, c.now))} (limit #{limit}): " <>
            "its Runtime may be stopped or cut off from the core."

        true ->
          "#{key} has not polled since the core started: its Runtime may be stopped or cut " <>
            "off from the core."
      end

    [
      {"health-error",
       Blocks.text(
         label: "Not seen",
         text:
           what <>
             " On #{key}, run `atlas-runtime service status`; when it says stopped, " <>
             "`atlas-runtime service start`.",
         role: "error"
       )}
    ]
  end

  # One row per configured slot, and any busy one the configuration no longer names.
  defp slot_rows(fact, attempts, c) do
    a = c.n["attempts"]

    busy =
      for att <- attempts,
          running?(att, c),
          slot = text(att["values"][a["slot"]]),
          into: %{},
          do: {slot, att}

    configured = configured_slots(fact["values"][c.n["configuration"]])
    names = configured ++ (Map.keys(busy) -- configured)

    for slot <- names do
      case busy[slot] do
        nil ->
          Blocks.row(id: slot, label: "Free", to: machine_path(fact["key"]))

        att ->
          started = text(att["values"][a["started"]])

          case subject(att, c) do
            {:ok, s} ->
              Blocks.row(
                id: slot,
                label: "#{s.key} · #{s.title}",
                detail:
                  join([
                    s.stage,
                    started && "for #{HealthPage.span(seconds(at(started), c.now))}"
                  ]),
                to: s.to,
                kind: s.kind_label,
                icon: s.icon,
                since: started,
                tone: "active"
              )

            :none ->
              Blocks.row(
                id: slot,
                label: "Busy",
                detail: started && "since #{HealthPage.moment(at(started))}",
                to: machine_path(fact["key"]),
                since: started,
                tone: "active"
              )
          end
      end
    end
  end

  defp queue_rows(c) do
    for entry <- (c.flow && c.flow["queue"]) || [] do
      subject = entry["subject_key"]

      Blocks.row(
        id: subject || entry["task"],
        label: join([subject, entry["title"]], " · "),
        detail: entry["profile"] && "needs " <> String.replace(entry["profile"], "_", " "),
        to: if(subject, do: Pages.path({:item, entry["subject_kind"], subject}), else: "/"),
        kind: kind_label(c, entry["subject_kind"]),
        icon: Pages.kind_icon(c.m, entry["subject_kind"]),
        since: entry["since"],
        tone: "waiting"
      )
    end
  end

  defp finished_rows(attempts, c) do
    a = c.n["attempts"]

    attempts
    |> Enum.filter(&text(&1["values"][a["ended"]]))
    |> Enum.sort_by(&recency(&1["values"][a["ended"]]), :desc)
    |> Enum.flat_map(fn att ->
      case subject(att, c) do
        {:ok, s} -> [{att, s}]
        :none -> []
      end
    end)
    |> Enum.take(@finished)
    |> Enum.map(fn {att, s} ->
      v = att["values"]
      ended = v[a["ended"]]

      Blocks.row(
        id: s.key,
        label: "#{s.key} · #{s.title}",
        detail: join([text(v[a["result"]]), duration(v[a["started"]], ended)]),
        to: s.to,
        kind: s.kind_label,
        icon: s.icon,
        since: ended,
        tone: if(v[a["result"]] in ["completed"], do: "done", else: "attention")
      )
    end)
  end

  defp upgrade_rows(upgrades, c) do
    u = c.n["upgrades"]

    upgrades
    |> Enum.take(@upgrades)
    |> Enum.map(fn up ->
      v = up["values"] || %{}

      Blocks.row(
        id: up["key"],
        label:
          join(["to #{v[u["build"]]}", text(v["from_build"]) && "from #{v["from_build"]}"], " "),
        detail: step_text(v, u),
        to: Pages.path({:item, u["kind"], up["key"]}),
        kind: kind_label(c, u["kind"]),
        icon: Pages.kind_icon(c.m, u["kind"]),
        since: created(up, u),
        tone:
          case v[u["step"]] do
            "done" -> "done"
            "failed" -> "attention"
            _ -> "active"
          end
      )
    end)
  end

  defp step_text(v, u) do
    case v[u["step"]] do
      nil ->
        "requested"

      "failed" ->
        join(
          [
            "failed",
            text(v[u["failed_step"]]) && "at #{v[u["failed_step"]]}",
            text(v[u["reason"]])
          ],
          " "
        )

      "waiting" ->
        join(["waiting until no slot is busy", text(v["busy"])], ": ")

      step ->
        step
    end
  end

  # -- Reads -------------------------------------------------------------------------

  defp context(m, read, flow, now, newest) do
    case Pages.machines(m) do
      %{} = n ->
        {:ok, %{m: m, n: n, read: read, flow: flow, now: now, newest: newest, cache: make_ref()}}

      _ ->
        {:error, "This model has no machines."}
    end
  end

  defp machines(c) do
    case c.read.(c.n["kind"], %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) -> {:ok, Enum.sort_by(facts, & &1["key"])}
      _ -> {:error, "Facts did not answer."}
    end
  end

  defp machine(c, key) do
    case cached(c, {c.n["kind"], key}) do
      %{} = fact -> {:ok, fact}
      nil -> {:error, "No machine #{key}."}
    end
  end

  defp upgrades(c, key) do
    u = c.n["upgrades"]

    case c.read.(u["kind"], %{"linked" => %{u["of"] => key}, "plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        Enum.sort_by(facts, &{open?(&1, c.n), recency(created(&1, u)), &1["key"]}, :desc)

      _ ->
        []
    end
  end

  defp attempts(c, key) do
    a = c.n["attempts"]

    case c.read.(a["kind"], %{"linked" => %{a["on"] => key}, "plain" => true}) do
      %{"facts" => facts} when is_list(facts) -> facts
      _ -> []
    end
  end

  # What an attempt works on: its task's subject, with its title and the task's stage.
  defp subject(att, c) do
    a = c.n["attempts"]
    work = c.n["work"]

    with [task_key] <- get_in(att, ["links", a["of"]]) || [],
         %{to: [task_kind | _]} <- c.m.relations[a["of"]],
         %{} = task <- cached(c, {task_kind, task_key}),
         [key] <- get_in(task, ["links", work["of"]]) || [],
         kind when is_binary(kind) <- subject_kind(c, key),
         %{} = fact <- cached(c, {kind, key}) do
      {:ok,
       %{
         key: key,
         title: Pages.label(Pages.kind_view(c.m, kind), fact),
         stage: work["stage"] && stage(task["values"][work["stage"]]),
         to: Pages.path({:item, kind, key}),
         kind_label: kind_label(c, kind),
         icon: Pages.kind_icon(c.m, kind)
       }}
    else
      _ -> :none
    end
  end

  defp subject_kind(c, key) do
    kinds = (c.m.relations[c.n["work"]["of"]] || %{to: []}).to
    kind = Pages.kind_of_key(c.m, key)
    if kind in kinds, do: kind
  end

  # One fact by key, read once per page.
  defp cached(c, {kind, key} = id) do
    case Process.get({__MODULE__, c.cache, id}, :unread) do
      :unread ->
        fact =
          case c.read.(kind, %{"key" => key}) do
            %{"fact" => %{} = fact} -> fact
            _ -> nil
          end

        Process.put({__MODULE__, c.cache, id}, fact)
        fact

      fact ->
        fact
    end
  end

  defp runtime(%{flow: flow}, key) when is_map(flow),
    do: Enum.find(flow["runtimes"] || [], &(&1["runtime"] == key))

  defp runtime(_c, _key), do: nil

  defp late(runtime, c) do
    case at(runtime && runtime["polled_at"]) do
      nil -> true
      polled -> seconds(polled, c.now) > HealthPage.limits().runtime
    end
  end

  defp open?(up, n),
    do: (up["values"] || %{})[n["upgrades"]["step"]] not in n["upgrades"]["ended"]

  defp running?(att, c) do
    a = c.n["attempts"]
    v = att["values"] || %{}
    text(v[a["ended"]]) == nil and text(v[a["started"]]) != nil
  end

  # The slots the configuration (the Runtime's policy.json) names.
  defp configured_slots(configuration) when is_binary(configuration) do
    case JSON.decode(configuration) do
      {:ok, %{"slots" => slots}} when is_list(slots) -> Enum.filter(slots, &is_binary/1)
      _ -> []
    end
  end

  defp configured_slots(_), do: []

  # The machine's name as the attempts that ran on it name it, the latest first.
  defp machine_name(attempts, c) do
    a = c.n["attempts"]

    attempts
    |> Enum.sort_by(&recency(&1["values"][a["started"]]), :desc)
    |> Enum.find_value(&text(&1["values"][a["machine"]]))
  end

  defp created(up, u), do: get_in(up, ["origins", u["of"], "since"])

  defp name(fact, c), do: Pages.label(Pages.kind_view(c.m, c.n["kind"]), fact)

  defp kind_label(c, kind) do
    case kind && Pages.kind_view(c.m, kind) do
      %{label: label} -> label
      _ -> nil
    end
  end

  defp stage(value) when is_binary(value) and value != "",
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp stage(_), do: nil

  # -- Values ------------------------------------------------------------------------

  defp machine_path(key), do: Pages.path({:machine_page, :machine, %{machine: key}})

  defp fields(pairs),
    do:
      for(
        {label, value} <- pairs,
        value not in [nil, ""],
        do: Blocks.pair(label: label, value: value)
      )

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: nil

  defp join(parts, by \\ " · "), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(by)

  defp at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp at(_), do: nil

  defp seconds(nil, _now), do: 0
  defp seconds(from, to), do: max(DateTime.diff(to, from), 0)

  defp duration(from, to) do
    with %DateTime{} = from <- at(from), %DateTime{} = to <- at(to) do
      HealthPage.span(seconds(from, to))
    end
  end

  defp recency(value) do
    case at(value) do
      nil -> 0
      at -> DateTime.to_unix(at, :microsecond)
    end
  end

  defp unavailable(why, back),
    do:
      view("Machines", back, [
        {"unavailable", Blocks.text(label: "Machines unavailable", text: why, role: "error")}
      ])

  defp view(title, back, blocks, markup \\ []),
    do: Map.merge(%{title: title, back: back}, Blocks.view_model(blocks, markup))
end
