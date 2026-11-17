defmodule AtlasRuntime.Policy do
  @moduledoc """
  The human-owned model policy, `policy.json` in the Runtime home, and its mechanical
  resolution of an execution profile to one concrete option (design §7).

  A human edits the file locally and raises `version` on every change; nothing in the
  Runtime writes it. It is read again for every resolution, so a change applies to every
  attempt that has not started. A missing or invalid file permits nothing.

  `load/1` returns `{:ok, policy}` or `{:error, reason}`; every other function takes that
  result as it is. Quota evidence is not policy: it lives in `AtlasRuntime.Availability`.
  """

  @file_name "policy.json"
  @permissions ~w(dedicated-repository materialized-folder workspace-write read-only review-packet)
  @cost_classes ~w(low standard high)
  @harnesses ~w(claude codex)
  # What each harness can serve; an option that cannot serve the request's permission is
  # skipped, never weakened (the former `BackendPolicy` capability check).
  @capabilities %{
    "claude" => ~w(dedicated-repository materialized-folder read-only review-packet),
    "codex" => @permissions
  }
  @default_slots ["default"]
  # Design §4; a profile's `limits.max_duration` overrides its default.
  @max_duration %{"deep_coding" => 14_400, "independent_review" => 3_600, "light_work" => 1_800}
  @default_max_duration 14_400
  @cancel_grace 30
  @retry_after 60
  # After-check (design §3.10, §4; s5a-plan B17): allowed unless a profile says
  # `allow_after_check: false`; `timeout` 120 s by default, capped by `limits.max_check_timeout`.
  @max_check_timeout 600
  @check_timeout 120
  @model ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]{0,199}\z/
  @provider ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @profile ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @type loaded :: {:ok, map()} | {:error, :missing | {:invalid, String.t()}}
  @type option :: %{String.t() => String.t()}
  @type request :: %{
          required(:profile) => String.t(),
          required(:cost_class) => String.t() | atom(),
          required(:permission) => String.t() | atom(),
          optional(:resume) => option() | nil
        }
  @type selection :: %{String.t() => term()}
  @type resolution ::
          {:ok, selection()}
          | {:refused, :policy_forbids | :no_permitted_option | :resume_unavailable, String.t()}
          | {:at_capacity, :profile_unavailable, %{until: DateTime.t() | nil, skipped: [map()]}}

  def path(dir), do: Path.join(dir, @file_name)

  @doc "Reads and strictly validates `policy.json`."
  @spec load(Path.t()) :: loaded()
  def load(dir) do
    case File.read(path(dir)) do
      {:ok, bytes} ->
        with {:ok, policy} <- decode(bytes), :ok <- validate(policy), do: {:ok, policy}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:invalid, "cannot read #{@file_name}: #{:file.format_error(reason)}"}}
    end
  end

  @doc "The policy version recorded in provenance; nil without a valid policy."
  def version({:ok, policy}), do: policy["version"]
  def version(_), do: nil

  @doc "The human-owned slot names (F1); `[\"default\"]` when the policy names none."
  @spec slots(loaded()) :: [String.t()]
  def slots({:ok, %{"slots" => slots}}), do: slots
  def slots(_), do: @default_slots

  @doc "Accepted work that may wait for a slot; by default one per slot (design §2)."
  @spec buffer_size(loaded()) :: non_neg_integer()
  def buffer_size({:ok, %{"buffer_size" => size}}), do: size
  def buffer_size(loaded), do: length(slots(loaded))

  @doc "Time limits in seconds for a profile (design §4)."
  @spec limits(loaded(), String.t()) :: %{
          max_duration: pos_integer(),
          cancel_grace: pos_integer(),
          retry_after: pos_integer()
        }
  def limits(loaded, profile) do
    configured =
      case loaded do
        {:ok, %{"profiles" => %{^profile => %{"limits" => %{"max_duration" => seconds}}}}} ->
          seconds

        _ ->
          Map.get(@max_duration, profile, @default_max_duration)
      end

    %{max_duration: configured, cancel_grace: @cancel_grace, retry_after: @retry_after}
  end

  @doc """
  A profile's after-check rules (design §3.10; s5a-plan B17): `allowed` (`allow_after_check`,
  default true), `max_timeout` (`limits.max_check_timeout`, default 600 s) and
  `default_timeout` (120 s, or `max_timeout` when that is lower). An unknown profile or no
  valid policy gives the defaults; its request is refused by `resolve/5` anyway.
  """
  @spec after_check(loaded(), String.t()) :: %{
          allowed: boolean(),
          max_timeout: pos_integer(),
          default_timeout: pos_integer()
        }
  def after_check(loaded, profile) do
    settings =
      case loaded do
        {:ok, %{"profiles" => %{^profile => %{} = settings}}} -> settings
        _ -> %{}
      end

    max = get_in(settings, ["limits", "max_check_timeout"]) || @max_check_timeout

    %{
      allowed: Map.get(settings, "allow_after_check", true),
      max_timeout: max,
      default_timeout: min(@check_timeout, max)
    }
  end

  @doc "Whether a harness can serve a workspace permission at all."
  def capable?(harness, permission), do: permission in Map.get(@capabilities, harness, [])

  @doc """
  The configured model of a harness when every policy option for it names the same model,
  otherwise nil (the harness's native default). Only for starts that name a backend
  explicitly instead of a profile (in-BEAM callers of the Service; runtime.sock serves no
  start).
  """
  def configured_model({:ok, policy}, harness) do
    models =
      for {_, profile} <- policy["profiles"],
          option <- profile["options"],
          option["harness"] == harness,
          uniq: true,
          do: option["model"]

    case models do
      [model] -> model
      _ -> nil
    end
  end

  def configured_model(_, _), do: nil

  @doc """
  Resolves a request to one option (design §7 steps 1–5, without the S4 independence step).

  `availability` comes from `AtlasRuntime.Availability.load/1`; `installed` is a list of
  installed harness names or a predicate; `now` is Unix seconds.
  """
  @spec resolve(loaded(), map(), request(), [String.t()] | (String.t() -> boolean()), integer()) ::
          resolution()
  def resolve({:error, :missing}, _availability, _request, _installed, _now),
    do: {:refused, :policy_forbids, "no #{@file_name} in the Runtime home"}

  def resolve({:error, {:invalid, why}}, _availability, _request, _installed, _now),
    do: {:refused, :policy_forbids, "invalid #{@file_name}: #{why}"}

  def resolve({:ok, policy}, availability, request, installed, now) do
    name = to_string(request.profile)
    permission = to_string(request.permission)
    cost_class = to_string(request.cost_class)
    profile = policy["profiles"][name]

    cond do
      is_nil(profile) ->
        {:refused, :policy_forbids, "unknown profile #{inspect(name)}"}

      permission not in profile["permissions"] ->
        {:refused, :policy_forbids,
         "profile #{name} does not permit #{inspect(permission)} workspaces"}

      cost_class not in profile["cost_classes"] ->
        {:refused, :policy_forbids,
         "profile #{name} does not permit cost class #{inspect(cost_class)}"}

      resume = Map.get(request, :resume) ->
        resume = Map.take(resume, ["provider", "harness", "model"])

        if resume in profile["options"],
          do: {:ok, selection(policy, name, resume, "continuation", [])},
          else:
            {:refused, :resume_unavailable,
             "the source turn's option is no longer listed for profile #{name}"}

      true ->
        walk(policy, name, profile["options"], availability, permission, installed, now)
    end
  end

  @doc """
  Per-profile availability for `capacity` (design §3.4): steps 3–5 for every profile,
  without a request's permission or cost class and without the independence step.
  """
  @spec profiles(loaded(), map(), [String.t()] | (String.t() -> boolean()), integer()) ::
          %{String.t() => %{available: boolean(), reason: atom(), until: DateTime.t() | nil}}
  def profiles({:ok, policy}, availability, installed, now) do
    Map.new(policy["profiles"], fn {name, profile} ->
      skipped = Enum.map(profile["options"], &skip(&1, availability, nil, installed, now))

      status =
        cond do
          Enum.any?(skipped, &is_nil/1) ->
            %{available: true}

          Enum.any?(skipped, &(&1.why == "quota")) ->
            %{available: false, reason: :quota, until: earliest(skipped)}

          Enum.all?(skipped, &(&1.why == "not_installed")) ->
            %{available: false, reason: :not_installed}

          true ->
            %{available: false, reason: :no_permitted_option}
        end

      {name, status}
    end)
  end

  def profiles(_, _availability, _installed, _now), do: %{}

  @doc """
  The declared policy view (operations `policy`, design §13.1 Q7): the operations
  contract's `policy` fields and nothing else, never the file and never the quota
  evidence. Profiles are sorted by name; each option keeps its order and carries its
  availability now (`not_installed` before `quota`, as in a resolution). `limits` shows
  the `max_duration` that applies, configured or default.

  Without a valid policy nothing is permitted: `version` is 0, there are no profiles and
  the buffer is the default one. A `changed_at` that is not ISO-8601 is left out.
  Arguments as for `profiles/4`.
  """
  @spec view(loaded(), map(), [String.t()] | (String.t() -> boolean()), integer()) :: map()
  def view({:ok, policy} = loaded, availability, installed, now) do
    view = %{
      version: policy["version"],
      buffer_size: buffer_size(loaded),
      profiles:
        for {name, profile} <- Enum.sort(policy["profiles"]) do
          %{
            profile: name,
            permissions: profile["permissions"],
            cost_classes: profile["cost_classes"],
            limits: %{max_duration: limits(loaded, name).max_duration},
            options: Enum.map(profile["options"], &option_view(&1, availability, installed, now))
          }
        end
    }

    view
    |> put_present(:changed_by, policy["changed_by"])
    |> put_present(:changed_at, datetime(policy["changed_at"]))
    |> put_present(:independence, independence_view(policy["independence"]))
  end

  def view(loaded, _availability, _installed, _now),
    do: %{version: 0, buffer_size: buffer_size(loaded), profiles: []}

  defp option_view(option, availability, installed, now) do
    harness = option["harness"]

    availability =
      if installed?(installed, harness) do
        case AtlasRuntime.Availability.status(availability, harness, now) do
          :available -> %{available: true}
          {:out, nil} -> %{available: false, reason: :quota}
          {:out, until} -> %{available: false, reason: :quota, until: DateTime.from_unix!(until)}
        end
      else
        %{available: false, reason: :not_installed}
      end

    %{
      provider: option["provider"],
      harness: harness,
      model: option["model"],
      availability: availability
    }
  end

  defp independence_view(%{"different_from" => strength}), do: %{different_from: strength}
  defp independence_view(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  defp walk(policy, name, options, availability, permission, installed, now) do
    {picked, skipped} =
      Enum.reduce_while(options, {nil, []}, fn option, {nil, skipped} ->
        case skip(option, availability, permission, installed, now) do
          nil -> {:halt, {option, skipped}}
          why -> {:cont, {nil, skipped ++ [Map.put(why, :option, option)]}}
        end
      end)

    public = Enum.map(skipped, &skipped_entry/1)

    cond do
      picked ->
        reason = if picked == hd(options), do: "preferred", else: "fallback"
        {:ok, selection(policy, name, picked, reason, public)}

      # Quota is the only temporary cause in S1: it returns, so the client waits.
      Enum.any?(skipped, &(&1.why == "quota")) ->
        {:at_capacity, :profile_unavailable, %{until: earliest(skipped), skipped: public}}

      true ->
        {:refused, :no_permitted_option,
         "no option of profile #{name} can run: " <>
           Enum.map_join(skipped, ", ", &"#{&1.option["harness"]} #{&1.why}")}
    end
  end

  # Why an option cannot be used now, or nil when it can. Order matters only for the reason
  # recorded: a permanent cause is reported before quota.
  defp skip(option, availability, permission, installed, now) do
    harness = option["harness"]

    cond do
      permission && not capable?(harness, permission) ->
        %{why: "unsupported_permission"}

      not installed?(installed, harness) ->
        %{why: "not_installed"}

      true ->
        case AtlasRuntime.Availability.status(availability, harness, now) do
          :available -> nil
          {:out, until} -> %{why: "quota", until: until}
        end
    end
  end

  defp installed?(installed, harness) when is_function(installed, 1),
    do: installed.(harness) == true

  defp installed?(installed, harness) when is_list(installed), do: harness in installed

  defp earliest(skipped) do
    skipped
    |> Enum.flat_map(fn
      %{why: "quota", until: until} when is_integer(until) -> [until]
      _ -> []
    end)
    |> case do
      [] -> nil
      untils -> DateTime.from_unix!(Enum.min(untils))
    end
  end

  defp skipped_entry(%{option: option, why: why} = skip) do
    entry = %{"option" => option, "why" => why}

    case skip do
      %{until: until} when is_integer(until) ->
        Map.put(entry, "until", DateTime.to_iso8601(DateTime.from_unix!(until)))

      _ ->
        entry
    end
  end

  # The persisted selection (string keys, as stored in turn.json). `requested` and
  # `selected` keep the shape every existing reader of a turn's selection uses.
  defp selection(policy, profile, option, reason, skipped) do
    target = %{"backend" => option["harness"], "model" => option["model"]}

    %{
      "profile" => profile,
      "policy_version" => policy["version"],
      "option" => option,
      "reason" => reason,
      "skipped" => skipped,
      "requested" => target,
      "selected" => target
    }
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:ok, _} -> {:error, {:invalid, "#{@file_name} must hold an object"}}
      {:error, _} -> {:error, {:invalid, "#{@file_name} is not valid JSON"}}
    end
  end

  @top ~w(version changed_by changed_at buffer_size slots independence profiles)
  @profile_keys ~w(permissions cost_classes options limits allow_after_check)
  @limit_keys ~w(max_duration max_check_timeout)

  defp validate(policy) do
    checks = [
      {Map.keys(policy) -- @top == [], "unknown fields #{inspect(Map.keys(policy) -- @top)}"},
      {positive?(policy["version"]), "version must be a positive integer"},
      {optional(policy, "changed_by", &text?/1), "changed_by must be a string"},
      {optional(policy, "changed_at", &text?/1), "changed_at must be a string"},
      {optional(policy, "buffer_size", &(is_integer(&1) and &1 >= 0)),
       "buffer_size must be a non-negative integer"},
      {optional(policy, "slots", &slots?/1),
       "slots must be a non-empty list of distinct worker names"},
      {optional(policy, "independence", &independence?/1),
       "independence.different_from must be conversation, model or provider"},
      {is_map(policy["profiles"]), "profiles must be an object"}
    ]

    with :ok <- first_failure(checks) do
      Enum.reduce_while(policy["profiles"], :ok, fn {name, profile}, :ok ->
        case profile(name, profile) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp profile(name, profile) do
    first_failure(
      [
        {is_binary(name) and Regex.match?(@profile, name), "invalid profile name"},
        {is_map(profile) and Map.keys(profile) -- @profile_keys == [], "unknown fields"},
        {subset?(profile["permissions"], @permissions),
         "permissions must be a non-empty list of #{Enum.join(@permissions, ", ")}"},
        {subset?(profile["cost_classes"], @cost_classes),
         "cost_classes must be a non-empty list of #{Enum.join(@cost_classes, ", ")}"},
        {options?(profile["options"]),
         "options must be a non-empty list of distinct {provider, harness, model}"},
        {optional(profile, "allow_after_check", &is_boolean/1),
         "allow_after_check must be a boolean"},
        {optional(profile, "limits", &limits?/1),
         "limits may hold only positive integers max_duration and max_check_timeout"}
      ],
      "profile #{inspect(name)}: "
    )
  end

  defp first_failure(checks, prefix \\ "") do
    case Enum.find(checks, fn {ok, _} -> not ok end) do
      nil -> :ok
      {_, why} -> {:error, {:invalid, prefix <> why}}
    end
  end

  defp optional(map, key, check), do: not Map.has_key?(map, key) or check.(map[key])
  defp positive?(value), do: is_integer(value) and value > 0
  defp text?(value), do: is_binary(value) and value != ""

  defp subset?(values, allowed),
    do:
      is_list(values) and values != [] and Enum.uniq(values) == values and
        Enum.all?(values, &(&1 in allowed))

  defp slots?(slots),
    do:
      is_list(slots) and slots != [] and Enum.uniq(slots) == slots and
        Enum.all?(slots, &AtlasRuntime.Execution.Identity.valid_worker_id?/1)

  defp independence?(%{"different_from" => strength} = value),
    do: map_size(value) == 1 and strength in ~w(conversation model provider)

  defp independence?(_), do: false

  defp options?(options),
    do:
      is_list(options) and options != [] and Enum.uniq(options) == options and
        Enum.all?(options, &option?/1)

  defp option?(%{"provider" => provider, "harness" => harness, "model" => model} = option),
    do:
      map_size(option) == 3 and is_binary(provider) and Regex.match?(@provider, provider) and
        harness in @harnesses and is_binary(model) and Regex.match?(@model, model)

  defp option?(_), do: false

  defp limits?(limits) when is_map(limits) and map_size(limits) > 0,
    do: Map.keys(limits) -- @limit_keys == [] and Enum.all?(Map.values(limits), &positive?/1)

  defp limits?(_), do: false
end
