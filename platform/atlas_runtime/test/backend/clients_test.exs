defmodule AtlasRuntime.BackendTest.Clients do
  @moduledoc """
  `clients.json` (design §8.1; S3 plan B2–B4, P2): its shape, the file's mode and owner,
  rights within the TCP ceiling (an entry outside it makes the file invalid), reasons
  that quote nothing from the file, and the token lookup.
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Backend.Clients

  @moduletag :tmp_dir

  @ceiling AtlasRuntime.Backend.Rest.__rights__(:tcp)
  @token "c2VjcmV0LXRva2VuLWZvci10ZXN0cw"
  @other "YW5vdGhlci10b2tlbi1mb3ItdGVzdHM"

  defp sha(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp uid do
    {:ok, uid} = Clients.uid()
    uid
  end

  defp entry(fields \\ %{}),
    do:
      Map.merge(%{"name" => "core", "token_sha256" => sha(@token), "rights" => ["read"]}, fields)

  defp file(clients, top \\ %{}),
    do: Map.merge(%{"version" => 1, "listen" => %{"port" => 8443}, "clients" => clients}, top)

  defp write!(dir, data, mode \\ 0o600) do
    path = Clients.path(dir)
    File.rm(path)
    File.write!(path, if(is_binary(data), do: data, else: JSON.encode!(data)))
    File.chmod!(path, mode)
    path
  end

  defp load(dir), do: Clients.load(dir, @ceiling, uid())

  test "the TCP ceiling excludes choose_slot and choose_path and is within the socket's rights" do
    refute :choose_slot in @ceiling
    refute :choose_path in @ceiling
    assert @ceiling -- AtlasRuntime.Backend.Rest.__rights__(:socket) == []
  end

  test "a valid file: the port, and each entry with its rights as atoms", %{tmp_dir: dir} do
    write!(
      dir,
      file([
        entry(),
        entry(%{
          "name" => "flow-engine_2",
          "token_sha256" => sha(@other),
          "rights" => ["submit", "cancel", "read", "read_all"],
          "disabled" => true
        })
      ])
    )

    assert {:ok, %{port: 8443, clients: [core, flow]}} = load(dir)
    assert core == %{name: "core", token_sha256: sha(@token), rights: [:read], disabled: false}
    assert flow.rights == [:submit, :cancel, :read, :read_all]
    assert flow.disabled
  end

  test "no file is :none, not an error", %{tmp_dir: dir} do
    assert load(dir) == :none
  end

  test "mode must be 0600: 0644, 0640 and 0400 are refused", %{tmp_dir: dir} do
    for mode <- [0o644, 0o640, 0o400, 0o700] do
      write!(dir, file([entry()]), mode)
      assert {:error, why} = load(dir)
      assert why =~ "mode #{Integer.to_string(mode, 8)}"
    end
  end

  test "it must be owned by the Runtime's uid", %{tmp_dir: dir} do
    write!(dir, file([entry()]))
    assert {:error, why} = Clients.load(dir, @ceiling, uid() + 1)
    assert why =~ "not owned by the Runtime's uid"
  end

  test "a symlink is refused, even to a private file", %{tmp_dir: dir} do
    real = Path.join(dir, "real.json")
    File.write!(real, JSON.encode!(file([entry()])))
    File.chmod!(real, 0o600)
    File.ln_s!(real, Clients.path(dir))
    assert {:error, why} = load(dir)
    assert why =~ "not a regular file"
  end

  test "choose_slot, choose_path, or any right outside the ceiling, makes the file invalid (never cut down)",
       %{tmp_dir: dir} do
    for rights <- [
          ["read", "choose_slot"],
          ["choose_slot"],
          ["read", "choose_path"],
          ["choose_path"],
          ["operate"],
          ["inspect"],
          ["READ"]
        ] do
      write!(dir, file([entry(%{"rights" => rights})]))
      assert {:error, why} = load(dir), inspect(rights)
      assert why =~ "clients[0].rights names a right outside the TCP listener's rights"
    end
  end

  test "every rule of the shape", %{tmp_dir: dir} do
    hash = sha(@token)

    cases = [
      {file([entry()], %{"version" => 2}), "version must be 1"},
      {Map.delete(file([entry()]), "version"), "version must be 1"},
      {file([entry()], %{"listen" => %{"port" => 0}}), "listen.port"},
      {file([entry()], %{"listen" => %{"port" => 65_536}}), "listen.port"},
      {file([entry()], %{"listen" => %{"port" => "8443"}}), "listen.port"},
      {file([entry()], %{"listen" => %{"port" => 1, "ip" => "0.0.0.0"}}), "listen has a field"},
      {Map.delete(file([entry()]), "listen"), "listen must be an object"},
      {file([entry()], %{"extra" => true}), "the top level has a field"},
      {file(%{}), "clients must be a list"},
      {file([entry(%{"name" => "Core"})]), "clients[0].name must match"},
      {file([entry(%{"name" => "-core"})]), "clients[0].name must match"},
      {file([entry(%{"name" => String.duplicate("a", 64)})]), "clients[0].name must match"},
      {file([entry(%{"name" => "a b"})]), "clients[0].name must match"},
      {file([Map.delete(entry(), "name")]), "clients[0].name is missing"},
      {file([entry(), entry(%{"token_sha256" => sha(@other)})]), "clients[1].name is not unique"},
      {file([entry(), entry(%{"name" => "other"})]), "clients[1].token_sha256 is not unique"},
      {file([entry(%{"token_sha256" => String.upcase(hash)})]),
       "clients[0].token_sha256 must be"},
      {file([entry(%{"token_sha256" => binary_part(hash, 0, 63)})]),
       "clients[0].token_sha256 must be"},
      {file([entry(%{"token_sha256" => @token})]), "clients[0].token_sha256 must be"},
      {file([entry(%{"rights" => "read"})]), "clients[0].rights must be a list"},
      {file([entry(%{"rights" => ["read", "read"]})]), "clients[0].rights must be a list"},
      {file([entry(%{"disabled" => "yes"})]), "clients[0].disabled must be true or false"},
      {file([entry(%{"token" => @token})]), "clients[0] has a field that is not allowed"},
      {file(["core"]), "clients[0] is no object"},
      {[file([entry()])], "the top level is no object"},
      {"{not json", "is no JSON"}
    ]

    for {data, expected} <- cases do
      write!(dir, data)
      assert {:error, why} = load(dir), "accepted: #{inspect(data)}"
      assert why =~ expected, "#{inspect(data)}: #{why}"
      # The reason names the problem, never a value from the file.
      refute why =~ hash
      refute why =~ String.upcase(hash)
      refute why =~ @token
      refute why =~ "Core"
    end
  end

  test "an empty client list is valid: nobody authenticates", %{tmp_dir: dir} do
    write!(dir, file([]))
    assert {:ok, %{clients: []}} = load(dir)
    assert Clients.authenticate([], @token) == :error
  end

  describe "authenticate/2" do
    setup %{tmp_dir: dir} do
      write!(
        dir,
        file([
          entry(%{"name" => "a", "token_sha256" => sha("first")}),
          entry(),
          entry(%{"name" => "off", "token_sha256" => sha(@other), "disabled" => true})
        ])
      )

      {:ok, %{clients: entries}} = load(dir)
      %{entries: entries}
    end

    test "the entry whose hash is the token's SHA-256", %{entries: entries} do
      assert {:ok, %{name: "core"}} = Clients.authenticate(entries, @token)
      assert {:ok, %{name: "a"}} = Clients.authenticate(entries, "first")
    end

    test "unknown, disabled, the hash itself and the empty token are refused alike",
         %{entries: entries} do
      for token <- ["nope", @other, sha(@token), "", @token <> " "],
          do: assert(Clients.authenticate(entries, token) == :error, inspect(token))
    end
  end
end
