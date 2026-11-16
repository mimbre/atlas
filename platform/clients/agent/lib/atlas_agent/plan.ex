defmodule AtlasAgent.Plan do
  @moduledoc """
  A plan: what an agent proposes for a request, checked against what Control offers
  before anyone sees it (UC-Atlas-16). Checking opens the form each step would fill and
  submits nothing.

  A step from a planner: `%{"tool" => "put", "kind", "in", "values", "why"}` or
  `%{"tool" => "set", "key", "values", "why"}` or `%{"tool" => "delete", "key", "why"}`.
  Values are text, by field name.

  A checked step adds:

  - `"n"`: its number, from 1;
  - `"label"`: the title of the form it fills, as Control sends it (`Create … in <key>`,
    `Update <key>`);
  - `"inputs"`: that form's inputs it fills, each with the value the step gives it, in
    the form's order (the contract's `input` model), so a client can show and edit them
    as it shows any form;
  - `"problem"`: why it cannot run, or nil. A plan with a problem is still shown, with
    the problem on its step.
  """

  alias AtlasAgent.{Planner, Tools}

  @doc """
  Plan `request`, made on the page at `on` (a path, or the key of a fact): read the page
  and the tools through Control, ask the environment's planner, check what it answers.
  Writes nothing. `{:ok, %{"request", "on", "by", "summary", "steps"}}` or `{:error, text}`.

  `before` is what became of the previous plan for the same request, when it was refused
  (see `AtlasAgent.Planner`), or nil.
  """
  def make(client, settings, on, request, before \\ nil) do
    with {:ok, page} <- AtlasAgent.page(client, on),
         {:ok, tools} <- Tools.list(client),
         input = %{
           "request" => request,
           "env" => settings["env"],
           "page" => page,
           "tools" => tools
         },
         input = if(before, do: Map.put(input, "before", before), else: input),
         {:ok, plan, by} <- Planner.plan(settings, input) do
      {:ok,
       %{
         "request" => request,
         "on" => page["path"],
         "by" => by,
         "summary" => plan["summary"],
         "steps" => check(client, plan["steps"], tools)
       }}
    end
  end

  @doc "Check `steps` (from a planner) against Control's forms and `tools`."
  def check(client, steps, tools) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, n} ->
      step |> normal() |> Map.put("n", n) |> check_step(client, tools)
    end)
  end

  defp normal(step) when is_map(step) do
    values = for {name, value} <- step["values"] || %{}, into: %{}, do: {name, text(value)}
    step |> Map.take(["tool", "kind", "in", "key", "why"]) |> Map.put("values", values)
  end

  defp normal(step), do: %{"tool" => nil, "values" => %{}, "why" => inspect(step)}

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp check_step(%{"tool" => "put", "kind" => kind} = step, client, tools) do
    tool = Tools.find(tools, "put", kind)

    cond do
      tool == nil ->
        problem(step, "Atlas has no kind #{inspect(kind)} to put")

      tool["in"] != nil and blank?(step["in"]) ->
        problem(step, "a #{kind} goes in a #{tool["in"]}; the step names none")

      tool["in"] == nil and not blank?(step["in"]) ->
        problem(step, "a #{kind} goes in nothing; the step puts it in #{step["in"]}")

      true ->
        with :ok <- parent(client, step["in"], tool["in"]),
             {:ok, form} <- AtlasAgent.create_form(client, kind, step["in"]) do
          fill(step, form, :create)
        else
          {:error, text} -> problem(step, text)
        end
    end
  end

  defp check_step(%{"tool" => "set", "key" => key} = step, client, _tools)
       when is_binary(key) do
    case AtlasAgent.change_form(client, key) do
      {:ok, form} -> fill(step, form, :change)
      {:error, text} -> problem(step, text)
    end
  end

  # A delete is checked against the confirm Control shows before it: the confirm's title is
  # its label; a confirm that cannot be confirmed says why it cannot run.
  defp check_step(%{"tool" => "delete", "key" => key} = step, client, _tools)
       when is_binary(key) do
    case AtlasAgent.delete_confirm(client, key) do
      {:ok, %{"confirm_to" => to} = confirm} when is_map(to) ->
        Map.merge(step, %{"label" => confirm["title"], "inputs" => [], "problem" => nil})

      {:ok, confirm} ->
        problem(Map.put(step, "label", confirm["title"]), confirm["text"])

      {:error, text} ->
        problem(step, text)
    end
  end

  defp check_step(%{"tool" => tool} = step, _client, _tools) when tool in ["get", "list", "help"],
    do: problem(step, "#{tool} only reads; a plan holds only what changes something")

  defp check_step(step, _client, _tools),
    do: problem(step, "a step is a put of a kind, or a set or delete of a key; this one is none")

  # The fact a put goes in exists, and is of the kind the tool says.
  defp parent(_client, nil, nil), do: :ok

  defp parent(client, key, kind) do
    case AtlasAgent.page(client, key) do
      {:ok, page} ->
        if Tools.kind_of_path(page["path"]) == kind and has_item?(page),
          do: :ok,
          else: {:error, "#{key} is not a #{kind} in Atlas"}

      {:error, _} = error ->
        error
    end
  end

  defp has_item?(page), do: Enum.any?(page["blocks"] || [], &(&1["type"] == "item"))

  defp fill(step, form, mode) do
    inputs =
      for input <- form["inputs"] || [],
          input["kind"] != "readonly",
          mode == :create or Map.has_key?(step["values"], input["name"]),
          do:
            Map.put(input, "value", Map.get(step["values"], input["name"], input["value"] || ""))

    step = Map.merge(step, %{"label" => form["title"], "inputs" => inputs})

    case AtlasAgent.asked(form, step["values"], mode) do
      :ok -> Map.put(step, "problem", nil)
      {:refused, reasons} -> problem(step, Enum.join(reasons, "; "))
      {:error, text} -> problem(step, text)
    end
  end

  defp problem(step, text) do
    step
    |> Map.put_new("label", label(step))
    |> Map.put_new("inputs", [])
    |> Map.put("problem", text)
  end

  defp label(%{"tool" => "put", "kind" => kind} = step),
    do: "Put #{kind}#{if step["in"], do: " in #{step["in"]}", else: ""}"

  defp label(%{"tool" => "set", "key" => key}), do: "Set #{key}"
  defp label(%{"tool" => "delete", "key" => key}), do: "Delete #{key}"
  defp label(step), do: "#{step["tool"] || "?"}"

  defp blank?(value), do: value in [nil, ""]

  @doc "Whether every step can run."
  def runnable?(steps), do: steps != [] and Enum.all?(steps, &is_nil(&1["problem"]))
end
