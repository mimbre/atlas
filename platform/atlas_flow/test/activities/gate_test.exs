defmodule AtlasFlow.Activities.GateTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Activities.Gate
  alias AtlasBus.Digest

  defp intent do
    Gate.intent(
      %{
        "key" => "r",
        "entry" => 3,
        "subject_key" => "B-1",
        "last_input" => %{
          "due" => "2026-11-12T00:05:00Z",
          "waited_from" => "2026-11-12T00:00:00Z"
        }
      },
      %{"gate" => "allocate", "version" => 1}
    )
  end

  defp frozen do
    i = intent()

    request = %{
      "subject" => "B-1",
      "gate_version" => "1",
      "fingerprint_definition" => %{"fields" => ["title"], "relations" => []},
      "fingerprint" => "fp",
      "evidence" => %{"ready" => true},
      "evidence_digest" => Digest.of_term(%{"ready" => true}),
      "allowed_outcomes" => ["clerk"]
    }

    {:ok, frozen} = Gate.freeze(i, Map.put(i, "request", request))
    frozen
  end

  test "snapshot is immutable and bound to activity identity" do
    i = intent()
    f = frozen()
    assert f["flow"]["timed_out"]

    for field <- ~w(version id run entry gate gate_version subject) do
      assert {:error, _} = Gate.freeze(i, Map.put(f, field, "foreign"))
    end

    assert {:error, _} = Gate.freeze(i, put_in(f, ["request", "evidence"], %{}))
    assert {:error, _} = Gate.freeze(i, Map.put(f, "error", "refused"))
    assert {:error, _} = Gate.freeze(i, "malformed")
  end

  test "only recorded replies for this fingerprint and entry are trusted" do
    f = frozen()

    reply =
      Map.merge(f, %{
        "fingerprint" => "fp",
        "evidence_digest" => f["request"]["evidence_digest"],
        "recorded" => "V-1",
        "outcome" => "clerk"
      })

    assert {:ok, _} = Gate.result(f, reply)

    for field <-
          ~w(version id run entry gate gate_version subject fingerprint evidence_digest outcome) do
      assert {:error, _} = Gate.result(f, Map.put(reply, field, "foreign")), field
    end

    assert {:error, _} = Gate.result(f, Map.put(reply, "recorded", ""))
    assert {:error, _} = Gate.result(f, Map.put(reply, "error", "Facts refused"))
    assert {:error, _} = Gate.result(f, "malformed")
  end
end
