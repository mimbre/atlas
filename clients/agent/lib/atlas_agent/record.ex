defmodule AtlasAgent.Record do
  @moduledoc """
  What the agent did, kept as facts in Facts (UC-Atlas-19): each request, each step of
  its plan with what became of it, and the request's outcome. Every change the agent
  makes is so a fact with its cause, which Melle can see and overrule.

  Which kinds hold the record is data: the kinds page (`/_kinds`) says, per kind, when it
  is an "Agent record" (`request` or `step`), from `rela/atlas.json`. This code names no
  kind; when the description has no such kinds, nothing is recorded. Everything goes
  through Control like any other write, so it is refused or stored by the same rules.
  """

  alias AtlasAgent.Client

  @doc "The record's kinds: `%{\"request\" => kind, \"step\" => kind}`, or nil without them."
  def kinds(client) do
    with {:ok, kinds} <- AtlasAgent.kinds(client) do
      roles =
        for kind <- kinds,
            [_, role] <- [Enum.find(kind["fields"], &match?(["Agent record", _], &1))],
            into: %{},
            do: {role, kind["kind"]}

      if Map.has_key?(roles, "request") and Map.has_key?(roles, "step"),
        do: {:ok, roles},
        else: {:ok, nil}
    end
  end

  @doc """
  Keep a request: `plan` as the agent has it (request, on, by, summary, before), with
  `outcome`. `{:ok, key}` or why not.
  """
  def request(client, %{"request" => kind}, plan, outcome) do
    values =
      %{
        "title" => plan.request |> String.split("\n") |> hd() |> String.slice(0, 200),
        "page" => plan.on || "",
        "planner" => plan.by || "",
        "outcome" => outcome,
        "summary" => plan.summary || "",
        "before" => plan[:before] || "",
        "overrules" => plan[:overrules] || ""
      }

    AtlasAgent.put(client, kind, values)
  end

  @doc "Set the outcome of the request with `key`."
  def outcome(client, key, outcome), do: AtlasAgent.set(client, key, %{"outcome" => outcome})

  @doc """
  Keep one step of the request with `key`: what it was, what became of it (`state`,
  `detail`), the key of the item it made, changed or deleted (`made`) and, for a change,
  the values it replaced (`was`).
  """
  def step(client, %{"step" => kind}, key, step, made \\ nil, was \\ nil) do
    values = %{
      # Its number in the plan first: steps are kept in the order they ran, dropped last.
      "title" => "#{step["n"]}. #{step["label"]}",
      "n" => to_string(step["n"]),
      "tool" => step["tool"] || "",
      "state" => step["state"],
      "detail" => step["detail"] || "",
      "made" => made || "",
      "values" => JSON.encode!(step["values"] || %{}),
      "was" => if(was, do: JSON.encode!(was), else: "")
    }

    AtlasAgent.put(client, kind, values, key)
  end

  @doc "The values a change will replace: those fields of the fact as they are now."
  def was(client, %{"tool" => "set", "key" => key, "values" => values}) do
    case AtlasAgent.get(client, key) do
      {:ok, item} -> Map.take(item["values"], Map.keys(values))
      _ -> nil
    end
  end

  def was(_client, _step), do: nil

  @doc "Run `fun` with a Control connection of its own."
  def with_client(env, fun) do
    with {:ok, client} <- AtlasAgent.connect(env) do
      try do
        fun.(client)
      after
        Client.close(client)
      end
    end
  end
end
