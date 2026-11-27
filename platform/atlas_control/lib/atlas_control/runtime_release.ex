defmodule AtlasControl.RuntimeRelease do
  @moduledoc false

  @api "https://api.github.com/repos/mimbre/atlas"
  @build ~r/\A(?:develop|master)-([0-9a-f]{12})\z/

  # GitHub's comparison proves ancestry, not lexical ordering of commit hashes. A release
  # is usable only when both files the Runtime downloads have actually been published.
  def newer?(from, to, get \\ &get/1) do
    with [_, old] <- match(from),
         [_, new] <- match(to),
         false <- old == new,
         {:ok, %{"draft" => false, "assets" => assets}} <-
           get.("#{@api}/releases/tags/atlas-runtime-#{to}"),
         true <- assets_ready?(assets, to),
         {:ok, %{"status" => "ahead", "ahead_by" => count}} when is_integer(count) and count > 0 <-
           get.("#{@api}/compare/#{old}...#{new}") do
      true
    else
      _ -> false
    end
  end

  defp match(build) when is_binary(build), do: Regex.run(@build, build)
  defp match(_), do: nil

  defp assets_ready?(assets, build) when is_list(assets) do
    archive = "atlas-runtime-#{build}-darwin-arm64.tar.gz"

    Enum.all?([archive, archive <> ".sha256"], fn name ->
      Enum.any?(
        assets,
        &match?(
          %{"name" => ^name, "state" => "uploaded", "size" => size}
          when is_integer(size) and size > 0,
          &1
        )
      )
    end)
  end

  defp assets_ready?(_, _), do: false

  defp get(url) do
    case Req.get(url,
           headers: [{"user-agent", "atlas-control"}],
           receive_timeout: 3_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
