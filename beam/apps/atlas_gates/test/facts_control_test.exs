defmodule AtlasGates.FactsControlTest do
  @moduledoc "Recording through Control with a stand-in for the `atlas` client."
  use ExUnit.Case, async: true

  alias AtlasGates.Fixtures

  # Answers as the client would and reports each call; `recorded` are the verdicts Control
  # lists, newest first, as `{key, field values}`.
  defp client(recorded, pid \\ self()) do
    fn args ->
      # A file the client is given is read while it runs, as the client does.
      files =
        for {"--" <> flag, path} <- Enum.zip(args, tl(args) ++ [nil]),
            String.ends_with?(flag, "-file"),
            do: {flag, File.read!(path)}

      send(pid, {:atlas, args, files})

      case args do
        ["list", "ruling" | _] -> {:ok, for({key, _} <- recorded, do: %{"key" => key})}
        ["get", key | _] -> {:ok, %{"fields" => for(v <- recorded[key], do: ["Label", v])}}
        ["put", "ruling" | _] -> {:ok, %{"key" => "RU-0001"}}
      end
    end
  end

  defp decide(request, facts),
    do: AtlasGates.decide(request, facts, kind: "ruling", now: Fixtures.now())

  test "a new verdict is put with its fields, links and environment" do
    facts = AtlasGates.Facts.Control.new("test", client: client(%{}))
    request = Fixtures.request("dispatch", Fixtures.evidence(), %{"links" => %{"about" => "C-7"}})

    assert {:ok, %{recorded: "RU-0001", recorded_as: :new}} = decide(request, facts)

    assert_received {:atlas, ["list", "ruling", "--env", "test", "--json"], _}
    assert_received {:atlas, ["put", "ruling" | args], files}

    assert ["--link", "about=C-7", "--env", "test", "--json"] = Enum.take(args, -5)
    assert ["--gate", "dispatch"] in Enum.chunk_every(args, 2, 1)
    assert ["--verdict", "ship"] in Enum.chunk_every(args, 2, 1)

    assert ["--duration_ms", _] =
             Enum.find(Enum.chunk_every(args, 2, 1), &(hd(&1) == "--duration_ms"))

    assert files == [{"evidence-file", "loaded_hash: h-1\npacked_hash: h-1\nseal: intact"}]
  end

  test "a repeat is found by the request's identity and nothing is put" do
    request = Fixtures.request()
    other = Fixtures.request("dispatch", Fixtures.evidence(%{"seal" => "broken"}))

    recorded = %{
      "RU-0003" => ["dispatch", "2", other.rule_version, "C-7", "f-1", other.evidence_digest],
      "RU-0002" => ["dispatch", "2", request.rule_version, "C-7", "f-1", request.evidence_digest]
    }

    facts = AtlasGates.Facts.Control.new("test", client: client(recorded))

    assert {:ok, %{recorded: "RU-0002", recorded_as: :again}} = decide(request, facts)
    refute_received {:atlas, ["put" | _], _}
  end

  test "a client that fails is an error, never a pass" do
    facts =
      AtlasGates.Facts.Control.new("test",
        client: fn _ -> {:error, "atlas list failed: down"} end
      )

    assert {:error, %{outcome: "ask", unsettled: "error"}, "atlas list failed: down"} =
             decide(Fixtures.request(), facts)
  end
end
