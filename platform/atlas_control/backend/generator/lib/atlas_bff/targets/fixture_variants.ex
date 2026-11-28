defmodule AtlasBFF.Targets.FixtureVariants do
  @moduledoc """
  Bounded structural samples plus lazy combinations of each entry's optional fields.
  Every mask is available without writing the exponential cross-product to JSON.
  Nested models are independent; callers compose their specimens as needed.
  """

  @lengths [:short, :normal, :long]

  def entries(entries, models) do
    for entry <- entries do
      %{
        "name" => to_string(entry.name),
        "optional" => for(field <- entry.fields, not field.required, do: to_string(field.name)),
        "variants" => variants(entry.fields, models)
      }
    end
  end

  @doc "Lazily enumerate every local optional-field presence mask in a generated entry."
  def combinations(entry) do
    optional = Map.fetch!(entry, "optional")
    count = Bitwise.bsl(1, length(optional))

    Stream.map(0..(count - 1), fn mask ->
      present =
        optional
        |> Enum.with_index()
        |> Enum.filter(fn {_name, index} -> Bitwise.band(mask, Bitwise.bsl(1, index)) != 0 end)
        |> Enum.map(&elem(&1, 0))

      combine(entry, present)
    end)
  end

  @doc "Construct one presence mask with optional per-field generated value-case overrides."
  def combine(entry, present, overrides \\ %{}) do
    optional = Map.fetch!(entry, "optional")
    if present -- optional != [], do: raise(ArgumentError, "unknown optional fixture fields")
    variants = Map.new(entry["variants"], &{&1["case"], &1})
    required = Map.fetch!(variants, "required")
    full = Map.fetch!(variants, "full")

    props = fn variant ->
      if variant["sample"], do: variant["sample"]["props"], else: variant["props"]
    end

    values = Map.merge(props.(required), Map.take(props.(full), present))

    values =
      Enum.reduce(overrides, values, fn {field, case_name}, current ->
        unless Map.has_key?(current, field),
          do: raise(ArgumentError, "override for absent field #{field}")

        example = Map.fetch!(variants, "value:#{field}:#{case_name}")
        Map.put(current, field, Map.fetch!(props.(example), field))
      end)

    if full["sample"] do
      put_in(full, ["sample", "props"], values)
    else
      Map.put(full, "props", values)
    end
    |> Map.put("case", "combination:" <> Enum.join(present, ","))
  end

  defp variants(fields, models) do
    required = object(fields, models, :required, [])
    full = object(fields, models, :full, [])

    optional = Enum.reject(fields, & &1.required)

    presence =
      Enum.flat_map(optional, fn field ->
        name = to_string(field.name)

        [
          %{
            "case" => "only:" <> name,
            "props" => Map.put(required, name, value(field, models, :normal, []))
          },
          %{"case" => "without:" <> name, "props" => Map.delete(full, name)}
        ]
      end)

    values =
      Enum.flat_map(fields, fn field ->
        for variant <- value_cases(field) do
          %{
            "case" => "value:#{field.name}:#{variant}",
            "props" => Map.put(full, to_string(field.name), value(field, models, variant, []))
          }
        end
      end)

    [%{"case" => "required", "props" => required}, %{"case" => "full", "props" => full}] ++
      presence ++ values
  end

  defp value_cases(%{type: :string, name: :syntax}), do: [:plain, :markdown]

  defp value_cases(%{type: :string, intent: intent}) when intent in [:label, :title, :body],
    do: @lengths

  defp value_cases(%{type: {:list, :string}, intent: intent})
       when intent in [:label, :title, :body],
       do: [:empty, :one, :many] ++ @lengths

  defp value_cases(%{type: {:list, _}}), do: [:empty, :one, :many]
  defp value_cases(%{type: {:map, _}}), do: [:empty, :one, :many]
  defp value_cases(%{type: :list}), do: [:empty, :one, :many]
  defp value_cases(%{type: :map}), do: [:empty, :one, :many]
  defp value_cases(%{type: :boolean}), do: [false, true]
  defp value_cases(%{type: :integer}), do: [:zero, :one]
  defp value_cases(_), do: []

  defp object(fields, models, which, stack) do
    fields
    |> Enum.filter(&(&1.required or which == :full))
    |> Map.new(fn field -> {to_string(field.name), value(field, models, :normal, stack)} end)
    |> syntax(fields)
  end

  defp syntax(object, fields) do
    if Map.has_key?(object, "syntax") and
         Enum.any?(
           fields,
           &(&1[:syntax] == :markdown and Map.has_key?(object, to_string(&1.name)))
         ) do
      Map.put(object, "syntax", "markdown")
    else
      object
    end
  end

  defp value(%{type: :string, name: :syntax}, _models, :plain, _stack), do: "plain"
  defp value(%{type: :string, name: :syntax}, _models, _size, _stack), do: "markdown"

  defp value(%{type: :string} = field, _models, size, _stack) do
    if field[:syntax] == :markdown do
      case size do
        :short ->
          "**Hi**"

        :long ->
          "# An example heading\n\nA longer paragraph with **emphasis**, `code`, and a [link](https://example.invalid).\n\n- First item\n- Second item\n\n> A quoted passage."

        _ ->
          "A **readable example** with `code`."
      end
    else
      case {field[:intent], size} do
        {_, :short} ->
          "Hi"

        {:label, :long} ->
          "A descriptive label that can wrap on a narrow screen"

        {:title, :long} ->
          "A longer example title that shows how a client handles wrapping"

        {:body, :long} ->
          "A longer example paragraph with enough content to exercise wrapping.\n\nA second paragraph keeps the example readable when the viewport is narrow."

        {:label, _} ->
          "Example label"

        {:title, _} ->
          "Example title"

        {:body, _} ->
          "This is an example of readable content."

        _ ->
          "example"
      end
    end
  end

  defp value(%{type: :integer}, _, :zero, _), do: 0
  defp value(%{type: :integer}, _, _, _), do: 1
  defp value(%{type: :boolean}, _, false, _), do: false
  defp value(%{type: :boolean}, _, _, _), do: true
  defp value(%{type: :list}, _, :empty, _), do: []
  defp value(%{type: :list}, _, :many, _), do: ["first", "second", "third"]
  defp value(%{type: :list}, _, _, _), do: ["example"]
  defp value(%{type: :map}, _, :empty, _), do: %{}

  defp value(%{type: :map}, _, :many, _),
    do: %{"first" => "one", "second" => "two", "third" => "three"}

  defp value(%{type: :map}, _, _, _), do: %{"key" => "example"}

  defp value(%{type: {:list, inner}} = field, models, size, stack) do
    element = Map.put(field, :type, inner)

    case size do
      :empty -> []
      :many -> for _ <- 1..3, do: value(element, models, :normal, stack)
      _ -> [value(element, models, size, stack)]
    end
  end

  defp value(%{type: {:map, inner}} = field, models, size, stack) do
    element = Map.put(field, :type, inner)

    case size do
      :empty -> %{}
      :many -> Map.new(1..3, &{"key#{&1}", value(element, models, :normal, stack)})
      _ -> %{"key" => value(element, models, :normal, stack)}
    end
  end

  defp value(%{type: type}, models, _size, stack) when is_map_key(models, type) do
    if type in stack, do: raise(ArgumentError, "recursive required fixture model #{type}")
    object(Map.fetch!(models, type), models, :required, [type | stack])
  end
end
