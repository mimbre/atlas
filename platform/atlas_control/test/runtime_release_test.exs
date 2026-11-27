defmodule AtlasControl.RuntimeReleaseTest do
  use ExUnit.Case, async: true

  alias AtlasControl.RuntimeRelease

  @old "develop-aaaaaaaaaaaa"
  @new "develop-bbbbbbbbbbbb"
  @archive "atlas-runtime-#{@new}-darwin-arm64.tar.gz"
  @assets for name <- [@archive, @archive <> ".sha256"],
              do: %{"name" => name, "state" => "uploaded", "size" => 12}

  defp api(release, comparison) do
    fn url ->
      cond do
        String.ends_with?(url, "/releases/tags/atlas-runtime-#{@new}") -> release
        String.ends_with?(url, "/compare/aaaaaaaaaaaa...bbbbbbbbbbbb") -> comparison
        true -> flunk("unexpected URL #{url}")
      end
    end
  end

  test "only a published release with both assets and a descendant commit is offered" do
    release = {:ok, %{"draft" => false, "assets" => @assets}}
    ahead = {:ok, %{"status" => "ahead", "ahead_by" => 1}}
    assert RuntimeRelease.newer?(@old, @new, api(release, ahead))

    for comparison <- [
          :error,
          {:ok, %{"status" => "behind", "ahead_by" => 0}},
          {:ok, %{"status" => "diverged", "ahead_by" => 1}},
          {:ok, %{"status" => "ahead", "ahead_by" => "1"}}
        ] do
      refute RuntimeRelease.newer?(@old, @new, api(release, comparison))
    end

    for unavailable <- [
          :error,
          {:ok, %{"draft" => true, "assets" => @assets}},
          {:ok, %{"draft" => false, "assets" => tl(@assets)}},
          {:ok,
           %{
             "draft" => false,
             "assets" => [%{"name" => @archive, "state" => "uploaded", "size" => 0}]
           }}
        ] do
      refute RuntimeRelease.newer?(@old, @new, api(unavailable, ahead))
    end

    refute RuntimeRelease.newer?(@new, @new, api(release, ahead))
    refute RuntimeRelease.newer?("local", @new, api(release, ahead))
  end

  test "render cache shares proof by build pair and fresh verification bypasses it" do
    test = self()

    {:ok, cache} =
      RuntimeRelease.start_link(
        name: nil,
        verify: fn from, to ->
          send(test, {:verified, from, to})
          true
        end
      )

    assert RuntimeRelease.cached_newer?(@old, @new, cache)
    assert RuntimeRelease.cached_newer?(@old, @new, cache)
    assert_receive {:verified, @old, @new}
    refute_received {:verified, @old, @new}
    refute RuntimeRelease.newer?(@old, @new, fn _ -> :error end)
    refute RuntimeRelease.cached_newer?("develop-cccccccccccc", @new, cache)
    refute_received {:verified, "develop-cccccccccccc", @new}
    :sys.replace_state(cache, fn {verify, entries, _} -> {verify, entries, nil} end)
    assert RuntimeRelease.cached_newer?("develop-cccccccccccc", @new, cache)
    assert_receive {:verified, "develop-cccccccccccc", @new}
  end

  test "render cache expires entries and remains bounded" do
    test = self()

    {:ok, cache} =
      RuntimeRelease.start_link(
        name: nil,
        verify: fn _, _ ->
          send(test, :verified)
          true
        end
      )

    assert RuntimeRelease.cached_newer?(@old, @new, cache)
    assert_receive :verified

    :sys.replace_state(cache, fn {verify, entries, last_probe} ->
      {verify,
       Map.new(entries, fn {key, {_, value}} ->
         {key, {System.monotonic_time(:millisecond) - 300_001, value}}
       end), last_probe}
    end)

    refute RuntimeRelease.cached_newer?(@old, @new, cache)
    refute_received :verified
    :sys.replace_state(cache, fn {verify, entries, _} -> {verify, entries, nil} end)
    assert RuntimeRelease.cached_newer?(@old, @new, cache)
    assert_receive :verified

    for n <- 1..140 do
      :sys.replace_state(cache, fn {verify, entries, _} -> {verify, entries, nil} end)
      assert RuntimeRelease.cached_newer?(Integer.to_string(n), @new, cache)
    end

    {_, entries, _} = :sys.get_state(cache)
    assert map_size(entries) <= 128
  end
end
