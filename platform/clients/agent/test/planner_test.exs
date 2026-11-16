defmodule AtlasAgent.PlannerTest do
  use ExUnit.Case, async: true

  alias AtlasAgent.Planner

  @input %{"request" => "make two", "env" => "test", "page" => %{"path" => "/"}, "tools" => []}

  # A planner command: reads the input on stdin, prints what the test gives it.
  defp command(tmp, body) do
    script = Path.join(tmp, "planner.sh")
    File.write!(script, "#!/bin/sh\n" <> body)
    File.chmod!(script, 0o755)
    %{"agent" => %{"planner" => [script], "name" => "a test planner"}}
  end

  @tag :tmp_dir
  test "a command gets the input on stdin and answers the plan on stdout", %{tmp_dir: tmp} do
    # It echoes the request back as the summary, so the input did arrive.
    settings =
      command(tmp, """
      request=$(sed -n 's/.*"request":"\\([^"]*\\)".*/\\1/p')
      echo "chatter" >&2
      printf '{"summary":"%s","steps":[{"tool":"put","kind":"part","values":{}}]}' "$request"
      """)

    assert {:ok, plan, "a test planner"} = Planner.plan(settings, @input)
    assert plan["summary"] == "make two"
    assert [%{"tool" => "put"}] = plan["steps"]
  end

  @tag :tmp_dir
  test "a command that fails, answers no JSON or no plan says so", %{tmp_dir: tmp} do
    assert {:error, "planner.sh failed (3): broken"} =
             Planner.plan(command(tmp, "echo broken >&2; exit 3"), @input)

    assert {:error, "planner.sh answered no JSON: not json\n"} =
             Planner.plan(command(tmp, "echo not json"), @input)

    assert {:error, "a test planner answered no plan: " <> _} =
             Planner.plan(command(tmp, ~s|echo '{"summary":"no steps"}'|), @input)
  end

  @tag :tmp_dir
  test "a command that takes too long is given up", %{tmp_dir: tmp} do
    settings = command(tmp, "sleep 5")
    settings = put_in(settings["agent"]["timeout_seconds"], 1)
    assert {:error, "planner.sh did not answer within 1 s"} = Planner.plan(settings, @input)
  end

  test "an unknown planner is refused" do
    assert {:error, "unknown planner" <> _} =
             Planner.plan(%{"agent" => %{"planner" => 7}}, @input)
  end

  test "claude is the default, and gets the request, the page and the writing tools" do
    assert Planner.name(%{}) == "claude -p"

    prompt =
      Planner.prompt(
        %{@input | "tools" => [%{"tool" => "put", "kind" => "part"}, %{"tool" => "get"}]},
        "test"
      )

    assert prompt =~ "make two"
    assert prompt =~ "--env test"
    assert prompt =~ ~s|"kind":"part"|
    refute prompt =~ ~s|"tool":"get"|
    refute prompt =~ "previous plan"

    before = %{"text" => "Step 2 (New part) was refused: gone.", "not_run" => [%{"n" => 3}]}
    prompt = Planner.prompt(Map.put(@input, "before", before), "test")
    assert prompt =~ "Step 2 (New part) was refused: gone."
    assert prompt =~ "Do not work around the refusal"
    assert prompt =~ ~s|"not_run":[{"n":3}]|
    assert Planner.schema()["required"] == ["summary", "steps"]
  end
end
