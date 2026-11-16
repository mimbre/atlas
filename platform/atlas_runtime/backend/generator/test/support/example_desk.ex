defmodule AtlasRuntimeBackend.Generator.Example.Desk do
  @moduledoc """
  A second neutral example boundary contract, as plain data: the library's front desk,
  which staff open and close and visitors ask for a seat at. It shares outcome names with
  the lending example (`missing`, `refused`), with statuses of its own.
  """

  @schema %{
    version: "1.0.0",
    file: "example_desk.ex",
    models: [
      # Who is calling, and the rights a client can hold: what a backend's rights name.
      %{
        name: :client,
        fields: [
          %{name: :id, type: :string, required: true},
          %{name: :rights, type: {:list, {:enum, [:staff, :visit]}}, required: true}
        ]
      },
      %{
        name: :desk,
        fields: [
          %{name: :open, type: :boolean, required: true},
          %{name: :seats, type: :integer, required: true}
        ]
      },
      %{name: :close_input, fields: [%{name: :hard, type: :boolean, required: false}]},
      %{name: :find_seat_input, fields: [%{name: :seat, type: :string, required: true}]},
      %{name: :seat, fields: [%{name: :seat, type: :string, required: true}]},
      %{
        name: :refused,
        fields: [
          %{name: :reason, type: {:enum, [:occupied, :invalid]}, required: true},
          %{name: :detail, type: :string, required: false}
        ]
      }
    ],
    capabilities: [
      %{name: :open_desk, input: nil, right: :staff, outcomes: [%{name: :opened, model: :desk}]},
      %{
        name: :close_desk,
        input: :close_input,
        right: :staff,
        outcomes: [%{name: :closing, model: :desk}]
      },
      %{
        name: :find_seat,
        input: :find_seat_input,
        right: :visit,
        outcomes: [
          %{name: :seated, model: :seat},
          %{name: :missing, model: nil},
          %{name: :refused, model: :refused}
        ]
      }
    ]
  }

  def __schema__, do: @schema
end

defmodule AtlasRuntimeBackend.Generator.Example.DeskApi do
  @moduledoc "A neutral backend contract over `AtlasRuntimeBackend.Generator.Example.Desk`."
  use AtlasRuntimeBackend.Generator.Schema

  version "1.0.0"
  boundary AtlasRuntimeBackend.Generator.Example.Desk

  expose [:open_desk, :close_desk, :find_seat]

  rights :socket, [:staff, :visit]
  rights :guest, [:visit]

  target :rest do
    resource :post, "/v1/desk/open", capability: :open_desk
    resource :post, "/v1/desk/close", capability: :close_desk, body: [:hard]
    resource :get, "/v1/seats/:seat", capability: :find_seat

    status :opened, 200
    status :closing, 202
    status :seated, 200
    status :missing, 404, type: "not-found"
    status :refused, by: :reason, cases: [occupied: {409, "occupied"}, invalid: {400, "invalid"}]

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
    # A listener's refusals, sent with the router's __problem__/2.
    error :unauthenticated, 401, type: "unauthenticated"
    error :origin_refused, 403, type: "origin-refused"
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.DeskFacade do
  @moduledoc """
  The desk's facade, by hand, like the lending one: refusals (`Denied`, `Rejected`) for a
  client without the right or an input it does not accept, and `{:desk_called, capability,
  client, input}` to the calling process.
  """
  alias AtlasRuntimeBackend.Generator.Example.Struct, as: S
  alias __MODULE__.Outcome

  defmodule Desk, do: use(S, open: {:boolean, true}, seats: {:integer, true})
  defmodule CloseInput, do: use(S, hard: {:boolean, false})
  defmodule FindSeatInput, do: use(S, seat: {:string, true})

  defmodule Outcome do
    @moduledoc false
    defmodule Opened, do: use(S, open: {:boolean, true}, seats: {:integer, true})
    defmodule Closing, do: use(S, open: {:boolean, true}, seats: {:integer, true})
    defmodule Seated, do: use(S, seat: {:string, true})
    defmodule Missing, do: use(S, [])

    defmodule Refused,
      do: use(S, reason: {{:enum, [:occupied, :invalid]}, true}, detail: {:string, false})
  end

  defmodule Denied do
    @moduledoc false
    defstruct [:capability, :right]
  end

  defmodule Rejected do
    @moduledoc false
    defstruct [:capability, :reasons]
  end

  def open_desk(client),
    do:
      permitted(client, :open_desk, :staff, nil, fn -> %Outcome.Opened{open: true, seats: 4} end)

  def close_desk(client, input) do
    permitted(client, :close_desk, :staff, input, fn ->
      %Outcome.Closing{open: input.hard != true, seats: 4}
    end)
  end

  def find_seat(client, input) do
    permitted(client, :find_seat, :visit, input, fn ->
      case input.seat do
        "none" -> %Outcome.Missing{}
        "taken" -> %Outcome.Refused{reason: :occupied, detail: "someone sits there"}
        "odd" -> %Outcome.Refused{reason: :invalid}
        "unchecked" -> %Rejected{capability: :find_seat, reasons: ["seat is not checked"]}
        seat -> %Outcome.Seated{seat: seat}
      end
    end)
  end

  defp permitted({_id, rights} = client, capability, right, input, answer) do
    send(self(), {:desk_called, capability, client, input})

    if right in rights,
      do: answer.(),
      else: %Denied{capability: capability, right: right}
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.Combined do
  @moduledoc "One router for both example contracts: lending (with the stream) and the desk."
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contracts: [
      lending:
        {AtlasRuntimeBackend.Generator.Example.Api,
         facade: AtlasRuntimeBackend.Generator.Example.Facade,
         stream: AtlasRuntimeBackend.Generator.Example.Loop},
      desk:
        {AtlasRuntimeBackend.Generator.Example.DeskApi,
         facade: AtlasRuntimeBackend.Generator.Example.DeskFacade}
    ]
end

defmodule AtlasRuntimeBackend.Generator.Example.Things do
  @moduledoc """
  A tiny neutral boundary, as plain data, for the tests that compile routers from contracts
  written on the spot: things looked at by id, the latest thing, a thing's parts, and a
  watch. Its facades are `ThingsA` and `ThingsB` (the same facade, twice, so two contracts
  can each have their own).
  """

  @schema %{
    version: "1.0.0",
    file: "example_desk.ex",
    models: [
      # Who is calling, and the rights a client can hold: what a backend's rights name.
      %{
        name: :client,
        fields: [
          %{name: :id, type: :string, required: true},
          %{name: :rights, type: {:list, {:enum, [:look]}}, required: true}
        ]
      },
      %{name: :thing, fields: [%{name: :thing_id, type: :string, required: true}]},
      %{name: :thing_input, fields: [%{name: :thing_id, type: :string, required: true}]},
      %{name: :watch_input, fields: [%{name: :from, type: :integer, required: false}]}
    ],
    capabilities: [
      %{
        name: :get_thing,
        input: :thing_input,
        right: :look,
        outcomes: [%{name: :shown, model: :thing}]
      },
      %{
        name: :latest_thing,
        input: nil,
        right: :look,
        outcomes: [%{name: :shown, model: :thing}]
      },
      %{
        name: :thing_parts,
        input: :thing_input,
        right: :look,
        outcomes: [%{name: :shown, model: :thing}]
      },
      %{
        name: :watch_things,
        input: :watch_input,
        right: :look,
        outcomes: [%{name: :watching, model: nil}]
      }
    ]
  }

  def __schema__, do: @schema
end

defmodule AtlasRuntimeBackend.Generator.Example.ThingsFacade do
  @moduledoc false
  # `use` it to get a facade of `Example.Things`.
  defmacro __using__(_opts) do
    quote do
      alias AtlasRuntimeBackend.Generator.Example.Struct, as: S

      defmodule Thing, do: use(S, thing_id: {:string, true})
      defmodule ThingInput, do: use(S, thing_id: {:string, true})
      defmodule WatchInput, do: use(S, from: {:integer, false})

      defmodule Outcome do
        @moduledoc false
        defmodule Shown, do: use(S, thing_id: {:string, true})
        defmodule Watching, do: use(S, [])
      end

      def get_thing(_client, input), do: %__MODULE__.Outcome.Shown{thing_id: input.thing_id}
      def latest_thing(_client), do: %__MODULE__.Outcome.Shown{thing_id: "latest"}
      def thing_parts(_client, input), do: %__MODULE__.Outcome.Shown{thing_id: input.thing_id}
      def watch_things(_client, _input), do: %__MODULE__.Outcome.Watching{}
    end
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.ThingsA do
  @moduledoc false
  use AtlasRuntimeBackend.Generator.Example.ThingsFacade
end

defmodule AtlasRuntimeBackend.Generator.Example.ThingsB do
  @moduledoc false
  use AtlasRuntimeBackend.Generator.Example.ThingsFacade
end
