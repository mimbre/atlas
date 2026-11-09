defmodule AtlasFacts.PresentationReadTest do
  @moduledoc """
  A read that asks for it answers each fact the work is written on with its
  presentation, derived from the runs of the subject the work is on. Neutral nouns: work
  on a parcel is written on its label, owned through `held_by`; `sorting` runs it.
  """
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.Rela

  defmodule Description do
    @moduledoc false
    @slots ~w(flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason)

    def of do
      string = %{"type" => "string"}

      cursor =
        Map.new(@slots, fn slot ->
          {slot,
           if(slot in ~w(entry generation input_cursor), do: %{"type" => "integer"}, else: string)}
        end)

      %{
        "entities" => %{
          "parcel" => %{"plural" => "parcels", "properties" => %{"phase" => string}},
          "label" => %{
            "plural" => "labels",
            "properties" => %{"step" => string, "todo" => string, "later" => string}
          },
          "clerk" => %{"plural" => "clerks", "properties" => %{}},
          "cursor" => %{"plural" => "cursors", "properties" => cursor},
          "choice" => %{"plural" => "choices", "properties" => %{"run" => string}}
        },
        "relations" => %{
          "label" => %{"from" => ["parcel"], "to" => ["label"], "max_outgoing" => 1},
          "held_by" => %{"from" => ["label"], "to" => ["clerk"], "max_outgoing" => 1}
        },
        "flows" => %{},
        "flow_runtime" => %{
          "version" => 1,
          "kind" => "cursor",
          "fields" => Map.new(@slots, &{&1, &1}),
          "writer" => %{"sender" => "flow", "by" => "flow"},
          "selection" => %{
            "sorting" => %{
              "subject" => "parcel",
              "choices" => [],
              "choice_states" => [],
              "admission" => %{"phase" => ["first"]},
              "reopen" => "explicit",
              "projection" => %{
                "on" => "label",
                "state_field" => "step",
                "handover_field" => "later",
                "owner_relation" => "held_by",
                "field" => "todo"
              }
            }
          },
          "inputs" => %{
            "kind" => "choice",
            "fields" => %{"run" => "run"},
            "acl" => %{},
            "roles" => %{}
          }
        }
      }
    end
  end

  defmodule Parcels do
    @moduledoc "Parcels whose work is written on their labels, and the runs that present it."
    use AtlasFacts.TestModel, description: AtlasFacts.PresentationReadTest.Description.of()
  end

  defmodule Backend do
    def description(_), do: {:ok, AtlasFacts.PresentationReadTest.Parcels.rela_schema()}
    defdelegate get(pid, plural, key), to: AtlasFacts.FakeRela
    defdelegate list(pid, plural), to: AtlasFacts.FakeRela
    defdelegate create(pid, plural, key, values, links), to: AtlasFacts.FakeRela
    defdelegate change(pid, plural, key, values, version, links), to: AtlasFacts.FakeRela
    defdelegate incoming(pid, plural, key, relation), to: AtlasFacts.FakeRela
    defdelegate delete(pid, plural, key, version), to: AtlasFacts.FakeRela
    def check_create(_, _, _, _, _), do: {:ok, []}
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "presentation-#{System.unique_integer([:positive])}")
    pid = AtlasFacts.FakeRela.start()
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    rela = {Backend, pid}

    {:ok, _} = Rela.create(rela, "clerks", "ada", %{}, %{})

    {:ok, _} =
      Rela.create(rela, "labels", "L-1", %{"step" => "weigh", "todo" => "Weigh it"}, %{
        "held_by" => {"clerk", ["ada"]}
      })

    {:ok, _} =
      Rela.create(rela, "parcels", "P-1", %{"phase" => "first"}, %{"label" => {"label", ["L-1"]}})

    run(rela, "active", "weigh")

    # Every read lists afresh: the test writes to rela directly.
    start_supervised!(
      {AtlasFacts.Server, rela: rela, data_dir: dir, model: Parcels, collection_freshness_ms: 0}
    )

    :ok = AtlasBus.attach("presentation-reader-#{System.unique_integer([:positive])}")
    %{rela: rela}
  end

  defp run(rela, status, state) do
    values = %{
      "flow" => "sorting",
      "subject_kind" => "parcel",
      "subject_key" => "P-1",
      "generation" => 1,
      "status" => status,
      "state" => state
    }

    case Rela.get(rela, "cursors", "R-1") do
      {:ok, fact} -> Rela.change(rela, "cursors", "R-1", values, fact.version, %{})
      _ -> Rela.create(rela, "cursors", "R-1", values, %{})
    end
  end

  defp read(kind, content) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer}, 1_000
    answer
  end

  test "a fact the work is written on carries its presentation when a read asks for it", ctx do
    assert %{"fact" => %{"presentation" => shown}} =
             read("label", %{"key" => "L-1", "plain" => true, "presentation" => true})

    assert %{
             "subject" => %{"kind" => "parcel", "key" => "P-1"},
             "flow" => "sorting",
             "run" => "R-1",
             "state" => "weigh",
             "actionable" => true,
             "expected" => "Weigh it",
             "owner" => ["ada"],
             "handover" => nil
           } = shown

    # Unasked, a read is as it was; so is a fact of a kind no work is written on.
    refute Map.has_key?(read("label", %{"key" => "L-1", "plain" => true})["fact"], "presentation")

    refute Map.has_key?(
             read("parcel", %{"key" => "P-1", "presentation" => true})["fact"],
             "presentation"
           )

    # A list read presents each fact; once the run ends, nothing is to be done there,
    # though the label still says what it said.
    run(ctx.rela, "completed", "done")

    assert %{
             "facts" => [
               %{"key" => "L-1", "values" => %{"step" => "weigh"}, "presentation" => ended}
             ]
           } =
             read("label", %{
               "linked" => %{"held_by" => "ada"},
               "plain" => true,
               "presentation" => true
             })

    assert %{
             "status" => "completed",
             "actionable" => false,
             "expected" => nil,
             "reopened" => true
           } = ended
  end
end
