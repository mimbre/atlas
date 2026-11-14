# e2e and tools/plan compile this folder outside the umbrella: keep it OTP-only.
defmodule AtlasFacts.Trust do
  @moduledoc """
  The CA certificates this VM trusts: the operating system's, else a PEM bundle on disk.

  `:public_key.cacerts_get/0` reads the system store (the Keychain on macOS). Where that is
  unreadable (a sandboxed worker), the bundle at `SSL_CERT_FILE`, or else
  `/etc/ssl/cert.pem`, stands in: `:public_key.cacerts_load/1` makes it the VM's store, so
  every later `cacerts_get/0` answers it.

  `:httpc` reads that store on every request, also for `http` (it builds its default TLS
  options eagerly), so `load/0` runs once when Facts starts, before any request. Projects
  outside the umbrella that use `:httpc` (e2e, tools/plan) compile this folder, which holds
  this one file and depends on nothing but OTP, and call `load/0` too.
  """

  @system_bundle "/etc/ssl/cert.pem"

  @doc """
  The trusted certificates: `{:ok, certs}`, or `{:error, {:no_cacerts, bundle}}` when
  neither the system store nor the bundle can be read. The arguments are the seams the
  tests use; callers take the defaults.
  """
  def load(
        os \\ &:public_key.cacerts_get/0,
        load_file \\ &:public_key.cacerts_load/1,
        bundle \\ bundle()
      ) do
    with :error <- read(os),
         :ok <- load_file.(bundle),
         {:ok, certs} <- read(os) do
      {:ok, certs}
    else
      {:ok, certs} -> {:ok, certs}
      _ -> {:error, {:no_cacerts, bundle}}
    end
  end

  @doc "The certificates for a TLS connection's `cacerts`; raises when there are none."
  def get! do
    case load() do
      {:ok, certs} -> certs
      {:error, reason} -> raise "no trusted CA certificates: #{inspect(reason)}"
    end
  end

  @doc "The PEM bundle used when the system store is unreadable: `SSL_CERT_FILE`, else #{@system_bundle}."
  def bundle(env \\ System.get_env("SSL_CERT_FILE"))
  def bundle(file) when is_binary(file) and file != "", do: file
  def bundle(_), do: @system_bundle

  # cacerts_get/0 raises where the store is unreadable (on OTP 28 a FunctionClauseError
  # from inside public_key), rather than answering an error.
  defp read(os) do
    case os.() do
      [_ | _] = certs -> {:ok, certs}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
