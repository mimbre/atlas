defmodule AtlasBFF.WireTest do
  use ExUnit.Case, async: true
  alias AtlasBFF.Wire

  defmodule Contract do
    def __schema__ do
      %{
        version: "1",
        models: [],
        pages: [],
        endpoints: [%{name: :probe, call: :probe, wire: :probe, path: nil, takes: nil}],
        protocol: [
          %{
            name: :probe,
            channel: :remote,
            direction: :request,
            request: %{select: %{"op" => "probe"}, required: %{"tag" => :string}},
            replies: [
              %{name: :ready, select: %{"op" => "ready"}, effect: :progress},
              %{
                name: :done,
                select: %{"op" => "answer"},
                absent: ["error"],
                required: %{"value" => :integer},
                effect: :complete,
                requires: [:ready]
              },
              %{
                name: :failed,
                select: %{"op" => "answer"},
                present: ["error"],
                required: %{"error" => :string},
                effect: :error
              }
            ]
          },
          %{
            name: :stop,
            channel: :remote,
            direction: :push,
            replies: [%{name: :stop, select: %{"op" => "stop"}, effect: :terminal}]
          },
          %{
            name: :local,
            channel: :local,
            direction: :stream,
            request: %{select: %{"op" => "local"}},
            replies: [%{name: :part, select: %{"op" => "part"}, effect: :progress}]
          }
        ]
      }
    end
  end

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: Contract
  end

  test "plain schema alone supplies new envelopes and classification without target edits" do
    assert Protocol.request(:probe, [tag: "α"], :remote) == %{"op" => "probe", "tag" => "α"}

    assert {:reply, %{name: :done, effect: :complete, requires: [:ready]}} =
             Protocol.classify(
               :probe,
               %{"op" => "answer", "value" => 3, "additive" => true},
               :remote
             )

    assert {:reply, %{effect: :error}} =
             Protocol.classify(:probe, %{"op" => "answer", "error" => "no"}, :remote)

    assert {:reply, %{effect: :terminal}} = Protocol.classify(:probe, %{"op" => "stop"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, %{"op" => "answer"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, %{"op" => "answer", "value" => "3"}, :remote)
    assert {:invalid, _} = Protocol.classify(:probe, [], :remote)
    assert :ignore = Protocol.classify(:probe, %{"op" => "part"}, :remote)

    for {name, channel} <- [
          {:stop, :remote},
          {:local, :remote},
          {:local, :local},
          {:probe, :local}
        ] do
      assert_raise ArgumentError, fn -> Protocol.request(name, %{}, channel) end
    end

    assert_raise ArgumentError, fn -> Protocol.request(:probe, [tag: 3], :remote) end

    assert_raise ArgumentError, fn ->
      Protocol.request(:probe, [tag: "x", other: true], :remote)
    end
  end

  test "invalid, incomplete, overlapping or executable selectors and classification fail" do
    schema = Contract.__schema__()
    [wire | rest] = schema.protocol
    [ready, done, failed] = wire.replies

    for {replacement, error} <- [
          {%{wire | direction: :other}, "direction"},
          {%{wire | replies: []}, "incomplete"},
          {%{wire | replies: [ready]}, "completion"},
          {%{wire | replies: [%{done | select: %{}}]}, "needs an op"},
          {%{wire | replies: [%{done | select: %{"op" => fn -> true end}}]}, "needs an op"},
          {%{wire | replies: [done, done]}, "duplicate"},
          {%{wire | replies: [ready, done, Map.merge(failed, %{present: [], absent: []})]},
           "overlapping"},
          {%{wire | replies: [ready, %{done | requires: [:missing]}, failed]},
           "unknown required"},
          {%{wire | replies: [ready, %{done | requires: [:done]}, failed]}, "prerequisite"},
          {%{wire | replies: [ready, Map.put(done, :absent, ["op"]), failed]}, "contradictory"},
          {%{wire | replies: [ready, Map.put(done, :required, %{"value" => :bad}), failed]},
           "invalid envelope"}
        ] do
      assert_raise ArgumentError, ~r/#{error}/, fn ->
        Wire.validate!(%{schema | protocol: [replacement | rest]})
      end
    end

    assert_raise ArgumentError, ~r/unclassified/, fn ->
      Wire.validate!(%{schema | endpoints: [%{name: :extra, wire: nil}]})
    end

    assert_raise ArgumentError, ~r/call mismatch/, fn ->
      Wire.validate!(%{schema | endpoints: [%{name: :extra, call: :other, wire: :probe}]})
    end

    assert_raise ArgumentError, ~r/unclassified endpoint reply/, fn ->
      Wire.validate!(%{
        schema
        | endpoints: [%{name: :probe, call: :probe, wire: :probe, replies: [%{name: :missing}]}]
      })
    end

    assert_raise ArgumentError, ~r/overlapping/, fn ->
      push = %{
        name: :bad,
        channel: :remote,
        direction: :push,
        replies: [Map.delete(done, :requires)]
      }

      Wire.validate!(%{schema | protocol: [wire, push]})
    end
  end

  test "DSL validates protocol and exports it as plain data" do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use AtlasBFF.Schema
          version "1"
          protocol_from(Contract)
          defendpoint :probe, call: :probe, wire: :probe, replies: [done: :view_model]
        end
      end
    )

    assert module.__schema__().protocol == Contract.__schema__().protocol
  end

  test "individual operations and imports preserve plain descriptors and declaration order" do
    [probe, stop, local] = Contract.__schema__().protocol
    imported = compile_spec(operation(stop))

    module =
      compile_spec("""
      descriptor = #{inspect(Map.delete(probe, :name), limit: :infinity)}
      defoperation :probe, descriptor
      protocol_from(#{inspect(imported)})
      #{operation(local)}
      """)

    assert module.__schema__().protocol == Contract.__schema__().protocol
  end

  test "invalid declarations report the declaration file and line" do
    [probe | _] = Contract.__schema__().protocol

    for {body, message} <- [
          {operation(%{probe | name: "probe"}), ~r/invalid wire name/},
          {operation(%{probe | direction: :other}), ~r/invalid wire direction/},
          {operation(Map.put(probe, :extra, true)), ~r/unknown wire metadata/},
          {operation(Map.delete(probe, :channel)), ~r/channel/},
          {operation(%{probe | replies: nil}), ~r/Enumerable/},
          {"defoperation :probe, []", ~r/wire descriptor must be a map/}
        ] do
      error = assert_raise CompileError, message, fn -> compile_spec(body) end
      assert error.file == "wire_contract.ex"
      assert error.line == 4
    end
  end

  test "duplicate operations point to the later declaration or import" do
    [probe | _] = Contract.__schema__().protocol
    declaration = operation(probe)
    import = "protocol_from(#{inspect(Contract)})"

    for body <- [
          "#{declaration}\n#{declaration}",
          "#{declaration}\n#{import}",
          "#{import}\n#{declaration}"
        ] do
      error =
        assert_raise CompileError, ~r/duplicate wire descriptor/, fn -> compile_spec(body) end

      assert error.file == "wire_contract.ex"
      assert error.line == 5
    end
  end

  test "imported descriptors are checked against the importing contract models" do
    [probe | _] = Contract.__schema__().protocol
    probe = put_in(probe.request.required, %{"payload" => :payload})

    imported =
      compile_spec("""
      defmodel :payload do
        field :value, :string
      end
      #{operation(probe)}
      """)

    error =
      assert_raise CompileError, ~r/invalid envelope field/, fn ->
        compile_spec("protocol_from(#{inspect(imported)})")
      end

    assert error.file == "wire_contract.ex"
    assert error.line == 4

    module =
      compile_spec("""
      models_from(#{inspect(imported)})
      protocol_from(#{inspect(imported)})
      """)

    assert module.__schema__().protocol == [probe]
    assert module.__schema__().models == imported.__schema__().models
  end

  test "wire conflicts and endpoint mismatches keep their declaration locations" do
    [probe | _] = Contract.__schema__().protocol
    other = %{probe | name: :other}

    error =
      assert_raise CompileError, ~r/overlapping/, fn ->
        compile_spec("#{operation(probe)}\n#{operation(other)}")
      end

    assert error.file == "wire_contract.ex"
    assert error.line == 5

    error =
      assert_raise CompileError, ~r/call mismatch/, fn ->
        compile_spec("""
        #{operation(probe)}
        defendpoint :probe, call: :other, wire: :probe, replies: [done: :view_model]
        """)
      end

    assert error.file == "wire_contract.ex"
    assert error.line == 5
  end

  defp operation(wire) do
    "defoperation #{inspect(wire.name)}, #{inspect(Map.delete(wire, :name), limit: :infinity)}"
  end

  defp compile_spec(body) do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    Code.compile_string(
      """
      defmodule #{inspect(module)} do
        use AtlasBFF.Schema
        version "1"
        #{body}
      end
      """,
      "wire_contract.ex"
    )

    module
  end
end
