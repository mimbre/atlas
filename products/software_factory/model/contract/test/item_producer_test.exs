defmodule Model.ItemProducerTest do
  @moduledoc """
  UC-Atlas-23 (SC-Atlas-09): every item records its producer (`produced_by`), and it is
  never empty. A use case or issue made by hand records it as a scene does (IS-Atlas-70):
  its create links, in the same write, the person who creates it, or the person the agent
  that creates it assists, with a truthful origin. What Flow makes (a proposal's creates,
  and a review's follow-ups, `issue_runs_test.exs` and `platform/atlas_flow/test/
  activities/proposal_test.exs`) links the run's supervisor. A create that would record
  none, such as one by an agent that assists nobody, is refused with a reason that says
  so, by Control before anything is sent and by Facts whoever sends it; nothing is stored.

  On the real path: Control's create (`Pages.put_in_by/4`), the real Facts on its
  in-memory rela, and the item's page as Control reads and renders it.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias AtlasBus.Envelope
  alias AtlasControl.Pages
  alias AtlasFacts.FakeRela
  alias Model.AtlasEyra

  @model AtlasEyra
  @assistant "assistant"
  @adrienne %{by: "adrienne", by_kind: "person", assists: nil, client: "tui"}
  @on_behalf %{by: @assistant, by_kind: "agent", assists: "melle", client: "agent"}
  @nobody %{by: "agent", by_kind: "agent", assists: nil, client: "agent"}

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    assists = Application.get_env(:atlas, :assists)
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_bus, :store, "producer-#{System.unique_integer([:positive])}")
    Application.put_env(:atlas, :assists, %{@assistant => "melle"})

    on_exit(fn ->
      restore_env(:atlas_bus, :environment, environment)
      restore_env(:atlas_bus, :store, store)
      restore_env(:atlas, :assists, assists)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    rela = FakeRela.start(@model)
    for p <- ~w(adrienne melle), do: {:ok, _} = FakeRela.create(rela, "people", p, %{}, %{})
    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})
    :ok = AtlasBus.attach("control/session-producer-#{System.unique_integer([:positive])}")

    %{m: AtlasControl.Model.catalog(@model)}
  end

  # A create as Control's session sends it (`session.ex` `create/5`): what was asked, the
  # parent's link, and who puts it in, taken from who the client is; the agent's write
  # says on whose behalf. `{class, answer}` from Facts, or Control's own refusal.
  defp create(m, kind, key, raw, parent, viewer) do
    case Pages.put_in_by(m, kind, raw, viewer) do
      {:refuse, reasons} ->
        {:not_sent, reasons}

      {:ok, put_in, on_behalf} ->
        content =
          %{
            "op" => "create",
            "key" => key,
            "values" => Pages.create_values(m, kind, raw),
            "links" => Map.merge(parent, put_in),
            "by" => viewer.by
          }
          |> then(fn c ->
            case on_behalf do
              {by, who} -> Map.put(c, "cause", "Put in by #{by} on behalf of #{who}")
              nil -> c
            end
          end)

        write(kind, content)
    end
  end

  defp write(kind, content) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: class}, answer}, 2_000
    {class, answer}
  end

  defp read(kind, content) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 2_000
    answer
  end

  defp fact(kind, key), do: read(kind, %{"key" => key})["fact"]

  # **Produced by** on the item's page, as Control reads it through Facts and renders it.
  defp produced_by(m, kind, key, viewer) do
    route = {:item, kind, key}
    answers = AtlasControl.PageReads.answers(route, m, fn k, c, _budget -> read(k, c) end)
    page = Pages.render(route, m, answers, viewer)

    for b <- page.blocks,
        pair <-
          List.wrap(get_in(b, ["props", "fields"])) ++ List.wrap(get_in(b, ["props", "links"])),
        is_map(pair) and pair["label"] == "Produced by",
        do: {pair["value"], pair["origin"]}
  end

  defp scene(m, key) do
    assert {"stored", _} =
             create(m, "scene", key, %{"title" => "Newcomers"}, %{}, @adrienne)
  end

  test "a use case made by hand under a scene records the person who creates it", c do
    scene(c.m, "SC-Atlas-01")
    raw = %{"title" => "Read the README", "description" => "Where to start."}
    under = %{"in_scene" => ["SC-Atlas-01"]}

    assert {"stored", _} = create(c.m, "use_case", "UC-Atlas-01", raw, under, @adrienne)
    assert fact("use_case", "UC-Atlas-01")["links"]["produced_by"] == ["adrienne"]

    assert [{"adrienne", %{"by" => "adrienne"} = origin}] =
             produced_by(c.m, "use_case", "UC-Atlas-01", @adrienne)

    refute origin["cause"]
  end

  test "an issue made by hand under a use case records its creator, or the agent's person on their behalf",
       c do
    scene(c.m, "SC-Atlas-01")
    under = %{"in_scene" => ["SC-Atlas-01"]}

    assert {"stored", _} =
             create(c.m, "use_case", "UC-Atlas-01", %{"title" => "U"}, under, @adrienne)

    under = %{"in_use_case" => ["UC-Atlas-01"]}

    # By a person at the TUI: theirs, by them.
    assert {"stored", _} =
             create(c.m, "issue", "IS-Atlas-01", %{"title" => "One"}, under, @adrienne)

    assert [{"adrienne", %{"by" => "adrienne"}}] =
             produced_by(c.m, "issue", "IS-Atlas-01", @adrienne)

    # By an agent that assists melle: melle's, written by the agent on melle's behalf.
    assert {"stored", _} =
             create(c.m, "issue", "IS-Atlas-02", %{"title" => "Two"}, under, @on_behalf)

    assert fact("issue", "IS-Atlas-02")["links"]["produced_by"] == ["melle"]

    assert [{"melle", %{"by" => @assistant, "cause" => cause}}] =
             produced_by(c.m, "issue", "IS-Atlas-02", @adrienne)

    assert cause == "Put in by assistant on behalf of melle"

    # A use case by that agent records melle the same way.
    under = %{"in_scene" => ["SC-Atlas-01"]}

    assert {"stored", _} =
             create(c.m, "use_case", "UC-Atlas-02", %{"title" => "V"}, under, @on_behalf)

    assert [{"melle", %{"by" => @assistant}}] =
             produced_by(c.m, "use_case", "UC-Atlas-02", @adrienne)
  end

  test "an agent that assists nobody creates no scene, use case or issue: refused, nothing stored",
       c do
    scene(c.m, "SC-Atlas-01")
    under = %{"in_scene" => ["SC-Atlas-01"]}

    assert {"stored", _} =
             create(c.m, "use_case", "UC-Atlas-01", %{"title" => "U"}, under, @adrienne)

    for {kind, key, parent} <- [
          {"scene", "SC-Atlas-02", %{}},
          {"use_case", "UC-Atlas-02", %{"in_scene" => ["SC-Atlas-01"]}},
          {"issue", "IS-Atlas-01", %{"in_use_case" => ["UC-Atlas-01"]}}
        ] do
      # Control refuses it before anything is sent, saying why.
      assert {:not_sent, [why]} = create(c.m, kind, key, %{"title" => "x"}, parent, @nobody)
      assert why =~ "assists nobody"
      assert why =~ "no producer (produced_by)"

      # A client that sends it anyway, without the link: Facts refuses it, saying why.
      assert {"refused", %{"reasons" => [why]}} =
               write(kind, %{
                 "op" => "create",
                 "key" => key,
                 "values" => %{"title" => "x"},
                 "links" => parent,
                 "by" => "agent"
               })

      assert why =~ "records its producer (produced_by)"
      assert why =~ "links nobody"

      # Or with a producer it does not put in: refused as before.
      assert {"refused", _} =
               write(kind, %{
                 "op" => "create",
                 "key" => key,
                 "values" => %{"title" => "x"},
                 "links" => Map.put(parent, "produced_by", ["melle"]),
                 "by" => "agent"
               })

      assert fact(kind, key) == nil
    end
  end

  test "a person's create that links nobody is refused too: nothing writes an empty producer",
       c do
    scene(c.m, "SC-Atlas-01")

    assert {"refused", %{"reasons" => [why]}} =
             write("use_case", %{
               "op" => "create",
               "key" => "UC-Atlas-01",
               "values" => %{"title" => "U"},
               "links" => %{"in_scene" => ["SC-Atlas-01"]},
               "by" => "adrienne"
             })

    assert why =~ "records its producer (produced_by)"
    assert fact("use_case", "UC-Atlas-01") == nil
  end

  # -- Flow: the run's supervisor, never nobody ---------------------------------------------

  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn
        "person", key -> if key in ~w(adrienne melle), do: %{key: key, links: %{}}
        _, _ -> nil
      end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  test "Flow's create links the run's supervisor; one that links nobody is refused" do
    flow = %{"by" => "flow", "sender" => "flow", "assists" => nil}

    for {kind, parent} <- [
          {"use_case", %{"in_scene" => ["SC-Atlas-01"]}},
          {"issue", %{"in_use_case" => ["UC-Atlas-01"]}}
        ] do
      made = %{"op" => "create", "key" => "X-1", "values" => %{"title" => "x"}}

      assert AtlasEyra.check(
               kind,
               Map.put(made, "links", Map.put(parent, "produced_by", ["melle"])),
               flow,
               lookup()
             ) == :ok

      assert {:refuse, [why]} =
               AtlasEyra.check(kind, Map.put(made, "links", parent), flow, lookup())

      assert why =~ "records its producer (produced_by)"
      assert why =~ "by flow links nobody"
    end
  end
end
