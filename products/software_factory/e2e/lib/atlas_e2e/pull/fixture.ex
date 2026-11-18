defmodule AtlasE2E.Pull.Fixture do
  @moduledoc """
  The pull-e2e's fixed inputs: the bytes of its blobs, the edge's test certificates and the
  fixture remote Code reads the base from.

  - `xorshift/2`: `size` bytes of xorshift64 output from `seed` (each step
    `x ^= x <<< 13; x ^= x >>> 7; x ^= x <<< 17`, its 8 bytes little-endian; seed 0 is 1),
    as the stub's `blob` edit writes them (`pull/stub/main.go`, `writeBlob`), so the bench
    knows each blob's sha256 without reading the Runtime's files.
  - `tls/0`: a root and a server certificate for `localhost` (SAN `DNS:localhost`) from
    `:public_key.pkix_test_data/1`: the edge serves the chain, the Runtime's `ca_file` is the root.
  - `remote!/2`: a bare repository with one `develop` commit: `bin/check` (`exit 0`),
    `README.md` and `fixture/base-2mib.bin` (seed 1).
  """
  import Bitwise

  @mask 0xFFFFFFFFFFFFFFFF
  @base_size 2 * 1024 * 1024
  @chunk 65_536

  def base_size, do: @base_size

  @doc "The bytes as a stream of binaries (at most #{@chunk} bytes each)."
  def xorshift(size, seed) do
    Stream.resource(
      fn -> {if(seed == 0, do: 1, else: seed), size} end,
      fn
        {_x, 0} ->
          {:halt, nil}

        {x, left} ->
          n = min(left, @chunk)
          {bytes, x} = words(x, div(n + 7, 8), [])
          {[binary_part(bytes, 0, n)], {x, left - n}}
      end,
      fn _ -> :ok end
    )
  end

  defp words(x, 0, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), x}

  defp words(x, n, acc) do
    x = bxor(x, x <<< 13 &&& @mask)
    x = bxor(x, x >>> 7)
    x = bxor(x, x <<< 17 &&& @mask)
    words(x, n - 1, [<<x::little-64>> | acc])
  end

  @doc "The lower-case hex sha256 of `xorshift(size, seed)`."
  def sha(size, seed) do
    xorshift(size, seed)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def sha_of(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "`%{cert: der, key: key, cacerts: [der], root_pem: pem}` for the edge on `localhost`."
  def tls do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
          intermediates: [],
          peer: [key: {:namedCurve, :secp256r1}, digest: :sha256, extensions: [san]]
        },
        client_chain: %{
          root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
          intermediates: [],
          peer: [key: {:namedCurve, :secp256r1}, digest: :sha256]
        }
      })

    [root | _] = Enum.reverse(server[:cacerts])

    %{
      cert: server[:cert],
      key: server[:key],
      cacerts: server[:cacerts],
      root_pem: :public_key.pem_encode([{:Certificate, root, :not_encrypted}])
    }
  end

  @doc "Make the bare fixture remote at `dir` (git with the run's own configuration `env`)."
  def remote!(dir, env) do
    work = dir <> ".work"
    File.mkdir_p!(Path.join(work, "bin"))
    File.mkdir_p!(Path.join(work, "fixture"))
    File.write!(Path.join(work, "bin/check"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(work, "bin/check"), 0o755)
    File.write!(Path.join(work, "README.md"), "# pull-e2e fixture\n")

    File.write!(
      Path.join(work, "fixture/base-2mib.bin"),
      Enum.into(xorshift(@base_size, 1), <<>>)
    )

    git = fn args, cd ->
      {out, status} = System.cmd("git", args, cd: cd, env: env, stderr_to_stdout: true)
      if status != 0, do: raise("git #{Enum.join(args, " ")}: #{out}")
      out
    end

    git.(["init", "-q", "-b", "develop"], work)
    git.(["add", "-A"], work)

    git.(
      [
        "-c",
        "user.name=pull-e2e",
        "-c",
        "user.email=pull-e2e@invalid",
        "commit",
        "-q",
        "-m",
        "fixture"
      ],
      work
    )

    git.(["clone", "-q", "--bare", work, dir], Path.dirname(dir))
    File.rm_rf!(work)
    %{dir: dir, url: "file://" <> dir, base_sha256: sha(@base_size, 1)}
  end
end
