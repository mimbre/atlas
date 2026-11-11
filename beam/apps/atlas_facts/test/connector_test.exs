defmodule AtlasFacts.ConnectorTest do
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.{Connector, Copies, FakeRela, StubHttp}

  @moduletag :tmp_dir

  # The outside system of these tests: a map of address => fields, or => {:error, why}.
  defmodule Outside do
    @behaviour AtlasFacts.Connector
    def label(_), do: "Outside"

    def read(agent, addresses) do
      Agent.update(agent, &%{&1 | asked: &1.asked ++ addresses})
      things = Agent.get(agent, & &1.things)

      Map.new(addresses, fn address ->
        case things[address] do
          nil -> {address, {:error, "nothing at #{address}"}}
          {:error, why} -> {address, {:error, why}}
          fields -> {address, {:ok, fields}}
        end
      end)
    end

    def put(agent, address, fields),
      do: Agent.update(agent, &put_in(&1, [:things, address], fields))

    def asked(agent), do: Agent.get_and_update(agent, &{&1.asked, %{&1 | asked: []}})
  end

  # As `rela/atlas.json` adds it: an address, the fields it fills, and when to stop.
  @extra %{
    "entities" => %{
      "widget" => %{
        "properties" => %{"link" => %{"type" => "string"}, "title" => %{"set_by" => "connector"}},
        "connector" => %{
          "system" => "outside",
          "address" => "link",
          "fields" => %{"title" => "name", "shade" => "tone", "done" => "finished"},
          "until" => %{"done" => [true]},
          # A finished widget whose name names parts was also done for them.
          "names" => %{
            "field" => "title",
            "relation" => "also_for",
            "when" => %{"done" => [true]}
          }
        }
      },
      "part" => %{"create" => %{"id" => %{"prefix" => "P-"}}}
    },
    "relations" => %{"also_for" => %{"from" => ["part"], "to" => ["widget"]}}
  }

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    extra = Path.join(dir, "extra.json")
    File.write!(extra, JSON.encode!(@extra))
    rela = FakeRela.start()

    start_supervised!(
      {AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, description_extra: extra}
    )

    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    {:ok, outside} = Agent.start_link(fn -> %{things: %{}, asked: []} end)
    %{rela: rela, dir: dir, outside: outside}
  end

  defp start_connector(%{dir: dir, outside: outside}) do
    start_supervised!(
      {Connector, system: "outside", source: {Outside, outside}, every: 3_600_000, data_dir: dir}
    )
  end

  defp fact(op, key, values, opts \\ []) do
    envelope = Envelope.new("fact", "widget")
    content = %{"op" => op, "key" => key, "values" => values, "version" => opts[:version]}
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "stored"}, _}, 1_000
  end

  defp read(key) do
    envelope = Envelope.new("read", "widget")
    :ok = AtlasBus.send(envelope, %{"key" => key})
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id}, answer}, 1_000
    answer
  end

  defp values(rela, key), do: rela |> FakeRela.facts() |> Map.fetch!(key) |> elem(0)

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("it did not happen")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "a round copies the outside fields; the same values again store nothing", ctx do
    fact("create", "W-1", %{"title" => "Old", "link" => "out/1"})
    Outside.put(ctx.outside, "out/1", %{"name" => "One", "tone" => "dark", "finished" => false})
    connector = start_connector(ctx)
    :ok = Connector.round(connector)

    assert %{"title" => "One", "shade" => "dark", "done" => false} = values(ctx.rela, "W-1")
    position = read("W-1")["position"]

    :ok = Connector.round(connector)
    assert read("W-1")["position"] == position
    assert ["out/1", "out/1" | _] = Outside.asked(ctx.outside)
  end

  test "a change is one fact, with its cause, and is hinted like any other", ctx do
    fact("create", "W-1", %{"title" => "Old", "link" => "out/1"})
    :ok = AtlasBus.listen("widget")
    Outside.put(ctx.outside, "out/1", %{"name" => "New"})
    :ok = Connector.round(start_connector(ctx))

    assert_receive {:atlas_bus, %Envelope{class: "stored", kind: "widget"},
                    %{"op" => "change", "key" => "W-1", "cause" => cause}}

    assert cause =~ ~r/^Outside connector, read at \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/
  end

  test "a fact just made is read at once, by its hint, without a round", ctx do
    start_connector(ctx)
    Outside.put(ctx.outside, "out/2", %{"name" => "Two", "tone" => "light"})
    fact("create", "W-2", %{"title" => "?", "link" => "out/2"})
    eventually(fn -> values(ctx.rela, "W-2")["title"] == "Two" end)
  end

  test "a finished fact whose name names other facts links them to it, once", ctx do
    for key <- ["P-1", "P-2"] do
      envelope = Envelope.new("fact", "part")

      :ok =
        AtlasBus.send(envelope, %{"op" => "create", "key" => key, "values" => %{"title" => key}})

      id = envelope.id
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "stored"}, _}, 1_000
    end

    fact("create", "W-1", %{"title" => "x", "link" => "o/1"})
    Outside.put(ctx.outside, "o/1", %{"name" => "Fixes P-1, P-2 and P-9", "finished" => false})
    connector = start_connector(ctx)
    :ok = Connector.round(connector)
    # Not finished yet: nothing linked.
    assert FakeRela.links(ctx.rela)["P-1"] in [nil, %{}]

    Outside.put(ctx.outside, "o/1", %{"name" => "Fixes P-1, P-2 and P-9", "finished" => true})
    :ok = Connector.round(connector)
    links = FakeRela.links(ctx.rela)
    assert links["P-1"]["also_for"] == ["W-1"]
    assert links["P-2"]["also_for"] == ["W-1"]
    # P-9 does not exist: nothing to link.
    refute Map.has_key?(links, "P-9")

    # The next round finds them linked and sends nothing.
    :ok = Connector.round(connector)
    assert FakeRela.links(ctx.rela) == links
  end

  test "a fact that is done is read no more", ctx do
    fact("create", "W-1", %{"title" => "One", "link" => "out/1", "done" => true})
    Outside.put(ctx.outside, "out/1", %{"name" => "Renamed"})
    connector = start_connector(ctx)
    Outside.asked(ctx.outside)
    :ok = Connector.round(connector)

    assert Outside.asked(ctx.outside) == []
    assert values(ctx.rela, "W-1")["title"] == "One"
  end

  test "a failed read keeps the stored values; the page says when it was last read", ctx do
    fact("create", "W-1", %{"title" => "Old", "link" => "out/1"})
    Outside.put(ctx.outside, "out/1", %{"name" => "One"})
    connector = start_connector(ctx)
    :ok = Connector.round(connector)

    assert %{"copy" => %{"source" => "Outside", "read_at" => read_at, "failure" => nil}} =
             read("W-1")

    Outside.put(ctx.outside, "out/1", {:error, "it answered 503"})
    :ok = Connector.round(connector)
    assert values(ctx.rela, "W-1")["title"] == "One"

    assert %{"read_at" => ^read_at, "failure" => "it answered 503", "failed_at" => _} =
             read("W-1")["copy"]

    Outside.put(ctx.outside, "out/1", %{"name" => "One"})
    :ok = Connector.round(connector)
    assert %{"failure" => nil} = Copies.get("widget", "W-1")
  end

  describe "GitHub, as the source" do
    alias AtlasFacts.Connector.GitHub

    @pull "https://github.com/eyra/atlas/pull/1"

    defp github(answer, token_command \\ ["echo", "t0ken"]) do
      stub = StubHttp.start(answer)
      {stub, %{"api" => stub.url, "token_command" => token_command}}
    end

    test "reads title, state and draft with a GET and the token; merged is a state" do
      {stub, config} =
        github(fn
          %{path: "/repos/eyra/atlas/pulls/1"} ->
            {200,
             ~s|{"title":"Skeleton","state":"closed","merged":true,"draft":false,"html_url":"#{@pull}"}|}

          %{path: "/repos/eyra/atlas/pulls/2"} ->
            {200, ~s|{"title":"Draft","state":"open","merged":false,"draft":true}|}
        end)

      second = "https://github.com/eyra/atlas/pull/2"

      assert %{
               @pull => {:ok, %{"title" => "Skeleton", "state" => "merged", "isDraft" => false}},
               ^second => {:ok, %{"title" => "Draft", "state" => "open", "isDraft" => true}}
             } = GitHub.read(config, [@pull, second])

      assert [_, _] = StubHttp.requests(stub)

      for request <- StubHttp.requests(stub) do
        assert request.method == "GET"
        assert request.headers["authorization"] == "Bearer t0ken"
      end
    end

    test "says why a read failed, never with the token" do
      {_stub, config} = github(fn _ -> {404, ~s|{"message":"Not Found"}|} end)

      assert %{@pull => {:error, "GitHub answered 404 (no such pull, or no access)"}} =
               GitHub.read(config, [@pull])

      assert %{@pull => {:error, "no token: false exited 1"}} =
               GitHub.read(%{config | "token_command" => ["false"]}, [@pull])

      assert %{
               "https://example.com/x" =>
                 {:error, "https://example.com/x is not the address" <> _}
             } =
               GitHub.read(config, ["https://example.com/x"])
    end

    test "on Fly the token comes from an environment variable, a secret of the app" do
      {stub, config} = github(fn _ -> {200, ~s|{"title":"T","state":"open","merged":false}|} end)
      config = config |> Map.delete("token_command") |> Map.put("token_env", "ATLAS_TEST_GH")

      assert %{@pull => {:error, "no token: ATLAS_TEST_GH is not set"}} =
               GitHub.read(config, [@pull])

      assert [] = StubHttp.requests(stub)

      System.put_env("ATLAS_TEST_GH", "s3cret\n")
      on_exit(fn -> System.delete_env("ATLAS_TEST_GH") end)

      assert %{@pull => {:ok, %{"title" => "T"}}} = GitHub.read(config, [@pull])
      assert [%{headers: %{"authorization" => "Bearer s3cret"}}] = StubHttp.requests(stub)
    end
  end
end
