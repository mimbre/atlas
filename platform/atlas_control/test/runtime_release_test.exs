defmodule AtlasControl.RuntimeReleaseTest do
  use ExUnit.Case, async: true

  alias AtlasControl.RuntimeRelease

  @old "develop-aaaaaaaaaaaa"
  @new "develop-bbbbbbbbbbbb"
  @archive "atlas-runtime-#{@new}-darwin-arm64.tar.gz"
  @assets for name <- [@archive, @archive <> ".sha256"], do: %{"name" => name, "state" => "uploaded", "size" => 12}

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

    for comparison <- [:error, {:ok, %{"status" => "behind", "ahead_by" => 0}},
                       {:ok, %{"status" => "diverged", "ahead_by" => 1}},
                       {:ok, %{"status" => "ahead", "ahead_by" => "1"}}] do
      refute RuntimeRelease.newer?(@old, @new, api(release, comparison))
    end

    for unavailable <- [:error, {:ok, %{"draft" => true, "assets" => @assets}},
                        {:ok, %{"draft" => false, "assets" => tl(@assets)}},
                        {:ok, %{"draft" => false, "assets" => [%{"name" => @archive, "state" => "uploaded", "size" => 0}]}}] do
      refute RuntimeRelease.newer?(@old, @new, api(unavailable, ahead))
    end

    refute RuntimeRelease.newer?(@new, @new, api(release, ahead))
    refute RuntimeRelease.newer?("local", @new, api(release, ahead))
  end
end
