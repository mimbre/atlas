defmodule AtlasRuntimeBackend.Generator.Example.Struct do
  @moduledoc """
  The example facade's structs, written by hand: what the router needs of a facade's
  struct (`new/1` from decoded JSON, strict; `dump/1` to JSON-ready data). Fields are
  `name: {type, required}`; a type is `:string`, `:integer`, `:boolean`, `:datetime`,
  `{:enum, [atom]}`, `{:model, module}`, `{:list, type}` or `{:one_of, [{name, module}], tag}`.
  """

  defmacro __using__(fields) do
    quote do
      defstruct unquote(Enum.map(fields, &elem(&1, 0)))

      def __fields__,
        do: for({name, {type, required}} <- unquote(fields), do: {name, type, required})

      def new(params), do: AtlasRuntimeBackend.Generator.Example.Struct.new(__MODULE__, params)
      def dump(value), do: AtlasRuntimeBackend.Generator.Example.Struct.dump(value)
    end
  end

  def new(module, params) when is_map(params) and not is_struct(params) do
    fields = module.__fields__()
    names = Map.new(fields, fn {name, _, _} -> {Atom.to_string(name), name} end)

    unknown =
      for {key, _} <- params,
          not Map.has_key?(names, to_string(key)),
          do: "no field #{inspect(key)}"

    {values, errors} =
      Enum.map_reduce(fields, unknown, fn {name, type, required}, errors ->
        value = Map.get(params, Atom.to_string(name), Map.get(params, name))

        case {value, required} do
          {nil, true} ->
            {{name, nil}, errors ++ ["#{name} is required"]}

          {nil, false} ->
            {{name, nil}, errors}

          {value, _} ->
            case cast(type, value) do
              {:ok, value} -> {{name, value}, errors}
              :error -> {{name, nil}, errors ++ ["#{name} is invalid: #{inspect(value)}"]}
            end
        end
      end)

    if errors == [], do: {:ok, struct(module, values)}, else: {:error, errors}
  end

  def new(_module, params), do: {:error, ["not a map: #{inspect(params)}"]}

  def dump(%module{} = value) do
    for {name, type, _} <- module.__fields__(),
        (item = Map.fetch!(value, name)) != nil,
        into: %{},
        do: {Atom.to_string(name), dump(type, item)}
  end

  defp dump(:datetime, value), do: DateTime.to_iso8601(value)
  defp dump({:enum, _}, value), do: Atom.to_string(value)
  defp dump({:model, _}, value), do: dump(value)
  defp dump({:list, inner}, values), do: Enum.map(values, &dump(inner, &1))

  defp dump({:one_of, members, tag}, %module{} = value) do
    {name, _} = List.keyfind(members, module, 1)
    Map.put(dump(value), Atom.to_string(tag), name)
  end

  defp dump(_type, value), do: value

  defp cast(:string, v) when is_binary(v), do: {:ok, v}
  defp cast(:integer, v) when is_integer(v), do: {:ok, v}
  defp cast(:boolean, v) when is_boolean(v), do: {:ok, v}

  defp cast(:datetime, v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp cast({:enum, values}, v) when is_binary(v) do
    case Enum.find(values, &(Atom.to_string(&1) == v)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp cast({:model, module}, v) when is_map(v) do
    case module.new(v) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  defp cast({:list, inner}, v) when is_list(v) do
    Enum.reduce_while(v, {:ok, []}, fn item, {:ok, acc} ->
      case cast(inner, item) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp cast({:one_of, members, tag}, v) when is_map(v) do
    case List.keyfind(members, Map.get(v, Atom.to_string(tag)), 0) do
      {_name, module} -> cast({:model, module}, Map.delete(v, Atom.to_string(tag)))
      nil -> :error
    end
  end

  defp cast(_type, _v), do: :error
end

defmodule AtlasRuntimeBackend.Generator.Example.Types do
  @moduledoc false
  # Field types of the example facade's structs that name other structs.
  @facade AtlasRuntimeBackend.Generator.Example.Facade
  def condition, do: {:enum, [:new, :worn, :"badly-worn"]}

  def place,
    do:
      {:one_of,
       [{"shelf", Module.concat(@facade, Shelf)}, {"branch", Module.concat(@facade, Branch)}],
       :kind}

  def book, do: {:model, Module.concat(@facade, Book)}
  def counts, do: {:model, Module.concat(@facade, Counts)}
end

defmodule AtlasRuntimeBackend.Generator.Example.Facade do
  @moduledoc """
  A neutral example facade for `AtlasRuntimeBackend.Generator.Example.Boundary`, written by
  hand with the module names a boundary facade has (`Facade.<Model>`,
  `Facade.Outcome.<Outcome>`). It refuses a client without the right, or an input it does
  not accept, with a refusal (`Denied`, `Rejected`) rather than an outcome, and tells the
  calling process what it was called with (`{:example_called, capability, client, input}`).
  """
  alias AtlasRuntimeBackend.Generator.Example.Struct, as: S
  alias AtlasRuntimeBackend.Generator.Example.Types, as: T
  alias __MODULE__.{Book, Shelf, Branch, Counts, BookChanged, Tick}
  alias __MODULE__.Outcome

  defmodule Shelf, do: use(S, row: {:integer, true})
  defmodule Branch, do: use(S, city: {:string, true})

  defmodule Book,
    do:
      use(S,
        book_id: {:string, true},
        title: {:string, true},
        edition: {:integer, true},
        condition: {T.condition(), true},
        place: {T.place(), false},
        due_at: {:datetime, false}
      )

  defmodule LendInput,
    do:
      use(S,
        request_key: {:string, false},
        title: {:string, true},
        place: {T.place(), false},
        until: {:datetime, false}
      )

  defmodule FindBookInput, do: use(S, book_id: {:string, true})
  defmodule SearchInput, do: use(S, title: {:string, true})

  defmodule ListBooksInput,
    do:
      use(S, condition: {T.condition(), false}, limit: {:integer, false}, lent: {:boolean, false})

  defmodule GiveBackInput,
    do: use(S, book_id: {:string, true}, note: {:string, false}, hurry: {:boolean, false})

  defmodule WatchInput, do: use(S, from: {:integer, false})
  defmodule AuditInput, do: use(S, [])
  defmodule Counts, do: use(S, total: {:integer, true}, wait: {:integer, false})
  defmodule BookChanged, do: use(S, sequence: {:integer, true}, book_id: {:string, true})
  defmodule Restart, do: use(S, current_sequence: {:integer, true})
  defmodule Tick, do: use(S, at: {:datetime, true})

  defmodule Outcome do
    @moduledoc false
    defmodule Lent, do: use(S, book: {T.book(), true})
    defmodule Found, do: use(S, book: {T.book(), true})
    defmodule Returned, do: use(S, book: {T.book(), true})
    defmodule Missing, do: use(S, [])
    defmodule Listed, do: use(S, books: {{:list, T.book()}, true})
    defmodule Busy, do: use(S, retry_after: {:integer, true}, counts: {T.counts(), true})

    defmodule Refused,
      do:
        use(S,
          reason: {{:enum, [:invalid, :taken, :not_permitted]}, true},
          detail: {:string, false}
        )

    defmodule Counted, do: use(S, total: {:integer, true}, wait: {:integer, false})
    defmodule Watching, do: use(S, [])
    defmodule Restart, do: use(S, current_sequence: {:integer, true})
    defmodule Audited, do: use(S, [])
  end

  defmodule Denied do
    @moduledoc "What the facade returns, instead of an outcome, to a client without the right."
    defstruct [:capability, :right]
  end

  defmodule Rejected do
    @moduledoc "What the facade returns, instead of an outcome, for an input it does not accept."
    defstruct [:capability, :reasons]
  end

  @rights %{
    lend: :lend,
    find_book: :browse,
    search: :browse,
    list_books: :browse,
    give_back: :lend,
    count: :browse,
    watch: :browse,
    audit: :audit
  }

  def lend(client, input) do
    permitted(client, :lend, input, fn ->
      case input.title do
        "busy" ->
          %Outcome.Busy{retry_after: 30, counts: %Counts{total: 3}}

        "taken" ->
          %Outcome.Refused{reason: :taken, detail: "already lent"}

        "odd" ->
          %Outcome.Refused{reason: :invalid}

        "not yours" ->
          %Outcome.Refused{reason: :not_permitted}

        "undeclared" ->
          :undeclared

        "unchecked" ->
          %Rejected{capability: :lend, reasons: ["title is not checked"]}

        title ->
          %Outcome.Lent{book: book(input.request_key || "b1", title, input.place, input.until)}
      end
    end)
  end

  # "reprinted" is in its second edition; every other book in its first.
  def find_book(client, input) do
    permitted(client, :find_book, input, fn ->
      case input.book_id do
        "missing" ->
          %Outcome.Missing{}

        id ->
          book = book(id, "Dune", %Shelf{row: 3}, nil)
          %Outcome.Found{book: %{book | edition: if(id == "reprinted", do: 2, else: 1)}}
      end
    end)
  end

  def search(client, input) do
    permitted(client, :search, input, fn ->
      if input.title == "missing",
        do: %Outcome.Missing{},
        else: %Outcome.Found{book: book("b2", input.title, %Branch{city: "Delft"}, nil)}
    end)
  end

  def list_books(client, input) do
    permitted(client, :list_books, input, fn ->
      %Outcome.Listed{books: List.duplicate(book("b3", "Emma", nil, nil), input.limit || 1)}
    end)
  end

  def give_back(client, input) do
    permitted(client, :give_back, input, fn ->
      if input.book_id == "missing",
        do: %Outcome.Missing{},
        else: %Outcome.Returned{book: book(input.book_id, "Dune", nil, nil)}
    end)
  end

  def count(client) do
    permitted(client, :count, nil, fn -> %Outcome.Counted{total: 2, wait: 5} end)
  end

  # Within the window (from 5 on): watching, and the missed events are on their way.
  def watch(client, input) do
    permitted(client, :watch, input, fn ->
      case input.from do
        from when is_integer(from) and from < 5 ->
          %Outcome.Restart{current_sequence: 9}

        from ->
          send(self(), {:notification, %BookChanged{sequence: (from || 8) + 1, book_id: "b1"}})
          send(self(), {:notification, %Tick{at: ~U[2026-03-01 10:00:00Z]}})
          send(self(), {:notification, :not_an_event})
          %Outcome.Watching{}
      end
    end)
  end

  def audit(client, input), do: permitted(client, :audit, input, fn -> %Outcome.Audited{} end)

  defp permitted({_id, rights} = client, capability, input, answer) do
    send(self(), {:example_called, capability, client, input})
    right = Map.fetch!(@rights, capability)

    if right in rights,
      do: answer.(),
      else: %Denied{capability: capability, right: right}
  end

  defp book(id, title, place, due_at),
    do: %Book{
      book_id: id,
      title: title,
      edition: 1,
      condition: :new,
      place: place,
      due_at: due_at
    }
end
