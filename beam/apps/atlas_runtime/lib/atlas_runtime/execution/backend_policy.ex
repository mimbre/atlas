defmodule AtlasRuntime.BackendPolicy do
  @moduledoc "Local Claude preference and confirmed weekly-quota fallback for new assignments."
  @empty %{"preferred" => nil, "fallback" => nil, "claude_quota" => nil}

  def empty, do: @empty

  def load(dir) do
    case File.read(Path.join(dir, "backends.json")) do
      {:ok, bytes} -> validate!(JSON.decode!(bytes))
      {:error, :enoent} -> empty()
      {:error, reason} -> raise("Cannot read backend policy: #{inspect(reason)}")
    end
  end

  def persist(dir, policy) do
    path = Path.join(dir, "backends.json")
    File.write!(path <> ".tmp", JSON.encode!(policy))
    File.rename!(path <> ".tmp", path)
  end

  def validate!(policy) when is_map(policy) do
    if Map.keys(policy) -- Map.keys(@empty) != [], do: raise("Unknown backend policy fields")
    policy = Map.merge(@empty, policy)

    case {policy["preferred"], policy["fallback"]} do
      {nil, nil} -> :ok
      {preferred, fallback} -> pair!(preferred, fallback)
    end

    case policy["claude_quota"] do
      nil ->
        :ok

      %{"evidence" => evidence, "turn_id" => id, "observed_at" => at, "reenabled_at" => enabled}
      when is_binary(id) and is_integer(at) and (is_nil(enabled) or is_integer(enabled)) ->
        if not weekly_quota?(evidence), do: raise("Invalid persisted weekly-quota evidence")

      _ ->
        raise("Invalid persisted quota record")
    end

    policy
  end

  def validate!(_), do: raise("Backend policy must be an object")

  def configure(policy, preferred, fallback) do
    pair!(preferred, fallback)
    %{policy | "preferred" => preferred, "fallback" => fallback}
  end

  defp pair!(preferred, fallback) do
    target!(preferred)
    target!(fallback)

    if preferred["backend"] != "claude" or fallback["backend"] != "codex",
      do: raise("Supported preference pair is claude then codex")
  end

  defp target!(%{"backend" => backend, "model" => model} = target) do
    if Map.keys(target) -- ["backend", "model"] != [] or backend not in ["claude", "codex"] or
         not (is_nil(model) or
                (is_binary(model) and
                   Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/, model))),
       do: raise("Backend target requires codex or claude and a valid optional model identifier")
  end

  defp target!(_), do: raise("Backend target requires backend and model fields")

  def weekly_quota?(%{"status" => "rejected", "rateLimitType" => "seven_day"} = info),
    do: info["isUsingOverage"] != true and info["overageStatus"] != "allowed"

  def weekly_quota?(_), do: false

  def record_quota(policy, evidence, turn_id, now) do
    if weekly_quota?(evidence) do
      reset = evidence["resetsAt"]

      evidence =
        Map.put(evidence, "resetsAt", if(is_number(reset) and reset > 0, do: reset, else: nil))

      %{
        policy
        | "claude_quota" => %{
            "evidence" => evidence,
            "turn_id" => turn_id,
            "observed_at" => now,
            "reenabled_at" => nil
          }
      }
    else
      policy
    end
  end

  def reenable(policy, "claude", now) do
    case policy["claude_quota"] do
      nil -> policy
      quota -> %{policy | "claude_quota" => Map.put(quota, "reenabled_at", now)}
    end
  end

  def reenable(_, _, _), do: raise("Only Claude has weekly-quota eligibility")

  def eligible?(policy, now) do
    case policy["claude_quota"] do
      nil -> true
      %{"reenabled_at" => enabled} when is_integer(enabled) -> true
      %{"evidence" => %{"resetsAt" => reset}} when is_number(reset) and reset > 0 -> reset <= now
      _ -> false
    end
  end

  def view(policy, now), do: Map.put(policy, "claude_eligible", eligible?(policy, now))

  def select(policy, explicit, request, now) do
    {requested, selected, reason} =
      cond do
        not is_nil(explicit) ->
          if explicit not in ["codex", "claude"], do: raise("Backend must be codex or claude")

          target =
            Enum.find(
              [policy["preferred"], policy["fallback"]],
              &(&1 && &1["backend"] == explicit)
            ) ||
              %{"backend" => explicit, "model" => nil}

          {target, target, "explicit"}

        is_nil(policy["preferred"]) ->
          target = %{"backend" => "codex", "model" => nil}
          {target, target, "default"}

        eligible?(policy, now) ->
          {policy["preferred"], policy["preferred"], "preferred"}

        true ->
          {policy["preferred"], policy["fallback"], "confirmed_weekly_quota"}
      end

    capable!(selected["backend"], request)
    selection = %{"requested" => requested, "selected" => selected, "reason" => reason}

    selection =
      if reason == "confirmed_weekly_quota",
        do: Map.put(selection, "quota", policy["claude_quota"]),
        else: selection

    selection
  end

  defp capable!(backend, request) do
    permissions = request["permissions"]
    sandbox = Map.get(request, "sandbox", "read-only")

    supported =
      case backend do
        "claude" ->
          (is_nil(permissions) and sandbox == "read-only" and
             not Map.has_key?(request, "repository")) or
            (permissions == "dedicated-repository" and not Map.has_key?(request, "sandbox")) or
            (permissions == "materialized-folder" and not Map.has_key?(request, "sandbox") and
               not Map.has_key?(request, "repository"))

        "codex" ->
          (is_nil(permissions) and sandbox in ["read-only", "workspace-write"] and
             not Map.has_key?(request, "repository")) or
            (permissions == "dedicated-repository" and not Map.has_key?(request, "sandbox")) or
            (permissions == "materialized-folder" and not Map.has_key?(request, "sandbox") and
               not Map.has_key?(request, "repository"))
      end

    if not supported,
      do:
        raise(
          "Selected #{backend} backend cannot meet the requested permissions or provisioning capabilities"
        )
  end
end
