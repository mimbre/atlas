defmodule AtlasRuntime.Sources.Supervisor do
  @moduledoc """
  The work sources and their pullers (M2 plan A2, A5): one `AtlasRuntime.Sources.Puller`
  per entry of the policy's `sources` (`AtlasRuntime.Policy.sources/1`, W1).

  - A `remote` entry's puller is over the HTTP client target
    (`AtlasRuntime.Sources.HttpTarget`: W3's transport and the credential in
    `<home>/sources/<name>/token`). Its TLS peer is verified against the OS CA store, or,
    when the entry names a `ca_file` (pull-e2e D5, a test source), against that file under
    the home only; a missing or non-regular one fails the open (`:no_cacerts`) and never
    falls back to the OS store. A source whose URL or credential is refused is logged and
    not pulled; the others are.
  - The `builtin` entry `local` (A5): the local work source itself
    (`AtlasRuntime.Sources.Local`, on its store under `<home>/local-source/`), then its
    puller over `AtlasRuntime.Sources.Local.Target`, renewed in-BEAM. Its puller is
    registered, so the source nudges it when work is added.

  Started by `host/service.exs` after the work core. With no entry it starts nothing
  (`:ignore`), and the Runtime runs as before. A puller that crashes is restarted.
  """
  use Supervisor

  alias AtlasRuntime.Policy
  alias AtlasRuntime.Sources.{HttpTarget, Local, Puller}

  @doc """
  Starts the sources and pullers of the policy in `home`. `opts`: `puller:` options passed
  to each puller, `target:` `{HttpTarget, :open}` options (`cacertfile:` for a test CA; an
  entry's `ca_file` wins over it), `local:` options for
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

        %{"kind" => "remote", "name" => name, "url" => url} = source ->
          open = {HttpTarget, :open, [name, url, home, target(source, home, opts)]}
          [{Puller, Keyword.merge(puller, name: name, open: open)}]
      end)

    # The local source starts before its puller; a puller whose source is down retries.
    Supervisor.init(children, strategy: :one_for_one)
  end

  # A remote entry's `{HttpTarget, :open}` options: the caller's, with the entry's own
  # `ca_file` (under the home) as `cacertfile:` in place of any the caller gave. Without a
  # `ca_file` they are the caller's as given, so the OS store applies unless a test sets one.
  defp target(%{"ca_file" => ca_file}, home, opts),
    do: Keyword.put(Keyword.get(opts, :target, []), :cacertfile, Path.join(home, ca_file))

  defp target(_source, _home, opts), do: Keyword.get(opts, :target, [])
end
