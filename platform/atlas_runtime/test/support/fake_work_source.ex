defmodule AtlasRuntime.Test.WorkSourceFacade do
  @moduledoc """
  The work source contract's in-BEAM Elixir target (`AtlasRuntimeBoundary.WorkSource`,
  M1), generated on `AtlasRuntime.Test.FakeWorkSource`, an in-test source. Test-only: no
  source or puller exists yet (M2/M3).
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.WorkSource,
    implementation: AtlasRuntime.Test.FakeWorkSource
end

defmodule AtlasRuntime.Test.WorkSourceRest do
  @moduledoc "The work source's HTTP routes, generated from the backend contract on the facade."
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contract: AtlasRuntimeBackend.WorkSource,
    facade: AtlasRuntime.Test.WorkSourceFacade
end

defmodule AtlasRuntime.Test.WorkSourceTransport do
  @moduledoc """
  A client transport for the work source's HTTP tests: each request goes through
  `Plug.Test` to `AtlasRuntime.Test.WorkSourceRest`, in the calling process, so it reaches
  the fake source that process uses. `transport: [credential: text]` stands for the
  per-Runtime bearer credential: a known one is the client `{runtime_id, [:lease]}`, a
  missing or unknown one is answered 401 by the listener, before the router runs.
  """
  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  alias AtlasRuntime.Test.{FakeWorkSource, WorkSourceRest}

  @impl true
  def request(request, opts) do
    conn = run(request, opts)
    {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
  end

  @impl true
  def stream(request, opts) do
    conn = run(request, opts)
    # Plug.Test keeps the chunks; they are handed on one by one.
    {:ok, %{status: conn.status, headers: conn.resp_headers, body: [conn.resp_body]}}
  end

  defp run(request, opts) do
    path = if request.query == "", do: request.path, else: request.path <> "?" <> request.query

    conn =
      Enum.reduce(
        request.headers,
        Plug.Test.conn(request.method, path, request.body || ""),
        fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end
      )

    case FakeWorkSource.credential(opts[:credential]) do
      {:ok, runtime_id} ->
        conn
        |> Plug.Conn.assign(:client, {runtime_id, [:lease]})
        |> WorkSourceRest.call(WorkSourceRest.init([]))

      :error ->
        WorkSourceRest.__problem__(:unauthenticated, conn)
    end
  end
end

defmodule AtlasRuntime.Test.WorkSourceClient do
  @moduledoc "The work source contract's HTTP client target, on the in-test transport."
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.WorkSource,
    transport: AtlasRuntime.Test.WorkSourceTransport
end

defmodule AtlasRuntime.Test.FakeWorkSource do
  @moduledoc """
  An in-test work source, the implementation behind `AtlasRuntime.Test.WorkSourceFacade`.
  It keeps the rules of decision §5.2, §5.3 and §6.2 that the M1 tests pin, and nothing
  more (no owner filter, no priorities, no csf_ check):

  - the offer is a total of free slots and the profiles available (Main's O1; each profile
    on the map names that total): at most that many leases in all, first in, first out
    among the works of those profiles;
  - one current lease per work; `poll` renews only current, unexpired holdings and names
    every other one in `lease_lost`; a lease expired for `lease_ttl + grace` is lost and
    its work offered again as a fresh lease;
  - every `report` and `put_blob` is fenced on the current, unexpired lease; an
    `accepted` after the accept deadline loses the lease;
  - reports are idempotent by (lease, revision);
  - `get_blob` serves only blobs the current lease's input names, from this source's own
    store; `put_blob` takes only blobs the lease's recorded `ended` references, and
    answers `too_large` past the per-result or the store cap, also while it reads.

  Each source is an Agent; a process calls the one it set with `use/1`. Time is the
  source's own, in seconds, moved on by `advance/2`.
  """
  use AtlasRuntime.Test.WorkSourceFacade.Implementation

  alias AtlasRuntime.Test.GitBase
  alias AtlasRuntime.Test.WorkSourceFacade, as: F

  @epoch ~U[2026-11-17 12:00:00Z]
  @credentials %{"cred-mini" => "mini", "cred-laptop" => "laptop"}

  ## Test helpers

  @doc """
  Starts a source. Options: `name`, `lease_ttl` (900), `grace` (120), `accept_deadline`
  (30), `poll_max` (25), `result_cap` (20 MB), `store_cap` (200 MB).
  """
  def start(opts \\ []) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          name: Keyword.get(opts, :name, "source"),
          now: 0,
          lease_ttl: Keyword.get(opts, :lease_ttl, 900),
          grace: Keyword.get(opts, :grace, 120),
          accept_deadline: Keyword.get(opts, :accept_deadline, 30),
          poll_max: Keyword.get(opts, :poll_max, 25),
          result_cap: Keyword.get(opts, :result_cap, 20_000_000),
          store_cap: Keyword.get(opts, :store_cap, 200_000_000),
          queue: [],
          leases: %{},
          current: %{},
          next: 1,
          blobs: %{},
          stored_bytes: 0,
          served: [],
          git: GitBase.url()
        }
      end)

    pid
  end

  @doc """
  Where the source's Code serves its bases over Git (`AtlasRuntime.Test.GitBase`): the
  `git` import option of a puller of this source.
  """
  def git(source), do: %{url: Agent.get(source, & &1.git), env: fn -> [] end}

  @doc "The source this process calls from now on."
  def use(source), do: Process.put(__MODULE__, source)

  @doc "The runtime id of a credential, or `:error`."
  def credential(credential), do: Map.fetch(@credentials, credential || "")

  @doc """
  Queues a work (an `offered_work` map, atom keys) and stores the blobs its input names
  (`%{sha256 => bytes}`): its manifests and their write entries' blobs.
  """
  def add_work(source, work, blobs \\ %{}) do
    serve_base(source, work, blobs)

    Agent.update(source, fn s ->
      s = Enum.reduce(blobs, s, fn {sha, bytes}, s -> store(s, sha, bytes) end)
      %{s | queue: s.queue ++ [%{work: work, names: MapSet.new(Map.keys(blobs))}]}
    end)
  end

  # The work's base over Git, as Code serves it: each file its manifest names, from `blobs`.
  defp serve_base(source, %{input: %{base: %{base_id: id, manifest: manifest}}}, blobs)
       when is_binary(:erlang.map_get(manifest, blobs)) do
    files =
      case JSON.decode(blobs[manifest]) do
        {:ok, %{"roots" => roots}} when is_list(roots) ->
          for %{"entries" => entries} when is_list(entries) <- roots,
              %{"kind" => "file", "path" => path, "sha256" => sha} <- entries,
              is_binary(blobs[sha]),
              do: {path, blobs[sha]}

        _ ->
          []
      end

    GitBase.serve(Agent.get(source, & &1.git), id, files)
  end

  defp serve_base(_source, _work, _blobs), do: :ok

  @doc """
  A base of one root `atlas` with `files` (`%{path => content}`), as a source offers it
  (M2 A3): `{manifest, blobs}`, the sha256 of its manifest (the `atlas-base` line the
  Runtime's `workspace base-import` validates) and every blob it names, the manifest
  included, for `add_work/3`.
  """
  def base(files) do
    entries =
      for {path, content} <- Enum.sort(files),
          do: %{
            "path" => path,
            "op" => "write",
            "kind" => "file",
            "mode" => "100644",
            "size" => byte_size(content),
            "sha256" => sha256(content)
          }

    line =
      JSON.encode!(%{
        "format" => "atlas-base",
        "version" => 1,
        "roots" => [%{"root" => "atlas", "entries" => entries}]
      }) <> "\n"

    blobs = Map.new(files, fn {_path, content} -> {sha256(content), content} end)
    {sha256(line), Map.put(blobs, sha256(line), line)}
  end

  @doc """
  Queues `work` (an `offered_work` map without its `input.base`) on a base of `files`
  (`base/1`): its `base` is set to that base, and its blobs stored for its lease (M2 A3:
  the Runtime imports what a lease names).
  """
  def add_base_work(source, work, files \\ %{"README.md" => "base\n"}) do
    {manifest, blobs} = base(files)

    work =
      put_in(work, [:input, :base], %{
        base_id: "base-" <> binary_part(manifest, 0, 12),
        manifest: manifest
      })

    add_work(source, work, blobs)
  end

  @doc "Moves the source's clock on by `seconds`."
  def advance(source, seconds), do: Agent.update(source, &%{&1 | now: &1.now + seconds})

  @doc "Asks for the work's current lease to be cancelled, through the next poll."
  def cancel(source, work_key) do
    Agent.update(source, fn s ->
      case s.current[work_key] do
        nil -> s
        id -> update_in(s.leases[id], &%{&1 | cancel: true})
      end
    end)
  end

  @doc "The blobs this source holds, by sha256."
  def blobs(source), do: Agent.get(source, & &1.blobs)

  @doc "`{lease_id, sha256}` of each blob served, oldest first."
  def served(source), do: Agent.get(source, &Enum.reverse(&1.served))

  @doc "The work's current lease id, or nil."
  def current(source, work_key), do: Agent.get(source, & &1.current[work_key])

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  ## The capabilities

  @impl true
  def poll({runtime_id, _rights}, %F.PollInput{} = input) do
    call(fn s ->
      s = sweep(s)

      {renewed, lost, s} =
        Enum.reduce(input.holdings, {[], [], s}, fn %F.Holding{lease_id: id}, {ok, lost, s} ->
          case live(s, id) do
            {:ok, lease} when lease.runtime_id == runtime_id ->
              {[id | ok], lost, put_in(s.leases[id].expires_at, s.now + s.lease_ttl)}

            _ ->
              {ok, [id | lost], s}
          end
        end)

      cancel = for id <- Enum.reverse(renewed), s.leases[id].cancel, do: id

      # Main's O1: the offer is a total of free slots and the profiles available; each
      # profile on the map names that same total. At most the total is leased, in all,
      # first in, first out among the works of those profiles.
      {total, profiles} = offered(input.offer)

      {leases, s} =
        Enum.reduce(1..total//1, {[], s}, fn _, {leases, s} ->
          case Enum.split_while(s.queue, &(&1.work.profile not in profiles)) do
            {before, [entry | rest]} ->
              {lease, s} = grant(%{s | queue: before ++ rest}, entry, runtime_id)
              {[lease | leases], s}

            {_, []} ->
              {leases, s}
          end
        end)

      outcome =
        F.Outcome.Polled.new!(%{
          leases: Enum.reverse(leases),
          cancel: cancel,
          lease_lost: Enum.reverse(lost),
          timing: %{lease_ttl: s.lease_ttl, poll_max: s.poll_max}
        })

      {outcome, s}
    end)
  end

  @impl true
  def report({runtime_id, _rights}, %F.ReportInput{lease_id: id, revision: revision} = input) do
    call(fn s ->
      s = sweep(s)
      state = state(input.report)

      with {:ok, lease} when lease.runtime_id == runtime_id <- live(s, id),
           :ok <- in_time(s, lease, state) do
        last = length(lease.reports)

        cond do
          revision == last and List.last(lease.reports) == input.report ->
            {recorded(s, lease), s}

          revision == last + 1 and follows?(lease.reports, state) ->
            lease =
              apply_report(%{lease | reports: lease.reports ++ [input.report]}, input.report)

            s = put_in(s.leases[id], lease)
            s = if state in [:refused, :ended], do: release(s, lease), else: s
            {recorded(s, lease), s}

          true ->
            {%F.Outcome.Rejected{reason: :conflict, detail: "revision #{revision} after #{last}"},
             s}
        end
      else
        :late -> {%F.Outcome.LeaseLost{}, lose(s, id)}
        _ -> {%F.Outcome.LeaseLost{}, s}
      end
    end)
  end

  @impl true
  def get_blob({runtime_id, _rights}, %F.GetBlobInput{lease_id: id, sha256: sha}) do
    call(fn s ->
      s = sweep(s)

      with {:ok, lease} when lease.runtime_id == runtime_id <- live(s, id),
           true <- MapSet.member?(lease.names, sha),
           {:ok, bytes} <- Map.fetch(s.blobs, sha) do
        outcome = %F.Outcome.Blob{sha256: sha, size: byte_size(bytes), content: chunks(bytes)}
        {outcome, %{s | served: [{id, sha} | s.served]}}
      else
        _ -> {%F.Outcome.NotFound{}, s}
      end
    end)
  end

  @impl true
  def put_blob({runtime_id, _rights}, %F.PutBlobInput{lease_id: id, sha256: sha} = input) do
    # Checked before a byte is read: fenced, referenced, within the caps.
    checked =
      call(fn s ->
        s = sweep(s)

        with {:lease, {:ok, lease}} when lease.runtime_id == runtime_id <- {:lease, live(s, id)},
             {:ref, true} <- {:ref, MapSet.member?(lease.referenced, sha)},
             room = room(s, lease),
             {:room, true} <- {:room, input.size <= room} do
          {{:ok, room}, s}
        else
          {:lease, _} -> {%F.Outcome.LeaseLost{}, s}
          {:ref, _} -> {%F.Outcome.NotReferenced{}, s}
          {:room, _} -> {%F.Outcome.TooLarge{}, s}
        end
      end)

    case checked do
      {:ok, room} -> receive_blob(id, input, room)
      outcome -> outcome
    end
  end

  # Read in the caller (the bytes are its stream), counting as it goes: never more than
  # the room is read.
  defp receive_blob(id, input, room) do
    read =
      Enum.reduce_while(input.content, {[], 0}, fn chunk, {acc, n} ->
        n = n + byte_size(chunk)
        if n > room, do: {:halt, :too_large}, else: {:cont, {[acc, chunk], n}}
      end)

    case read do
      :too_large ->
        %F.Outcome.TooLarge{}

      {iodata, n} ->
        bytes = IO.iodata_to_binary(iodata)

        if n != input.size or sha256(bytes) != input.sha256 do
          %F.Outcome.Rejected{reason: :digest_mismatch}
        else
          call(fn s ->
            # Fenced again at the write: the lease may have been lost while it streamed.
            case live(s, id) do
              {:ok, _lease} ->
                s = store(s, input.sha256, bytes)
                s = update_in(s.leases[id].result_bytes, &(&1 + n))
                {%F.Outcome.Stored{}, s}

              _ ->
                {%F.Outcome.LeaseLost{}, s}
            end
          end)
        end
    end
  end

  ## Rules

  defp call(fun), do: Agent.get_and_update(Process.get(__MODULE__), fun)

  # The total and the profiles of an offer (O1). The values must agree; the least one is
  # taken if they do not, so a source never leases beyond what the Runtime has free.
  defp offered(offer) when map_size(offer) == 0, do: {0, []}
  defp offered(offer), do: {offer |> Map.values() |> Enum.min(), Map.keys(offer)}

  defp grant(s, entry, runtime_id) do
    id = "#{s.name}-lease-#{s.next}"

    lease = %{
      id: id,
      work: entry.work,
      names: entry.names,
      runtime_id: runtime_id,
      offered_at: s.now,
      expires_at: s.now + s.lease_ttl,
      accepted: false,
      lost: false,
      done: false,
      cancel: false,
      reports: [],
      referenced: MapSet.new(),
      result_bytes: 0,
      entry: entry
    }

    wire = %{
      lease_id: id,
      expires_at: DateTime.add(@epoch, lease.expires_at),
      work: entry.work
    }

    {wire,
     %{
       s
       | next: s.next + 1,
         leases: Map.put(s.leases, id, lease),
         current: Map.put(s.current, entry.work.work_key, id)
     }}
  end

  # The lease if it is its work's current one and has not expired.
  defp live(s, id) do
    case s.leases[id] do
      %{lost: false} = lease ->
        if s.current[lease.work.work_key] == id and s.now < lease.expires_at,
          do: {:ok, lease},
          else: :lost

      _ ->
        :lost
    end
  end

  # An accepted after the accept deadline loses the lease (§5.3 item 1).
  defp in_time(s, lease, :accepted) do
    if s.now - lease.offered_at > s.accept_deadline, do: :late, else: :ok
  end

  defp in_time(_s, _lease, _state), do: :ok

  defp follows?([], state), do: state in [:accepted, :refused]

  defp follows?(reports, state) do
    case {state(List.last(reports)), state} do
      {:accepted, s} -> s in [:started, :ended]
      {:started, :ended} -> true
      _ -> false
    end
  end

  defp apply_report(lease, %F.Accepted{}), do: %{lease | accepted: true}

  defp apply_report(lease, %F.Ended{change_set: change_set}) do
    referenced =
      for %{entries: entries} <- (change_set && change_set.roots) || [],
          %{op: :write, sha256: sha} when is_binary(sha) <- entries,
          into: MapSet.new(),
          do: sha

    %{lease | referenced: referenced}
  end

  defp apply_report(lease, _report), do: lease

  defp recorded(s, lease) do
    missing =
      case List.last(lease.reports) do
        %F.Ended{} -> lease.referenced |> Enum.reject(&Map.has_key?(s.blobs, &1)) |> Enum.sort()
        _ -> []
      end

    %F.Outcome.Recorded{missing: missing}
  end

  # A refused or ended lease is done: its work is not offered again.
  defp release(s, lease), do: put_in(s.leases[lease.id].done, true)

  # Lost: no longer current, and its work goes back to the queue for a fresh lease.
  defp lose(s, id) do
    lease = s.leases[id]
    s = put_in(s.leases[id].lost, true)
    s = %{s | current: Map.delete(s.current, lease.work.work_key)}
    if lease.done, do: s, else: %{s | queue: s.queue ++ [lease.entry]}
  end

  # Leases past their accept deadline without an accepted, or expired for lease_ttl +
  # grace, are lost; their work is offered again.
  defp sweep(s) do
    Enum.reduce(s.leases, s, fn {id, lease}, s ->
      cond do
        lease.lost or lease.done -> s
        not lease.accepted and s.now - lease.offered_at > s.accept_deadline -> lose(s, id)
        s.now >= lease.expires_at + s.grace -> lose(s, id)
        true -> s
      end
    end)
  end

  defp room(s, lease), do: min(s.result_cap - lease.result_bytes, s.store_cap - s.stored_bytes)

  defp store(s, sha, bytes) do
    if Map.has_key?(s.blobs, sha),
      do: s,
      else: %{
        s
        | blobs: Map.put(s.blobs, sha, bytes),
          stored_bytes: s.stored_bytes + byte_size(bytes)
      }
  end

  defp state(%F.Accepted{}), do: :accepted
  defp state(%F.Refused{}), do: :refused
  defp state(%F.Started{}), do: :started
  defp state(%F.Ended{}), do: :ended

  # The bytes in chunks of at most 4 KiB, made only as they are read.
  defp chunks(bytes) do
    Stream.unfold(bytes, fn
      "" -> nil
      <<chunk::binary-size(4096), rest::binary>> -> {chunk, rest}
      rest -> {rest, ""}
    end)
  end
end

defmodule AtlasRuntime.Test.FakeSourceTarget do
  @moduledoc """
  The puller's target (`AtlasRuntime.Sources.Puller.Target`) and `Upload`'s on the in-test
  source (M2 plan A2): `AtlasRuntime.Sources.InBeamTarget` on
  `AtlasRuntime.Test.WorkSourceFacade`, each call made with the source set in the calling
  process (a puller's poll runs in a task of its own).

  A test may set a hook per call (`hook/3`, `:poll`, `:report` or `:get_blob`): a function of the real
  call (zero-arity) and the input, answering what the puller gets. So a test fails polls,
  delays an answer while it moves the clock on, or loses a report. `calls/2` lists the inputs
  each call was made with, oldest first.
  """
  @behaviour AtlasRuntime.Sources.Puller.Target
  @behaviour AtlasRuntime.Sources.Upload

  alias AtlasRuntime.Sources.InBeamTarget
  alias AtlasRuntime.Test.FakeWorkSource

  @doc "The target `{module, ref}` on `source`, calling as `runtime` (`{id, [:lease]}`)."
  def new(source, runtime \\ {"mini", [:lease]}) do
    {:ok, hooks} = Agent.start_link(fn -> %{hooks: %{}, calls: []} end)

    {__MODULE__,
     %{source: source, facade: AtlasRuntime.Test.WorkSourceFacade, client: runtime, hooks: hooks}}
  end

  @doc "Sets (or with nil, clears) the hook of `call`."
  def hook({__MODULE__, %{hooks: hooks}}, call, fun),
    do: Agent.update(hooks, &put_in(&1.hooks[call], fun))

  @doc "The inputs `call` was made with, oldest first."
  def calls({__MODULE__, %{hooks: hooks}}, call),
    do: Agent.get(hooks, fn s -> for {^call, input} <- Enum.reverse(s.calls), do: input end)

  @impl AtlasRuntime.Sources.Puller.Target
  def poll(ref, input), do: hooked(ref, :poll, input, fn -> InBeamTarget.poll(ref, input) end)

  @impl AtlasRuntime.Sources.Puller.Target
  def send_report(ref, input),
    do: hooked(ref, :report, input, fn -> InBeamTarget.send_report(ref, input) end)

  @impl AtlasRuntime.Sources.Puller.Target
  def uploader(ref, revision), do: {__MODULE__, Map.put(ref, :revision, revision)}

  @impl AtlasRuntime.Sources.Puller.Target
  def get_blob(ref, lease_id, sha256),
    do:
      hooked(ref, :get_blob, {lease_id, sha256}, fn ->
        InBeamTarget.get_blob(ref, lease_id, sha256)
      end)

  @impl AtlasRuntime.Sources.Upload
  def report(ref, report) do
    FakeWorkSource.use(ref.source)
    InBeamTarget.report(ref, report)
  end

  @impl AtlasRuntime.Sources.Upload
  def put_blob(ref, blob) do
    FakeWorkSource.use(ref.source)
    InBeamTarget.put_blob(ref, blob)
  end

  defp hooked(%{source: source, hooks: hooks}, call, input, real) do
    FakeWorkSource.use(source)

    hook =
      Agent.get_and_update(hooks, &{&1.hooks[call], %{&1 | calls: [{call, input} | &1.calls]}})

    if hook, do: hook.(real, input), else: real.()
  end
end
