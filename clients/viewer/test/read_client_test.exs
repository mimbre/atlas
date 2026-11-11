defmodule AtlasViewer.ReadClientTest do
  use ExUnit.Case, async: true
  alias AtlasViewer.ReadClient

  test "admits exactly the runtime.read/1 operations and fields" do
    assert {:ok, %{"api" => "runtime.read/1", "op" => "workers"}} =
             ReadClient.request(%{"op" => "workers"})

    assert {:ok, %{"cursor" => "c", "limit" => 5}} =
             ReadClient.request(%{"op" => "events", "cursor" => "c", "limit" => 5})

    assert {:ok, _} = ReadClient.request(%{"op" => "output", "turn_id" => "t", "cursor" => "c"})
    assert {:error, "not_a_read"} = ReadClient.request(%{"op" => "answer"})
    assert {:error, "not_a_read"} = ReadClient.request(%{"command" => "stop"})

    assert {:error, "invalid_request"} =
             ReadClient.request(%{"op" => "workers", "worker_id" => "w"})
  end

  test "builds only the read.sock path" do
    assert ReadClient.socket("/h") == "/h/read.sock"
  end
end
