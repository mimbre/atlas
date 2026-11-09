defmodule AtlasCode.GithubSlugTest do
  use ExUnit.Case, async: true

  test "HTTPS and SSH GitHub remotes name the same repository for its pull requests" do
    for url <- [
          "https://github.com/mimbre/atlas.git",
          "https://github.com/mimbre/atlas",
          "git@github.com:mimbre/atlas.git",
          "git@github.com:mimbre/atlas",
          "ssh://git@github.com/mimbre/atlas.git"
        ] do
      assert AtlasCode.github_slug(url) == "mimbre/atlas", url
    end
  end

  test "remotes that are not GitHub repositories get no pull request" do
    for url <- [
          "file:///tmp/remote",
          "/tmp/remote",
          "https://gitlab.com/mimbre/atlas.git",
          "git@gitlab.com:mimbre/atlas.git",
          "https://github.com/mimbre",
          "https://github.com/mimbre/atlas/extra.git",
          "https://github.com.evil/mimbre/atlas.git"
        ] do
      assert AtlasCode.github_slug(url) == nil, url
    end
  end
end
