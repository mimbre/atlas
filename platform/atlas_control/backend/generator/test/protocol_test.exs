defmodule AtlasBFF.ProtocolTest do
  use ExUnit.Case, async: true

  # A plain-data contract proves the target has no dependency on the DSL or its catalogue.
  defmodule Contract do
    def __schema__ do
      %{
        version: "2.0",
        models: [
          %{
            name: :command_options,
            fields: [
              %{name: :name, type: :string, required: true},
              %{name: :verbose, type: :boolean, required: false},
              %{name: :limit, type: :integer, required: false}
            ]
          },
          %{name: :sample, fields: [%{name: :count, type: :integer, required: true}]},
          %{
            name: :probe_input,
            fields: [
              %{name: :items, type: {:list, :sample}, required: true},
              %{name: :flags, type: {:map, :boolean}, required: false},
              %{name: :note, type: :string, required: false}
            ]
          }
        ],
        pages: [
          %{name: :entry, path: "/entries/:id", params: [:id]},
          %{name: :new, path: "/entries/new", params: []}
        ],
        endpoints: [
          %{name: :probe, call: :probe, path: nil, takes: :probe_input},
          %{name: :ping, call: :ping, path: nil, takes: nil},
          %{name: :save, call: :submit, path: "/entries/:id", takes: :values}
        ]
      }
    end
  end

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: Contract
  end

  test "CLI option parsing is generated from primitive model fields" do
    assert {:ok, %{"name" => "literal", "verbose" => true, "limit" => 2}} =
             Protocol.options(:command_options, ["--name", "literal", "--verbose", "--limit", "2"])

    for argv <- [
          [],
          ["--name", "one", "--name", "two"],
          ["--name", "one", "extra"],
          ["--name", "one", "--unknown"],
          ["--name", "one", "--limit", "bad"]
        ] do
      assert {:invalid, _} = Protocol.options(:command_options, argv)
    end

    assert {:invalid, _} = Protocol.options(:probe_input, [])
  end

  test "new operations, nested models and fields come only from schema data" do
    assert Protocol.message(:probe, :probe,
             items: [[count: 3]],
             flags: %{"ok" => false},
             note: nil
           ) ==
             %{"op" => "probe", "items" => [%{"count" => 3}], "flags" => %{"ok" => false}}

    assert Protocol.message(:ping, :ping) == %{"op" => "ping"}
    assert Protocol.version() == "2.0"
    assert Protocol.payload(:submit, :save, %{"arbitrary" => ""}) == %{"arbitrary" => ""}
  end

  test "rejects missing, unknown and wrongly typed outgoing fields including nested data" do
    for props <- [
          %{},
          %{items: nil},
          %{items: [count: 3]},
          %{items: [%{count: "3"}]},
          %{items: [%{}]},
          %{items: [%{count: 1, extra: true}]},
          %{items: [], flags: %{"ok" => 1}},
          %{items: [], extra: true},
          %{items: [], note: 1},
          %{items: "bad"}
        ] do
      assert_raise ArgumentError, fn -> Protocol.payload(:probe, :probe, props) end
    end

    assert_raise ArgumentError, fn -> Protocol.message(:ping, :ping, extra: true) end
    assert_raise ArgumentError, fn -> Protocol.payload(:submit, :save, %{x: 1}) end
    assert_raise ArgumentError, fn -> Protocol.message(:submit, :save, %{}) end
    assert_raise ArgumentError, fn -> Protocol.message(:unknown, :probe) end
  end

  test "paths encode data and preserve literal precedence without creating runtime atoms" do
    assert Protocol.path(:entry, id: "é /?%") == "/entries/%C3%A9%20%2F%3F%25"
    assert Protocol.match("/entries/new") == {:ok, :new, %{}}
    assert Protocol.endpoint_path(:submit, :save, %{"id" => "A/B"}) == "/entries/A%2FB"
    assert Protocol.endpoint_path(:probe, :probe) == nil
    assert_raise ArgumentError, fn -> Protocol.path(:entry) end
    assert_raise ArgumentError, fn -> Protocol.path(:absent) end
  end
end
