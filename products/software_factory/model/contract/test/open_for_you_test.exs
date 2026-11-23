defmodule Model.OpenForYouTest do
  @moduledoc """
  Open for you on the real path, with no coordinator: the real Facts (on its in-memory
  rela) derives how the issue's work is presented, on the Assignment the work is written
  on; the real Flow engine (on a manual clock) runs the issue and moves its supervisor;
  Control's pages read through Facts as a page does (`_page`). A person sees the open
  issue, picks it up, then sees it as theirs to supervise and may hand it over; Open work
  still lists its Assignment. Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasControl.Pages
  alias AtlasFacts.FakeRela
  alias AtlasFlow.{Engine, ManualClock}

  @moduletag :tmp_dir
  @model Model.AtlasEyra
  @issue "IS-Atlas-01"
  @ada %{by: "ada", by_kind: "person", client: "tui"}

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_bus, :store, "open-for-you-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:atlas_bus, :environment, environment)
      restore_env(:atlas_bus, :store, store)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    # rela in memory, linked to this test process: it ends with the test.
    rela = FakeRela.start(@model)
    for p <- ~w(ada bea), do: {:ok, _} = FakeRela.create(rela, "people", p, %{}, %{})

    facts =
      start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})

    clock = start_supervised!({ManualClock, ~U[2026-11-18 09:00:00Z]})
    # Control's session endpoint: Facts takes a pickup only from one.
    :ok = AtlasBus.attach("control/session-open-for-you-#{System.unique_integer([:positive])}")
    m = AtlasControl.Model.catalog(@model)
    runs = @model.run_mapping()["kind"]
    for kind <- ["assignment", runs], do: :ok = AtlasBus.listen(kind)

    engine =
      start_supervised!(
        {Engine,
         every: 3_600_000,
         clock: {ManualClock, clock},
         model: @model,
         environment: :test,
         actors: %{"decider" => "someone"}}
      )

    %{facts: facts, engine: engine, m: m, runs: runs, rela: rela}
  end

  # A write through Facts, as Control's session sends one; its acknowledgement.
  defp put(kind, content) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: class}, answer}
    assert class == "stored", inspect(answer)
    answer
  end

  defp read(kind, content) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}
    answer
  end

  # A page as Control reads and renders it: its reads, asked of Facts as one `_page`.
  defp answers(route, m) do
    AtlasControl.PageReads.answers(route, m, fn kind, content, _budget ->
      read(kind, content)
    end)
  end

  defp render(route, m, viewer \\ @ada), do: Pages.render(route, m, answers(route, m), viewer)

  defp block(page, id), do: Enum.find(page.blocks, &(&1["id"] == id))
  defp rows(page, id), do: block(page, id)["props"]["rows"]
  defp tos(rows), do: for(%{"to" => to} <- rows, do: to)

  defp actions(page) do
    for %{"to" => to} <- block(page, "item")["props"]["actions"] || [],
        route = Pages.route(to),
        elem(route, 0) in [:pick_up, :hand_over],
        do: route
  end

  test "an open issue is open for a person, who picks it up, then supervises it", c do
    m = c.m
    span = Enum.find(Pages.open_for_you_rule(m).spans, &(&1.subflow == "issue"))
    list = "list:#{span.subflow}:#{span.span}"
    to = Pages.path({:item, "issue", @issue})

    # No coordinator: the model's default owner of the issue's work does not exist.
    assert %{"fact" => nil} = read("agent", %{"key" => "coordinator"})

    # The issue, made through Facts (which makes its Assignment); Flow runs it into its
    # span and writes what is expected on the Assignment.
    put("issue", %{
      "op" => "create",
      "key" => @issue,
      "values" => %{"title" => "Open"},
      "by" => "ada"
    })

    Engine.round(c.engine)
    [spec] = for {_relation, "assignment", spec} <- Pages.components(m, "issue"), do: spec
    assignment = Pages.part_key(spec, @issue)

    await("assignment", fn ->
      p =
        read("assignment", %{"key" => assignment, "presentation" => true})["fact"]["presentation"]

      p["flow"] == span.subflow and p["state"] in span.states
    end)

    # (1) Open for you lists the issue, once, in its span.
    assert tos(rows(render({:open_for_you, "ada"}, m), list)) == [to]

    # (2) The issue's page offers Pick up of the run that presents it, and Pick up may.
    assert [{:pick_up, "issue", @issue, run} = pick] =
             actions(render({:item, "issue", @issue}, m))

    assert Pages.pick_up_problem(m, pick, answers(pick, m), @ada) == nil

    # (3) Picked up (an input of the flow, as the session sends it): once Flow links the
    # run to ada, it is no longer open, and it is ada's to supervise.
    values = %{"run" => run, "request_id" => Envelope.new("fact", "flow_input").id}
    put(Pages.inputs_kind(m), %{"op" => "pickup", "values" => values, "by" => "ada"})
    relation = Pages.open_for_you_rule(m).relation
    await(c.runs, fn -> read(c.runs, %{"key" => run})["fact"]["links"][relation] == ["ada"] end)

    assert tos(rows(render({:open_for_you, "ada"}, m), list)) == []
    assert tos(rows(render({:supervised_by_you, "ada"}, m), "list")) == [to]

    # (4) Its supervisor may hand it over (to bea), under the page's More….
    assert [{:hand_over, "issue", @issue, ^run}] = actions(render({:more, "issue", @issue}, m))
    hand = {:hand_over, "issue", @issue, run, "ada"}
    assert Pages.hand_over_problem(m, hand, answers(hand, m), @ada) == nil

    # (5) Open work still lists the issue's Assignment: what is expected of it is written.
    [from] = m.relations[Pages.assigned_rule(m).relation].from
    assert to in tos(rows(render({:list, from}, m), "list"))
  end

  # Until `done?` holds, read again on each hint of `kind` (a write Facts stored); never
  # the clock. `assert_receive` bounds a hint that never comes.
  defp await(kind, done?) do
    unless done?.() do
      assert_receive {:atlas_bus, %Envelope{class: "stored", kind: ^kind}, _}
      await(kind, done?)
    end
  end
end
