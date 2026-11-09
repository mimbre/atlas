defmodule AtlasStateTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasState.FakeRela

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    rela = FakeRela.start()
    start_supervised!({AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    %{rela: rela, dir: dir}
  end

  defp fact(op, key, values \\ %{}, opts \\ []) do
    envelope = Envelope.new("fact", Keyword.get(opts, :kind, "widget"), Keyword.take(opts, [:id]))
    content = %{"op" => op, "key" => key, "values" => values, "version" => opts[:version]}

    content =
      for name <- [:links, :cause, :by],
          opts[name] != nil,
          into: content,
          do: {Atom.to_string(name), opts[name]}

    send_and_wait(envelope, content)
  end

  defp read(kind, content \\ %{}) do
    {"answer", answer, _} = send_and_wait(Envelope.new("read", kind), content)
    answer
  end

  defp send_and_wait(envelope, content) do
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 1_000
    {reply.class, answer, reply.position}
  end

  test "a fact is stored once and answered with stored and a position", %{rela: rela} do
    assert {"stored", %{"op" => "create", "key" => "W-1"}, 1} =
             fact("create", "W-1", %{"title" => "One", "shade" => "dark"})

    assert {"stored", _, 2} = fact("create", "W-2", %{"title" => "Two"})
    assert %{"W-1" => {%{"title" => "One", "shade" => "dark"}, _}} = FakeRela.facts(rela)
  end

  test "a resent id is stored once and gets the same answer again", %{rela: rela} do
    first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    FakeRela.poke(rela, "W-1", %{"title" => "Changed by someone else"})
    assert ^first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    assert {"stored", _, 1} = first
    assert {"stored", _, 2} = fact("change", "W-1", %{"title" => "Again"})
  end

  test "the answers survive a restart of State", %{rela: rela, dir: dir} do
    first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    stop_supervised!(AtlasState.Server)
    start_supervised!({AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir})
    assert ^first = fact("create", "W-1", %{"title" => "One"}, id: "fixed-id")
    assert {"stored", _, 2} = fact("create", "W-2", %{"title" => "Two"})
  end

  test "a create that rela already has, after a lost answer, counts as stored", %{rela: rela} do
    {:ok, _} = FakeRela.create(rela, "widgets", "W-1", %{"title" => "One"}, %{})
    assert {"stored", _, 1} = fact("create", "W-1", %{"title" => "One"})

    assert {"refused", %{"reasons" => ["W-1 already exists"], "code" => "exists"}, nil} =
             fact("create", "W-1", %{"title" => "Other"})
  end

  test "values that do not fit the description are refused before rela sees them", %{rela: rela} do
    assert {"refused", %{"reasons" => reasons}, nil} =
             fact("create", "W-1", %{"shade" => "purple", "done" => "yes", "size" => 3})

    assert "shade must be one of light, dark" in reasons
    assert "done must be true or false" in reasons
    assert "size is not described" in reasons
    assert "title is required" in reasons

    assert {"refused", %{"reasons" => ["id must start with W-", "title is required"]}, nil} =
             fact("create", "X-1", %{})

    assert FakeRela.facts(rela) == %{}
  end

  test "an unknown kind is refused", _ do
    assert {"refused", %{"reasons" => ["rela does not describe \"gadget\""]}, nil} =
             fact("create", "G-1", %{"title" => "x"}, kind: "gadget")
  end

  test "a change on an old version is refused, unless it is already applied", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    assert {"stored", _, _} = fact("change", "W-1", %{"title" => "Two"}, version: version)
    assert {"stored", _, _} = fact("change", "W-1", %{"title" => "Two"}, version: version)

    assert {"refused", %{"reasons" => ["W-1 changed meanwhile; open it again"]}, nil} =
             fact("change", "W-1", %{"title" => "Three"}, version: version)

    assert {%{"title" => "Two"}, _} = FakeRela.facts(rela)["W-1"]
  end

  test "an old version is no conflict when only other fields changed meanwhile (was)",
       %{rela: rela} do
    fact("create", "W-1", %{"title" => "One", "shade" => "light"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    read_with = %{"title" => "One", "shade" => "light"}

    # Someone else (Flow, a connector) changes another field meanwhile.
    FakeRela.poke(rela, "W-1", %{"done" => true})

    assert {"stored", _, _} =
             send_and_wait(Envelope.new("fact", "widget"), %{
               "op" => "change",
               "key" => "W-1",
               "values" => %{"title" => "Uno", "shade" => "light"},
               "version" => version,
               "was" => read_with
             })

    # The user's change and the other writer's both stay.
    assert {%{"title" => "Uno", "shade" => "light", "done" => true}, _} =
             FakeRela.facts(rela)["W-1"]
  end

  test "an old version is refused when a field it sets changed meanwhile, or without was",
       %{rela: rela} do
    fact("create", "W-1", %{"title" => "One", "shade" => "light"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    FakeRela.poke(rela, "W-1", %{"shade" => "dark"})

    change = fn content ->
      send_and_wait(
        Envelope.new("fact", "widget"),
        Map.merge(%{"op" => "change", "key" => "W-1", "version" => version}, content)
      )
    end

    assert {"refused", %{"reasons" => ["W-1 changed meanwhile; open it again"]}, _} =
             change.(%{
               "values" => %{"title" => "Uno", "shade" => "light"},
               "was" => %{"title" => "One", "shade" => "light"}
             })

    # Without was, any change meanwhile is a conflict, as before.
    FakeRela.poke(rela, "W-1", %{"done" => true})

    assert {"refused", _, _} = change.(%{"values" => %{"title" => "Uno"}})
    assert {%{"title" => "One", "shade" => "dark"}, _} = FakeRela.facts(rela)["W-1"]
  end

  test "an empty optional value clears it; a required one cannot be cleared", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One", "shade" => "dark"})
    assert {"stored", _, _} = fact("change", "W-1", %{"shade" => ""})
    assert {%{"title" => "One"}, _} = FakeRela.facts(rela)["W-1"]

    assert {"refused", %{"reasons" => ["title is required"]}, nil} =
             fact("change", "W-1", %{"title" => ""})
  end

  test "a delete on an old version is refused", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    %{"fact" => %{"version" => version}} = read("widget", %{"key" => "W-1"})
    FakeRela.poke(rela, "W-1", %{"title" => "Changed by someone else"})

    assert {"refused", %{"reasons" => ["W-1 changed meanwhile; open it again"]}, nil} =
             fact("delete", "W-1", %{}, version: version)
  end

  test "a deleted id is reserved for a while, and State says so", _ do
    fact("create", "W-1", %{"title" => "One"})
    assert {"stored", %{"op" => "delete"}, _} = fact("delete", "W-1")
    assert {"stored", _, _} = fact("delete", "W-1")

    assert {"refused", %{"reasons" => [reason], "code" => "reserved"}, nil} =
             fact("create", "W-1", %{"title" => "One"})

    assert reason =~ "deleted a moment ago"
  end

  test "when rela is down, State still answers, and the id can be stored later", %{rela: rela} do
    FakeRela.down(rela)

    assert {"refused", %{"reasons" => ["rela is not reachable"]}, nil} =
             fact("create", "W-1", %{"title" => "One"}, id: "later")

    FakeRela.up(rela)
    assert {"stored", _, 1} = fact("create", "W-1", %{"title" => "One"}, id: "later")
  end

  test "reads: the description, all facts of a kind, one fact with what points at it",
       %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two"})
    FakeRela.link(rela, "P-1", "W-1")

    assert %{"description" => %{"entities" => %{"widget" => _}}, "position" => 2} =
             read("_description")

    assert %{"facts" => [%{"key" => "W-1"}, %{"key" => "W-2"}]} = read("widget")

    assert %{
             "fact" => %{"key" => "W-1", "values" => %{"title" => "One"}, "version" => "v0"},
             "incoming" => %{"of_widget" => ["P-1"]}
           } = read("widget", %{"key" => "W-1"})

    assert %{"fact" => nil} = read("widget", %{"key" => "W-9"})
    assert %{"error" => "rela does not describe \"gadget\""} = read("gadget")
  end

  test "a plain read answers the fact and its links only", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    FakeRela.link(rela, "P-1", "W-1")

    assert %{"fact" => %{"key" => "W-1", "values" => %{"title" => "One"}} = plain} =
             answer = read("widget", %{"key" => "W-1", "plain" => true})

    refute Map.has_key?(answer, "incoming")
    refute Map.has_key?(plain, "progress")
    assert %{"fact" => nil} = read("widget", %{"key" => "W-9", "plain" => true})
  end

  test "Atlas's additions are merged into the description State answers", %{rela: rela, dir: dir} do
    extra = Path.join(dir, "atlas.json")

    File.write!(
      extra,
      ~s({"_about": "x", "entities": {"widget": {"create": {"ask": ["title"]}}}})
    )

    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    %{"description" => description} = read("_description")
    assert description["entities"]["widget"]["create"] == %{"ask" => ["title"]}
    assert description["entities"]["widget"]["plural"] == "widgets"
    refute Map.has_key?(description, "_about")
  end

  # A widget has a tag, made and deleted with it (a made-up component, as the Assignment).
  test "a fact's components are made in the same write, and deleted with it", %{
    rela: rela,
    dir: dir
  } do
    extra = Path.join(dir, "atlas.json")

    File.write!(
      extra,
      JSON.encode!(%{
        "entities" => %{
          "tag" => %{"plural" => "tags", "properties" => %{"title" => %{"type" => "string"}}}
        },
        "relations" => %{
          "tagged" => %{
            "from" => ["widget"],
            "to" => ["tag"],
            "max_outgoing" => 1,
            "component" => %{"key" => "T-{key}", "values" => %{"title" => "{key}"}}
          }
        }
      })
    )

    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    assert {"stored", _, _} = fact("create", "W-1", %{"title" => "One"}, cause: "made")
    assert {%{"title" => "W-1"}, _} = FakeRela.facts(rela)["T-W-1"]
    assert %{"fact" => %{"links" => %{"tagged" => ["T-W-1"]}}} = read("widget", %{"key" => "W-1"})

    # Sent again after a lost answer: stored, once.
    assert {"stored", _, _} = fact("create", "W-1", %{"title" => "One"})
    assert map_size(FakeRela.facts(rela)) == 2

    # A fact that is refused leaves no component behind.
    assert {"refused", _, _} = fact("create", "W-2", %{"title" => "Two", "shade" => "red"})
    refute Map.has_key?(FakeRela.facts(rela), "T-W-2")

    # Never alone while its fact exists; with it, always.
    assert {"refused", %{"reasons" => ["T-W-1 goes with W-1; delete that instead"]}, _} =
             fact("delete", "T-W-1", %{}, kind: "tag")

    assert {"stored", _, _} = fact("delete", "W-1")
    assert FakeRela.facts(rela) == %{}
  end

  test "a kind rela does not know says so, and what to do; never 'not reachable'", %{
    rela: rela,
    dir: dir
  } do
    # The build's additions name a kind the running rela's description does not have.
    extra = Path.join(dir, "atlas.json")
    File.write!(extra, ~s({"entities": {"ghost": {"create": {"ask": ["title"]}}}}))
    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    older =
      "rela does not know ghost: its description is older than this build; " <>
        "run atlas restart --env #{AtlasBus.environment()}"

    assert %{"error" => ^older, "error_kind" => "answered"} = read("ghost")
    assert %{"error" => ^older} = read("ghost", %{"key" => "G-1"})

    assert {"refused", %{"reasons" => [^older]}, nil} =
             fact("create", "G-1", %{"title" => "x"}, kind: "ghost")

    # Only a rela that does not answer is "not reachable".
    FakeRela.down(rela)
    assert %{"error" => "rela is not reachable", "error_kind" => "unreachable"} = read("widget")
  end

  test "reads carry how far a fact is, from the facts under it, as the description's rule says",
       %{rela: rela, dir: dir} do
    extra = Path.join(dir, "atlas.json")

    File.write!(
      extra,
      ~s({"progress": {"order": ["rough", "fine"]},
      "entities": {"widget": {"progress": {"over": "of_widget", "field": "phase", "own": "shade"}}}})
    )

    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two", "shade" => "dark"})

    for {key, phase} <- [{"P-1", "fine"}, {"P-2", "rough"}, {"P-3", "fine"}] do
      {:ok, _} =
        FakeRela.create(rela, "parts", key, %{"title" => key, "phase" => phase}, %{
          "of_widget" => {"widget", ["W-1"]}
        })
    end

    assert %{"fact" => %{"progress" => %{"value" => "rough", "count" => 1, "of" => 3}}} =
             read("widget", %{"key" => "W-1"})

    assert %{"fact" => %{"progress" => %{"value" => "dark", "label" => "dark"}}} =
             read("widget", %{"key" => "W-2"})

    # Nothing is stored: a change under it shows on the next read.
    FakeRela.poke(rela, "P-2", %{"phase" => "fine"})

    assert %{"fact" => %{"progress" => %{"value" => "fine", "count" => 3, "of" => 3}}} =
             read("widget", %{"key" => "W-1"})

    refute Map.has_key?(elem(FakeRela.facts(rela)["W-1"], 0), "progress")
  end

  test "a create can link to the fact it belongs to; reads show the link and filter by it", _ do
    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two"})

    assert {"stored", _, _} =
             fact("create", "P-1", %{"title" => "Part"},
               kind: "part",
               links: %{"of_widget" => ["W-1"]}
             )

    fact("create", "P-2", %{"title" => "Loose"}, kind: "part")

    assert %{"fact" => %{"links" => %{"of_widget" => ["W-1"]}}} = read("part", %{"key" => "P-1"})

    assert %{"facts" => [%{"key" => "P-1"}]} =
             read("part", %{"linked" => %{"of_widget" => "W-1"}})

    assert %{"facts" => []} = read("part", %{"linked" => %{"of_widget" => "W-2"}})
    assert %{"incoming" => %{"of_widget" => ["P-1"]}} = read("widget", %{"key" => "W-1"})
  end

  test "a read can filter on what the linked fact points at, one step on", _ do
    fact("create", "M-1", %{"title" => "Maker"}, kind: "maker")
    fact("create", "W-1", %{"title" => "Made"}, links: %{"made_by" => ["M-1"]})
    fact("create", "W-2", %{"title" => "Not made"})
    fact("create", "P-1", %{"title" => "On made"}, kind: "part", links: %{"of_widget" => ["W-1"]})

    fact("create", "P-2", %{"title" => "On other"},
      kind: "part",
      links: %{"of_widget" => ["W-2"]}
    )

    assert %{"facts" => [%{"key" => "P-1"}]} =
             read("part", %{"linked" => %{"of_widget" => %{"made_by" => "M-1"}}})

    assert %{"facts" => []} = read("part", %{"linked" => %{"of_widget" => %{"made_by" => "M-9"}}})
  end

  test "a link the description does not allow, or to nothing, is refused", _ do
    fact("create", "W-1", %{"title" => "One"})

    assert {"refused", %{"reasons" => ["of_gadget is not described"]}, nil} =
             fact("create", "P-1", %{}, kind: "part", links: %{"of_gadget" => ["W-1"]})

    assert {"refused", %{"reasons" => ["of_widget does not start at widget"]}, nil} =
             fact("create", "W-2", %{"title" => "Two"}, links: %{"of_widget" => ["W-1"]})

    assert {"refused", %{"reasons" => ["of_widget allows at most 1"]}, nil} =
             fact("create", "P-1", %{}, kind: "part", links: %{"of_widget" => ["W-1", "W-1"]})

    assert {"refused", %{"reasons" => ["W-9 does not exist"]}, nil} =
             fact("create", "P-1", %{"title" => "x"},
               kind: "part",
               links: %{"of_widget" => ["W-9"]}
             )
  end

  test "a change sets or removes the links it names; reads say since when, by whom and why",
       _ do
    fact("create", "M-1", %{"title" => "Ada"}, kind: "maker")
    fact("create", "W-1", %{"title" => "One"})

    assert {"stored", %{"by" => "ada", "cause" => "made it"}, position} =
             fact("change", "W-1", %{},
               links: %{"made_by" => ["M-1"]},
               by: "ada",
               cause: "made it"
             )

    assert %{"fact" => %{"links" => %{"made_by" => ["M-1"]}, "origins" => origins}} =
             read("widget", %{"key" => "W-1"})

    assert %{"made_by" => %{"keys" => ["M-1"], "by" => "ada", "cause" => "made it"}} = origins
    assert %{"position" => ^position, "since" => since} = origins["made_by"]
    assert {:ok, _, 0} = DateTime.from_iso8601(since)
    # The fake lists every kind's facts at once.
    assert %{"origins" => ^origins} = Enum.find(read("widget")["facts"], &(&1["key"] == "W-1"))

    # Removing it is a fact too: the origin then says who removed it and why.
    assert {"stored", _, _} =
             fact("change", "W-1", %{}, links: %{"made_by" => []}, by: "bob", cause: "not hers")

    assert %{"fact" => fact, "history" => %{"made_by" => [first, second]}} =
             read("widget", %{"key" => "W-1"})

    assert fact["links"] == %{}
    assert %{"made_by" => %{"keys" => [], "by" => "bob", "cause" => "not hers"}} = fact["origins"]
    assert first["keys"] == ["M-1"] and second["keys"] == []
  end

  test "a link set behind State's back has no origin", %{rela: rela} do
    fact("create", "M-1", %{"title" => "Ada"}, kind: "maker")
    fact("create", "W-1", %{"title" => "One"})
    fact("change", "W-1", %{}, links: %{"made_by" => ["M-1"]})
    fact("create", "M-2", %{"title" => "Bob"}, kind: "maker")
    FakeRela.link(rela, "W-1", "M-2", "made_by")

    assert %{"fact" => %{"links" => %{"made_by" => ["M-2"]}, "origins" => %{}}} =
             read("widget", %{"key" => "W-1"})
  end

  # One owner (at most one link); a new one replaces the old,
  # which stays in the link's history with the cause it was set with.
  test "one owner: a new owner replaces the old; the old stays in the history, with its cause",
       _ do
    fact("create", "M-1", %{"title" => "Coordinator"}, kind: "maker")
    fact("create", "M-2", %{"title" => "Ann"}, kind: "maker")
    fact("create", "W-1", %{"title" => "One"})

    fact("change", "W-1", %{},
      links: %{"made_by" => ["M-1"]},
      by: "agent",
      cause: "owner introduced"
    )

    fact("change", "W-1", %{},
      links: %{"made_by" => ["M-2"]},
      by: "agent",
      cause: "all its parts are done"
    )

    assert %{"fact" => fact, "history" => %{"made_by" => [first, second]}} =
             read("widget", %{"key" => "W-1"})

    assert fact["links"]["made_by"] == ["M-2"]
    assert %{"keys" => ["M-2"], "cause" => "all its parts are done"} = fact["origins"]["made_by"]
    assert %{"keys" => ["M-1"], "by" => "agent", "cause" => "owner introduced"} = first
    assert %{"keys" => ["M-2"], "cause" => "all its parts are done"} = second
  end

  # Only facts of the kinds a relation points at can be linked: here a widget is owned by
  # a maker or a part.
  test "a link to one of several kinds: a key of none of them is refused, naming the kinds",
       %{rela: rela, dir: dir} do
    extra = Path.join(dir, "atlas.json")

    File.write!(
      extra,
      ~s({"relations": {"owned_by": {"from": ["widget"], "to": ["maker", "part"], "max_outgoing": 1}}})
    )

    stop_supervised!(AtlasState.Server)

    start_supervised!(
      {AtlasState.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    fact("create", "M-1", %{"title" => "Coordinator"}, kind: "maker")
    fact("create", "P-1", %{"title" => "Ann"}, kind: "part")
    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two"})

    assert {"stored", _, _} = fact("change", "W-1", %{}, links: %{"owned_by" => ["M-1"]})
    assert {"stored", _, _} = fact("change", "W-1", %{}, links: %{"owned_by" => ["P-1"]})

    assert {"refused", %{"reasons" => ["nobody is not a maker or part"]}, nil} =
             fact("change", "W-1", %{}, links: %{"owned_by" => ["nobody"]})

    # A fact of another kind is no owner either.
    assert {"refused", %{"reasons" => ["W-2 is not a maker or part"]}, nil} =
             fact("change", "W-1", %{}, links: %{"owned_by" => ["W-2"]})

    assert %{"fact" => %{"links" => %{"owned_by" => ["P-1"]}}} = read("widget", %{"key" => "W-1"})
  end

  test "a change's links are checked like a create's", _ do
    fact("create", "W-1", %{"title" => "One"})

    assert {"refused", %{"reasons" => ["made_by allows at most 1"]}, nil} =
             fact("change", "W-1", %{}, links: %{"made_by" => ["M-1", "M-2"]})

    assert {"refused", %{"reasons" => ["M-9 does not exist"]}, nil} =
             fact("change", "W-1", %{}, links: %{"made_by" => ["M-9"]})

    assert {"refused", %{"reasons" => ["of_widget does not start at widget"]}, nil} =
             fact("change", "W-1", %{}, links: %{"of_widget" => []})
  end

  test "a deleted fact's links are forgotten", _ do
    fact("create", "M-1", %{"title" => "Ada"}, kind: "maker")
    fact("create", "W-1", %{"title" => "One"}, links: %{"made_by" => ["M-1"]})
    assert %{"history" => %{"made_by" => [_]}} = read("widget", %{"key" => "W-1"})
    fact("delete", "W-1")
    assert %{"fact" => nil} = read("widget", %{"key" => "W-1"})
  end

  test "a change can move a fact to another parent; reads follow it", %{rela: rela} do
    fact("create", "W-1", %{"title" => "One"})
    fact("create", "W-2", %{"title" => "Two"})
    fact("create", "P-1", %{"title" => "Part"}, kind: "part", links: %{"of_widget" => ["W-1"]})
    %{"fact" => %{"version" => version}} = read("part", %{"key" => "P-1"})

    assert {"stored", %{"op" => "change", "cause" => "moved"}, _} =
             send_and_wait(Envelope.new("fact", "part"), %{
               "op" => "change",
               "key" => "P-1",
               "values" => %{},
               "version" => version,
               "links" => %{"of_widget" => ["W-2"]},
               "cause" => "moved"
             })

    assert %{"fact" => %{"links" => %{"of_widget" => ["W-2"]}}} = read("part", %{"key" => "P-1"})
    assert %{"incoming" => %{"of_widget" => []}} = read("widget", %{"key" => "W-1"})
    assert %{"incoming" => %{"of_widget" => ["P-1"]}} = read("widget", %{"key" => "W-2"})

    # Sent again on the old version after a lost answer: already where it was asked to go.
    assert {"stored", _, _} =
             fact("change", "P-1", %{},
               kind: "part",
               version: version,
               links: %{"of_widget" => ["W-2"]}
             )

    # On the old version to somewhere else: someone changed it meanwhile.
    assert {"refused", %{"reasons" => ["P-1 changed meanwhile; open it again"]}, _} =
             fact("change", "P-1", %{},
               kind: "part",
               version: version,
               links: %{"of_widget" => ["W-1"]}
             )

    assert {"refused", %{"reasons" => ["W-9 does not exist"]}, _} =
             fact("change", "P-1", %{}, kind: "part", links: %{"of_widget" => ["W-9"]})

    assert {"refused", %{"reasons" => ["of_widget allows at most 1"]}, _} =
             fact("change", "P-1", %{}, kind: "part", links: %{"of_widget" => ["W-1", "W-2"]})

    assert FakeRela.facts(rela)["P-1"] |> elem(0) == %{"title" => "Part"}
  end

  test "a stored fact is a hint to listeners of its kind", _ do
    test = self()

    spawn_link(fn ->
      :ok = AtlasBus.attach("listener-#{System.unique_integer([:positive])}")
      :ok = AtlasBus.listen("widget")
      send(test, :listening)

      receive do
        {:atlas_bus, envelope, content} -> send(test, {:hint, envelope, content})
      end
    end)

    assert_receive :listening
    fact("create", "W-1", %{"title" => "One"})

    assert_receive {:hint, %Envelope{class: "stored", kind: "widget", position: 1},
                    %{"key" => "W-1"}}
  end
end
