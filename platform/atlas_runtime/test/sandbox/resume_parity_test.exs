defmodule AtlasRuntime.Sandbox.ResumeParityTest do
  # S6 package A3: AtlasRuntime.Sandbox.Resume against the shared resume tables, which Go
  # wrote from today's helper (host/host/s6_resume_parity_test.go, TestS6Resume*). A row with
  # `elixir: "skip:…"` is Go-only; a `change` row's expect is the new result and its
  # expect.legacy is Go's (B2).
  use ExUnit.Case, async: true

  alias AtlasRuntime.S6Fixture
  alias AtlasRuntime.Sandbox.Resume

  @tables Path.join(S6Fixture.dir(), "resume")
  for name <- ~w(validate verdict question_session),
      do: @external_resource(Path.join(@tables, name <> ".json"))

  defp places do
    root = S6Fixture.new_root!()
    S6Fixture.default_places(root)
  end

  defp expected(%{"change" => change, "expect" => expect}) when is_binary(change) do
    refute expect["legacy"] in [nil, Map.delete(expect, "legacy")]
    Map.delete(expect, "legacy")
  end

  defp expected(%{"expect" => expect}), do: expect

  for row <- S6Fixture.load_table!(Path.join(@tables, "validate.json"))["rows"] do
    @row row
    if row["elixir"], do: @tag(skip: "legacy-only: " <> row["elixir"])

    test "validate row #{row["id"]}" do
      places = places()
      input = S6Fixture.substitute_value(places, @row["input"])

      result =
        Resume.validate(
          input["backend"],
          input["scope"],
          input["sandbox"],
          input["session"],
          input["model"],
          input["context"],
          workspace: input["workspace"],
          repository: input["repository"],
          questions: input["questions"]
        )

      result =
        case result do
          :ok -> %{"ok" => true}
          {:error, text} -> %{"error" => text}
        end

      assert S6Fixture.abstract_value(places, result) == expected(@row)
    end
  end

  for row <- S6Fixture.load_table!(Path.join(@tables, "verdict.json"))["rows"] do
    @row row
    if row["elixir"], do: @tag(skip: "legacy-only: " <> row["elixir"])

    test "verdict row #{row["id"]}" do
      places = places()
      input = S6Fixture.substitute_value(places, @row["input"])

      result =
        Enum.reduce_while(input["records"], {Resume.start(input["start"]), []}, fn record,
                                                                                   {state,
                                                                                    verdicts} ->
          case Resume.verdict(state, record) do
            {:continue, state} -> {:cont, {state, ["continue" | verdicts]}}
            {:refuse, text} -> {:halt, {:refused, [%{"refuse" => text} | verdicts]}}
          end
        end)

      result =
        case result do
          {:refused, verdicts} ->
            %{"verdicts" => Enum.reverse(verdicts)}

          {state, verdicts} ->
            complete =
              case Resume.verdict(state, {:completed, input["stopped"]}) do
                {:continue, _state} -> "continue"
                {:refuse, text} -> %{"refuse" => text}
              end

            %{"verdicts" => Enum.reverse(verdicts), "complete" => complete}
        end

      assert S6Fixture.abstract_value(places, result) == expected(@row)
    end
  end

  for row <- S6Fixture.load_table!(Path.join(@tables, "question_session.json"))["rows"] do
    @row row

    test "question_session row #{row["id"]}" do
      random = Base.decode16!(@row["input"]["random"], case: :mixed)
      session = Resume.question_session(nil, fn -> random end)
      assert %{"question_session" => session} == expected(@row)
      assert Resume.question_session("", fn -> random end) == session
    end
  end

  test "a resumed question turn keeps its session (host.go:149)" do
    session = "8f0e3a52-6c1d-4b7a-9e2f-1a2b3c4d5e6f"
    assert Resume.question_session(session, fn -> flunk("no id is generated") end) == session
  end

  test "question_session/1 generates distinct version 4 UUIDs" do
    sessions = for _ <- 1..64, do: Resume.question_session(nil)
    assert length(Enum.uniq(sessions)) == 64

    for session <- sessions,
        do:
          assert(
            session =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
          )
  end
end
