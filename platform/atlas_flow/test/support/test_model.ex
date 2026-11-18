defmodule AtlasFlow.TestModel do
  @moduledoc """
  A model for one test: the depot's (`AtlasFlow.Depot`), with some of its parts given
  instead: `subflows:` (every environment), `runs:`, `selection:` (by
  subflow name; nil deselects it), `composition:` (the depot's has no links or counts),
  `relations:` (the depot's, with the model's
  additions), `turn:` (nil: the depot runs no turns), `supervision:` (the depot
  declares none) or `actors:` (the configured actors its owners name, `[{role, kind}]`;
  none by default). `AtlasFlow.TestModel.Watch` is a model of its own whose runs are
  supervised.

      defmodule Plain do
        use AtlasFlow.TestModel, subflows: [AtlasFlow.Sorts.Plain]
      end
  """

  defmacro __using__(opts) do
    quote do
      @behaviour AtlasFlow.Model
      @parts Map.new(unquote(opts))

      @impl true
      def subflows(env),
        do: Map.get_lazy(@parts, :subflows, fn -> AtlasFlow.Depot.subflows(env) end)

      @impl true
      def runs, do: Map.get_lazy(@parts, :runs, &AtlasFlow.Depot.runs/0)

      @impl true
      def selection(name),
        do:
          Map.get_lazy(@parts[:selection] || %{}, name, fn -> AtlasFlow.Depot.selection(name) end)

      @impl true
      def migrations, do: []
      @impl true
      def composition, do: Map.get_lazy(@parts, :composition, &AtlasFlow.Depot.composition/0)
      @impl true
      def actors, do: Map.get(@parts, :actors, [])
      @impl true
      def relations, do: Map.get_lazy(@parts, :relations, &AtlasFlow.Depot.relations/0)

      def turn, do: Map.get_lazy(@parts, :turn, &AtlasFlow.Depot.turn/0)

      def supervision, do: Map.get_lazy(@parts, :supervision, &AtlasFlow.Depot.supervision/0)
    end
  end

  @doc "The run configuration of `model` (where runs are kept, how they are selected)."
  def config(model \\ AtlasFlow.Depot), do: AtlasFlow.Model.load(model, :prod).config

  @doc "The depot's sort, compiled for `environment`."
  def sort(environment \\ :prod), do: hd(AtlasFlow.Depot.subflows(environment))
end

defmodule AtlasFlow.TestModel.Watch do
  @moduledoc """
  A neutral model whose runs are supervised (work acquisition decision 2026-11-17 §5.6),
  in the DSL a model declares supervision in (M3a): a clerk watches a bin's run while it
  is in a supervised span. Its subflow `watch` starts `open` (in no span), moves to
  `packing` or `loading` (span `pack`; `loading` runs a task) and then to `checking` (span
  `check`, next to `pack`), and ends `done`. A robot is a fact of another kind: it can
  never supervise. Pickup and hand-over inputs are slips (`operation`, `hand_to`).
  """
  use RelaDSL.Composition,
    name: "watch",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  defmodule Desk do
    @moduledoc "The bins, who watches their runs, and the slips that move them."
    use RelaDSL

    type(:slip_operation, values: [:choice, :pickup, :hand_over])

    entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
      field(:name, :string)
    end

    entity :robot, label: "Robot", plural: "robots", id_type: :manual do
      field(:name, :string)
    end

    entity :bin, label: "Bin", plural: "bins", id_type: :manual do
      field(:phase, :string)
      field(:step, :string)
      field(:choice, :string)
      field(:task_result, :string)
    end

    relation(:chosen_by, label: "chosen by", from: [:bin], to: [:clerk], max_outgoing: 1)

    entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
      for f <- ~w(flow subject_kind subject_key definition_sha256 state entered_at status
                  deadlines pending last_input blocked_reason)a,
          do: field(f, :string)

      for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
    end

    entity :slip, label: "Slip", plural: "slips", id_type: :manual do
      field(:run, :string)
      field(:actor, :string)
      field(:operation, :slip_operation)
      field(:hand_to, :string)
    end

    relation(:watched_by,
      label: "watched by",
      from: [:cursor],
      to: [:clerk],
      max_outgoing: 1,
      set_by: [:flow]
    )

    flow_runtime(
      runs: :cursor,
      writer: [sender: :flow, by: :flow],
      inputs: :slip,
      supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]
    )

    subflow :watch, label: "Watch", subject: :bin do
      run_as("system:watch")
      owner(default: {:clerk, :desk})
      start(:create)
      initial(:open)
      supervise(:pack, label: "Pack", states: [:packing, :loading])
      supervise(:check, label: "Check", states: [:checking])

      state :open do
        branch(to: :packing, when: "entity.step == 'pack'")
        branch(to: :loading, when: "entity.step == 'load'")
      end

      state :packing do
        branch(to: :loading, when: "entity.step == 'load'")
        branch(to: :checking, when: "entity.step == 'check'")
        wait_for([:clerk], on: :choice, reset: false, yes: :checking)
      end

      state :loading do
        task(:author,
          role: :developer,
          profile: :deep_coding,
          input: [repository: "example.invalid/watch", base: "develop"],
          instructions: "Load the bin.",
          fields: [:step],
          records: [kind: "task", relation: "task_of"],
          machinery: "machinery",
          on: [completed: :checking, check_failed: :checking, stuck: :checking, abandoned: :open]
        )
      end

      state :checking do
        branch(to: :done, when: "entity.step == 'done'")
      end

      final(:done)
    end

    select(:watch,
      choices: [:choice],
      roles: [clerk: :chosen_by],
      admission: [phase: [:first]],
      imports: []
    )
  end

  defmodule Bins do
    @moduledoc "The watch model's one module."
    use RelaDSL.Module, path: "modules/bins/schema.yaml", concepts: [Desk]
  end

  schema(version: "1.0", namespace: "https://example.invalid/watch#", description: "Bins.\n")
  modules([Bins])
  environments([:prod, :test])

  acl(comment: "The watch's roles.")
  role("watch", read: ["*"], create: [:cursor], update: [:bin, :cursor])
  role("clerk", read: ["*"], update: [:bin])
  assign("system:watch", "watch")

  defcomposition :watch do
    subflows([Desk])
  end
end
