defmodule Model.SceneProducerTest do
  @moduledoc """
  IS-Atlas-70 (UC-Atlas-23, SC-Atlas-09): a scene records who put it in. Its create links
  `produced_by`, in the same write, to the person who creates it (at the TUI), or to the
  person the agent that creates it assists (`assists`); Control takes it from who the
  client is, never from the form, and Facts takes it on that create only (the scene's
  `create.producer`, data in the extension). Its origin is truthful: by the person, or
  by the agent on behalf of its person. "Accept the scene" then goes to that producer;
  a scene that records none goes to the configured decider. Three cases: a person who
  is not the decider, an assisting agent, and a form or write that sets it itself.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{Projection, Store}
  alias Model.AtlasEyra

  @now ~U[2026-11-26 09:00:00Z]
  # bo decides; adrienne is not the decider; the assistant assists melle.
  @actors %{"decider" => "bo"}
  @people ~w(adrienne melle bo)
  @assistant "assistant"

  defp extension, do: AtlasEyra.__rela__(:description).extension

  # Facts' reader, with the people as facts of their kind (and nothing else).
  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn
        "person", key -> if key in @people, do: %{key: key, links: %{}}
        _, _ -> nil
      end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  defp create(_kind, key, producer) do
    links = if producer, do: %{"produced_by" => [producer]}, else: %{}
    %{"op" => "create", "key" => key, "values" => %{"title" => "Newcomers"}, "links" => links}
  end

  defp check(kind, change, actor), do: AtlasEyra.check(kind, change, actor, lookup())

  # As Facts gives the writer: who sent it, from where, and whom it assists.
  defp person(by), do: %{"by" => by, "sender" => "control/session-1", "assists" => nil}

  defp agent(by, assists),
    do: %{"by" => by, "sender" => "control/session-2", "assists" => assists}

  defp catalog, do: AtlasControl.Model.catalog(AtlasEyra)

  # -- The model -------------------------------------------------------------------------

  test "a scene's create names produced_by as data; the relation stays Flow's otherwise" do
    assert get_in(extension(), ["entities", "scene", "create", "producer"]) == "produced_by"
    assert get_in(extension(), ["relations", "produced_by", "set_by"]) == ["flow"]

    # A use case or issue made by hand records it the same way (UC-Atlas-23,
    # item_producer_test.exs); what Design and Plan make gets it from Flow.
    for kind <- ~w(use_case issue),
        do: assert(get_in(extension(), ["entities", kind, "create", "producer"]) == "produced_by")

    # Never in a form.
    assert %{producer: "produced_by", ask: ask} = AtlasEyra.form("scene", :create)
    refute "produced_by" in ask
    assert AtlasEyra.form("scene", :edit).producer == nil
  end

  test "Accept the scene asks its producer, the decider when it records none" do
    for env <- [:prod, :test] do
      accept = Enum.find(AtlasEyra.subflows(env), &(&1.name() == "accept_scene"))

      assert %{"kind" => "person", "config" => "decider", "producer" => "produced_by"} =
               accept.owner("to_accept")["default"]

      # Not the run's supervisor: the scene's producer, as Design's questions are.
      refute AtlasFlow.Model.supervisable?(accept.owner("to_accept")["default"])
    end
  end

  # -- Facts: the link on that create only --------------------------------------------------

  test "a person's create of a scene links them as its producer; Facts takes it" do
    assert check("scene", create("scene", "SC-Atlas-30", "adrienne"), person("adrienne")) == :ok
  end

  test "an agent's create links whom it assists; Facts takes it" do
    assert check("scene", create("scene", "SC-Atlas-31", "melle"), agent(@assistant, "melle")) ==
             :ok
  end

  test "Facts refuses a producer the writer did not put in, or one nobody puts in" do
    refusals = [
      # Someone else than who creates it.
      {create("scene", "SC-Atlas-32", "melle"), person("adrienne")},
      # The agent itself, or someone else than whom it assists.
      {create("scene", "SC-Atlas-33", @assistant), agent(@assistant, "melle")},
      {create("scene", "SC-Atlas-34", "adrienne"), agent(@assistant, "melle")},
      # An agent that assists nobody puts nothing in for anyone.
      {create("scene", "SC-Atlas-35", "melle"), agent("agent", nil)},
      # Two producers.
      {put_in(
         create("scene", "SC-Atlas-36", "adrienne"),
         ["links", "produced_by"],
         ~w(adrienne melle)
       ), person("adrienne")}
    ]

    for {change, actor} <- refusals do
      assert {:refuse, [why]} = check("scene", change, actor), inspect({change, actor})
      assert why =~ "produced_by"
    end

    # A create that links nobody: refused, whoever writes it (UC-Atlas-23).
    for actor <- [person("adrienne"), agent(@assistant, "melle"), agent("agent", nil)] do
      assert {:refuse, [why]} = check("scene", create("scene", "SC-Atlas-37", nil), actor)
      assert why =~ "records its producer (produced_by)"
    end

    # After the create, nobody but Flow changes it, not even its producer.
    stored = %{
      "key" => "SC-Atlas-30",
      "values" => %{},
      "links" => %{"produced_by" => ["adrienne"]}
    }

    change = %{
      "op" => "change",
      "key" => "SC-Atlas-30",
      "values" => %{},
      "links" => %{"produced_by" => ["melle"]}
    }

    for actor <- [person("adrienne"), person("melle"), agent(@assistant, "melle")] do
      assert {:refuse, [why]} =
               AtlasEyra.check("scene", change, actor, %{lookup() | "current" => fn -> stored end})

      assert why =~ "produced_by"
    end
  end

  # -- Control: from who the client is, never from the form ---------------------------------

  test "Control's create links the person at the TUI, by themselves" do
    viewer = %{by: "adrienne", by_kind: "person", assists: nil}
    raw = %{"title" => "Newcomers"}

    assert AtlasControl.Pages.put_in_by(catalog(), "scene", raw, viewer) ==
             {:ok, %{"produced_by" => ["adrienne"]}, nil}
  end

  test "Control's create by an assisting agent links its person, on their behalf" do
    viewer = %{by: @assistant, by_kind: "agent", assists: "melle"}

    assert AtlasControl.Pages.put_in_by(catalog(), "scene", %{"title" => "x"}, viewer) ==
             {:ok, %{"produced_by" => ["melle"]}, {@assistant, "melle"}}
  end

  test "Control refuses a create by a client that is no person and assists nobody" do
    agent = %{by: "agent", by_kind: nil, assists: nil}

    assert {:refuse, [why]} = AtlasControl.Pages.put_in_by(catalog(), "scene", %{}, agent)
    assert why =~ "agent is no person and assists nobody"
    assert why =~ "no producer (produced_by)"
  end

  test "a form or atlas write that sets produced_by itself is refused before anything is sent" do
    m = catalog()

    for viewer <- [
          %{by: "adrienne", by_kind: "person", assists: nil},
          %{by: @assistant, by_kind: "agent", assists: "melle"}
        ],
        kind <- ~w(scene use_case),
        raw <- [%{"title" => "x", "produced_by" => "adrienne"}, %{"produced_by" => ""}] do
      assert {:refuse, [why]} = AtlasControl.Pages.put_in_by(m, kind, raw, viewer)
      assert why =~ "produced_by"
    end
  end

  # -- The scene's page: Produced by, with its origin --------------------------------------

  test "the scene's page shows Produced by with the person and its origin" do
    m = catalog()

    for origin <- [
          %{"by" => "adrienne"},
          %{"by" => @assistant, "cause" => "Put in by #{@assistant} on behalf of melle"}
        ] do
      producer = if origin["by"] == "adrienne", do: "adrienne", else: "melle"

      scene = %{
        "key" => "SC-Atlas-30",
        "values" => %{"title" => "Newcomers"},
        "links" => %{"produced_by" => [producer]},
        "origins" => %{"produced_by" => origin}
      }

      reads = AtlasControl.Pages.reads({:item, "scene", "SC-Atlas-30"}, m)
      answers = [%{"fact" => scene} | for(_ <- tl(reads), do: %{"facts" => []})]
      page = AtlasControl.Pages.render({:item, "scene", "SC-Atlas-30"}, m, answers)

      assert [%{"value" => ^producer, "origin" => shown}] =
               for(
                 b <- page.blocks,
                 pair <-
                   List.wrap(get_in(b, ["props", "fields"])) ++
                     List.wrap(get_in(b, ["props", "links"])),
                 is_map(pair) and pair["label"] == "Produced by",
                 do: pair
               )

      assert shown["by"] == origin["by"]
      assert shown["cause"] == origin["cause"]
    end
  end

  # -- Flow: Accept the scene goes to its producer ---------------------------------------

  describe "Accept the scene" do
    setup do
      Application.put_env(:atlas_bus, :store, "producer-#{System.unique_integer([:positive])}")
      environment = Application.get_env(:atlas_bus, :environment)
      Application.put_env(:atlas_bus, :environment, "test")

      on_exit(fn ->
        if environment,
          do: Application.put_env(:atlas_bus, :environment, environment),
          else: Application.delete_env(:atlas_bus, :environment)
      end)

      {:ok, _} = Application.ensure_all_started(:atlas_bus)
      start_supervised!(FakeFacts)
      :ok = AtlasBus.attach("flow")
      for p <- @people, do: FakeFacts.put("person", %{"key" => p})

      %{runner: AtlasFlow.Model.load(AtlasEyra, :test, @actors)}
    end

    # A scene whose one use case is accepted, put in by `producer` (nil: none recorded).
    defp scene(key, producer) do
      links = %{"assignment" => ["AS-" <> key]}
      links = if producer, do: Map.put(links, "produced_by", [producer]), else: links

      FakeFacts.put("scene", %{
        "key" => key,
        "values" => %{"title" => "Newcomers", "phase" => "accept"},
        "links" => links
      })

      FakeFacts.put("assignment", %{"key" => "AS-" <> key, "values" => %{"of" => key}})

      FakeFacts.put("use_case", %{
        "key" => "UC-" <> key,
        "values" => %{"title" => "Read the README", "phase" => "accepted"},
        "links" => %{"in_scene" => [key]},
        # Completed, as Facts works it out (its `completion`).
        "completion" => %{"field" => "phase", "value" => "accepted"}
      })
    end

    defp accept(c, key, rounds \\ 5) do
      config = c.runner.config
      flows = c.runner.flows
      {:ok, %{runs: known}} = Store.plan(config, flows)
      subjects = [{"use_case", "UC-" <> key}, {"scene", key}]
      {:ok, runs} = Store.reconcile_subjects(config, flows, @now, known, subjects)
      run = Enum.find(runs, &(&1["flow"] == "accept_scene" and &1["subject_key"] == key))

      cond do
        run["state"] == "to_accept" ->
          assert {:ok, _} = Projection.project(c.runner, "scene", key)
          FakeFacts.get("assignment", "AS-" <> key)

        rounds == 0 ->
          flunk("accept_scene in #{inspect(run && run["state"])}, not to_accept")

        true ->
          accept(c, key, rounds - 1)
      end
    end

    test "a person who is not the decider put it in: Accept is theirs, not the decider's", c do
      scene("SC-Atlas-30", "adrienne")
      assignment = accept(c, "SC-Atlas-30")
      assert assignment["values"]["flow_state"] == "to_accept"
      assert assignment["links"]["assigned_to"] == ["adrienne"]
    end

    test "an assisting agent put it in: Accept is its person's", c do
      scene("SC-Atlas-31", "melle")
      assert accept(c, "SC-Atlas-31")["links"]["assigned_to"] == ["melle"]
    end

    test "a scene that records no producer: Accept is the decider's, for now", c do
      scene("SC-Atlas-32", nil)
      assert accept(c, "SC-Atlas-32")["links"]["assigned_to"] == ["bo"]
    end
  end
end
