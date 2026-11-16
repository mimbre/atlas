defmodule AtlasAgent.Overrule do
  @moduledoc """
  Overrule a step the agent took (UC-Atlas-19, d-0016): the steps that undo it, as a
  plan to accept like any other. The agent works them out from the step's record, not by
  asking a planner, so an overrule does exactly the reverse of what the step did:

  - a step that made a fact (put): delete that fact;
  - a step that changed a fact (set): set the values it replaced back;
  - a step that deleted a fact: no steps yet; the record does not keep what was deleted,
    and the plan says so.

  The step's fields are read by name from its page (`tool`, `made`, `was`, `state`, `n`),
  as its kind in rela's description has them; no kind is named. The plan names the
  request it overrules (`overrules`), so the record links the two.
  """

  alias AtlasAgent.{Client, Plan}

  @doc """
  The plan that undoes the step at `on` (its page's path or key): `{:ok, %{"request",
  "on", "by", "summary", "steps", "overrules"}}`, the steps checked against Control's
  forms, or `{:error, text}`.
  """
  def make(client, on) do
    key = Client.key_of(on)

    with {:ok, page} <- Client.open(client, "/k/_/#{URI.encode(key, &URI.char_unreserved?/1)}"),
         {:ok, step} <- AtlasAgent.get(client, key) do
      values = step["values"]
      overrules = page["back"] && Client.key_of(page["back"])
      {steps, summary} = reverse(values, key)

      {:ok,
       %{
         "request" => "Overrule #{key}: #{values["title"]}",
         "on" => page["path"],
         "by" => "Atlas, from the record of #{key}",
         "summary" => summary,
         "steps" => Plan.check(client, steps, []),
         "overrules" => overrules
       }}
    end
  end

  @doc "The steps that undo a step with these recorded `values`, and what to say about it."
  def reverse(%{"state" => state}, key) when state != "stored",
    do: {[], "#{key} stored nothing, so there is nothing to undo."}

  def reverse(%{"tool" => "put", "made" => made} = values, key) when made != "" do
    {[
       %{
         "tool" => "delete",
         "key" => made,
         "values" => %{},
         "why" => "Step #{values["n"]} (#{key}) made #{made}; deleting it undoes that."
       }
     ], "Undoes #{key}: deletes #{made}, which it made."}
  end

  def reverse(%{"tool" => "set", "made" => made, "was" => was} = values, key)
      when made != "" do
    case JSON.decode(was) do
      {:ok, before} when is_map(before) and before != %{} ->
        {[
           %{
             "tool" => "set",
             "key" => made,
             "values" => before,
             "why" =>
               "Step #{values["n"]} (#{key}) changed #{made}; this puts back what it replaced."
           }
         ], "Undoes #{key}: puts back the values of #{made} it replaced."}

      _ ->
        {[], "#{key} kept no values to put back, so it cannot be undone from its record."}
    end
  end

  def reverse(%{"tool" => "delete", "made" => made}, key),
    do:
      {[],
       "#{key} deleted #{made}. The record does not keep what was deleted, so it cannot " <>
         "be undone from it yet."}

  def reverse(_values, key), do: {[], "#{key} says too little to be undone."}
end
