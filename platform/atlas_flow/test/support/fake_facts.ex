defmodule AtlasFlow.FakeFacts do
  @moduledoc """
  A stand-in for Facts on the Bus, for Flow's tests: answers reads with facts as Facts
  wires them (values, links, origins, progress, completion), stores changes in memory,
  and answers each fact with stored and a position (the Bus hints it to listeners). Its
  kinds are the neutral depot's (`AtlasFlow.Depot`): a box holds crates, a clerk signs a
  box off.

  It keeps a run's inputs as Facts does (its flow inputs), for the kind a fact
  `submit` is sent of: a submit applies the choice to the run's subject and records it
  applied; a read by `run` answers the run's inputs; Flow's `consume` is taken only for the
  input the stored run names as its last, at or past its position.

  Like Facts, it answers a resent id from its ledger: what was stored, and a refusal with a
  code (`"exists"`: another fact holds the key; `"reserved"`: the key is held back after its
  fact was deleted, `reserve/2`). Such a refusal stays the answer to its id, even once the
  key is free again; refusals without a code are not recorded.
  """
  use GenServer

  alias AtlasBus.Envelope

  @doc """
  What Facts describes: rela's kinds and relations. What the model adds to them (parent
  relations, components, the turn) and its flows are the model's (`AtlasFlow.Depot`),
  never the description's.
  """
  def description do
    %{
      "entities" => %{
        "box" => %{"plural" => "boxes"},
        "crate" => %{"plural" => "crates"},
        "clerk" => %{"plural" => "clerks"}
      },
      "relations" => %{
        "in_box" => %{"from" => ["crate"], "to" => ["box"], "max_outgoing" => 1},
        "signed_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1},
        "owned_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1}
      }
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Put a fact as Facts would answer it: `%{\"key\", \"values\", \"links\", …}`."
  def put(kind, fact), do: GenServer.call(__MODULE__, {:put, kind, fact})

  @doc """
  Once, around the next write of fact `{kind, key}` from the endpoint `sender`, change
  the fact `target` (default that one) with `fun` (the stored fact → the fact), as another
  writer's write would: `:before` Facts handles the write, or `:after` it stored it. A
  race between two named steps.
  """
  def hook(kind, key, sender, at, fun, target \\ nil)
      when at in [:before, :after] and is_function(fun, 1),
      do: GenServer.call(__MODULE__, {:hook, kind, key, sender, at, {target || {kind, key}, fun}})

  def lose_ack(kind), do: GenServer.call(__MODULE__, {:lose_ack, kind})

  @doc "Delete the fact at `key` and hold the key back: a create of it is refused `reserved`."
  def reserve(kind, key), do: GenServer.call(__MODULE__, {:reserve, kind, key})

  @doc "Free a held-back key again (rela let it go); the ledger keeps what it answered."
  def release(kind, key), do: GenServer.call(__MODULE__, {:release, kind, key})

  def get(kind, key), do: GenServer.call(__MODULE__, {:get, kind, key})

  @doc "Every fact content Flow sent, oldest first."
  def sent, do: GenServer.call(__MODULE__, :sent)

  @doc "Every fact content stored from Flow's endpoints only, oldest first."
  def stored_from_flow, do: GenServer.call(__MODULE__, :from_flow)

  def set_description(description), do: GenServer.call(__MODULE__, {:description, description})

  @doc """
  How many of Flow's reads were answered so far, and of those how many plain. Only reads
  from Flow's endpoints count: the Bus is shared, and a process another test left behind
  (a Control session still asking, in the same VM) reads from whatever the store is now.
  """
  def reads, do: GenServer.call(__MODULE__, :reads)

  @doc "How many times Flow read each run's inputs so far: `%{run key => reads}`."
  def input_reads, do: GenServer.call(__MODULE__, :input_reads)

  @doc """
  Leave an input of a run as Facts holds it (`%{"key", "run", "entry", "status", …}`), as
  when its answer was prepared and not yet applied. Facts applies a prepared input only to
  the entry an active run is in: a read of the inputs of a run it was left on otherwise
  fails, as Facts answers it (`:prepared_input_needs_reconciliation`).
  """
  def put_input(input), do: GenServer.call(__MODULE__, {:put_input, input})

  @doc "How many facts Flow sent so far, each attempt and replay counted: its round trips."
  def puts, do: GenServer.call(__MODULE__, :puts)

  @doc "How many facts its answers to Flow's reads held so far (a list counts each fact)."
  def facts_read, do: GenServer.call(__MODULE__, :facts_read)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(AtlasBus.store())

    {:ok,
     %{
       facts: %{},
       sent: [],
       ledger: %{},
       lose_ack: nil,
       reads: {0, 0},
       input_reads: %{},
       facts_read: 0,
       puts: 0,
       from_flow: [],
       inputs: %{},
       position: 0,
       busy: MapSet.new(),
       blocked_reads: MapSet.new(),
       refused_writes: MapSet.new(),
       reserved: MapSet.new(),
       busy_after_write: MapSet.new(),
       hooks: %{},
       description: Keyword.get(opts, :description, description())
     }}
  end

  @impl true
  def handle_call({:put, kind, fact}, _from, s) do
    fact = Map.merge(%{"values" => %{}, "links" => %{}, "origins" => %{}}, fact)
    {:reply, :ok, put_in(s.facts[{kind, fact["key"]}], fact)}
  end

  def handle_call({:lose_ack, kind}, _from, s), do: {:reply, :ok, %{s | lose_ack: kind}}

  def handle_call({:reserve, kind, key}, _from, s),
    do:
      {:reply, :ok,
       %{
         s
         | facts: Map.delete(s.facts, {kind, key}),
           reserved: MapSet.put(s.reserved, {kind, key})
       }}

  def handle_call({:release, kind, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.delete(s.reserved, {kind, key})}}

  def handle_call({:get, kind, key}, _from, s), do: {:reply, s.facts[{kind, key}], s}
  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:from_flow, _from, s), do: {:reply, Enum.reverse(s.from_flow), s}
  def handle_call({:description, d}, _from, s), do: {:reply, :ok, %{s | description: d}}
  def handle_call(:reads, _from, s), do: {:reply, s.reads, s}
  def handle_call(:facts_read, _from, s), do: {:reply, s.facts_read, s}
  def handle_call(:puts, _from, s), do: {:reply, s.puts, s}

  def handle_call(:input_reads, _from, s), do: {:reply, s.input_reads, s}

  def handle_call({:put_input, input}, _from, s),
    do: {:reply, :ok, put_in(s.inputs[input["key"]], input)}

  def handle_call({:drop, kind, key}, _from, s),
    do: {:reply, :ok, %{s | facts: Map.delete(s.facts, {kind, key})}}

  # A read of this fact gets Facts' answer when it could not read it, until `{:free, …}`.
  def handle_call({:busy, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy: MapSet.put(s.busy, {kind, key})}}

  # Reads of this fact fail once its next write is stored (Flow stops there, as on a crash
  # right after that write), until `{:free, …}`.
  def handle_call({:busy_after_write, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy_after_write: MapSet.put(s.busy_after_write, {kind, key})}}

  def handle_call({:free, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy: MapSet.delete(s.busy, {kind, key})}}

  def handle_call({:block_read, kind, content}, _from, s),
    do: {:reply, :ok, %{s | blocked_reads: MapSet.put(s.blocked_reads, {kind, content})}}

  def handle_call({:allow_read, kind, content}, _from, s),
    do: {:reply, :ok, %{s | blocked_reads: MapSet.delete(s.blocked_reads, {kind, content})}}

  # Once, around the next write of this fact from `sender`: `fun` changes the fact as
  # another writer's write would (a new version), `:before` Facts handles that write or
  # `:after` it was stored. How a race between two named steps is staged.
  def handle_call({:hook, kind, key, sender, at, fun}, _from, s),
    do: {:reply, :ok, put_in(s.hooks[{kind, key, sender, at}], fun)}

  def handle_call({:refuse_write, kind, key}, _from, s),
    do: {:reply, :ok, %{s | refused_writes: MapSet.put(s.refused_writes, {kind, key})}}

  def handle_call({:allow_write, kind, key}, _from, s),
    do: {:reply, :ok, %{s | refused_writes: MapSet.delete(s.refused_writes, {kind, key})}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    s = if flow?(e.sender), do: %{s | reads: count(s.reads, content)}, else: s

    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => s.description}

        {kind, %{"key" => key}} ->
          if MapSet.member?(s.busy, {kind, key}),
            do: %{"error" => "Facts did not answer"},
            else: %{"fact" => s.facts[{kind, key}]}

        {kind, %{"linked" => linked}} ->
          facts =
            for {{^kind, _}, fact} <- s.facts,
                Enum.all?(linked, fn {rel, key} -> key in (fact["links"][rel] || []) end),
                do: fact

          %{"facts" => facts}

        # Completed runs expose all retained inputs without applying prepared choices.
        # Otherwise a prepared one fails unless the run is active in its entry.
        {_kind, %{"run" => run}} ->
          inputs = for({_, i} <- s.inputs, i["run"] == run, do: i)
          cursor = cursor(s, run)

          completed? = cursor != nil and cursor["values"]["status"] == "completed"

          if not completed? and
               Enum.any?(inputs, &(&1["status"] == "prepared" and not open?(cursor, &1))),
             do: %{"error" => ":prepared_input_needs_reconciliation"},
             else: %{"inputs" => Enum.sort_by(inputs, & &1["position"])}

        {kind, _} ->
          %{"facts" => for({{^kind, _}, fact} <- s.facts, do: fact)}
      end

    answer =
      if MapSet.member?(s.blocked_reads, {e.kind, content}),
        do: %{"error" => "Facts did not answer"},
        else: answer

    s =
      case content do
        %{"run" => run} when is_binary(run) ->
          if flow?(e.sender),
            do: update_in(s.input_reads, &Map.update(&1, run, 1, fn n -> n + 1 end)),
            else: s

        _ ->
          s
      end

    s =
      if flow?(e.sender),
        do: %{s | facts_read: s.facts_read + length(List.wrap(answer["facts"] || answer["fact"]))},
        else: s

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, c}, s) do
    s = if flow?(e.sender), do: %{s | puts: s.puts + 1}, else: s

    case {s.ledger[e.id], c} do
      {{class, answer, position}, _} ->
        AtlasBus.send(Envelope.reply(e, class, position: position), answer)
        {:noreply, s}

      {nil, %{"op" => "submit"}} ->
        {:noreply, submit(e, c, s)}

      {nil, %{"op" => "consume"}} ->
        {:noreply, consume(e, c, s)}

      {nil, %{"key" => _}} ->
        fact(e, c, s)

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # Someone's choice (`values`: `run`, `entry`, `roles`, `changed_fields`): its subject
  # changed as it says, and the input recorded applied on the subject's new version.
  defp submit(e, %{"key" => key, "values" => v}, s) do
    run = cursor(s, v["run"])
    subject_key = {run["values"]["subject_kind"], run["values"]["subject_key"]}
    position = s.position + 1
    subject = s.facts[subject_key]

    subject =
      Map.merge(subject, %{
        "values" => Map.merge(subject["values"], v["changed_fields"]),
        "version" => position,
        "position" => position
      })

    input =
      Map.merge(v, %{
        "key" => key,
        "status" => "applied",
        "position" => position,
        "subject_version" => position,
        "prepared_at" => v["prepared_at"] || "2026-11-12T00:00:00Z"
      })

    answer = %{
      "op" => "submit",
      "key" => key,
      "subject_kind" => elem(subject_key, 0),
      "subject_key" => elem(subject_key, 1),
      "changes" => [
        %{"kind" => elem(subject_key, 0), "key" => elem(subject_key, 1), "op" => "change"}
      ]
    }

    AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)

    %{
      s
      | position: position,
        facts: Map.put(s.facts, subject_key, subject),
        inputs: Map.put(s.inputs, key, input),
        ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
    }
  end

  # Flow's consume: only of the input the stored run accepted last, as Facts takes it.
  defp consume(e, %{"key" => key, "run" => run_key} = c, s) do
    input = s.inputs[key]
    run = cursor(s, run_key)
    last = run && JSON.decode!(run["values"]["last_input"])

    if input != nil and input["run"] == run_key and last["input"] == key and
         run["values"]["input_cursor"] >= input["position"] do
      position = s.position + 1
      answer = %{"key" => key, "status" => "consumed"}
      AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)

      %{
        s
        | position: position,
          sent: [c | s.sent],
          from_flow: [c | s.from_flow],
          inputs: Map.put(s.inputs, key, Map.put(input, "status", "consumed")),
          ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
      }
    else
      AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["input authority"]})
      s
    end
  end

  defp cursor(s, run_key),
    do: Enum.find_value(s.facts, fn {{_, key}, fact} -> if key == run_key, do: fact end)

  defp open?(nil, _input), do: false

  defp open?(run, input),
    do: run["values"]["status"] == "active" and run["values"]["entry"] == input["entry"]

  defp fact(e, %{"key" => key} = c, s) do
    s = run_hook(s, {e.kind, key, e.sender, :before})
    old = s.facts[{e.kind, key}]

    # As Facts does (P1): a change on an old version is stored when it changes nothing
    # (a resend), applied when every field and link it sets still has its `was` value,
    # and refused otherwise.
    conflict =
      old != nil and c["op"] == "change" and c["version"] != nil and
        c["version"] != old["version"] and not same?(old, c) and not untouched?(old, c)

    cond do
      old != nil and c["op"] == "change" and c["version"] != nil and
        c["version"] != old["version"] and same?(old, c) ->
        AtlasBus.send(
          Envelope.reply(e, "stored", position: s.position),
          Map.take(c, ["op", "key", "by"])
        )

        {:noreply, s}

      flow?(e.sender) and MapSet.member?(s.refused_writes, {e.kind, key}) ->
        AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["projection unavailable"]})
        {:noreply, s}

      old != nil and c["op"] == "create" and
          Enum.all?(c["values"] || %{}, fn {f, v} -> old["values"][f] == v end) ->
        AtlasBus.send(
          Envelope.reply(e, "stored", position: s.position),
          Map.take(c, ["op", "key", "by"])
        )

        {:noreply, s}

      old != nil and c["op"] == "create" ->
        {:noreply, refuse(e, c, s, "exists")}

      old == nil and c["op"] == "create" and MapSet.member?(s.reserved, {e.kind, key}) ->
        {:noreply, refuse(e, c, s, "reserved")}

      conflict ->
        AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["conflict"]})
        {:noreply, s}

      true ->
        position = s.position + 1
        fact = old || %{"key" => key, "values" => %{}, "links" => %{}, "origins" => %{}}

        values =
          Map.merge(fact["values"], c["values"] || %{})
          |> Map.reject(fn {_, v} -> v in [nil, ""] end)

        links = Map.merge(fact["links"], c["links"] || %{})

        fact =
          Map.merge(fact, %{
            "values" => values,
            "links" => links,
            "version" => position,
            "position" => position
          })

        # What changed, as Facts says it: the fact, with its links before and after.
        both =
          Map.merge(fact_links(old), links, fn _, a, b -> Enum.uniq(a ++ b) end)
          |> Map.reject(fn {_, keys} -> keys == [] end)

        change = %{"kind" => e.kind, "key" => key, "op" => c["op"], "links" => both}
        answer = Map.put(Map.take(c, ["op", "key", "by"]), "changes", [change])

        facts =
          if c["op"] == "delete",
            do: Map.delete(s.facts, {e.kind, key}),
            else: Map.put(s.facts, {e.kind, key}, fact)

        s = %{
          s
          | sent: [c | s.sent],
            from_flow: if(flow?(e.sender), do: [c | s.from_flow], else: s.from_flow),
            position: position,
            facts: facts,
            ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
        }

        s =
          if MapSet.member?(s.busy_after_write, {e.kind, key}),
            do: %{
              s
              | busy: MapSet.put(s.busy, {e.kind, key}),
                busy_after_write: MapSet.delete(s.busy_after_write, {e.kind, key})
            },
            else: s

        s = run_hook(s, {e.kind, key, e.sender, :after})

        if s.lose_ack == e.kind do
          # Commit, then lose the answer. Immediate transport failure avoids timer waits.
          AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["answer lost"]})
          {:noreply, %{s | lose_ack: nil}}
        else
          AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)
          {:noreply, s}
        end
    end
  end

  # A refusal with a code, as Facts answers it: recorded under the id, so a resend of the
  # same id gets it again.
  defp refuse(e, c, s, code) do
    refusal = %{"op" => c["op"], "key" => c["key"], "reasons" => [code], "code" => code}
    AtlasBus.send(Envelope.reply(e, "refused"), refusal)
    %{s | ledger: Map.put(s.ledger, e.id, {"refused", refusal, nil})}
  end

  defp run_hook(s, hook) do
    case Map.pop(s.hooks, hook) do
      {nil, _} ->
        s

      {{target, fun}, hooks} ->
        # Always a newer version than the fact had, also one a test put with its own.
        position = max(s.position, (s.facts[target] || %{})["version"] || 0) + 1
        fact = Map.merge(fun.(s.facts[target]), %{"version" => position, "position" => position})
        %{s | hooks: hooks, position: position, facts: Map.put(s.facts, target, fact)}
    end
  end

  defp loose(""), do: nil
  defp loose(value), do: value

  defp same?(old, c) do
    Enum.all?(c["values"] || %{}, fn {f, v} -> loose(old["values"][f]) == loose(v) end) and
      Enum.all?(c["links"] || %{}, fn {r, keys} ->
        Enum.sort(old["links"][r] || []) == Enum.sort(List.wrap(keys))
      end)
  end

  defp untouched?(old, %{"was" => was} = c) when is_map(was) do
    Enum.all?(c["values"] || %{}, fn {f, _} ->
      Map.has_key?(was, f) and loose(old["values"][f]) == loose(was[f])
    end) and
      Enum.all?(c["links"] || %{}, fn {r, _} ->
        Map.has_key?(was, r) and
          Enum.sort(old["links"][r] || []) == Enum.sort(List.wrap(was[r]))
      end)
  end

  defp untouched?(_old, _c), do: false

  defp fact_links(nil), do: %{}
  defp fact_links(fact), do: fact["links"] || %{}

  defp flow?(sender), do: sender == "flow" or String.starts_with?(sender || "", "flow/")

  defp count({all, plain}, content),
    do: {all + 1, plain + if(content["plain"] == true, do: 1, else: 0)}
end

defmodule AtlasFlow.FakeFacts.Leasing do
  @moduledoc """
  Facts as the work source's tests prepare them (plan m3 A2), on `AtlasFlow.FakeFacts`:
  the neutral watch model (`AtlasFlow.TestModel.Watch`) with crates under their bin
  (`in_bin`, a parent relation) and attempts that ran on a robot (`ran_on`); a bin's run in
  a supervised span, its supervisor as the run fact's link; runs that hold a version-2
  intent; and the work source's processes on one manual clock.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias AtlasFlow.{Delivery, Dispatch, FakeFacts, ManualClock, Results}
  alias AtlasFlow.Runs.{Run, Store}
  alias AtlasFlow.WorkSource.Translate

  defmodule Model do
    @moduledoc "The watch model, with crates under bins and attempts on robots."
    @behaviour AtlasFlow.Model
    alias AtlasFlow.TestModel.Watch

    @impl true
    def subflows(env), do: Watch.subflows(env)
    @impl true
    def runs, do: Watch.runs()
    @impl true
    def selection(name), do: Watch.selection(name)
    @impl true
    def migrations, do: Watch.migrations()
    @impl true
    def composition, do: Watch.composition()
    @impl true
    def actors, do: Watch.actors()
    def turn, do: Watch.turn()
    def supervision, do: Watch.supervision()

    @impl true
    def relations,
      do:
        Map.merge(Watch.relations(), %{
          "in_bin" => %{
            "from" => ["crate"],
            "to" => ["bin"],
            "max_outgoing" => 1,
            "parent" => true
          },
          "ran_on" => %{"from" => ["task_attempt"], "to" => ["robot"], "max_outgoing" => 1}
        })
  end

  @epoch ~U[2026-11-17 12:00:00Z]

  def epoch, do: @epoch
  def config, do: AtlasFlow.Model.load(Model, :prod).config

  @doc """
  Starts FakeFacts, the clock, the result store (in `dir`), Dispatch and Delivery
  (Delivery casts to the test process as its Engine). Options go to Dispatch (`poll_wait`
  0, no sweep or resync timer by default) and `results:` to the store.
  """
  def start(dir, opts \\ []) do
    Application.put_env(:atlas_bus, :store, "lease-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@epoch)
    clock = {ManualClock, clock}

    results =
      Keyword.merge(
        [dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end],
        Keyword.get(opts, :results, [])
      )

    start_supervised!(Supervisor.child_spec({Results, results}, id: Results))
    start_dispatch(clock, opts)
    start_supervised!({Delivery, model: Model, clock: clock, engine: self()})
    %{clock: clock, dir: dir}
  end

  @doc "Starts Dispatch (again) on `clock`."
  def start_dispatch(clock, opts \\ []) do
    opts =
      Keyword.merge(
        [model: Model, clock: clock, poll_wait: 0, sweep_ms: nil, resync_ms: nil],
        Keyword.drop(opts, [:results])
      )

    start_supervised!(Supervisor.child_spec({Dispatch, opts}, id: Dispatch))
  end

  @doc "Moves the manual clock on by `seconds`."
  def advance(%{clock: {ManualClock, clock}}, seconds),
    do: ManualClock.advance(clock, seconds * 1000)

  def now(%{clock: clock}), do: AtlasFlow.Runs.Clock.now(clock)

  @doc "A base as Bases makes it (no Code behind it)."
  def base(name \\ "repo") do
    hex = sha256("snapshot " <> name)

    %{
      base_id: "code-" <> hex,
      manifest: sha256("manifest " <> name),
      snapshot_id: "sha256:" <> hex
    }
  end

  @doc "A version-2 intent for task `key`, made at `at`."
  def intent(key, opts \\ []) do
    base = Keyword.get(opts, :base, base())

    spec = %{
      "kind" => Keyword.get(opts, :kind, "author"),
      "profile" => Keyword.get(opts, :profile, "deep_coding"),
      "cost_class" => "standard",
      "instructions" => "Load the bin.",
      "fields" => [],
      "check" => Keyword.get(opts, :check)
    }

    Translate.intent(
      spec,
      %{"key" => key, "values" => %{}},
      key,
      base,
      "robot-1",
      Keyword.get(opts, :at, @epoch)
    )
  end

  @doc """
  The run of `{kind, key}` holding `intent` (or none), as a run fact: in `state`
  (`loading`, inside the span `pack`, by default), `status` active, and supervised by
  `supervisor` (a clerk's key, or nil). Answers the run's key.
  """
  def run(kind, key, opts \\ []) do
    config = config()
    flow = Keyword.get(opts, :flow, if(kind == "bin", do: "watch", else: "pack"))
    run_key = Run.key(flow, kind, key, 1)
    pending = %{"version" => 1, "writes" => []}
    pending = if opts[:intent], do: Map.put(pending, "task", opts[:intent]), else: pending

    run = %{
      "flow" => flow,
      "subject_kind" => kind,
      "subject_key" => key,
      "generation" => 1,
      "definition_sha256" => "test",
      "state" => Keyword.get(opts, :state, "loading"),
      "entry" => 1,
      "entered_at" => DateTime.to_iso8601(@epoch),
      "status" => Keyword.get(opts, :status, "active"),
      "deadlines" => %{"version" => 1},
      "pending" => pending,
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    supervisor = Keyword.get(opts, :supervisor)
    links = if supervisor, do: %{"watched_by" => [supervisor]}, else: %{}

    FakeFacts.put(config["kind"], %{
      "key" => run_key,
      "version" => 0,
      "values" => Store.encode(config, run),
      "links" => links
    })

    run_key
  end

  @doc "Sets (or, with nil, clears) the run's supervisor, as S1's pickup or hand-over writes it."
  def supervise(run_key, supervisor) do
    config = config()
    fact = FakeFacts.get(config["kind"], run_key)
    links = Map.put(fact["links"], "watched_by", List.wrap(supervisor))

    FakeFacts.put(
      config["kind"],
      Map.merge(fact, %{"links" => links, "version" => (fact["version"] || 0) + 1})
    )
  end

  @doc "A function a FakeFacts hook runs: the run fact's supervisor set to `supervisor`."
  def supervisor_set(supervisor),
    do: fn fact -> put_in(fact, ["links", "watched_by"], List.wrap(supervisor)) end

  @doc "The task fact as the Engine writes it with its intent."
  def task(key, subject) do
    FakeFacts.put("task", %{
      "key" => key,
      "version" => 0,
      "values" => %{"kind" => "author", "client_key" => key, "state" => "waiting"},
      "links" => %{"task_of" => [subject]}
    })
  end

  @doc "A bin `key` supervised by `supervisor`, whose run holds task `TK-<key>-1`'s intent."
  def supervised_task(key, supervisor, opts \\ []) do
    task = "TK-#{key}-1"
    FakeFacts.put("bin", %{"key" => key, "values" => %{"phase" => "first"}})

    run =
      run("bin", key, Keyword.merge([intent: intent(task, opts), supervisor: supervisor], opts))

    task(task, key)
    %{task: task, run: run}
  end

  @doc "A crate `key` in bin `bin`, whose own run holds task `TK-<key>-1`'s intent."
  def crate_task(key, bin, opts \\ []) do
    task = "TK-#{key}-1"
    FakeFacts.put("crate", %{"key" => key, "links" => %{"in_bin" => [bin]}})
    run("crate", key, Keyword.merge([intent: intent(task, opts), state: "packing"], opts))
    task(task, key)
    task
  end

  @doc "The task fact's values."
  def values(task), do: FakeFacts.get("task", task)["values"]

  @doc "A poll input from Runtime `runtime_id`."
  def poll_input(runtime_id, holdings \\ [], offer \\ %{"deep_coding" => 1}) do
    %{
      runtime_id: runtime_id,
      incarnation: "inc-1",
      build: "test",
      policy_version: 1,
      offer: offer,
      holdings: for(h <- holdings, do: %{lease_id: h, state: :running})
    }
  end

  @doc """
  A change set over `files` (`[{path, bytes}]`) on `base_id`, with each root's `csf_` as
  `AtlasChangeset` computes it (or `fingerprint:` given).
  """
  def change_set(files, base_id, opts \\ []) do
    entries =
      for {path, bytes} <- files,
          do: %{
            path: path,
            op: :write,
            kind: :file,
            mode: :"100644",
            size: byte_size(bytes),
            sha256: sha256(bytes)
          }

    fingerprint =
      Keyword.get_lazy(opts, :fingerprint, fn ->
        AtlasChangeset.fingerprint(base_id, "repo", Translate.normal(entries))
      end)

    %{roots: [%{root: "repo", fingerprint: fingerprint, entries: entries}]}
  end

  @doc "An `ended` report: `kind` (completed), its change set and check, and one turn's provenance."
  def ended(change_set \\ nil, opts \\ []) do
    result =
      %{kind: Keyword.get(opts, :kind, :completed), retryable: false, never_started: false}
      |> Map.merge(Map.new(Keyword.take(opts, [:reason, :answer, :check])))

    %{
      state: :ended,
      result: result,
      provenance: [
        %{
          provider: "vendor",
          harness: "harness",
          runtime_build: "rt-1",
          machine: "machine-1",
          slot: "slot-1",
          configured_model: "model-a",
          reported_model: "model-a",
          profile: "deep_coding",
          policy_version: 1,
          turn_id: "turn-1",
          started_at: ~U[2026-11-17 12:00:10Z]
        }
      ],
      change_set: change_set
    }
  end

  def sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
