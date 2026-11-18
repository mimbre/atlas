defmodule AtlasRuntime.Sources.Supervisor do
  @moduledoc """
  The work sources and their pullers (M2 plan A2, A5): one `AtlasRuntime.Sources.Puller`
  per entry of the policy's `sources` (`AtlasRuntime.Policy.sources/1`, W1).

  - A `remote` entry's puller is over the HTTP client target
    (`AtlasRuntime.Sources.HttpTarget`: W3's transport and the credential in
    `<home>/sources/<name>/token`). Its TLS peer is verified against the OS CA store, or,
    when the entry names a `ca_file` (pull-e2e D5, a test source), against the CAs of that
    file under the home only (`open/5`). A `ca_file` that is refused fails the open
    (`{:ca_file, reason}`) and never falls back to the OS store. A source whose URL or
    credential is refused is logged and not pulled; the others are.
  - The `builtin` entry `local` (A5): the local work source itself
    (`AtlasRuntime.Sources.Local`, on its store under `<home>/local-source/`), then its
    puller over `AtlasRuntime.Sources.Local.Target`, renewed in-BEAM. Its puller is
    registered, so the source nudges it when work is added.

  Started by `host/service.exs` after the work core. With no entry (`sources: []`) it starts
  nothing (`:ignore`), and no work reaches the executor: the CLI's `start` is
  `at_capacity(not_accepting)` (M2 A7). A puller that crashes is restarted.
  """
  use Supervisor

  alias AtlasRuntime.Policy
  alias AtlasRuntime.Sources.{HttpTarget, Local, Puller, Transport}

  # A CA bundle is a few KiB; anything far larger is not one.
  @max_ca_file 1_048_576

  @doc """
  Starts the sources and pullers of the policy in `home`. `opts`: `puller:` options passed
  to each puller, `target:` `{HttpTarget, :open}` options (`cacertfile:` for a test CA; an
  entry's `ca_file` replaces it, see `open/5`), `local:` options for
  `AtlasRuntime.Sources.Local.start_link/2`.
  """
  def start_link(home, opts \\ []) do
    case Policy.sources(Policy.load(home)) do
      [] -> :ignore
      sources -> Supervisor.start_link(__MODULE__, {home, sources, opts}, name: __MODULE__)
    end
  end

  @doc """
  The work sources pulled in `home`, in priority order: every entry of the policy's `sources`,
  the builtin `local` included (`host/service.exs` reports their count).
  """
  def sources(home), do: Policy.sources(Policy.load(home))

  @impl true
  def init({home, sources, opts}) do
    puller = Keyword.get(opts, :puller, [])

    children =
      Enum.flat_map(sources, fn
        %{"kind" => "builtin", "name" => name} ->
          [
            %{id: Local, start: {Local, :start_link, [home, Keyword.get(opts, :local, [])]}},
            {Puller,
             Keyword.merge(puller,
               name: name,
               target: Local.Target.new(),
               register: Local.puller_name()
             )}
          ]

        %{"kind" => "remote", "name" => name} = source ->
          [{Puller, Keyword.merge(puller, name: name, open: open(source, home, opts))}]
      end)

    # The local source starts before its puller; a puller whose source is down retries.
    Supervisor.init(children, strategy: :one_for_one)
  end

  # A remote puller's open (run at every open, not once here): without a `ca_file`, the
  # `{HttpTarget, :open}` with the caller's `target:` options as given (as before D5, so the
  # OS store applies unless a test sets one); with one, `open/5`.
  defp open(%{"name" => name, "url" => url, "ca_file" => ca_file}, home, opts),
    do: {__MODULE__, :open, [name, url, home, ca_file, Keyword.get(opts, :target, [])]}

  defp open(%{"name" => name, "url" => url}, home, opts),
    do: {HttpTarget, :open, [name, url, home, Keyword.get(opts, :target, [])]}

  @doc """
  Opens remote source `name` at `url` (`HttpTarget.open/4`, `opts` as there) trusting only
  the CAs in its `ca_file` (a path relative to `home`, under `sources/<name>/`, as
  `AtlasRuntime.Policy` admits it). Answers `{:ok, ref}` or `{:error, reason}`; a refused
  `ca_file` is `{:error, {:ca_file, why}}`, and nothing is opened.

  The file is taken by the rule `AtlasRuntime.Sources.Credential.load/3` applies to the
  token (`credential.ex:97-115`, `:123-152`): every component from `sources/` down to it
  is checked with `lstat`, so none may be a symbolic link (`:symlink`); each directory must
  be a directory (`:directory`) and the file a regular file (`:not_regular`); the file it
  opens must be the one it checked (same device and inode, else `:changed`). It is read
  once, at most #{@max_ca_file} bytes (`:too_large`), and must hold at least one PEM
  certificate (`:no_certificates`). The connection then trusts those decoded certificates
  (`cacerts:`), never the path, so a file changed after the check is not read again.
  """
  def open(name, url, home, ca_file, opts) do
    path = Path.join(home, ca_file)

    # `Transport.open/3` is given the checked path only so that it does not load the OS
    # store; its `{:cacertfile, path}` is then replaced by the certificates read here.
    with {:ok, ders} <- ca_file(home, name, ca_file),
         {:ok, %{host: host}} <- Transport.parse_url(url),
         {:ok, %{conn: conn} = ref} <-
           HttpTarget.open(name, url, home, Keyword.put(opts, :cacertfile, path)) do
      {:ok, %{ref | conn: %{conn | ssl: Transport.ssl(host, {:cacerts, ders})}}}
    end
  end

  ## The ca_file

  defp ca_file(home, name, ca_file) do
    case checked(home, name, ca_file) do
      {:ok, ders} -> {:ok, ders}
      {:error, why} -> {:error, {:ca_file, why}}
    end
  end

  defp checked(home, name, ca_file) do
    path = Path.join(home, ca_file)

    with {:ok, dirs} <- under(name, ca_file),
         :ok <- directories(home, dirs),
         {:ok, stat} <- regular(path),
         {:ok, pem} <- read_checked(path, stat) do
      certificates(pem)
    end
  end

  # The directories from `sources/` down to the file, for a path the policy admits:
  # `sources/<name>/.../<file>` with no empty, `.` or `..` segment (checked again here, as
  # `open/5` is public).
  defp under(name, ca_file) when is_binary(ca_file) do
    segments = String.split(ca_file, "/")

    case segments do
      ["sources", ^name, _ | _] ->
        if Enum.any?(segments, &(&1 in ["", ".", ".."])),
          do: {:error, :outside},
          else: {:ok, Enum.drop(segments, -1)}

      _ ->
        {:error, :outside}
    end
  end

  defp under(_name, _ca_file), do: {:error, :outside}

  # Each directory from `sources/` down, without following a link (as `Credential`'s).
  defp directories(home, dirs) do
    dirs
    |> Enum.scan(home, &Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, :ok}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink}}
        {:ok, _other} -> {:halt, {:error, :directory}}
        {:error, :enoent} -> {:halt, {:error, :missing}}
        {:error, _} -> {:halt, {:error, :unreadable}}
      end
    end)
  end

  defp regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _other} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :missing}
      {:error, _} -> {:error, :unreadable}
    end
  end

  # Read once; the file opened is the file checked (a link or another file renamed in
  # between has another device or inode). Public only so a test can give it a stale `stat`.
  @doc false
  def read_checked(path, %File.Stat{major_device: device, inode: inode}) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          with {:ok, info} <- :file.read_file_info(fd, time: :posix),
               %File.Stat{type: :regular, major_device: ^device, inode: ^inode} <-
                 File.Stat.from_record(info) do
            case :file.read(fd, @max_ca_file + 1) do
              {:ok, data} when byte_size(data) > @max_ca_file -> {:error, :too_large}
              {:ok, data} -> {:ok, data}
              :eof -> {:ok, ""}
              {:error, _} -> {:error, :unreadable}
            end
          else
            {:error, _} -> {:error, :unreadable}
            %File.Stat{} -> {:error, :changed}
          end
        after
          :file.close(fd)
        end

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  defp certificates(pem) do
    case for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      [] -> {:error, :no_certificates}
      ders -> {:ok, ders}
    end
  rescue
    _ -> {:error, :no_certificates}
  end
end
