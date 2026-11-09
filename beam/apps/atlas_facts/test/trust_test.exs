defmodule AtlasFacts.TrustTest do
  # The system store and the bundle loader are stand-ins: the VM's real store is never touched.
  use ExUnit.Case, async: true
  alias AtlasFacts.Trust

  defp unreadable, do: fn -> raise FunctionClauseError end

  test "the system store is used when it can be read; no bundle is loaded" do
    loader = fn file -> send(self(), {:loaded, file}) end
    assert {:ok, [:os_cert]} = Trust.load(fn -> [:os_cert] end, loader, "/no/bundle.pem")
    refute_received {:loaded, _}
  end

  test "an unreadable system store falls back to the bundle, which then answers" do
    {:ok, store} = Agent.start_link(fn -> nil end)
    os = fn -> Agent.get(store, & &1) || raise FunctionClauseError end
    loader = fn file -> Agent.update(store, fn _ -> [{:from, file}] end) end

    assert {:ok, [{:from, "/given/bundle.pem"}]} = Trust.load(os, loader, "/given/bundle.pem")
  end

  test "an empty or failing system store counts as unreadable" do
    for os <- [fn -> [] end, fn -> throw(:no_cacerts_found) end, fn -> exit(:boom) end] do
      assert {:error, {:no_cacerts, "/b.pem"}} =
               Trust.load(os, fn _ -> {:error, :enoent} end, "/b.pem")
    end
  end

  test "neither the store nor the bundle: an error naming the bundle" do
    assert {:error, {:no_cacerts, "/missing.pem"}} =
             Trust.load(unreadable(), fn _ -> {:error, :enoent} end, "/missing.pem")
  end

  test "the bundle is SSL_CERT_FILE when set, else the system's" do
    assert Trust.bundle("/etc/custom.pem") == "/etc/custom.pem"
    assert Trust.bundle(nil) == "/etc/ssl/cert.pem"
    assert Trust.bundle("") == "/etc/ssl/cert.pem"
  end
end
