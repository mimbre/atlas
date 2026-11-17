defmodule AtlasBFFContract.SupervisionVersionTest do
  @moduledoc """
  Contract 0.18.0 (work acquisition decision 2026-11-17, §5.8; M3b P3): the supervision
  pages Open for you and Supervised by you, and Pick up and Hand over… on a fact, each
  with its submit. An older client cannot render them, so they need the version. The

  tests assert structure: names, parameters and paths, never wording.
  """
  use ExUnit.Case, async: true

  alias AtlasBFF.Paths
  alias AtlasBFFContract.Contract

  @schema Contract.__schema__()
  @screens [:open_for_you, :supervised_by_you]
  @actions [:pick_up, :hand_over]

  test "the supervision pages need 0.18.0" do
    assert Version.compare(@schema.version, "0.18.0") != :lt
    names = Enum.map(@schema.pages, & &1.name)
    for name <- @screens ++ @actions, do: assert(name in names, "#{name}")
  end

  test "each new page matches its own path, and builds it again, percent-encoded" do
    for name <- @screens do
      page = Enum.find(@schema.pages, &(&1.name == name))
      assert page.params == [], "#{name}"
      path = Paths.build(@schema.pages, name, %{})
      assert Paths.match(@schema.pages, path) == {:ok, name, %{}}
    end

    params = %{kind: "a kind", key: "K 1/2", run: "R-1#3"}

    for name <- @actions do
      page = Enum.find(@schema.pages, &(&1.name == name))
      assert Enum.sort(page.params) == Enum.sort(Map.keys(params)), "#{name}"
      path = Paths.build(@schema.pages, name, params)
      refute path =~ " " or path =~ "#", path
      assert Paths.match(@schema.pages, path) == {:ok, name, params}
    end
  end

  test "Pick up and Hand over… each submit at their page's path, with its parameters" do
    for name <- @actions do
      page = Enum.find(@schema.pages, &(&1.name == name))
      endpoint = Enum.find(@schema.endpoints, &(&1.name == name and &1.call == :submit))

      assert %{path: path, params: params, takes: :values} = endpoint, "#{name}"
      assert path == page.path
      assert Enum.sort(params) == Enum.sort(page.params)
      assert Enum.map(endpoint.replies, & &1.name) == [:stored, :refused]
    end

    # The two screens are read, never submitted.
    for name <- @screens,
        do: refute(Enum.any?(@schema.endpoints, &(&1.name == name and &1.call == :submit)))
  end

  test "the rank rule: a key named new is a new fact under a parent, as for answer" do
    # Different literals than answer's; with the key `new`, new_under's literal comes first.
    for action <- ~w(pick_up hand_over) do
      assert {:ok, :new_under, _} = Paths.match(@schema.pages, "/k/x/new/#{action}/r")
      assert {:ok, :answer, _} = Paths.match(@schema.pages, "/k/x/K-1/answer/#{action}")
    end

    assert {:ok, :new_under, _} = Paths.match(@schema.pages, "/k/x/new/answer/r")
  end
end
