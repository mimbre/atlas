defmodule AtlasRuntime.Interactions.QuestionApproval do
  @moduledoc """
  Question approval for one native Claude query (S6 package A5, shadow; design §12 item 5).

  It ports the decisions of the Go `questionHost` (`host/host/claude_questions.go`):

  - which control request is approved, denied or answered with an error (`event`, `reject`);
  - tool-use correlation between the assistant's `AskUserQuestion` block and the
    `can_use_tool` request (`correlate`, `questionInput`);
  - detection of the processed answer (`tool_result`) and of the terminal `result`;
  - answer matching (`answer`, `matches`) and the `updatedInput` it sends.

  It is a pure function of its state: `step/2` takes a native record, a Runtime answer
  command or a cancel, and returns the actions the helper performs, in order:

  - `%{"send" => record}`: a native `control_response` to write;
  - `%{"emit" => record}`: a `runtime.*` record (`runtime.question`, `runtime.answer_delivered`,
    `runtime.answer_processed`, `runtime.answer_rejected`);
  - `%{"close" => true}`: close native input.

  Not decided here (design §0.1 rows 3 and 5): the initialize request and the first user
  message (transport, they stay in the helper), and the init identity, the tools sameness
  and the assistant model (row 3: `Sandbox.Resume`, package A3). The state starts after the
  initialization, with the model that identity confirmed.

  Text rules are Go's, which follow Python: blank is `not text.strip()` (the
  `\\x1c`-`\\x1f` separators are blank, F3), lengths of identifiers are code points, text
  limits are bytes, sizes are `json.dumps(value, ensure_ascii=False, separators=(",", ":"))`.
  Not wired: `Interactions.NativeQuestion` still validates answers until C5.
  """

  @question "AskUserQuestion"
  @request_keys ~w(subtype tool_name display_name input tool_use_id requires_user_interaction)
  # Python's str.strip set (Go `unicode.IsSpace` plus the \x1c-\x1f separators), as
  # `pythonBlank` (claude_questions.go:364-368).
  @blank [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680] ++
           Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  @type state :: map()
  @type action :: %{optional(String.t()) => term()}
  @type input :: {:native, map()} | {:answer, map()} | :cancel

  @doc """
  A state for one query whose initialization is confirmed.

  Options: `:session` and `:model` (required, the confirmed identity), `:native_pid`, and
  `:ids`, a list of question ids to hand out in order (tests); without it each id is
  `question-` and the hex of a fresh uuid4, as Go makes it.
  """
  def new(opts) do
    %{
      session: Keyword.fetch!(opts, :session),
      model: Keyword.fetch!(opts, :model),
      native_pid: Keyword.get(opts, :native_pid),
      ids: Keyword.get(opts, :ids, :random),
      finished: false,
      last_tool: "",
      candidate: nil,
      pending: nil,
      inflight: nil
    }
  end

  @doc """
  One step. Returns `{state, actions}`, or `{:error, text, actions}` when the query must
  fail: `actions` are the writes due before that (for example the `deny` of a malformed
  request), and `text` is the helper's exact refusal.
  """
  @spec step(state, input) :: {state, [action]} | {:error, String.t(), [action]}
  def step(state, {:native, record}) when is_map(record), do: event(state, record)
  def step(state, {:answer, command}) when is_map(command), do: answer(state, command)

  def step(state, :cancel),
    do: {%{state | candidate: nil, pending: nil, inflight: nil, finished: true}, [close()]}

  # claude_questions.go `event` 116-261.
  defp event(%{finished: true}, _record), do: fail("Native event after terminal result")

  defp event(state, record) do
    cond do
      Map.has_key?(record, "session_id") and record["session_id"] != state.session ->
        fail("Native question session changed")

      record["parent_tool_use_id"] != nil ->
        fail("Subagent question transport is not supported")

      true ->
        kind(state, record["type"], record)
    end
  end

  # The state starts initialized, so any later initialization response is unexpected.
  defp kind(_state, "control_response", _record),
    do: fail("Unexpected native initialization response")

  # The init identity is Resume's verdict (A3); it decides nothing about questions.
  defp kind(state, "system", %{"subtype" => "init"}), do: {state, []}

  defp kind(state, "assistant", record) do
    message = record["message"]

    cond do
      record["session_id"] != state.session or not is_map(message) ->
        fail("Native question assistant identity changed")

      not is_list(message["content"]) ->
        fail("Invalid native assistant content")

      true ->
        assistant_blocks(state, message["content"])
    end
  end

  defp kind(state, "control_request", record), do: control_request(state, record)
  defp kind(state, "user", record), do: tool_result(state, record)

  defp kind(_state, "control_cancel_request", _record),
    do: fail("Native cancelled its pending control request")

  defp kind(state, "result", record) do
    if record["session_id"] != state.session or state.candidate != nil or
         state.pending != nil or state.inflight != nil,
       do: {:error, "Native result ended without processing its question", [close()]},
       else: {%{state | finished: true}, [close()]}
  end

  defp kind(_state, "control_" <> _, _record), do: fail("Unsupported native control message")
  defp kind(state, _kind, _record), do: {state, []}

  defp assistant_blocks(state, []), do: {state, []}

  defp assistant_blocks(_state, [block | _]) when not is_map(block),
    do: fail("Invalid native assistant block")

  defp assistant_blocks(state, [%{"type" => "tool_use", "name" => @question} = block | rest]) do
    tool = block["id"]

    if state.candidate != nil or state.pending != nil or state.inflight != nil or
         not is_binary(tool) or tool == "" or code_points(tool) > 256 or
         tool == state.last_tool or
         (Map.has_key?(block, "caller") and
            not python_equal(%{"type" => "direct"}, block["caller"])) do
      fail("Ambiguous native question tool use")
    else
      case question_input(block["input"]) do
        {:ok, _questions} ->
          assistant_blocks(%{state | candidate: %{tool: tool, input: block["input"]}}, rest)

        {:error, text} ->
          fail(text)
      end
    end
  end

  defp assistant_blocks(state, [_block | rest]), do: assistant_blocks(state, rest)

  defp control_request(state, record) do
    request = record["request"]

    cond do
      not is_map(request) or request["subtype"] != "can_use_tool" ->
        {:error, "Unsupported native control request",
         reject(record, "Runtime does not permit native control changes", false)}

      not valid_identifier?(record["request_id"]) or not nonempty?(request["tool_name"]) or
        not nonempty?(request["tool_use_id"]) or not is_map(request["input"]) ->
        {:error, "Malformed native permission request",
         reject(record, "Runtime refused a malformed native request", true)}

      request["tool_name"] != @question ->
        {state, reject(record, "Runtime does not approve non-question tools", true)}

      true ->
        case correlate(state, request) do
          {:ok, questions} ->
            ask(state, record["request_id"], questions)

          {:error, text} ->
            {:error, text, reject(record, "Runtime refused an invalid native question", true)}
        end
    end
  end

  defp ask(state, request_id, questions) do
    {id, state} = next_id(state)
    pending = Map.merge(state.candidate, %{request: request_id, id: id})

    question = %{
      "id" => id,
      "questions" => questions,
      "correlation" => %{
        "session_id" => state.session,
        "model" => state.model,
        "tool_use_id" => pending.tool,
        "request_id" => request_id,
        "native_pid" => state.native_pid
      }
    }

    {%{state | pending: pending, candidate: nil},
     [%{"emit" => %{"type" => "runtime.question", "question" => question}}]}
  end

  # claude_questions.go `correlate` 264-277: the request repeats the pending tool use exactly.
  defp correlate(state, request) do
    if Enum.all?(Map.keys(request), &(&1 in @request_keys)) and
         request["requires_user_interaction"] === true and state.model != "" and
         state.pending == nil and state.inflight == nil and state.candidate != nil and
         request["tool_use_id"] == state.candidate.tool and
         python_equal(state.candidate.input, request["input"]),
       do: question_input(request["input"]),
       else: {:error, "Uncorrelated native question request"}
  end

  defp tool_result(state, record) do
    message = record["message"]

    if is_map(message) and is_list(message["content"]),
      do: tool_result_blocks(state, record, message["content"], []),
      else: fail("Invalid native tool result")
  end

  defp tool_result_blocks(state, _record, [], actions), do: {state, actions}

  # Go emits `runtime.answer_processed` for a matching block before it reaches a later block
  # that is not an object, so that emit is still due when the record fails.
  defp tool_result_blocks(_state, _record, [block | _], actions) when not is_map(block),
    do: fail("Invalid native tool result block", actions)

  defp tool_result_blocks(
         %{inflight: %{tool: tool} = inflight} = state,
         record,
         [block | rest],
         actions
       )
       when :erlang.map_get("type", block) == "tool_result" and
              :erlang.map_get("tool_use_id", block) == tool do
    if record["session_id"] != state.session or
         (Map.has_key?(block, "is_error") and block["is_error"] !== false) do
      fail("Native question processing failed")
    else
      processed = %{
        "emit" => %{"type" => "runtime.answer_processed", "question_id" => inflight.id}
      }

      tool_result_blocks(
        %{state | last_tool: tool, inflight: nil},
        record,
        rest,
        actions ++ [processed]
      )
    end
  end

  defp tool_result_blocks(state, record, [_block | rest], actions),
    do: tool_result_blocks(state, record, rest, actions)

  # claude_questions.go `answer` 280-301.
  defp answer(state, command) do
    id = command["question_id"]

    cond do
      Enum.sort(Map.keys(command)) != ["answers", "command", "question_id"] or
        command["command"] != "answer" or not valid_identifier?(id) ->
        fail("Malformed Runtime answer command")

      state.finished or state.pending == nil or id != state.pending.id or
        not is_map(command["answers"]) or not matches?(state.pending, command["answers"]) ->
        {state,
         [
           %{
             "emit" => %{
               "type" => "runtime.answer_rejected",
               "question_id" => id,
               "error" => "Answer does not match the pending native question"
             }
           }
         ]}

      true ->
        pending = state.pending
        updated = Map.put(pending.input, "answers", command["answers"])

        allow = %{
          "type" => "control_response",
          "response" => %{
            "subtype" => "success",
            "request_id" => pending.request,
            "response" => %{"behavior" => "allow", "updatedInput" => updated}
          }
        }

        {%{state | inflight: pending, pending: nil},
         [
           %{"send" => allow},
           %{"emit" => %{"type" => "runtime.answer_delivered", "question_id" => id}}
         ]}
    end
  end

  # claude_questions.go `matches` 304-320: one bounded nonblank answer per question text.
  defp matches?(pending, answers) do
    texts = Enum.map(pending.input["questions"], & &1["question"])

    map_size(answers) == length(texts) and Enum.all?(texts, &Map.has_key?(answers, &1)) and
      Enum.all?(
        Map.values(answers),
        &(is_binary(&1) and not blank?(&1) and byte_size(&1) <= 4096)
      ) and
      canonical_size(answers) <= 16_384
  end

  @doc """
  Validates one `AskUserQuestion` input and returns its questions (`questionInput`,
  claude_questions.go 64-100), or the exact refusal.
  """
  def question_input(value) do
    with true <- exact_keys?(value, ["questions"]) and canonical_size(value) <= 32_768,
         questions when is_list(questions) and length(questions) in 1..4 <- value["questions"] do
      questions
      |> Enum.reduce_while(MapSet.new(), &check_question/2)
      |> case do
        {:error, text} -> {:error, text}
        _seen -> {:ok, questions}
      end
    else
      false -> {:error, "Invalid native question input"}
      _ -> {:error, "Invalid native question count"}
    end
  end

  defp check_question(entry, seen) do
    text = is_map(entry) && entry["question"]

    cond do
      not exact_keys?(entry, ["question", "header", "options", "multiSelect"]) ->
        {:halt, {:error, "Invalid native question fields"}}

      not is_binary(text) or blank?(text) or byte_size(text) > 4096 or MapSet.member?(seen, text) or
        not is_binary(entry["header"]) or not is_boolean(entry["multiSelect"]) ->
        {:halt, {:error, "Invalid native question"}}

      not is_list(entry["options"]) or length(entry["options"]) not in 2..4 ->
        {:halt, {:error, "Invalid native question options"}}

      not Enum.all?(entry["options"], &option?/1) ->
        {:halt, {:error, "Invalid native question option"}}

      true ->
        {:cont, MapSet.put(seen, text)}
    end
  end

  defp option?(option),
    do:
      exact_keys?(option, ["label", "description"]) and is_binary(option["label"]) and
        is_binary(option["description"]) and not blank?(option["label"])

  # `reject` 102-113: nothing is written for a missing or unbounded request id.
  defp reject(record, message, deny) do
    id = record["request_id"]

    if valid_identifier?(id) do
      response =
        if deny,
          do: %{
            "subtype" => "success",
            "request_id" => id,
            "response" => %{"behavior" => "deny", "message" => message}
          },
          else: %{"subtype" => "error", "request_id" => id, "error" => message}

      [%{"send" => %{"type" => "control_response", "response" => response}}]
    else
      []
    end
  end

  defp next_id(%{ids: [id | rest]} = state), do: {id, %{state | ids: rest}}

  defp next_id(%{ids: :random} = state),
    do: {"question-" <> Base.encode16(uuid4(), case: :lower), state}

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
  end

  defp fail(text, actions \\ []), do: {:error, text, actions}
  defp close, do: %{"close" => true}

  defp valid_identifier?(id), do: nonempty?(id) and code_points(id) <= 256
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp exact_keys?(fields, keys),
    do:
      is_map(fields) and map_size(fields) == length(keys) and
        Enum.all?(keys, &Map.has_key?(fields, &1))

  # Python's len of a str: code points, not graphemes (`pythonLength`).
  defp code_points(text), do: text |> String.to_charlist() |> length()

  @doc "Python's `not text.strip()` (`pythonBlank`); `String.trim/1` keeps `\\x1c`-`\\x1f`."
  def blank?(text), do: text |> String.to_charlist() |> Enum.all?(&(&1 in @blank))

  # `pythonEqual`: Python's == between a validated value (strings, booleans, lists, objects)
  # and decoded native JSON, where true == 1 and false == 0.
  defp python_equal(validated, other) when is_map(validated),
    do:
      is_map(other) and map_size(other) == map_size(validated) and
        Enum.all?(validated, fn {key, value} ->
          Map.has_key?(other, key) and python_equal(value, other[key])
        end)

  defp python_equal(validated, other) when is_list(validated),
    do:
      is_list(other) and length(other) == length(validated) and
        Enum.all?(Enum.zip(validated, other), fn {value, item} -> python_equal(value, item) end)

  defp python_equal(validated, other) when is_boolean(validated) and is_number(other),
    do: other == if(validated, do: 1, else: 0)

  defp python_equal(validated, other), do: validated === other

  @doc """
  The byte size of `json.dumps(value, ensure_ascii=False, separators=(",", ":"))`
  (`canonicalSize`). Like Go, numbers count as written; Elixir has only the decoded value,
  so a number written in another form (`1e2`) can count differently. Validated questions and
  answers hold no numbers, so only rejected inputs could differ.
  """
  def canonical_size(value), do: value |> compact() |> IO.iodata_length()

  defp compact(nil), do: "null"
  defp compact(true), do: "true"
  defp compact(false), do: "false"
  defp compact(value) when is_integer(value), do: Integer.to_string(value)
  defp compact(value) when is_float(value), do: JSON.encode!(value)
  defp compact(value) when is_binary(value), do: [?", escape(value), ?"]

  defp compact(value) when is_list(value),
    do: [?[, Enum.map_intersperse(value, ?,, &compact/1), ?]]

  defp compact(value) when is_map(value) do
    entries =
      value
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_intersperse(?,, &[compact(&1), ?:, compact(value[&1])])

    [?{, entries, ?}]
  end

  defp escape(text) do
    for <<char::utf8 <- text>> do
      case char do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        ?\b -> "\\b"
        ?\f -> "\\f"
        char when char < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")
        char -> <<char::utf8>>
      end
    end
  end
end
