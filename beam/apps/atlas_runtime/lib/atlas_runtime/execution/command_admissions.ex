defmodule AtlasRuntime.CommandAdmissions do
  @moduledoc "Immutable command admissions; an indeterminate reservation never implies native delivery."
  alias AtlasRuntime.Workspaces

  defmodule StorageError do
    defexception [:message]
  end

  @request_bytes 128 * 1024
  @record_bytes 1024 * 1024
  @binding_keys ~w(worker_id source_turn_id cwd sandbox permissions repository backend model session_id questions_enabled)
  @record_keys ~w(version request_id record_ref request binding turn_id admission recorded_result)

  def canonical(request) do
    unless is_map(request), do: raise(ArgumentError, "Command must be an object")
    if Map.has_key?(request, "request_id"), do: validate_id!(request["request_id"])
    request = request |> Map.delete("request_id") |> normalize_request!()
    bounded!(request, @request_bytes, "Command request")

    if Map.has_key?(request, "cwd") do
      cwd = Workspaces.workspace_path(request["cwd"])
      request = Map.put(request, "cwd", cwd)
      bounded!(request, @request_bytes, "Command request")
      request
    else
      request
    end
  rescue
    error in ArgumentError -> reraise error, __STACKTRACE__
    error -> raise ArgumentError, "Invalid command request: #{Exception.message(error)}"
  end

  def load(dir, id) do
    validate_id!(id)

    storage(fn ->
      directory!(dir)
      path = Path.join(dir, reference(id))

      case File.lstat(path) do
        {:error, :enoent} ->
          case File.lstat(path <> ".tmp") do
            {:error, :enoent} -> nil
            {:ok, _} -> raise("Unresolved command admission temporary file")
            {:error, reason} -> raise File.Error, reason: reason, action: "read temporary command admission", path: path <> ".tmp"
          end
        {:ok, %{type: :regular, links: 1, size: size}} when size <= @record_bytes ->
          bytes = File.open!(path, [:read, :binary], &IO.binread(&1, @record_bytes + 1))
          unless is_binary(bytes) and byte_size(bytes) <= @record_bytes,
            do: raise("Oversized or empty command admission")
          record = bytes |> JSON.decode!() |> validate_record!()
          unless record["request_id"] == id, do: raise("Command admission ownership does not match its path")
          record
        {:ok, _} -> raise("Invalid or oversized command admission file")
        {:error, reason} -> raise File.Error, reason: reason, action: "read command admission", path: path
      end
    end)
  end

  def reserve(dir, id, request, binding, turn_id, run) do
    validate_id!(id)

    storage(fn ->
      if load(dir, id), do: raise("Request ID already recorded")
      record = %{
        "version" => 1, "request_id" => id, "record_ref" => reference(id),
        "request" => request, "binding" => binding, "turn_id" => turn_id,
        "admission" => "indeterminate", "recorded_result" => nil
      }
      accepted(record, run)
      persist(dir, record)
    end)
  end

  def accept(dir, record, run) do
    storage(fn ->
      validate_record!(record)
      unless record["admission"] == "indeterminate" and load(dir, record["request_id"]) == record,
        do: raise("Command admission changed or is already accepted")
      persist(dir, accepted(record, run))
    end)
  end

  def public(record) do
    %{
      "request_id" => record["request_id"], "admission" => record["admission"],
      "worker_id" => record["binding"]["worker_id"], "turn_id" => record["turn_id"],
      "source_turn_id" => record["binding"]["source_turn_id"],
      "recorded_result" => record["recorded_result"],
      "requires_reconciliation" => record["admission"] == "indeterminate"
    }
  end

  defp normalize_request!(request) do
    operation = request["command"]
    allowed = case operation do
      "start" -> ~w(command assignment cwd repository branch permissions sandbox backend worker_id questions_enabled)
      "continue" -> ~w(command assignment worker_id turn_id)
      _ -> raise ArgumentError, "Request ID is supported only for start and continue"
    end
    unless Map.keys(request) -- allowed == [], do: raise(ArgumentError, "Unknown command fields")
    unless text?(request["assignment"]), do: raise(ArgumentError, "A nonempty assignment is required")
    optional!(request, "worker_id", &worker_id?/1)
    optional!(request, "turn_id", &turn_id?/1)
    optional!(request, "backend", &(&1 in ["codex", "claude"]))

    if operation == "continue" do
      request
    else
      questions = Map.get(request, "questions_enabled", false)
      unless is_boolean(questions), do: raise(ArgumentError, "questions_enabled must be a boolean")
      if questions and request["backend"] == "codex",
        do: raise(ArgumentError, "Questions are supported only by Claude")
      request = Map.put(request, "questions_enabled", questions)
      optional!(request, "permissions", &(&1 == "dedicated-repository"))

      cond do
        Map.has_key?(request, "repository") or Map.has_key?(request, "branch") ->
          unless text?(request["repository"]) and text?(request["branch"]) and
                   request["permissions"] == "dedicated-repository" and
                   not Map.has_key?(request, "cwd") and not Map.has_key?(request, "sandbox"),
            do: raise(ArgumentError, "Repository provisioning requires URL, branch and dedicated-repository permissions only")
          request
        not path?(request["cwd"]) ->
          raise ArgumentError, "A working directory is required"
        request["permissions"] == "dedicated-repository" ->
          if Map.has_key?(request, "sandbox"), do: raise(ArgumentError, "Permissions cannot be combined with sandbox")
          request
        true ->
          sandbox = Map.get(request, "sandbox", "read-only")
          unless sandbox in ["read-only", "workspace-write"],
            do: raise(ArgumentError, "Sandbox must be read-only or workspace-write")
          Map.put(request, "sandbox", sandbox)
      end
    end
  end

  defp validate_record!(record) do
    unless is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@record_keys) and
             record["version"] == 1 and request_id?(record["request_id"]) and
             record["record_ref"] == reference(record["request_id"]) and turn_id?(record["turn_id"]) and
             record["admission"] in ["indeterminate", "accepted"],
      do: raise("Invalid command admission")
    request = record["request"]
    unless is_map(request) and normalize_request!(request) == request and
             (not Map.has_key?(request, "cwd") or absolute_path?(request["cwd"])),
      do: raise("Invalid canonical command request")
    bounded!(request, @request_bytes, "Command request")
    validate_binding!(record)

    case record["admission"] do
      "indeterminate" ->
        unless is_nil(record["recorded_result"]), do: raise("Indeterminate admission cannot contain a result")
      "accepted" -> validate_result!(record)
    end
    record
  end

  defp validate_binding!(record) do
    binding = record["binding"]
    request = record["request"]
    unless is_map(binding) and Enum.sort(Map.keys(binding)) == Enum.sort(@binding_keys) and
             worker_id?(binding["worker_id"]) and absolute_path?(binding["cwd"]) and
             binding["backend"] in ["codex", "claude"] and
             (is_nil(binding["model"]) or text?(binding["model"])) and
             is_boolean(binding["questions_enabled"]) and
             (not binding["questions_enabled"] or binding["backend"] == "claude") and
             valid_permissions?(binding) and valid_repository?(binding),
      do: raise("Invalid command admission binding")

    if request["command"] == "start" do
      unless is_nil(binding["source_turn_id"]) and is_nil(binding["session_id"]) and
               binding["questions_enabled"] == request["questions_enabled"] and
               binding["sandbox"] == request["sandbox"] and
               (request["permissions"] == "dedicated-repository") == is_map(binding["permissions"]) and
               Map.has_key?(request, "repository") == is_map(binding["repository"]),
        do: raise("Start binding does not match its request")
      if Map.has_key?(request, "branch") and request["branch"] != binding["repository"]["branch"],
        do: raise("Repository branch does not match its request")
    else
      unless turn_id?(binding["source_turn_id"]) and binding["source_turn_id"] != record["turn_id"] and
               text?(binding["session_id"]), do: raise("Invalid continuation binding")
    end

    for key <- ~w(worker_id backend cwd), Map.has_key?(request, key) do
      unless request[key] == binding[key], do: raise("Command binding does not match #{key}")
    end
    if Map.has_key?(request, "turn_id") and request["turn_id"] != binding["source_turn_id"],
      do: raise("Command binding does not match source turn")
  end

  defp valid_permissions?(%{"permissions" => nil, "sandbox" => sandbox}),
    do: sandbox in ["read-only", "workspace-write"]
  defp valid_permissions?(%{"permissions" => scope, "sandbox" => nil, "cwd" => cwd}) when is_map(scope) do
    scope == %{"profile" => "dedicated-repository", "version" => 1, "root" => cwd,
      "git_dir" => Path.join(cwd, ".git"), "network_hosts" => ["github.com", "api.github.com"]}
  end
  defp valid_permissions?(_), do: false

  defp valid_repository?(%{"repository" => nil}), do: true
  defp valid_repository?(%{"repository" => repository, "permissions" => scope, "session_id" => session})
       when is_map(repository) and is_map(scope) do
    sha = ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    # Fresh starts carry Code's resolved commit; admissions saved before Code carry only branch and url.
    valid_revision =
      case {is_nil(session), Enum.sort(Map.keys(repository))} do
        {true, ~w(branch url)} -> true
        {true, ~w(branch resolved_commit url)} -> matches?(repository["resolved_commit"], sha)
        {false, ~w(base_sha branch url)} -> matches?(repository["base_sha"], sha)
        _ -> false
      end
    valid_revision and text?(repository["url"]) and text?(repository["branch"])
  end
  defp valid_repository?(_), do: false

  defp validate_result!(record) do
    run = record["recorded_result"]
    binding = record["binding"]
    unless is_map(run) and run["id"] == record["turn_id"] and
             run["request_id"] == record["request_id"] and run["state"] == "running" and
             run["assignment"] == record["request"]["assignment"] and
             run["requested_model"] == binding["model"] and
             Enum.all?(~w(worker_id cwd sandbox permissions repository backend session_id questions_enabled),
               &(run[&1] == binding[&1])),
      do: raise("Recorded result does not match command admission")
  end

  defp accepted(record, run) do
    run = run |> JSON.encode!() |> JSON.decode!()
    record = Map.merge(record, %{"admission" => "accepted", "recorded_result" => run})
    validate_record!(record)
    bounded!(record, @record_bytes, "Command admission")
    record
  end

  defp persist(dir, record) do
    validate_record!(record)
    encoded = bounded!(record, @record_bytes, "Command admission")
    directory!(dir)
    File.mkdir_p!(Path.join(dir, "admissions"))
    directory!(dir)
    path = Path.join(dir, record["record_ref"])
    File.write!(path <> ".tmp", encoded, [:exclusive])
    File.rename!(path <> ".tmp", path)
    record
  end

  defp directory!(dir) do
    path = Path.join(dir, "admissions")
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> raise("Command admissions path is not an owned directory")
      {:error, reason} -> raise File.Error, reason: reason, action: "read admissions directory", path: path
    end
  end

  defp reference(id), do: Path.join("admissions", id <> ".json")
  defp validate_id!(id) do
    unless request_id?(id), do: raise(ArgumentError, "Request ID must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")
  end
  defp request_id?(id), do: matches?(id, ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/)
  defp worker_id?(id), do: matches?(id, ~r/\A[a-z][a-z0-9_-]{0,63}\z/)
  defp turn_id?(id), do: matches?(id, ~r/\Aturn-[0-9a-f]{16}\z/)
  defp matches?(value, regex), do: is_binary(value) and String.valid?(value) and Regex.match?(regex, value)
  defp text?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
  defp path?(value), do: text?(value) and not String.contains?(value, <<0>>)
  defp absolute_path?(value), do: path?(value) and Path.type(value) == :absolute and Path.expand(value) == value
  defp optional!(request, key, valid?) do
    if Map.has_key?(request, key) and not valid?.(request[key]), do: raise(ArgumentError, "Invalid #{key}")
  end
  defp bounded!(value, limit, label) do
    encoded = JSON.encode!(value)
    if byte_size(encoded) > limit, do: raise(ArgumentError, "#{label} exceeds #{limit} bytes")
    encoded
  end
  defp storage(fun) do
    fun.()
  rescue
    error in StorageError -> reraise error, __STACKTRACE__
    error -> raise StorageError, message: "Command admission storage failed: #{Exception.message(error)}"
  end
end
