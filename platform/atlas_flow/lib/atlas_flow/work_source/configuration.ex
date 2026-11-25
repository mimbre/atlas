defmodule AtlasFlow.WorkSource.Configuration do
  @moduledoc """
  A Runtime's configuration, as its supervisor sets it through Control (IS-Atlas-27): the
  whole `policy.json` document (JSON text) in the `configuration` field of the Runtime's
  machinery fact, the fact whose key is the Runtime's id (its credential's, as for
  `ran_on`, Q7). The work source serves it in a poll answer (`polled.configuration`,
  `work_source` 0.4.0); the Runtime checks it as its own policy, writes it and applies it,
  or refuses it.

  On each poll of a Runtime, `poll/2` (run by `AtlasFlow.Delivery`, the process that
  writes Flow's records on the Runtime's behalf):

  1. records on the machinery fact what the poll says: `applied_version`, the
     `policy_version` the Runtime runs under; `runtime_build` and `runtime_incarnation`,
     the build and incarnation it polled from, so Control shows it linked (IS-Atlas-116);
     and, when the poll carries
     `configuration_refused`, `refused_version` and `refused_reason`. A field is written
     only when it changes; a refused write (the fact changed meanwhile) is left to the
     next poll;
  2. answers `{:serve, document}` while the document's `version` is not the Runtime's
     `policy_version` and not the version it refused; otherwise `:none`.

  A document that is not a JSON object with a positive integer `version` is never served:
  Flow records it refused itself (`refused_version` 0), so Control shows why. Every other
  check is the Runtime's own, where the policy rules are.

  No machinery fact under the Runtime's id, no configuration on it, or a Facts that does
  not answer: `:none`, and the poll is answered as before. A poll is never refused or held
  up for the configuration.

  Who may set the field is Control's and Facts' rule for the fact (anyone who may change
  a machinery fact; IS-Atlas-27 leaves "only its supervisor" open).
  """

  require Logger

  alias AtlasFlow.Talk
  alias AtlasFlow.WorkSource.Translate

  # The kind and fields (Model.Machinery), named here as Leases names the task's.
  @machinery "machinery"
  @document "configuration"
  @applied "applied_version"
  @refused "refused_version"
  @reason "refused_reason"
  @build "runtime_build"
  @incarnation "runtime_incarnation"
  @unreadable "the configuration is not a JSON object with a positive integer version"

  @doc "The kind the configuration is kept on."
  def kind, do: @machinery

  @doc """
  One poll of Runtime `runtime_id` (`input` the poll's input, atom or string keys):
  records what it says, then `{:serve, document}` or `:none`. `by` is the writer.
  """
  @spec poll(String.t(), map(), String.t()) :: {:serve, String.t()} | :none
  def poll(runtime_id, input, by \\ "flow") when is_binary(runtime_id) do
    input = Translate.normal(input)

    case read(runtime_id) do
      {:ok, %{"values" => values} = fact} ->
        document = values[@document]
        wanted = wanted(document)
        recorded = recorded(input, wanted)
        record(fact, recorded, by)
        serve(document, wanted, input["policy_version"], Map.merge(values, recorded))

      _none_or_unreadable ->
        :none
    end
  end

  # The document's version, `:unreadable`, or nil when there is none.
  defp wanted(document) when is_binary(document) and document != "" do
    case JSON.decode(document) do
      {:ok, %{"version" => version}} when is_integer(version) and version > 0 -> version
      _ -> :unreadable
    end
  end

  defp wanted(_none), do: nil

  # What the poll says, as the fields it sets.
  defp recorded(input, wanted) do
    applied =
      case input["policy_version"] do
        version when is_integer(version) and version >= 0 -> %{@applied => version}
        _ -> %{}
      end

    refused =
      case {input["configuration_refused"], wanted} do
        {%{"version" => version, "reason" => reason}, _}
        when is_integer(version) and is_binary(reason) ->
          %{@refused => version, @reason => String.slice(reason, 0, 2_000)}

        {_, :unreadable} ->
          %{@refused => 0, @reason => @unreadable}

        _ ->
          %{}
      end

    linked =
      for {field, value} <- [{@build, input["build"]}, {@incarnation, input["incarnation"]}],
          is_binary(value) and value != "",
          into: %{},
          do: {field, String.slice(value, 0, 200)}

    applied |> Map.merge(refused) |> Map.merge(linked)
  end

  defp serve(document, version, policy_version, values) when is_integer(version) do
    if version != policy_version and version != values[@refused],
      do: {:serve, document},
      else: :none
  end

  defp serve(_document, _unreadable_or_none, _policy_version, _values), do: :none

  defp record(fact, recorded, by) do
    values = fact["values"]
    changed = Map.filter(recorded, fn {field, value} -> values[field] != value end)

    if changed != %{} do
      content = %{
        "op" => "change",
        "key" => fact["key"],
        "values" => changed,
        "version" => fact["version"],
        "was" => Map.new(Map.keys(changed), &{&1, values[&1]}),
        "by" => by
      }

      case Talk.put(@machinery, content, digest([fact["key"], fact["version"], changed])) do
        {:stored, _position} ->
          :ok

        other ->
          Logger.warning(
            "flow work source: configuration of #{fact["key"]} not recorded: #{inspect(other)}"
          )
      end
    end
  end

  defp read(key) do
    case Talk.read(@machinery, %{"key" => key, "plain" => true}) do
      %{"fact" => %{"values" => values} = fact} when is_map(values) -> {:ok, fact}
      %{"fact" => nil} -> :none
      other -> {:error, other}
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
