defmodule AtlasControl.RuntimeRelease do
  @moduledoc false
  use GenServer

  @api "https://api.github.com/repos/mimbre/atlas"
  @build ~r/\A(?:develop|master)-([0-9a-f]{12})\z/
  @ttl 300_000
  @probe_interval 150_000
  @max_entries 128

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts), do: {:ok, {Keyword.get(opts, :verify, &newer?/2), %{}, nil}}

  # Each probe uses up to two GitHub calls. Throttle all pairs to reserve quota for submits.
  # Expired and throttled proofs fail closed; submits always call newer?/2 directly.
  def cached_newer?(from, to, server \\ __MODULE__) do
    GenServer.call(server, {:newer, from, to}, 10_000)
  catch
    :exit, _ -> false
  end

  @impl true
  def handle_call({:newer, from, to}, _caller, {verify, entries, last_probe}) do
    now = System.monotonic_time(:millisecond)
    key = {from, to}
    entries = Map.reject(entries, fn {_, {at, _}} -> now - at >= @ttl end)

    case entries do
      %{^key => {_, result}} ->
        {:reply, result, {verify, entries, last_probe}}

      _ when not is_nil(last_probe) and now - last_probe < @probe_interval ->
        {:reply, false, {verify, entries, last_probe}}

      _ ->
        result = verify.(from, to) == true
        entries = if map_size(entries) >= @max_entries, do: %{}, else: entries
        finished = System.monotonic_time(:millisecond)
        {:reply, result, {verify, Map.put(entries, key, {finished, result}), finished}}
    end
  end

  # GitHub's comparison proves ancestry; both Runtime download assets must exist.
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
