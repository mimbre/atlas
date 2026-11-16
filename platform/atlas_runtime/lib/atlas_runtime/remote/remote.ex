defmodule AtlasRuntime.Remote do
  @moduledoc """
  The core's client of a Runtime backend on another machine (design
  2026-11-16-runtime-backend §1.8, §9, §10; S3 plan B9-B12, P6). Its calls are generated at
  compile time from the backend contract `AtlasRuntimeBackend.Work` by
  `AtlasRuntimeBackend.Generator.Targets.Client`, so their routes, statuses and values are the
  server's own. They travel through `AtlasRuntime.Remote.Transport`, configured by
  `AtlasRuntime.Remote.Config` (only with `ATLAS_RUNTIME_REMOTE=1`).

  Each call answers a typed outcome (see the generator), never retries, and keeps these
  apart: `{:error, :unreachable}`, `{:error, :unauthenticated}` (401), `:not_found` (404),
  `{:pruned, fields}` (410) and `{:at_capacity, fields}` (503 `at-capacity`, with
  `retry_after`). A caller's `client_key` is sent as `Idempotency-Key` only when the caller
  gives one. What to do with an answer (backlog, resubmitting with the same key, resume) is
  the caller's (§10). `subscribe/2` streams in the calling process.

  A request names a `repository` workspace, never a folder: a token never holds
  `choose_path`, so the backend refuses a folder (`not_permitted`), and the works it
  returns carry no path on its machine (D44).
  """

  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.Work,
    transport: AtlasRuntime.Remote.Transport

  alias AtlasRuntime.Remote.Config

  @doc """
  One read-only `GET /v1/capacity`, to check that the backend is reachable and this token
  is accepted. It never submits. Answers `{:ok, capacity}`, `{:error, :not_configured}`
  when `ATLAS_RUNTIME_REMOTE` is off, or the call's typed error (`:unreachable`,
  `:unauthenticated`, `:not_permitted`, ...).
  """
  def probe(opts \\ []) do
    if Config.configured?() do
      case capacity(opts) do
        {:capacity, capacity} -> {:ok, capacity}
        {:error, _} = error -> error
      end
    else
      {:error, :not_configured}
    end
  end
end
