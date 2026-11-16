defmodule AtlasViewer.ReadClientTest do
  use ExUnit.Case, async: true
  alias AtlasViewer.ReadClient

  test "maps exactly the five reads and their fields to their socket" do
    assert {:ok, {:backend, "/v1/runtime"}} = ReadClient.request(%{"op" => "runtime"})

    assert {:ok, {:backend, "/v1/turns?limit=5"}} =
             ReadClient.request(%{"op" => "turns", "limit" => 5})

    assert {:ok, {:backend, "/v1/turns/t"}} =
             ReadClient.request(%{"op" => "turn", "turn_id" => "t"})

    assert {:ok, {:backend, "/v1/turns/t/output?cursor=c"}} =
             ReadClient.request(%{"op" => "output", "turn_id" => "t", "cursor" => "c"})

    assert {:ok,
            {:journal,
             %{"api" => "runtime.read/1", "op" => "events", "cursor" => "c", "limit" => 5}}} =
             ReadClient.request(%{"op" => "events", "cursor" => "c", "limit" => 5})

    assert {:error, "not_a_read"} = ReadClient.request(%{"op" => "answer"})
    assert {:error, "not_a_read"} = ReadClient.request(%{"op" => "workers"})
    assert {:error, "not_a_read"} = ReadClient.request(%{"command" => "stop"})
    assert {:error, "invalid_request"} = ReadClient.request(%{"op" => "runtime", "slot" => "s"})
    assert {:error, "invalid_request"} = ReadClient.request(%{"op" => "output"})
  end

  test "builds only the backend.sock and runtime.sock paths" do
    assert ReadClient.sockets("/h") == %{backend: "/h/backend.sock", journal: "/h/runtime.sock"}
  end
end
