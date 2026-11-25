defmodule AtlasFlow.Answers do
  @moduledoc """
  What Flow reads from a task's answer, and the answer formats it asks for (#297's rules,
  kept from the review → fix ladder that IS-Atlas-100 retired with the package kind). Pure:
  it reads only its arguments.

    * `verdict/1`: a review's verdict and findings, from the JSON block its answer ends
      with;
    * `follow_ups/1`: the follow-ups a review splits off (`follow_ups:` of its spec);
    * `diagnosis/1`: a diagnose task's diagnosis;
    * `sections/1`: the answer format a review or a diagnose task is asked for, after its
      instructions.

  A subflow sequences its own author, review and fix states; nothing here decides what
  follows a task.
  """

  @findings 20
  @finding_chars 300
  @clip 2000
  @causes ~w(wrong_assumption unclear_spec flaky_test environment other)

  @doc """
  A review's verdict from its answer, which ends with a JSON block `{"verdict":
  "approved" | "changes_required", "findings": [...]}`, fenced (any fence) or bare:
  `{:ok, verdict, findings}`, at most 20 findings of at most 300 characters each (a
  finding that is not a text is JSON-encoded). `:error` when the answer does not end
  with such a block, or its `findings` is not a list. A `changes_required` without
  findings parses with `[]`.
  """
  def verdict(answer) do
    with {:ok, %{"verdict" => verdict} = block} <- last_json(answer),
         true <- verdict in ["approved", "changes_required"],
         {:ok, findings} <- findings(block["findings"]) do
      {:ok, verdict, findings}
    else
      _ -> :error
    end
  end

  defp findings(nil), do: {:ok, []}

  defp findings(list) when is_list(list) do
    texts =
      for f <- Enum.take(list, @findings) do
        text = if is_binary(f), do: f, else: JSON.encode!(f)
        String.slice(text, 0, @finding_chars)
      end

    {:ok, texts}
  end

  defp findings(_), do: :error

  @doc """
  A review's follow-ups from its answer's JSON block (the one `verdict/1` reads): its
  `follow_ups`, each `{"title", "description"}`, as entries `%{"title", "description"}`
  (the description left out when it is none), at most 20, the title clipped to 300
  characters and the description to 2000. An entry without a title is left out; `[]`
  when the answer has no such block or no follow-ups.
  """
  def follow_ups(answer) do
    case last_json(answer) do
      {:ok, %{"follow_ups" => list}} when is_list(list) ->
        for %{"title" => t} = f <- Enum.take(list, @findings), text?(t) do
          title = t |> String.trim() |> String.slice(0, @finding_chars)

          case clip(f["description"]) do
            nil -> %{"title" => title}
            description -> %{"title" => title, "description" => description}
          end
        end

      _ ->
        []
    end
  end

  @doc """
  A diagnosis from a diagnose task's answer, which ends with a JSON block `{cause,
  evidence, advice, needs?}` (#297 §4.1 a): the map, or nil when it cannot be parsed.
  `cause` is one of `wrong_assumption`, `unclear_spec`, `flaky_test`, `environment`,
  `other`; texts are clipped to 2000 characters.
  """
  def diagnosis(answer) do
    with {:ok, %{"cause" => cause} = block} <- last_json(answer),
         true <- cause in @causes do
      %{
        "cause" => cause,
        "evidence" => clip(block["evidence"]),
        "advice" => clip(block["advice"]),
        "needs" => if(block["needs"] in ["access", "native_check"], do: block["needs"])
      }
      |> Map.reject(fn {_, v} -> v == nil end)
    else
      _ -> nil
    end
  end

  # The last JSON object the answer ends with (a fenced block or bare).
  defp last_json(answer) when is_binary(answer) do
    text =
      answer
      |> String.trim_trailing()
      |> String.replace_suffix("```", "")
      |> String.trim_trailing()

    if String.ends_with?(text, "}") do
      :binary.matches(text, "{")
      |> Enum.reverse()
      |> Enum.take(400)
      |> Enum.find_value(:error, fn {at, _} ->
        case JSON.decode(binary_part(text, at, byte_size(text) - at)) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> nil
        end
      end)
    else
      :error
    end
  end

  defp last_json(_), do: :error

  defp clip(text) when is_binary(text), do: String.slice(text, 0, @clip)
  defp clip(_), do: nil

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  @review_format """
  ## Your answer

  Review the result you are given; change nothing. End your answer with one JSON block, \
  and nothing after it: {"verdict": "approved" | "changes_required", "findings": ["…"]}. \
  Give at most 20 findings of at most 300 characters each; changes_required needs at \
  least one.\
  """

  @diagnose_format """
  ## Your answer

  Find out why the work keeps failing; change nothing. End your answer with one JSON \
  block, and nothing after it: {"cause": "wrong_assumption" | "unclear_spec" | \
  "flaky_test" | "environment" | "other", "evidence": "…", "advice": "…"}. For an \
  environment cause, add "needs": "access" when it needs access, credentials or \
  permissions, or "native_check" when only a privileged command can check it.\
  """

  @doc """
  The sections a task of `kind` adds to its instructions: a review's answer format, or a
  diagnose task's; none for any other kind.
  """
  def sections("review"), do: ["\n\n" <> @review_format]
  def sections("diagnose"), do: ["\n\n" <> @diagnose_format]
  def sections(_kind), do: []
end
