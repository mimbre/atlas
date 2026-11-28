defmodule ControlFixtures.ProductPages do
  @moduledoc """
  Synthetic facts rendered by the product model and Control's normal page builders.
  Run from the software_factory Mix project in MIX_ENV=test, with applications not
  started. No server, Rela database, credentials, or production data are used.
  """

  alias AtlasControl.{PageReads, Pages}
  alias AtlasControl.Freshness.RowKey
  alias AtlasFlow.Talk

  @root Path.expand("../..", __DIR__)
  @routes [
    {:item, "decision", "D-7"},
    {:list, "decision"},
    {:item, "scene", "SC-1"},
    {:list, "scene"},
    {:item, "to_do", "TD-12"},
    {:list, "to_do"},
    {:list, "issue"},
    {:open_for_you, "ada"}
  ]

  @doc "Build the immutable path-to-wire-page map once, before accepting connections."
  def build! do
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_bus, :store, "control-fixture-store")
    Application.put_env(:atlas_bus, :link, nil)
    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    :ok = AtlasBus.attach("control-fixture-builder")

    unless Code.ensure_loaded?(AtlasControl.FakeStore) do
      Code.require_file(Path.join(@root, "platform/atlas_control/test/support/fake_store.ex"))
    end

    {:ok, store} = AtlasControl.FakeStore.start_link(model: Model.AtlasEyra)

    try do
      seed!()
      catalog = AtlasControl.Model.catalog(Model.AtlasEyra)
      Map.new(@routes, fn route -> {Pages.path(route), render!(route, catalog)} end)
    after
      GenServer.stop(store)
    end
  end

  defp render!(route, catalog) do
    answers = PageReads.answers(route, catalog, fn kind, query, _budget -> Talk.read(kind, query) end)

    if Enum.any?(answers, &Map.has_key?(&1, "error")) do
      raise "fixture read failed for #{inspect(route)}: #{inspect(answers)}"
    end

    page = Pages.render(route, catalog, answers, %{by: "ada", by_kind: "person"})

    %{
      "op" => "page",
      "reason" => "open",
      "path" => Pages.path(route),
      "title" => page.title,
      "back" => page.back,
      "blocks" => RowKey.put(page.blocks),
      "markup" => page.markup
    }
  end

  defp seed! do
    store = AtlasControl.FakeStore
    options = File.read!(Path.join(@root, "products/software_factory/e2e/fixtures/decision-options.json"))

    decision = %{
      "title" => "How do we store examples?",
      "decision" => "Keep the same examples available to each client.",
      "context" => "Both clients should show the same content from Control.",
      "status" => "proposed",
      "options" => options,
      "category" => "product",
      "scope" => "software",
      "reversibility" => "two_way",
      "force" => "direction"
    }

    scene = %{
      "title" => "Make examples easy to inspect",
      "description" => "Review the same decision and To-Do across clients.\n\n" <>
        String.duplicate("The description remains visible at different widths and while scrolling. ", 12),
      "phase" => "break_down"
    }

    todo = %{
      "title" => "Prepare the local examples",
      "instructions" => "Why: make the same content available to both clients.\n\n1. Open the gallery\n\n2. Compare both clients",
      "status" => "open"
    }

    :ok = store.put("ada", %{"name" => "Ada"}, "person")
    :ok = store.put("D-7", decision, "decision", %{"assignment" => ["AS-D-7"]})
    :ok = store.put("SC-1", scene, "scene", %{"assignment" => ["AS-SC-1"]})
    :ok = store.put("TD-12", todo, "to_do", %{"assignment" => ["AS-TD-12"], "based_on" => ["D-7"]})

    assignment!("AS-D-7", "D-7", "decide", "for_person_always", decision)
    assignment!("AS-SC-1", "SC-1", "break_down_scene", "break_down", scene)
    assignment!("AS-TD-12", "TD-12", "to_do", "open", todo)
  end

  defp assignment!(key, subject, flow_name, state, values) do
    store = AtlasControl.FakeStore
    flow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == flow_name)) ||
      raise "missing product subflow #{flow_name}"

    presentation =
      flow.present(state, values)
      |> Map.merge(%{"owner" => ["ada"], "actionable" => true})

    :ok = store.put(key, %{"of" => subject, "flow_state" => state}, "assignment", %{"assigned_to" => ["ada"]})
    :ok = store.present("assignment", key, presentation)
  end
end
