defmodule AtlasFacts.RecoveryReadDescription do
  def of do
    %{
      "entities" => %{
        "widget" => %{
          "plural" => "widgets",
          "properties" => %{
            "quantity" => %{"type" => "integer", "set_by" => ["flow"]},
            "title" => %{"type" => "string"},
            "approval" => %{"type" => "string"},
            "shade" => %{"type" => "string"}
          }
        },
        "cursor" => %{"plural" => "cursors", "properties" => %{}}
      },
      "relations" => %{},
      "types" => %{},
      "flow_runtime" => %{
        "kind" => "cursor",
        "fields" => %{},
        "selection" => %{},
        "writer" => %{"by" => "flow", "sender" => "flow"}
      }
    }
  end
end

defmodule AtlasFacts.RecoveryReadTest do
  use ExUnit.Case, async: false
  alias AtlasFacts.FakeRela
  alias AtlasBus.Envelope
  @moduletag :tmp_dir

  defmodule Current do
    use AtlasFacts.TestModel, description: AtlasFacts.RecoveryReadDescription.of()

    def __rela__(:description),
      do: %{
        extension: elem(AtlasFacts.TestModel.split(AtlasFacts.RecoveryReadDescription.of()), 1)
      }
  end

  defmodule Before do
    use AtlasFacts.TestModel,
      description:
        put_in(AtlasFacts.RecoveryReadDescription.of(), ["entities", "widget", "requires"], [
          %{
            "when" => %{"shade" => ["dark"]},
            "fields" => ["approval"],
            "error" => "approval needed"
          }
        ])

    def __rela__(:description), do: Current.__rela__(:description)
  end

  defmodule Expanded do
    defdelegate rela_schema(), to: Current
    defdelegate check(k, c, a, l), to: Current
    defdelegate derived(k, f, l), to: Current
    defdelegate run_mapping(), to: Current
    defdelegate presentation(), to: Current
    defdelegate connector(k), to: Current
    defdelegate guidance(), to: Current
    defdelegate turn(), to: Current
    defdelegate __rela__(key), to: Current

    def with_change(kind, change, lookup),
      do:
        Current.with_change(kind, change, lookup) ++
          if(change["values"]["quantity"] > 0, do: [%{"as" => "replaced"}], else: [])
  end

  defp request(kind, class, content, opts \\ []) do
    e = Envelope.new(class, kind, opts)
    :ok = AtlasBus.send(e, content)
    assert_receive {:atlas_bus, %Envelope{id: id, class: reply}, answer}, 1_000
    assert id == e.id
    {reply, answer}
  end

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "receipt-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Current)

    assert {:ok, []} =
             FakeRela.create(
               rela,
               "widgets",
               "W-1",
               %{"title" => "Widget", "shade" => "dark"},
               %{}
             )

    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, model: Before, data_dir: dir})
    :ok = AtlasBus.attach("flow")
    content = %{"op" => "change", "key" => "W-1", "values" => %{"quantity" => 0}, "by" => "flow"}
    assert {"refused", refusal} = request("widget", "fact", content, id: "terminal")
    stop_supervised!(AtlasFacts.Server)
    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, model: Current, data_dir: dir})

    %{
      rela: rela,
      dir: dir,
      refusal: refusal,
      write: %{"id" => "terminal", "kind" => "widget", "content" => content}
    }
  end

  test "authentic preflight is read-only and leaves the old refused answer unchanged", c do
    before = FakeRela.facts(c.rela)

    assert {"answer", %{"receipt" => receipt}} =
             request("_flow_recovery", "read", %{"by" => "flow", "write" => c.write})

    assert receipt == %{
             "class" => "refused",
             "content" => c.refusal,
             "position" => nil,
             "binding" => "legacy_unbound"
           }

    assert FakeRela.facts(c.rela) == before

    candidate =
      c.write |> Map.put("id", "successor") |> put_in(["content", "values", "quantity"], 1)

    assert {"answer", %{"receipt" => ^receipt}} =
             request("_flow_recovery", "read", %{
               "by" => "flow",
               "write" => c.write,
               "candidate" => candidate
             })

    assert FakeRela.facts(c.rela) == before
    assert {"refused", c.refusal} == request("widget", "fact", c.write["content"], id: "terminal")
    assert {"stored", _} = request("widget", "fact", c.write["content"], id: "fresh")

    assert {"answer", %{"error" => _}} =
             request("_flow_recovery", "read", %{
               "by" => "flow",
               "write" => Map.put(c.write, "id", "fresh")
             })
  end

  test "untrusted senders, absent receipts and malformed or mixed candidates cannot obtain evidence",
       c do
    for write <- [
          Map.put(c.write, "id", "absent"),
          put_in(c.write, ["content", "values"], %{"quantity" => -1}),
          put_in(c.write, ["content", "values", "title"], "mixed"),
          put_in(c.write, ["content", "by"], "somebody"),
          put_in(c.write, ["content", "links"], %{"anything" => []}),
          Map.put(c.write, "content", %{})
        ] do
      assert {"answer", %{"error" => _}} =
               request("_flow_recovery", "read", %{"by" => "flow", "write" => write})
    end

    parent = self()

    Task.async(fn ->
      :ok = AtlasBus.attach("flow/forged")
      send(parent, request("_flow_recovery", "read", %{"by" => "flow", "write" => c.write}))
    end)
    |> Task.await()

    assert_receive {"answer", %{"error" => "forbidden"}}
    assert {"refused", c.refusal} == request("widget", "fact", c.write["content"], id: "terminal")
  end

  test "still-failing admission, expanded writes and backend failure stop without writes", c do
    before = FakeRela.facts(c.rela)

    for model <- [Before, Expanded] do
      stop_supervised!(AtlasFacts.Server)

      start_supervised!(
        {AtlasFacts.Server, rela: {FakeRela, c.rela}, model: model, data_dir: c.dir}
      )

      candidate =
        c.write |> Map.put("id", "successor") |> put_in(["content", "values", "quantity"], 1)

      assert {"answer", %{"error" => _}} =
               request("_flow_recovery", "read", %{
                 "by" => "flow",
                 "write" => c.write,
                 "candidate" => candidate
               })

      assert FakeRela.facts(c.rela) == before
    end

    FakeRela.down(c.rela)

    assert {"answer", %{"error" => _}} =
             request("_flow_recovery", "read", %{"by" => "flow", "write" => c.write})
  end
end
