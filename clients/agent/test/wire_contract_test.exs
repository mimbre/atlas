defmodule AtlasAgent.WireContractTest do
  use ExUnit.Case, async: true

  test "independent observed turn-end replies have distinct contract payloads" do
    # Observed Control transcript: these are separate wire shapes, not aliases.
    transcript = [
      {%{
         "op" => "page",
         "reason" => "stored",
         "path" => "/k/sample/X",
         "title" => "Sample",
         "blocks" => [],
         "markup" => []
       }, :stored, :view_model},
      {%{"op" => "turn", "error" => "stale turn"}, :error, :turn_context},
      {%{
         "op" => "page",
         "reason" => "refused",
         "path" => "/k/sample/X",
         "title" => "Sample",
         "blocks" => [],
         "markup" => [],
         "refused" => ["refused"]
       }, :refused, :view_model}
    ]

    endpoint =
      Enum.find(AtlasBFFContract.Contract.__schema__().endpoints, &(&1.name == :turn_end))

    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)

        for {wire, _, _} <- transcript do
          :ok = :gen_tcp.send(socket, [JSON.encode!(wire), "\n"])
        end

        :gen_tcp.close(socket)
      end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    try do
      for {wire, name, payload} <- transcript do
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        assert JSON.decode!(line) == wire
        assert %{name: name, returns: payload} in endpoint.replies

        assert {:reply, %{name: ^name}} =
                 AtlasAgent.Protocol.classify(:turn_end, JSON.decode!(line))
      end

      Task.await(peer)
    after
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end
  end

  test "local streams and server pushes never become Control commands" do
    for {call, name, props} <- [
          {:ask, :ask, %{request: "plan", on: "/"}},
          {:run, :run, %{steps: []}},
          {:cancel, :cancel, %{}},
          {:stop, :stop, %{}},
          {:page, :hint, %{}},
          {:notice, :notice, %{}},
          {:bye, :bye, %{}}
        ] do
      assert_raise ArgumentError, fn -> AtlasAgent.Protocol.message(call, name, props) end
    end
  end
end
