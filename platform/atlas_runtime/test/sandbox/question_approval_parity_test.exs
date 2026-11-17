defmodule AtlasRuntime.Sandbox.QuestionApprovalParityTest do
  # S6 package A5 (plan s6-plan.md): every row of test/fixtures/s6/questions/*.json
  # (transcripts.json, and limits.json for the size bounds) is replayed through
  # AtlasRuntime.Interactions.QuestionApproval and must give the expect that Go wrote
  # from the legacy questionHost (host/host/s6_questions_parity_test.go,
  # TestS6QuestionsParity). Elixir never writes expect (B2). The question ids are injected
  # from input.ids, which is how the Go side reports its random ids.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Interactions.QuestionApproval
  alias AtlasRuntime.S6Fixture

  @tables Path.wildcard(Path.join([S6Fixture.dir(), "questions", "*.json"]))
  for table <- @tables, do: @external_resource(table)
  @rows Enum.flat_map(@tables, &S6Fixture.load_table!(&1)["rows"])

  test "the tables have rows, unique ids, and an expect per row" do
    assert length(@tables) > 0 and length(@rows) > 0
    assert length(Enum.uniq_by(@rows, & &1["id"])) == length(@rows)
    assert Enum.all?(@rows, &is_map(&1["expect"]))
  end

  for row <- @rows do
    @row row
    if skip = row["elixir"], do: @tag(skip: skip)

    test "question row #{row["id"]}" do
      assert replay(@row["input"]) == @row["expect"]
    end
  end

  test "generated ids are question- and a uuid4 in hex, and differ" do
    state = QuestionApproval.new(session: "s", model: "m", native_pid: 1)
    input = %{"questions" => [question("Which value?")]}

    ids =
      for tool <- ["tool-1", "tool-2"] do
        {state, []} = QuestionApproval.step(state, {:native, assistant("s", tool, input)})

        {_state, [%{"emit" => %{"question" => %{"id" => id}}}]} =
          QuestionApproval.step(state, {:native, request(tool, input)})

        assert id =~ ~r/\Aquestion-[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}\z/
        id
      end

    assert Enum.uniq(ids) == ids
  end

  defp replay(input) do
    state =
      QuestionApproval.new(
        session: input["session"],
        model: input["model"],
        native_pid: input["native_pid"],
        ids: input["ids"]
      )

    {steps, final} =
      Enum.reduce(input["steps"], {[], state}, fn step, {steps, state} ->
        refute state == :failed, "a step follows the refusal that ends the query"

        case QuestionApproval.step(state, decode_step(step)) do
          {:error, text, actions} -> {[%{"actions" => actions, "error" => text} | steps], :failed}
          {state, actions} -> {[%{"actions" => actions} | steps], state}
        end
      end)

    expect = %{"steps" => Enum.reverse(steps)}

    expect =
      if final == :failed,
        do: expect,
        else:
          Map.put(expect, "state", %{
            "candidate" => final.candidate && final.candidate.tool,
            "pending" => final.pending && final.pending.id,
            "inflight" => final.inflight && final.inflight.id,
            "last_tool" => final.last_tool,
            "finished" => final.finished
          })

    # Compare as JSON values, as the Go side does.
    expect |> JSON.encode!() |> JSON.decode!()
  end

  defp decode_step(%{"native" => record}), do: {:native, record}
  defp decode_step(%{"answer" => command}), do: {:answer, command}
  defp decode_step(%{"cancel" => true}), do: :cancel

  defp question(text),
    do: %{
      "question" => text,
      "header" => "Value",
      "multiSelect" => false,
      "options" => [
        %{"label" => "11", "description" => "First"},
        %{"label" => "23", "description" => "Second"}
      ]
    }

  defp assistant(session, tool, input),
    do: %{
      "type" => "assistant",
      "session_id" => session,
      "message" => %{
        "content" => [
          %{"type" => "tool_use", "id" => tool, "name" => "AskUserQuestion", "input" => input}
        ]
      }
    }

  defp request(tool, input),
    do: %{
      "type" => "control_request",
      "request_id" => "request-" <> tool,
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "AskUserQuestion",
        "tool_use_id" => tool,
        "requires_user_interaction" => true,
        "input" => input
      }
    }
end
