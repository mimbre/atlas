defmodule AtlasFlow.WorkSource.CredentialsTest do
  # Plan m3 A2 acceptance 9: the per-Runtime credentials. A token is compared as its
  # sha256; an unknown, empty or missing token is unauthenticated; the holder comes from the
  # credential only. And the work source's configuration: it refuses to start without a
  # result store (rev 3, N7), and with one its processes boot. Asserted on tags, the client
  # tuple and the running processes.
  use ExUnit.Case, async: false

  alias AtlasFlow.WorkSource
  alias AtlasFlow.WorkSource.Credentials

  @mini_token "token-of-the-mini"
  @laptop_token "token-of-the-laptop"

  defp secret do
    JSON.encode!(%{
      "mini" => %{"holder" => "ada", "token_sha256" => Credentials.token_sha256(@mini_token)},
      "laptop" => %{"holder" => "bea", "token_sha256" => Credentials.token_sha256(@laptop_token)}
    })
  end

  setup do
    {:ok, credentials} = Credentials.parse(secret())
    %{credentials: credentials}
  end

  test "a known token is its Runtime and that Runtime's holder", %{credentials: c} do
    assert {:ok, {"mini", "ada"}} = WorkSource.authenticate(c, @mini_token)
    assert {:ok, {"laptop", "bea"}} = WorkSource.authenticate(c, @laptop_token)
  end

  test "an unknown, empty or missing token is unauthenticated", %{credentials: c} do
    assert :unauthenticated = Credentials.lookup(c, "token-of-someone")
    assert :unauthenticated = Credentials.lookup(c, "")
    assert :unauthenticated = Credentials.lookup(c, nil)
    # The secret holds the hash, never the token: the hash is no token.
    assert :unauthenticated = Credentials.lookup(c, Credentials.token_sha256(@mini_token))
  end

  test "the secret keeps only hashes" do
    {:ok, c} = Credentials.parse(secret())
    refute inspect(c) =~ @mini_token
    assert c["mini"].token_sha256 =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a malformed secret is refused" do
    assert {:error, :invalid} = Credentials.parse("not json")
    assert {:error, :invalid} = Credentials.parse(JSON.encode!(%{"mini" => %{"holder" => "ada"}}))

    assert {:error, :invalid} =
             Credentials.parse(
               JSON.encode!(%{
                 "mini" => %{"holder" => "", "token_sha256" => String.duplicate("a", 64)}
               })
             )

    assert {:error, :invalid} =
             Credentials.parse(
               JSON.encode!(%{"mini" => %{"holder" => "ada", "token_sha256" => "ABC"}})
             )
  end

  test "the credentials come from the environment variable the configuration names" do
    name = "FLOW_TEST_CREDENTIALS_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:atlas_flow, :work_source)

    try do
      Application.put_env(:atlas_flow, :work_source, credentials_env: name)
      assert {:error, :unset} = Credentials.load()
      System.put_env(name, secret())
      assert {:ok, %{"mini" => %{holder: "ada"}}} = Credentials.load()
    after
      System.delete_env(name)

      if previous,
        do: Application.put_env(:atlas_flow, :work_source, previous),
        else: Application.delete_env(:atlas_flow, :work_source)
    end
  end

  test "the work source starts with no result store: results travel over Git (IS-Atlas-100)" do
    previous = Application.get_env(:atlas_flow, :work_source)

    try do
      Application.put_env(:atlas_flow, :work_source, lease_ttl: 900)
      assert {:ok, [_root]} = AtlasFlow.Application.work_source()

      Application.delete_env(:atlas_flow, :work_source)
      assert {:ok, []} = AtlasFlow.Application.work_source()
    after
      if previous,
        do: Application.put_env(:atlas_flow, :work_source, previous),
        else: Application.delete_env(:atlas_flow, :work_source)
    end
  end

  test "configured, the work source's processes boot: Bases, Dispatch and Delivery" do
    previous =
      for {app, key} <- [atlas_flow: :work_source, atlas: :model],
          do: {app, key, Application.get_env(app, key)}

    Application.put_env(:atlas_bus, :store, "boot-#{System.unique_integer([:positive])}")
    start_supervised!(AtlasFlow.FakeFacts)

    try do
      Application.put_env(:atlas, :model, AtlasFlow.FakeFacts.Leasing.Model)
      Application.put_env(:atlas_flow, :work_source, sweep_ms: nil, resync_ms: nil)
      {:ok, [root]} = AtlasFlow.Application.work_source()
      start_supervised!(root)

      for name <- [AtlasFlow.Bases, AtlasFlow.Dispatch, AtlasFlow.Delivery],
          do: assert(is_pid(Process.whereis(name)))

      assert %{leases: []} = AtlasFlow.Dispatch.status()
      refute "flow/results" in AtlasBus.endpoints()
    after
      for {app, key, value} <- previous,
          do:
            if(value,
              do: Application.put_env(app, key, value),
              else: Application.delete_env(app, key)
            )
    end
  end
end
