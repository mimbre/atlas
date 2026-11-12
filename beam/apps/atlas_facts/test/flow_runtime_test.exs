defmodule AtlasFacts.FlowRuntimeTest do
  use ExUnit.Case, async: true
  alias AtlasFacts.FlowRuntime

  def fixture do
    fields = Map.new(FlowRuntime.fields(), &{&1, &1})

    props =
      Map.new(fields, fn {name, field} ->
        {field,
         %{"type" => if(name in ~w(generation entry input_cursor), do: "integer", else: "string")}}
      end)

    projection = %{"field" => "todo"}

    selection = %{
      "subject" => "box",
      "legacy" => "pack",
      "projection" => projection,
      "admission" => %{"phase" => ["first"]},
      "imports" => [%{"when" => %{"phase" => ["old"]}, "state" => "done"}],
      "follow_through" => nil
    }

    description = %{
      "entities" => %{
        "cursor" => %{"properties" => props},
        "box" => %{"properties" => %{"phase" => %{"type" => "string"}}}
      },
      "flows" => %{"pack" => Map.put(projection, "kinds", ["box"])}
    }

    config = %{
      "version" => 1,
      "kind" => "cursor",
      "fields" => fields,
      "writer" => %{"sender" => "flow", "by" => "flow"},
      "selection" => %{"sort" => selection}
    }

    {description, config}
  end

  test "the separate fragment binds only to described kinds, fields and legacy projection" do
    {description, config} = fixture()
    assert FlowRuntime.validate(description, config) == :ok
    assert {:ok, merged} = FlowRuntime.describe(description, %{"flow_runtime" => config})
    assert merged["flow_runtime"] == config

    for bad <- [
          Map.put(config, "version", 2),
          Map.put(config, "extra", true),
          Map.put(config, "kind", "missing"),
          put_in(config, ["fields", "entry"], "unknown"),
          put_in(config, ["fields", "state"], "entry"),
          put_in(config, ["writer", "sender"], ""),
          put_in(config, ["selection", "sort", "legacy"], "missing"),
          put_in(config, ["selection", "sort", "projection", "field"], "other"),
          put_in(config, ["selection", "sort", "admission"], %{"unknown" => ["yes"]}),
          put_in(config, ["selection", "sort", "imports", Access.at(0), "when"], %{
            "unknown" => ["yes"]
          })
        ],
        do: assert({:error, _} = FlowRuntime.validate(description, bad))
  end

  test "two phases may have disjoint admission, overlapping projection owners are refused" do
    {description, config} = fixture()
    second = put_in(config["selection"]["sort"], ["admission", "phase"], ["second"])
    disjoint = put_in(config, ["selection", "ship"], second)
    assert FlowRuntime.validate(description, disjoint) == :ok

    assert {:error, _} =
             FlowRuntime.validate(
               description,
               put_in(config, ["selection", "ship"], config["selection"]["sort"])
             )
  end

  test "migration reasons are optional text in the separately deployed mapping" do
    {description, config} = fixture()

    mapping = %{
      "from" => String.duplicate("a", 64),
      "to" => String.duplicate("b", 64),
      "states" => %{"waiting" => "checking"}
    }

    for row <- [mapping, Map.put(mapping, "reason", "Enter the new check")] do
      configured = put_in(config, ["selection", "sort", "migrations"], [row])
      assert FlowRuntime.validate(description, configured) == :ok
    end

    for reason <- ["", false, [], %{}] do
      configured =
        put_in(config, ["selection", "sort", "migrations"], [Map.put(mapping, "reason", reason)])

      assert {:error, _} = FlowRuntime.validate(description, configured)
    end
  end

  test "encoding migrations require an explicit true marker and identity state mappings" do
    {description, config} = fixture()

    row = %{
      "from" => String.duplicate("a", 64),
      "to" => String.duplicate("b", 64),
      "rekey" => true,
      "states" => %{"waiting" => "waiting"}
    }

    assert :ok =
             FlowRuntime.validate(
               description,
               put_in(config, ["selection", "sort", "migrations"], [row])
             )

    for bad <- [
          Map.put(row, "rekey", false),
          Map.put(row, "rekey", "true"),
          put_in(row, ["states", "waiting"], "checking")
        ] do
      assert {:error, _} =
               FlowRuntime.validate(
                 description,
                 put_in(config, ["selection", "sort", "migrations"], [bad])
               )
    end
  end

  test "presentation templates apply only to targets the composition declares" do
    {description, config} = fixture()

    description =
      Map.put(description, "relations", %{"anchor" => %{"from" => ["cursor"], "to" => ["box"]}})

    rule = %{"field" => "phase", "value" => "first", "label" => "Check anchor"}

    config =
      config
      |> Map.put("reviews", %{"anchor" => [rule], "absent" => [rule]})
      |> Map.put("flags", %{"box" => rule, "absent" => rule})

    assert :ok = FlowRuntime.validate(description, config)
    assert {:ok, merged} = FlowRuntime.describe(description, %{"flow_runtime" => config})
    assert merged["flow_runtime"]["reviews"] == %{"anchor" => [rule]}
    assert merged["flow_runtime"]["flags"] == %{"box" => rule}
    refute Map.has_key?(merged["relations"], "absent")
    assert merged["relations"]["anchor"]["review"] == [rule]
    assert merged["flow_runtime"]["selection"] == config["selection"]

    for bad <- [
          put_in(config, ["reviews", "anchor"], [Map.put(rule, "field", "unknown")]),
          put_in(config, ["flags", "box", "field"], "unknown"),
          Map.put(config, "reviews", [])
        ] do
      assert {:error, _} = FlowRuntime.describe(description, %{"flow_runtime" => bad})
    end
  end
end

defmodule AtlasFacts.FlowRuntimeWriterTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope

  defmodule Backend do
    def description(_pid) do
      {description, _} = AtlasFacts.FlowRuntimeTest.fixture()
      description = put_in(description, ["entities", "cursor", "plural"], "cursors")
      {:ok, Map.put(description, "flows", %{})}
    end

    defdelegate get(pid, plural, key), to: AtlasFacts.FakeRela
    defdelegate list(pid, plural), to: AtlasFacts.FakeRela
    defdelegate incoming(pid, plural, key, relation), to: AtlasFacts.FakeRela
    defdelegate check_create(pid, plural, key, values, targets), to: AtlasFacts.FakeRela
    defdelegate create(pid, plural, key, values, targets), to: AtlasFacts.FakeRela
    defdelegate change(pid, plural, key, values, version, targets), to: AtlasFacts.FakeRela
    defdelegate delete(pid, plural, key, version), to: AtlasFacts.FakeRela
  end

  @tag :tmp_dir
  test "Facts refuses a client impersonating the machine writer before touching storage", %{
    tmp_dir: dir
  } do
    Application.put_env(:atlas_bus, :store, "machine-#{System.unique_integer([:positive])}")
    backend = AtlasFacts.FakeRela.start()
    on_exit(fn -> if Process.alive?(backend), do: Agent.stop(backend) end)
    {_description, config} = AtlasFacts.FlowRuntimeTest.fixture()
    config = Map.put(config, "selection", %{})
    fragment = Path.join(dir, "flow-runtime.json")
    File.write!(fragment, JSON.encode!(%{"flow_runtime" => config}))

    start_supervised!(
      {AtlasFacts.Server, rela: {Backend, backend}, data_dir: dir, flow_runtime: fragment}
    )

    :ok = AtlasBus.attach("client")

    for op <- ["create", "change", "delete"] do
      envelope = Envelope.new("fact", "cursor")
      AtlasBus.send(envelope, %{"op" => op, "key" => "C-1", "by" => "flow", "values" => %{}})
      id = envelope.id
      assert_receive {:atlas_bus, %Envelope{id: ^id, class: "refused"}, answer}
      assert answer["reasons"] == ["only the configured machine writer may write this kind"]
    end

    assert AtlasFacts.FakeRela.facts(backend) == %{}
  end
end
