defmodule AtlasAgent.Planner do
  @moduledoc """
  Who plans a request: the one place that knows (UC-Atlas-16). The environment's
  settings choose it, under `"agent"`:

  - `"planner": "claude"` (also when unset): a local headless Claude session
    (`claude -p`). Its only tools are `atlas help`, `atlas get` and `atlas list` on the
    same environment, so it can read Atlas and change nothing. `"model"` picks the model.
  - `"planner": ["<command>", "<arg>", ...]`: any command. It gets the planner's input as
    JSON on stdin and prints the plan as JSON on stdout. The end-to-end test uses a
    scripted stand-in this way, so CI needs no model.

  `"name"` names the planner for its users (a plan says who made it); `"timeout_seconds"`
  is how long it may take, 300 by default.

  The input: `%{"request", "env", "page", "tools"}`; `page` is the view model of the page
  the request was made on, `tools` are `AtlasAgent.Tools.list/1`. After a refusal it also
  has `"before"`: what became of the previous plan for the same request, `%{"text",
  "stored", "refused", "not_run"}`, each step as the plan had it (with `"detail"`: the id
  it stored, or why it was refused). The answer:
  `%{"summary" => text, "steps" => [step]}`, the steps as `AtlasAgent.Plan` takes them.

  A planner only proposes. Nothing it answers is run before a user accepts it; the
  Runtime of SC-Atlas-02 will take this place later.
  """

  @timeout 300_000

  @doc "Ask the planner of `settings` for a plan: `{:ok, %{\"summary\", \"steps\"}, by}`."
  def plan(settings, input) do
    agent = settings["agent"] || %{}
    timeout = (agent["timeout_seconds"] || div(@timeout, 1000)) * 1000

    case agent["planner"] || "claude" do
      "claude" -> claude(agent, input, timeout)
      [_ | _] = command -> command(command, JSON.encode!(input), timeout)
      other -> {:error, "unknown planner #{inspect(other)} in the settings (agent.planner)"}
    end
    |> case do
      {:ok, plan} -> answer(plan, name(agent))
      {:error, _} = error -> error
    end
  end

  @doc "What the settings' planner is called, for its users: `\"name\"`, or its command."
  def name(%{"name" => name}) when is_binary(name), do: name

  def name(agent) do
    case agent["planner"] || "claude" do
      "claude" -> "claude -p"
      [command | _] -> Path.basename(command)
      other -> inspect(other)
    end
  end

  defp answer(%{"steps" => steps} = plan, by) when is_list(steps),
    do: {:ok, %{"summary" => plan["summary"] || "", "steps" => steps}, by}

  defp answer(other, by),
    do: {:error, "#{by} answered no plan: #{String.slice(inspect(other), 0, 200)}"}

  # A command: input on stdin, the plan on stdout.
  defp command([command | args], input, timeout) do
    with {:ok, out} <- run(command, args, input, [], timeout) do
      case JSON.decode(out) do
        {:ok, plan} ->
          {:ok, plan}

        {:error, _} ->
          {:error, "#{Path.basename(command)} answered no JSON: #{String.slice(out, 0, 200)}"}
      end
    end
  end

  # Claude Code, headless, with the plan as structured output.
  defp claude(agent, input, timeout) do
    env = input["env"]

    reads =
      for command <- ["get", "list", "help"],
          do: "Bash(atlas #{command}:*)"

    args =
      ["-p", "--tools", "Bash", "--allowedTools" | reads] ++
        [
          "--permission-mode",
          "dontAsk",
          "--strict-mcp-config",
          "--no-session-persistence",
          "--output-format",
          "json",
          "--json-schema",
          JSON.encode!(schema())
        ] ++ if(agent["model"], do: ["--model", agent["model"]], else: [])

    # `atlas` is this build's, on this environment (ATLAS_ENV_FILE passes on as it is).
    path = Path.join(AtlasAgent.root(), "bin") <> ":" <> (System.get_env("PATH") || "")

    with {:ok, out} <- run("claude", args, prompt(input, env), [{"PATH", path}], timeout) do
      case JSON.decode(out) do
        {:ok, %{"structured_output" => plan}} when is_map(plan) -> {:ok, plan}
        {:ok, %{"is_error" => true} = result} -> {:error, "claude: #{result["result"]}"}
        _ -> {:error, "claude answered no plan: #{String.slice(out, 0, 200)}"}
      end
    end
  end

  @doc "The JSON schema of a plan, as a planner answers it."
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string"},
        "steps" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "tool" => %{"type" => "string", "enum" => ["put", "set", "delete"]},
              "kind" => %{"type" => "string"},
              "in" => %{"type" => "string"},
              "key" => %{"type" => "string"},
              "values" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
              "why" => %{"type" => "string"}
            },
            "required" => ["tool", "values", "why"]
          }
        }
      },
      "required" => ["summary", "steps"]
    }
  end

  @doc "What Claude is told: the request, the page, the tools and the answer's shape."
  def prompt(input, env) do
    """
    You plan changes in Atlas for Melle. He is on a page of Atlas and asked, in his own words:

    #{input["request"]}

    You propose; you never change anything yourself. Your answer is a plan: steps, each one call of a tool below. Atlas shows the plan to Melle, and he keeps, edits or drops each step before anything runs. Propose only what the request asks for. When there is nothing to do, answer no steps and say why in the summary.

    To read more of Atlas you may run only these commands, always with --env #{env}, each on its own: no pipes, redirections, `cd` or `&&`, which are refused. Anything else you run is refused too.
    - atlas get <key> --env #{env} --json      one item, and what hangs under it
    - atlas list <kind> [--in <key>] --env #{env} --json
    - atlas help [<kind>] --env #{env}         every kind: what a create asks, its fields

    #{before(input["before"])}The page he is on, as Atlas's Control sends it (its blocks):
    #{JSON.encode!(input["page"])}

    The tools a step may use:
    #{JSON.encode!(Enum.filter(input["tools"] || [], &(&1["tool"] in ["put", "set", "delete"])))}

    A step is {"tool": "put", "kind": <kind>, "in": <the key of the item it goes in, when the tool has "in">, "values": {<field>: <text>}, "why": <one sentence>} or {"tool": "set", "key": <key>, "values": {<only the fields that change>: <text>}, "why": <one sentence>} or {"tool": "delete", "key": <key>, "values": {}, "why": <one sentence>}. Atlas refuses to delete an item while anything hangs under it; propose deleting what hangs under it first, deepest first. Use only fields the tool asks for. Ids are made by Atlas: never give one. Write titles and descriptions in the language and style of the items on the page; a title says what, without a code. The summary says in one or two sentences what the plan does.
    """
  end

  defp before(nil), do: ""

  defp before(before) do
    """
    Your previous plan for this request ran, and Atlas refused one of its steps; the run stopped there. What happened:
    #{before["text"]}

    In detail: #{JSON.encode!(Map.drop(before, ["text"]))}

    Propose what next. Do not work around the refusal: never propose the refused step again with other values only to get it stored, unless the reason says what to change. Steps already stored stay; do not propose them again. Say in the summary what was refused and why. When nothing sensible is left, answer no steps.

    """
  end

  # Run `command` with `input` on stdin; its stdout, or why not. stderr is kept apart, so a
  # planner's chatter never mixes into its answer.
  defp run(command, args, input, env, timeout) do
    dir = Path.join(System.tmp_dir!(), "atlas-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    stdin = Path.join(dir, "input")
    stderr = Path.join(dir, "stderr")
    File.write!(stdin, input)

    script = ~s|exec "$0" "$@" < "$ATLAS_PLAN_STDIN" 2> "$ATLAS_PLAN_STDERR"|
    env = [{"ATLAS_PLAN_STDIN", stdin}, {"ATLAS_PLAN_STDERR", stderr} | env]

    task =
      Task.async(fn -> System.cmd("sh", ["-c", script, command | args], env: env, cd: dir) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {out, 0}} ->
          {:ok, out}

        {:ok, {out, status}} ->
          err = File.read!(stderr) |> String.trim()

          {:error,
           "#{Path.basename(command)} failed (#{status}): #{String.slice(err <> out, 0, 300)}"}

        nil ->
          {:error, "#{Path.basename(command)} did not answer within #{div(timeout, 1000)} s"}
      end

    File.rm_rf(dir)
    result
  end
end
