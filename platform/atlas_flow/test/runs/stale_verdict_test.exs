defmodule AtlasFlow.Runs.StaleVerdictTest do
  use ExUnit.Case, async: true

  alias AtlasFlow.Runs.Run

  # A gate in `asking` leads to `waiting`; a choice there sends the subject to `revising`,
  # whose return asks the gate again.
  defmodule Flow do
    def states, do: ~w(asking waiting revising done)
    def mechanism("asking"), do: {:gate, %{"gate" => "check", "version" => 1}}
    def mechanism(_), do: nil
    def next("asking", %{"gate_result" => "person"}, :result), do: {:to, "waiting"}
    def next(_state, _values, _role), do: :stay
  end

  @definition %{"fields" => ["title"], "relations" => []}

  defp run(state, subject) do
    %{
      "status" => "active",
      "state" => state,
      "pending" => %{
        "verdict" => %{
          "gate" => "check",
          "outcome" => "person",
          "fingerprint_definition" => @definition,
          "fingerprint" => AtlasBus.SubjectFingerprint.of(subject, @definition)
        }
      }
    }
  end

  @asked %{"key" => "W-1", "values" => %{"title" => "As asked"}, "links" => %{}}
  @edited %{"key" => "W-1", "values" => %{"title" => "Revised"}, "links" => %{}}

  test "an edit in the state the verdict led to makes it stale: the gate is asked again" do
    refute Run.stale_verdict?(run("waiting", @asked), Flow, @asked)
    assert Run.stale_verdict?(run("waiting", @asked), Flow, @edited)
  end

  test "an edit in a later state is expected (a revision): the verdict waits for the return" do
    refute Run.stale_verdict?(run("revising", @asked), Flow, @edited)
  end

  test "an ended run or one without a verdict is never stale" do
    refute Run.stale_verdict?(
             Map.put(run("waiting", @asked), "status", "completed"),
             Flow,
             @edited
           )

    refute Run.stale_verdict?(
             put_in(run("waiting", @asked), ["pending", "verdict"], nil),
             Flow,
             @edited
           )
  end
end
