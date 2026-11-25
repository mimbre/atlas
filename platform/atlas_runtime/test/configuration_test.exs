defmodule AtlasRuntime.ConfigurationTest do
  @moduledoc """
  IS-Atlas-27: a configuration its supervisor set through Control, as the work source
  serves it, is checked as the Runtime's own policy and written whole, or refused with a
  reason, the policy in force left as it was.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.{Configuration, Policy}

  @moduletag capture_log: true

  @source "flow"

  defp policy(changes \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "slots" => ["s1", "s2"],
        "profiles" => %{
          "light_work" => %{
            "permissions" => ["workspace-write"],
            "cost_classes" => ["standard"],
            "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-5"}]
          }
        },
        "sources" => [
          %{
            "name" => @source,
            "kind" => "remote",
            "url" => "https://flow.example/",
            "credential_file" => "sources/flow/token",
            "git_url" => "https://code.example/git",
            "priority" => 1,
            "max_slots" => 2,
            "max_store_bytes" => 2_147_483_648
          },
          %{
            "name" => "local",
            "kind" => "builtin",
            "priority" => 2,
            "max_slots" => 2,
            "max_store_bytes" => 2_147_483_648
          }
        ]
      },
      changes
    )
  end

  setup do
    home =
      Path.join(System.tmp_dir!(), "atlas-configuration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    File.write!(Policy.path(home), JSON.encode!(policy()))
    %{home: home}
  end

  defp sources(fun), do: Enum.map(policy()["sources"], fun)

  test "a valid, newer configuration is written whole and is the policy in force", %{home: home} do
    option = %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-opus-5-5"}

    document =
      policy(%{
        "version" => 2,
        "profiles" => put_in(policy()["profiles"], ["light_work", "options"], [option]),
        "sources" =>
          sources(fn
            %{"name" => "local"} = s -> %{s | "priority" => 0}
            s -> %{s | "git_url" => "https://code.example/other"}
          end)
      })
      |> JSON.encode!()

    assert Configuration.apply(home, @source, document) == {:applied, 2}
    assert File.read!(Policy.path(home)) == document
    assert {:ok, applied} = Policy.load(home)
    assert applied["profiles"]["light_work"]["options"] == [option]

    assert [%{"name" => "local", "priority" => 0}, %{"name" => @source}] =
             Policy.sources({:ok, applied})

    refute File.exists?(Policy.path(home) <> ".tmp")
  end

  test "the version in force again is current, and nothing is written", %{home: home} do
    before = File.read!(Policy.path(home))

    assert Configuration.apply(home, @source, JSON.encode!(policy(%{"slots" => ["s1"]}))) ==
             :current

    assert File.read!(Policy.path(home)) == before
  end

  test "an invalid document is refused with the policy's own reason", %{home: home} do
    before = File.read!(Policy.path(home))
    document = JSON.encode!(policy(%{"version" => 3, "slots" => []}))

    assert {:refused, 3, "invalid: slots must be a non-empty list of distinct worker names"} =
             Configuration.apply(home, @source, document)

    assert File.read!(Policy.path(home)) == before

    assert {:refused, 0, "invalid: policy.json is not valid JSON"} =
             Configuration.apply(home, @source, "{")
  end

  test "an older version is refused", %{home: home} do
    File.write!(Policy.path(home), JSON.encode!(policy(%{"version" => 5})))

    assert {:refused, 4, "version 4 is not above 5, the one in force"} =
             Configuration.apply(home, @source, JSON.encode!(policy(%{"version" => 4})))
  end

  test "it must keep the link it came over", %{home: home} do
    moved =
      sources(fn
        %{"name" => @source} = s -> %{s | "url" => "https://elsewhere.example/"}
        s -> s
      end)

    assert {:refused, 2, "it must keep source flow, the link it came over, as it is"} =
             Configuration.apply(
               home,
               @source,
               JSON.encode!(policy(%{"version" => 2, "sources" => moved}))
             )

    dropped = Enum.reject(policy()["sources"], &(&1["name"] == @source))

    assert {:refused, 2, "it must keep source flow" <> _} =
             Configuration.apply(
               home,
               @source,
               JSON.encode!(policy(%{"version" => 2, "sources" => dropped}))
             )

    assert {:ok, %{"version" => 1}} = Policy.load(home)
  end

  test "another source added or moved needs a restart, so it is refused", %{home: home} do
    other = %{
      "name" => "other",
      "kind" => "remote",
      "url" => "https://other.example/",
      "credential_file" => "sources/other/token",
      "priority" => 3,
      "max_slots" => 1,
      "max_store_bytes" => 1_000
    }

    document =
      JSON.encode!(policy(%{"version" => 2, "sources" => policy()["sources"] ++ [other]}))

    assert {:refused, 2, "adding, removing or moving a source" <> _} =
             Configuration.apply(home, @source, document)

    assert {:ok, %{"version" => 1}} = Policy.load(home)
  end
end
