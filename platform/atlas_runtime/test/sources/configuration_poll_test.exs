defmodule AtlasRuntime.Sources.ConfigurationPollTest do
  @moduledoc """
  IS-Atlas-27 over the puller: a configuration the source serves in a poll answer is
  applied within that poll, without a restart (the next poll carries its version, the
  executor resolves under it and the operations' policy view shows it); one the Runtime
  refuses leaves the policy as it was and is reported with every later poll until another
  one is applied. A poll carries no `configuration_refused` while there is none.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.{Policy, Work}
  alias AtlasRuntime.Sources.Puller
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source

  @moduletag capture_log: true

  @name "flow-test"

  @source %{
    "name" => @name,
    "kind" => "remote",
    "url" => "https://flow-test.example/",
    "credential_file" => "sources/flow-test/token",
    "priority" => 1,
    "max_slots" => 2,
    "max_store_bytes" => 2_147_483_648
  }

  setup do
    bench = start!(%{"sources" => [@source]})
    source = Source.start(name: @name)
    Source.use(source)
    target = FakeSourceTarget.new(source)

    puller =
      start_supervised!(
        {Puller, name: @name, target: target, tick: :manual, polling: :manual},
        id: make_ref()
      )

    %{bench: bench, target: target, puller: puller}
  end

  # The bench's policy as Control would set it: `changes` merged in.
  defp document(dir, changes) do
    {:ok, policy} = Policy.load(dir)
    JSON.encode!(Map.merge(policy, changes))
  end

  # The next answer carries `document`, once.
  defp serve(target, document) do
    {:ok, once} = Agent.start_link(fn -> document end)

    FakeSourceTarget.hook(target, :poll, fn call, _input ->
      {:polled, polled} = call.()
      {:polled, Map.put(polled, :configuration, Agent.get_and_update(once, &{&1, nil}))}
    end)
  end

  defp last_poll(target), do: target |> FakeSourceTarget.calls(:poll) |> List.last()

  test "a served configuration applies within the poll, without a restart", ctx do
    dir = ctx.bench.dir
    assert :polled = Puller.poll_now(ctx.puller)
    assert last_poll(ctx.target).policy_version == 1
    refute Map.has_key?(last_poll(ctx.target), :configuration_refused)

    {:ok, policy} = Policy.load(dir)
    option = %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-test"}
    profiles = put_in(policy["profiles"], ["light_work", "options"], [option])
    sources = [%{@source | "priority" => 7}]

    serve(
      ctx.target,
      document(dir, %{"version" => 2, "profiles" => profiles, "sources" => sources})
    )

    work = Process.whereis(AtlasRuntime.Work.Server)
    assert is_pid(work)
    assert :polled = Puller.poll_now(ctx.puller)

    # The same core, now under version 2.
    assert Process.whereis(AtlasRuntime.Work.Server) == work
    assert Work.runtime().policy_version == 2
    assert [%{"priority" => 7}] = Policy.sources(Policy.load(dir))

    assert %{version: 2, profiles: [%{profile: "light_work", options: [%{harness: "claude"}]}]} =
             Policy.view(Policy.load(dir), %{}, ["claude"], 0)

    assert :polled = Puller.poll_now(ctx.puller)
    assert last_poll(ctx.target).policy_version == 2
    refute Map.has_key?(last_poll(ctx.target), :configuration_refused)
  end

  test "a refused configuration keeps the policy and is reported until one applies", ctx do
    dir = ctx.bench.dir
    before = File.read!(Policy.path(dir))
    serve(ctx.target, document(dir, %{"version" => 3, "slots" => []}))
    assert :polled = Puller.poll_now(ctx.puller)

    assert File.read!(Policy.path(dir)) == before
    assert Work.runtime().policy_version == 1

    refused = %{
      version: 3,
      reason: "invalid: slots must be a non-empty list of distinct worker names"
    }

    # Reported with every poll, the source serving it again or not.
    assert :polled = Puller.poll_now(ctx.puller)
    assert last_poll(ctx.target).configuration_refused == refused
    assert last_poll(ctx.target).policy_version == 1
    assert :polled = Puller.poll_now(ctx.puller)
    assert last_poll(ctx.target).configuration_refused == refused

    serve(ctx.target, document(dir, %{"version" => 4}))
    assert :polled = Puller.poll_now(ctx.puller)
    assert Work.runtime().policy_version == 4
    assert :polled = Puller.poll_now(ctx.puller)
    refute Map.has_key?(last_poll(ctx.target), :configuration_refused)
    assert last_poll(ctx.target).policy_version == 4
  end
end
