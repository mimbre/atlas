defmodule AtlasFacts.RelationRulesTest do
  @moduledoc """
  The rules of a relation the model gives, which Facts enforces for every writer (Control
  no longer checks them first): who sets it (`set_by`), how many facts may point at one
  parent (`limit`), a parent closed by a link (`closes_parent`) and a link that waits for
  what is under the fact (`requires_completed_children`).
  """
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFacts.FakeRela
  alias AtlasFacts.Workshops.Accepted

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "rules-#{System.unique_integer([:positive])}")
    rela = FakeRela.start(Accepted)
    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: Accepted})
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    put("maker", "create", "M-1", %{"title" => "Maker"})
    put("widget", "create", "W-1", %{"title" => "One"})
    put("widget", "create", "W-2", %{"title" => "Two"})
    %{rela: rela}
  end

  defp put(kind, op, key, values, opts \\ []) do
    envelope = Envelope.new("fact", kind)

    content =
      %{"op" => op, "key" => key, "values" => values, "version" => nil}
      |> then(&if(opts[:links], do: Map.put(&1, "links", opts[:links]), else: &1))
      |> then(&if(opts[:by], do: Map.put(&1, "by", opts[:by]), else: &1))

    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id} = reply, answer}, 1_000
    {reply.class, answer["reasons"]}
  end

  defp part(key, phase, widget),
    do:
      put("part", "create", key, %{"title" => key, "phase" => phase},
        links: %{"of_widget" => [widget]}
      )

  test "a relation set_by a connector or a migration is set by them alone" do
    stamp = fn by ->
      put("widget", "change", "W-1", %{}, links: %{"stamped_by" => ["M-1"]}, by: by)
    end

    for by <- [nil, "M-1", "control/session-1", "connectors"] do
      assert {"refused", ["only a connector or migration sets stamped_by"]} = stamp.(by)
    end

    assert {"stored", nil} = stamp.("connector/outside")
    # The same links again change nothing, whoever sends them.
    assert {"stored", nil} = stamp.("M-1")

    assert {"stored", nil} =
             put("widget", "change", "W-2", %{},
               links: %{"stamped_by" => ["M-1"]},
               by: "migration"
             )
  end

  test "a parent takes as many counted facts as its limit, and a move counts as a new one" do
    # Only rough parts count; once the parent has as many, it takes no new part at all.
    assert {"stored", nil} = part("P-0", "fine", "W-1")
    assert {"stored", nil} = part("P-1", "rough", "W-1")
    assert {"refused", ["W-1 already has P-1 (Rough)"]} = part("P-2", "rough", "W-1")
    assert {"refused", ["W-1 already has P-1 (Rough)"]} = part("P-3", "fine", "W-1")
    assert {"stored", nil} = part("P-4", "rough", "W-2")

    assert {"refused", ["W-1 already has P-1 (Rough)"]} =
             put("part", "change", "P-4", %{}, links: %{"of_widget" => ["W-1"]})

    # A part that stays where it is is no new one.
    assert {"stored", nil} =
             put("part", "change", "P-1", %{"title" => "Again"}, links: %{"of_widget" => ["W-1"]})
  end

  test "a fact is accepted only once all under it is completed; then it takes nothing new" do
    part("P-2", "fine", "W-1")
    part("P-1", "rough", "W-1")
    accept = fn -> put("widget", "change", "W-1", %{}, links: %{"accepted_by" => ["M-1"]}) end

    assert {"refused", ["W-1 has P-1, P-2 open"]} = accept.()

    put("part", "change", "P-1", %{}, links: %{"made_by" => ["M-1"]})
    assert {"refused", ["W-1 has P-2 open"]} = accept.()
    put("part", "change", "P-2", %{}, links: %{"made_by" => ["M-1"]})
    assert {"stored", nil} = accept.()

    closed = "W-1 is accepted; reopen it first, or put this under another widget"
    full = "W-1 already has P-1 (Rough)"
    # Closed, and full besides: both are said.
    assert {"refused", [^closed, ^full]} = part("P-3", "fine", "W-1")
    part("P-4", "fine", "W-2")

    assert {"refused", [^closed, ^full]} =
             put("part", "change", "P-4", %{}, links: %{"of_widget" => ["W-1"]})

    # Reopened, it is no longer closed.
    assert {"stored", nil} = put("widget", "change", "W-1", %{}, links: %{"accepted_by" => []})
    assert {"refused", [^full]} = part("P-3", "fine", "W-1")
  end
end
