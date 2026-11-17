defmodule AtlasRuntime.Sources.CredentialTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.Sources.Credential

  @name "flow-prod"

  setup do
    home =
      Path.join(System.tmp_dir!(), "w3-cred-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([home, "sources", @name]))
    File.chmod!(Path.join([home, "sources", @name]), 0o700)
    on_exit(fn -> File.rm_rf!(home) end)

    token = "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    %{home: home, token: token, uid: File.stat!(home).uid}
  end

  defp put(ctx, contents, mode \\ 0o600) do
    path = Credential.path(ctx.home, @name)
    File.rm(path)
    File.write!(path, contents)
    File.chmod!(path, mode)
    path
  end

  defp refusal(ctx, opts \\ []) do
    assert {:error, {:credential, reason}} = Credential.load(ctx.home, @name, opts)
    reason
  end

  test "the path is sources/<name>/token in the home", ctx do
    assert Credential.path(ctx.home, @name) == Path.join([ctx.home, "sources", @name, "token"])
  end

  describe "a valid credential" do
    test "answers the bearer header, through a closure that inspects without it", ctx do
      put(ctx, ctx.token)
      assert {:ok, secret} = Credential.load(ctx.home, @name)
      assert is_function(secret, 0)
      assert secret.() == "Bearer " <> ctx.token
      refute inspect(secret, limit: :infinity) =~ ctx.token
    end

    test "may end with one line ending", ctx do
      for ending <- ["\n", "\r\n"] do
        put(ctx, ctx.token <> ending)
        assert {:ok, secret} = Credential.load(ctx.home, @name)
        assert secret.() == "Bearer " <> ctx.token
      end
    end

    test "is owned by the Runtime's own uid by default", ctx do
      put(ctx, ctx.token)
      assert {:ok, _} = Credential.load(ctx.home, @name, uid: ctx.uid)
      assert {:ok, _} = Credential.load(ctx.home, @name)
    end
  end

  describe "the rules, one by one" do
    test "credential must be 0600", ctx do
      for mode <- [0o644, 0o640, 0o604, 0o660, 0o606, 0o400, 0o700] do
        put(ctx, ctx.token, mode)
        assert refusal(ctx) == :mode, "mode #{Integer.to_string(mode, 8)} was taken"
      end
    end

    test "credential must be owned by the Runtime's uid", ctx do
      put(ctx, ctx.token)
      assert refusal(ctx, uid: ctx.uid + 1) == :owner
    end

    test "credential must not be a symlink", ctx do
      target = Path.join(ctx.home, "elsewhere")
      File.write!(target, ctx.token)
      File.chmod!(target, 0o600)
      File.ln_s!(target, Credential.path(ctx.home, @name))
      assert refusal(ctx) == :symlink
    end

    test "credential must be a regular file", ctx do
      File.mkdir!(Credential.path(ctx.home, @name))
      assert refusal(ctx) == :not_regular
    end

    test "the source's directory must not be a symlink", ctx do
      real = Path.join(ctx.home, "real")
      File.rename!(Path.join([ctx.home, "sources", @name]), real)
      File.write!(Path.join(real, "token"), ctx.token)
      File.chmod!(Path.join(real, "token"), 0o600)
      File.ln_s!(real, Path.join([ctx.home, "sources", @name]))
      assert refusal(ctx) == :symlink
    end

    test "sources/ must be a directory, not a symlink", ctx do
      real = Path.join(ctx.home, "real-sources")
      File.rename!(Path.join(ctx.home, "sources"), real)
      File.ln_s!(real, Path.join(ctx.home, "sources"))
      put(ctx, ctx.token)
      assert refusal(ctx) == :symlink
    end

    test "a missing credential is refused", ctx do
      assert refusal(ctx) == :missing
      File.rm_rf!(Path.join(ctx.home, "sources"))
      assert refusal(ctx) == :missing
    end

    test "credential must not be empty", ctx do
      for contents <- ["", "\n", "\r\n"] do
        put(ctx, contents)
        assert refusal(ctx) == :empty
      end
    end

    test "credential must be one bearer token", ctx do
      for contents <- [
            "two words",
            ctx.token <> "\n\n",
            "\n" <> ctx.token,
            "tok\"en",
            String.duplicate("a", 4097)
          ] do
        put(ctx, contents)
        assert refusal(ctx) == :malformed
      end

      put(ctx, String.duplicate("a", 4096))
      assert {:ok, _} = Credential.load(ctx.home, @name)
    end

    test "the name stays one component under sources/", ctx do
      for name <- ["..", "../x", "a/b", "", ".hidden", "/abs", "a\0b", String.duplicate("a", 65)] do
        assert Credential.load(ctx.home, name) == {:error, {:credential, :invalid_name}}
      end
    end
  end

  test "a refusal never quotes the file's contents", ctx do
    marker = "s3cr3t-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    for {contents, mode} <- [{marker <> " x", 0o600}, {marker, 0o644}] do
      put(ctx, contents, mode)
      assert {:error, reason} = Credential.load(ctx.home, @name)
      refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ marker
    end
  end

  test "redact/2 replaces the token in binaries and charlists at any depth", ctx do
    header = String.to_charlist("Bearer " <> ctx.token)
    term = %{a: [{~c"authorization", header}], b: {"x #{ctx.token} y"}, c: [1 | ctx.token]}
    redacted = Credential.redact(term, ctx.token)
    refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ ctx.token
    assert inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ "[redacted]"
  end
end
