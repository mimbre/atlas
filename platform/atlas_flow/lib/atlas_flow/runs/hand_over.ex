defmodule AtlasFlow.Runs.HandOver do
  @moduledoc """
  The To-Do a hand-over gives the holder it is handed to (work acquisition decision
  2026-11-17, decision 4; M3 S3): nothing runs until the holder picks it up
  themselves. A checked hand-over (`AtlasFlow.Runs.Inputs.supervision/4`) clears the
  run's supervisor and keeps `pending.hand_over`; this module builds the writes that
  give the chosen holder their To-Do, which join the run's pending writes and are sent
  under their stable ids once the run holding them is stored (`AtlasFlow.Runs.Store`).

  Flow names no kind here. What it writes is configured (`config :atlas_flow,
  :hand_over`) and checked against the model's relations when the runs are activated
  (`resolve/3`):

    * `kind`, `id_prefix`, `digits`: the To-Do's kind and its manual ids (`<prefix><n>`,
      `n` at least `digits` long);
    * `assignment`: the component relation from the To-Do to the part that names who it
      is assigned to (made with the To-Do, key from the relation's own template);
    * `assigned_to`: that part's relation to the holder;
    * `title`, `instructions` (`{subject}`: the handed-over subject's key, `{from}`: the
      supervisor who handed it over) and `values`, the rest of the create.

  Two writes, in order: the To-Do's create (by Flow), then the link from its part to
  the holder. The link is written by the supervisor who handed the run over, whose
  checked act it is: Facts keeps that as an assignment made by hand, so the To-Do's own
  run keeps it and does not move it to its subflow's default owner
  (`AtlasFlow.Runs.Presentation.manual?/2`). Flow never closes the To-Do.
  """

  @doc """
  The hand-over configuration `config` (a keyword list or map, as configured), checked
  against `relations` (`AtlasFlow.Model` `relations/0`) for `holders` (the kinds a
  supervisor is a fact of): a map the other functions take, or nil when it is not
  configured or the model has no part for it to write (no component relation from the
  kind, or a part whose relation cannot name every holder kind).
  """
  def resolve(nil, _relations, _holders), do: nil

  def resolve(config, relations, holders) when is_list(config) or is_map(config) do
    c = Map.new(config, fn {k, v} -> {to_string(k), v} end)
    part = relations[to_string(c["assignment"])] || %{}
    owner = relations[to_string(c["assigned_to"])] || %{}

    with kind when is_binary(kind) and kind != "" <- c["kind"],
         prefix when is_binary(prefix) and prefix != "" <- c["id_prefix"],
         %{"key" => template} when is_binary(template) <- part["component"],
         true <- kind in (part["from"] || []),
         [part_kind] <- part["to"],
         true <- part_kind in (owner["from"] || []),
         true <- holders != [] and Enum.all?(holders, &(&1 in (owner["to"] || []))),
         true <- is_binary(c["title"]) and is_binary(c["instructions"]) do
      %{
        "kind" => kind,
        "prefix" => prefix,
        "digits" => c["digits"] || 1,
        "values" => Map.new(c["values"] || %{}, fn {k, v} -> {to_string(k), v} end),
        "title" => c["title"],
        "instructions" => c["instructions"],
        "part" => %{"kind" => part_kind, "key" => template},
        "owner_relation" => to_string(c["assigned_to"])
      }
    else
      _ -> nil
    end
  end

  def resolve(_config, _relations, _holders), do: nil

  @doc "The To-Do's key for `number`: the prefix and the number, at least `digits` long."
  def key(spec, number),
    do: spec["prefix"] <> String.pad_leading(Integer.to_string(number), spec["digits"], "0")

  @doc "The first number after every one of `keys` (the To-Dos there are) that is a To-Do id."
  def next_number(spec, keys) do
    pattern = ~r/\A#{Regex.escape(spec["prefix"])}([0-9]+)\z/

    keys
    |> Enum.flat_map(fn key ->
      case is_binary(key) && Regex.run(pattern, key) do
        [_, n] -> [String.to_integer(n)]
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  @doc """
  The writes that give the holder `hand_over["to"]` the To-Do for `run`'s hand-over by
  `from`, numbered `number`: the To-Do's create, then the link from its part to the
  holder. Each has a stable id, a digest of the run, the input, `"hand_over"` and the
  To-Do's key, so a resend is stored once; each is marked (`"hand_over"`) with the input
  and the number, so a taken number can be replaced (`renumber/5`).
  """
  def writes(spec, run, %{"to" => to, "input" => input}, from, number) do
    key = key(spec, number)
    part = String.replace(spec["part"]["key"], "{key}", key)
    mark = %{"input" => input, "number" => number, "from" => from, "to" => to}

    text =
      &(&1 |> String.replace("{subject}", run["subject_key"]) |> String.replace("{from}", from))

    values =
      Map.merge(spec["values"], %{
        "title" => text.(spec["title"]),
        "instructions" => text.(spec["instructions"])
      })

    [
      %{
        "id" => AtlasBus.Digest.of_term([run["key"], input, "hand_over", key]),
        "kind" => spec["kind"],
        "hand_over" => Map.put(mark, "write", "create"),
        "content" => %{"op" => "create", "key" => key, "values" => values, "by" => "flow"}
      },
      %{
        "id" =>
          AtlasBus.Digest.of_term([run["key"], input, "hand_over", key, spec["owner_relation"]]),
        "kind" => spec["part"]["kind"],
        "hand_over" => Map.put(mark, "write", "owner"),
        "content" => %{
          "op" => "change",
          "key" => part,
          "values" => %{},
          "links" => %{spec["owner_relation"] => [to]},
          "by" => from
        }
      }
    ]
  end

  @doc "Whether `write` is the create of a hand-over's To-Do."
  def create?(write), do: match?(%{"hand_over" => %{"write" => "create"}}, write)

  @doc """
  `writes` with the hand-over To-Do of `input` numbered `number` instead: both of its
  writes are rebuilt, in their place, under the ids of the new key.
  """
  def renumber(spec, run, writes, input, number) do
    case Enum.find(writes, &(create?(&1) and &1["hand_over"]["input"] == input)) do
      nil ->
        writes

      %{"hand_over" => mark} ->
        [create, owner] =
          writes(spec, run, %{"to" => mark["to"], "input" => input}, mark["from"], number)

        Enum.map(writes, fn
          %{"hand_over" => %{"input" => ^input, "write" => "create"}} -> create
          %{"hand_over" => %{"input" => ^input, "write" => "owner"}} -> owner
          other -> other
        end)
    end
  end

  @doc """
  What a refused create of a To-Do met at its key (`fact`, as Facts holds it, or nil):
  `:ours` when it is the To-Do this create makes (its answer was lost), `:taken` when
  another fact holds the key, `:unknown` when there is none (the refusal was for
  something else, or the key is held back: the create is sent again later).
  """
  def met(_write, nil), do: :unknown

  def met(%{"content" => %{"values" => values}}, %{} = fact) do
    if Enum.all?(values, fn {f, v} -> (fact["values"] || %{})[f] == v end),
      do: :ours,
      else: :taken
  end

  @doc "Whether `writes` hold the To-Do of the hand-over of `input`."
  def holds?(writes, input),
    do: Enum.any?(writes, &(create?(&1) and &1["hand_over"]["input"] == input))
end
