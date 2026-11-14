defmodule AtlasBFFContract.WorkerEndpointsTest.Root do
  @moduledoc false
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
end

defmodule AtlasBFFContract.WorkerEndpointsTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias __MODULE__.Root

  @schema AtlasBFFContract.Contract.__schema__()
  @worker_page ~w(worker_inspect worker_submit worker_query worker_history worker_receipts
                  worker_output_subscribe worker_output_next worker_output_unsubscribe)a
  @execution %{
    "worker" => %{"environment" => "test", "machine" => "box", "worker" => "w"},
    "turn" => "t",
    "attempt" => "a"
  }

  defp endpoint(name), do: Enum.find(@schema.endpoints, &(&1.name == name and &1.call == name))
  defp wire(name), do: Enum.find(@schema.protocol, &(&1.name == name))

  defp fields(model) do
    fields = Enum.find(@schema.models, &(&1.name == model)).fields

    split = fn required? ->
      for f <- fields, f.required == required?, into: %{}, do: {Atom.to_string(f.name), f.type}
    end

    {split.(true), split.(false)}
  end

  defp envelope(envelope), do: {envelope.required, Map.get(envelope, :optional, %{})}

  test "every worker page operation is an endpoint whose call is its op" do
    for name <- @worker_page do
      assert %{wire: ^name, path: nil, params: []} = endpoint(name), "no endpoint #{name}"
      assert wire(name).request.select["op"] == Atom.to_string(name)
    end
  end

  test "what an endpoint takes and replies is exactly its envelope, without the selector" do
    for name <- @worker_page do
      %{takes: takes, replies: replies} = endpoint(name)
      descriptor = wire(name)
      assert fields(takes) == envelope(descriptor.request), "#{name} takes #{takes}"

      assert Enum.map(replies, & &1.name) == Enum.map(descriptor.replies, & &1.name)

      for %{name: reply, returns: model} <- replies do
        envelope = Enum.find(descriptor.replies, &(&1.name == reply))
        assert fields(model) == envelope(envelope), "#{name} #{reply} returns #{model}"
      end
    end
  end

  test "a payload built from an endpoint is the request the TUI sends today" do
    props = %{id: "r1", execution: @execution, client_key: "k"}
    payload = Root.payload(:worker_query, :worker_query, props)

    assert Root.message(:worker_query, :worker_query, props) ==
             Wire.request(:worker_query, payload)

    assert %{"op" => "worker_query", "channel" => "control", "version" => "0.1.0", "id" => "r1"} =
             Wire.request(:worker_query, payload)
  end
end
