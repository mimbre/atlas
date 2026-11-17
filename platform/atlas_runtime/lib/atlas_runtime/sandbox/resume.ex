defmodule AtlasRuntime.Sandbox.Resume do
  @moduledoc """
  Resume and continuation validation (S6 §12 item 3), decided in Elixir. Shadow only: nothing
  calls it in production until cutover C3, and the Go helper still decides today.

  Pure functions, no I/O (B4). The shared table `test/fixtures/s6/resume/*.json` pins every
  rule to today's Go decision (B2, B3: refusal texts are byte-identical):

    * `validate/7`: before launch, `claudeValidate` (`host/host/claude.go:31-55`, with
      Python's `uuid.UUID` parse messages) and the argument checks of `run`
      (`host/host/host.go:76-101`), in Go's order.
    * `start/1` and `verdict/2`: over the native record sequence, `claudeProtocol`
      (`claude.go:139-176`), `codexProtocol` (`codex.go:571-593`), and the question
      session's identity (`claude_questions.go:116-165`), against an expected
      `question_session` passed in (plan row 3a).
    * `question_session/1,2`: the id a fresh question turn gets (`host.go:149-151`).

  One deliberate difference, marked `"change": "D29"` in the table: a subagent record
  (non-null `parent_tool_use_id`) is never judged (design D29, §3.5); today's helper judges
  it on a resumed Claude session.

  Kept in the helper and not decided here (plan §0.1 row 3, rows 5): the question
  transport (the initialize handshake, a subagent question record, tool use, control
  requests and the result's question state) and holding forwarding until the verdict.
  The saved Claude context is compared in the helper (RQ4).
  """

  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  # host.go:27 modelPattern.
  @model ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/
  # claude.go:35; review-packet stays Go-decided until removed (B9), so it is kept here.
  @claude_profiles ["dedicated-repository", "materialized-folder", "review-packet"]
  # workspace.go:162-166, the scope a managed repository's start must carry.
  @network_hosts ["github.com", "api.github.com"]
  # Go's unicode.IsSpace (pythonHexInteger trims with it, claude.go:59).
  @spaces [?\t, ?\n, ?\v, ?\f, ?\r, ?\s, 0x85, 0xA0, 0x1680] ++
            Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  @type refusal :: {:error, String.t()}

  @doc """
  The pre-launch checks of a native start or continuation.

  `sandbox` and `session` are strings, `""` when absent (`nil` is read as `""`); `scope`,
  `model` and `context` are decoded JSON. `launch` holds the rest of the start:
  `:workspace` (the path native.ex passes), `:repository` (decoded JSON, default `nil`)
  and `:questions` (default `false`).
  """
  @spec validate(term(), term(), String.t() | nil, String.t() | nil, term(), term(), keyword()) ::
          :ok | refusal()
  def validate(backend, scope, sandbox, session, model, context, launch \\ []) do
    sandbox = sandbox || ""
    session = session || ""
    questions = Keyword.get(launch, :questions, false)
    repository = Keyword.get(launch, :repository)

    # Go's order (host.go:76-101); the first refusal wins.
    [
      fn ->
        if not is_boolean(questions) or (questions and backend != "claude"),
          do: {:error, "Questions require a boolean opt-in and the Claude backend"}
      end,
      fn ->
        if not is_nil(model) and not (is_binary(model) and Regex.match?(@model, model)),
          do: {:error, "Model must be a nonempty identifier of at most 200 characters"}
      end,
      fn ->
        if backend not in ["codex", "claude"], do: {:error, "Backend must be codex or claude"}
      end,
      fn ->
        if backend == "claude" do
          with :ok <- claude_validate(scope, sandbox, session, model, context), do: nil
        end
      end,
      fn ->
        if is_nil(scope) and sandbox not in ["read-only", "workspace-write"],
          do: {:error, "Sandbox must be read-only or workspace-write"}
      end,
      fn ->
        if not is_nil(repository) and
             (not python_equal(dedicated_scope(Keyword.fetch!(launch, :workspace)), scope) or
                session != "" != (is_map(repository) and Map.has_key?(repository, "base_sha"))),
           do: {:error, "Managed repository context does not match this start or continuation"}
      end,
      fn ->
        if not is_nil(scope) and sandbox != "",
          do: {:error, "Dedicated repository permissions conflict with sandbox"}
      end
    ]
    |> Enum.find_value(:ok, & &1.())
  end

  defp claude_validate(scope, sandbox, session, model, context) do
    cond do
      is_nil(scope) and sandbox != "read-only" ->
        {:error,
         "Claude requires read-only, dedicated-repository or materialized-folder execution"}

      not is_nil(scope) and not (is_map(scope) and scope["profile"] in @claude_profiles) ->
        {:error,
         "Claude supports only the dedicated-repository, materialized-folder and review-packet permission profiles"}

      session == "" ->
        :ok

      true ->
        canonical = Regex.match?(@canonical_uuid, session)

        with :ok <- if(canonical, do: :ok, else: python_uuid(session)) do
          if canonical and not is_nil(model) and is_map(context),
            do: :ok,
            else:
              {:error,
               "Claude resume requires a confirmed UUID, model and saved execution context"}
        end
    end
  end

  # Python's uuid.UUID(text) parse errors, in its order (claude.go:41-50).
  defp python_uuid(session) do
    hex =
      session
      |> String.replace("urn:", "")
      |> String.replace("uuid:", "")
      |> then(&Regex.replace(~r/\A[{}]+|[{}]+\z/, &1, ""))
      |> String.replace("-", "")

    cond do
      length(String.codepoints(hex)) != 32 ->
        {:error, "badly formed hexadecimal UUID string"}

      not python_hex_integer(hex) ->
        {:error, "invalid literal for int() with base 16: " <> python_repr(hex)}

      true ->
        :ok
    end
  end

  # What int(text, 16) accepts, ASCII digits only, as claude.go:58-74.
  defp python_hex_integer(text) do
    text =
      text
      |> String.to_charlist()
      |> Enum.drop_while(&(&1 in @spaces))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 in @spaces))
      |> Enum.reverse()
      |> List.to_string()

    text =
      if String.starts_with?(text, ["+", "-"]),
        do: binary_part(text, 1, byte_size(text) - 1),
        else: text

    text =
      case text do
        <<?0, x, rest::binary>> when x in [?x, ?X] ->
          if String.starts_with?(rest, "_"),
            do: binary_part(rest, 1, byte_size(rest) - 1),
            else: rest

        _ ->
          text
      end

    text != "" and not String.starts_with?(text, "_") and not String.ends_with?(text, "_") and
      not String.contains?(text, "__") and Regex.match?(~r/\A[0-9a-fA-F_]*\z/, text)
  end

  # Python's str repr as claude.go:77-101 renders it.
  defp python_repr(text) do
    quote =
      if String.contains?(text, "'") and not String.contains?(text, "\""), do: "\"", else: "'"

    body =
      text
      |> String.to_charlist()
      |> Enum.map(fn
        char when char == ?\\ ->
          "\\\\"

        ?\n ->
          "\\n"

        ?\r ->
          "\\r"

        ?\t ->
          "\\t"

        char when char < 0x20 or char == 0x7F ->
          "\\x" <> String.pad_leading(Integer.to_string(char, 16) |> String.downcase(), 2, "0")

        char ->
          if <<char::utf8>> == quote, do: "\\" <> quote, else: <<char::utf8>>
      end)

    quote <> IO.iodata_to_binary(body) <> quote
  end

  # workspace.DedicatedScope (workspace.go:158-166): lexical, no filesystem access.
  defp dedicated_scope(workspace) do
    root = clean(workspace)

    %{
      "profile" => "dedicated-repository",
      "version" => 1,
      "root" => root,
      "git_dir" => clean(root <> "/.git"),
      "network_hosts" => @network_hosts
    }
  end

  # workspacePath (workspace.go:66-86): drop empty and "." parts, keep "..", keep a leading "//".
  defp clean(path) do
    prefix =
      cond do
        String.starts_with?(path, "//") and not String.starts_with?(path, "///") -> "//"
        String.starts_with?(path, "/") -> "/"
        true -> ""
      end

    case prefix <> Enum.join(Enum.reject(String.split(path, "/"), &(&1 in ["", "."])), "/") do
      "" -> "."
      result -> result
    end
  end

  # workspace.JSONEqual (workspace.go:575-626) with our scope on the left: Python equality,
  # so the version 1 equals 1.0 and true.
  defp python_equal(left, right) when is_map(left) do
    is_map(right) and map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        Map.has_key?(right, key) and python_equal(value, right[key])
      end)
  end

  defp python_equal(left, right) when is_list(left) do
    is_list(right) and length(left) == length(right) and
      Enum.all?(Enum.zip(left, right), fn {one, other} -> python_equal(one, other) end)
  end

  defp python_equal(left, right) when is_integer(left) do
    cond do
      is_boolean(right) -> left == if(right, do: 1, else: 0)
      is_number(right) -> left == right
      true -> false
    end
  end

  defp python_equal(left, right), do: left === right

  @doc """
  The verdict state for one native turn.

  `start` has the string keys `"backend"`, `"session"` (`""` or `nil` for a fresh turn),
  `"model"`, `"question_session"` (`nil` without questions) and `"tools"` (the question
  turn's expected init tools).
  """
  @spec start(map()) :: map()
  def start(start) do
    session = start["session"] || ""
    model = start["model"]

    %{
      backend: start["backend"],
      session: session,
      # claudeProtocol compares with modelName, "" when no model was requested.
      model: if(is_binary(model), do: model, else: ""),
      question_session: start["question_session"],
      tools: start["tools"] || [],
      resume_model: if(session != "" and is_binary(model), do: model, else: ""),
      confirmed: nil,
      seen: false
    }
  end

  @doc """
  The verdict on one decoded native record, or on `{:completed, stopped?}` when the native
  process ended. A refusal ends the turn; its text is the turn's failure detail.
  """
  @spec verdict(map(), map() | {:completed, boolean()}) ::
          {:continue, map()} | {:refuse, String.t()}
  def verdict(state, {:completed, stopped}) do
    if state.session != "" and not state.seen and not stopped do
      {:refuse,
       if(state.backend == "codex",
         do: "Codex resume ended without confirming its session",
         else: "Claude resume ended without confirming its session"
       )}
    else
      {:continue, state}
    end
  end

  def verdict(state, record) when is_map(record) do
    case question_identity(state, record) do
      {:refuse, _} = refusal -> refusal
      {:transport, state} -> {:continue, state}
      {:continue, state} -> protocol(state, record)
    end
  end

  # The question session's identity, before the provider protocol (host.go:451-461).
  defp question_identity(%{question_session: nil} = state, _record), do: {:continue, state}

  defp question_identity(state, %{"type" => "runtime.repository_prepared"}),
    do: {:continue, state}

  defp question_identity(%{question_session: expected} = state, record) do
    cond do
      Map.has_key?(record, "session_id") and record["session_id"] != expected ->
        {:refuse, "Native question session changed"}

      record["type"] == "control_response" ->
        # The initialize handshake is the helper's transport.
        {:transport, state}

      record["type"] == "system" and record["subtype"] == "init" ->
        actual = record["model"]
        tools = record["tools"]

        if record["session_id"] == expected and is_binary(actual) and
             actual not in ["", "<synthetic>"] and
             (state.resume_model == "" or actual == state.resume_model) and
             (is_nil(state.confirmed) or actual == state.confirmed) and
             Map.get(record, "permissionMode", "default") in ["default", "manual"] and
             is_list(tools) and same_tools?(tools, state.tools),
           do: {:continue, %{state | confirmed: actual}},
           else: {:refuse, "Native question initialization identity changed"}

      record["type"] == "assistant" and top_level?(record) ->
        message = record["message"]

        if not is_nil(state.confirmed) and record["session_id"] == expected and is_map(message) and
             model_matches?(state.confirmed, message["model"]),
           do: {:continue, state},
           else: {:refuse, "Native question assistant identity changed"}

      true ->
        {:continue, state}
    end
  end

  defp protocol(%{backend: "codex"} = state, %{"type" => "thread.started"} = record) do
    id = record["thread_id"]

    if is_binary(id) and id != "" and (state.session == "" or id == state.session),
      do: {:continue, %{state | seen: true}},
      else: {:refuse, "Codex did not confirm the requested session"}
  end

  defp protocol(%{backend: "codex"} = state, _record), do: {:continue, state}

  defp protocol(%{session: ""} = state, _record), do: {:continue, state}

  defp protocol(state, %{"type" => "system", "subtype" => "init"} = record) do
    if record["session_id"] == state.session and record["model"] == state.model,
      do: {:continue, %{state | seen: true}},
      else: {:refuse, "Claude did not confirm the requested session and model"}
  end

  # Only a top-level record names the turn's model; a subagent's never counts (D29).
  defp protocol(state, %{"type" => "assistant"} = record) do
    with true <- top_level?(record),
         {:ok, actual} <- assistant_model(record),
         true <-
           truthy?(actual) and actual != "<synthetic>" and not model_matches?(state.model, actual) do
      {:refuse, "Claude resumed with a different model"}
    else
      {:refuse, _} = refusal -> refusal
      _ -> {:continue, state}
    end
  end

  defp protocol(state, _record), do: {:continue, state}

  # Python's record.get("message", {}).get("model") (claude.go:156-162).
  defp assistant_model(record) do
    case record do
      %{"message" => message} when is_map(message) ->
        {:ok, message["model"]}

      %{"message" => message} ->
        {:refuse, "'#{python_type(message)}' object has no attribute 'get'"}

      _ ->
        {:ok, nil}
    end
  end

  defp top_level?(record), do: is_nil(record["parent_tool_use_id"])

  # assistantModelMatches (claude_questions.go:328-333): the configured model, or its base
  # when the configured one carries the context-window option; never the other way round.
  defp model_matches?(configured, actual) do
    is_binary(actual) and actual != "" and
      (actual == configured or configured == actual <> "[1m]")
  end

  # sameTools (claude_questions.go:344-356): the same set of names, duplicates allowed.
  defp same_tools?(tools, expected) do
    Enum.all?(tools, &(is_binary(&1) and &1 in expected)) and Enum.all?(expected, &(&1 in tools))
  end

  defp python_type(nil), do: "NoneType"
  defp python_type(value) when is_binary(value), do: "str"
  defp python_type(value) when is_boolean(value), do: "bool"
  defp python_type(value) when is_list(value), do: "list"
  defp python_type(value) when is_integer(value), do: "int"
  defp python_type(value) when is_float(value), do: "float"
  defp python_type(_value), do: "dict"

  defp truthy?(value) when value in [nil, false, "", [], 0], do: false
  defp truthy?(value) when is_float(value), do: value != 0.0
  defp truthy?(value) when is_map(value), do: map_size(value) > 0
  defp truthy?(_value), do: true

  @doc """
  The expected session of a question turn (`host.go:149-151`): the resumed session, or a
  fresh version 4 UUID. `random` returns the 16 random bytes; tests inject it.
  """
  @spec question_session(String.t() | nil, (-> <<_::128>>)) :: String.t()
  def question_session(session, random \\ fn -> :crypto.strong_rand_bytes(16) end)

  def question_session(session, _random) when is_binary(session) and session != "", do: session

  def question_session(_session, random) do
    <<head::binary-6, b6, b7, b8, tail::binary-7>> = random.()

    hex =
      Base.encode16(
        <<head::binary, Bitwise.bor(Bitwise.band(b6, 0x0F), 0x40), b7,
          Bitwise.bor(Bitwise.band(b8, 0x3F), 0x80), tail::binary>>,
        case: :lower
      )

    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    Enum.join([a, b, c, d, e], "-")
  end
end
