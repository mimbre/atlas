defmodule AtlasFacts.Model do
  @moduledoc """
  The model Facts stores facts for: a module the domain compiles, wired by configuration
  at boot:

      config :atlas, model: SomeModel

  Facts reads it once when it starts; a missing module, or one without these callbacks,
  refuses the start, and so does a rela that serves another schema than `rela_schema/0`.
  Facts names no model and no kind: every write rule, everything worked out on a read
  and every connector is the model's. What a kind is (its fields, its relations) Facts
  reads from rela; `_description` answers rela's schema, as rela serves it.

  Besides its own callbacks, Facts calls two that the component that runs turns
  declares, for the records it keeps: the turn and the durable guidance records
  (`turn/0` and `guidance/0`). A model implements them once.

  A `change` is `%{"op" => "create" | "change" | "delete", "key", "values", "links" =>
  %{relation => [key]}, "by"}`; an `actor` is `%{"by", "sender"}`: who the write says it
  is by, and the endpoint that sent it. `lookup` is Facts' reader, so the model calls no
  service:

    * `"current"`: `fn -> nil | %{"values", "links"} end`, the fact as stored before the
      write;
    * `"fact"`: `fn kind, key -> nil | fact end`;
    * `"list"`: `fn kind -> {:ok, [fact]} | {:error, reason} end`;
    * `"incoming"`: `fn kind, key, relation -> [key] end`, the facts that point at one;
    * `"fingerprint"`: `fn fact, spec -> digest end` (`AtlasBus.SubjectFingerprint`);
    * for `derived/3` only, what it reads, asked as precisely as its rules read it, so
      a read says what it depended on: `"linked"`, `fn kind, relation, keys -> {:ok,
      [fact]} | {:error, reason} end` (the facts of `kind` that point at one of `keys`
      through `relation`), and `"facts"`, `fn kind, keys -> {:ok, [fact]} | {:error,
      reason} end` (those of `kind` with one of `keys`);
    * `"now"`: the time lateness is worked out at (optional).

  A `fact` there is as rela gives it: `%{key, properties, links}`.
  """

  @type change :: map
  @type lookup :: map

  @doc "The schema rela must serve (`entities`, `relations`, `types`, as rela serves them)."
  @callback rela_schema() :: map

  @doc "Whether `change` of a fact of `kind` may be stored: `:ok` or `{:refuse, reasons}`."
  @callback check(kind :: String.t(), change, actor :: map, lookup) ::
              :ok | {:refuse, [String.t()]}

  @doc """
  The changes the write makes, in order, each with `"as"`: `"component"` (a fact made
  before it, or deleted after it, with the `relation` that links them), `"fact"` (the
  change itself) and `"replaced"` (a fact it replaces, and what is set on it after it is
  stored). Each has `"kind"`, `"op"`, `"key"` and `"values"`.
  """
  @callback with_change(kind :: String.t(), change, lookup) :: [map]

  @doc """
  What is worked out for each of `facts` on a read, in order: `%{"progress", "completion",
  "review", "late", "until"}` with only what applies (`until`: the first instant a value
  of it changes by time alone, ISO 8601); or the error a read of `lookup` gave. Without
  `"linked"` in `lookup`, only what needs no other fact.
  """
  @callback derived(kind :: String.t(), facts :: [map], lookup) ::
              {:ok, [map]} | {:error, term}

  @doc """
  The run mapping, for the records Facts keeps of runs and their inputs, or nil: `kind`
  (where runs are kept) and its `fields`, the `writer` (`%{"by", "sender"}`) that alone
  writes them, `inputs` (where a run's inputs are kept: `kind`, `fields`, `roles`,
  `acl`) and per selected subflow its `selection` (`subject`, `choices`,
  `choice_states`).
  """
  @callback run_mapping() :: nil | map

  @doc """
  The outside system the facts of `kind` are copied from, or nil: `%{"system",
  "address", "fields", "until", "names"}` (`names`: `%{"field", "relation", "when",
  "kind", "prefix"}`).
  """
  @callback connector(kind :: String.t()) :: nil | map

  # The callbacks of other components Facts calls too.
  @shared [turn: 0, guidance: 0]

  @doc "The model Facts is wired to, checked: raises when it is missing or wrong."
  def configured!, do: check!(Application.fetch_env!(:atlas, :model))

  @doc "`model` when it implements this behaviour and the shared callbacks; raises otherwise."
  def check!(model) do
    unless is_atom(model) and Code.ensure_loaded?(model),
      do: raise(ArgumentError, "the model #{inspect(model)} is not a module Facts can load")

    missing =
      for {name, arity} <- __MODULE__.behaviour_info(:callbacks) ++ @shared,
          not function_exported?(model, name, arity),
          do: "#{name}/#{arity}"

    if missing != [],
      do: raise(ArgumentError, "the model #{inspect(model)} lacks #{Enum.join(missing, ", ")}")

    model
  end

  @doc """
  Why rela's schema (`served`, what `GET /_schema` answers) is not the model's, or nil.
  Only `entities`, `relations` and `types` count; the first few differences are named.
  """
  def mismatch(model, served) do
    case differences(model.rela_schema(), served) do
      [] ->
        nil

      found ->
        shown = Enum.take(found, 5)
        more = if length(found) > 5, do: " (and #{length(found) - 5} more)", else: ""

        "rela serves another schema than this build's model #{inspect(model)}: " <>
          Enum.join(shown, "; ") <> more <> ". Deploy rela and the core from the same build."
    end
  end

  defp differences(expected, served) when is_map(served),
    do: diff(expected, Map.take(served, ["entities", "relations", "types"]), [])

  defp differences(_expected, _served), do: ["rela served no schema"]

  defp diff(a, b, path) when is_map(a) and is_map(b) do
    for k <- Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b))),
        d <-
          (cond do
             not Map.has_key?(b, k) -> [at(path, k) <> " is not served"]
             not Map.has_key?(a, k) -> [at(path, k) <> " is served, but not built"]
             true -> diff(a[k], b[k], path ++ [k])
           end),
        do: d
  end

  defp diff(a, a, _path), do: []
  defp diff(a, b, path), do: ["#{Enum.join(path, ".")} is #{inspect(b)}, built #{inspect(a)}"]

  defp at(path, k), do: Enum.join(path ++ [k], ".")
end
