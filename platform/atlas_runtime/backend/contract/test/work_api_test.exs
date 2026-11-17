defmodule AtlasRuntimeBackend.WorkTest do
  use ExUnit.Case, async: true

  @schema AtlasRuntimeBackend.Work.__schema__()
  @rest hd(@schema.targets)

  test "carries the work boundary, exposing every capability but S5a's frozen reads" do
    assert @schema.boundary == AtlasRuntimeBoundary.Work
    capabilities = for c <- AtlasRuntimeBoundary.Work.__schema__().capabilities, do: c.name
    # S5a P4: not exposed until S5a P11 gives them resources.
    assert @schema.not_exposed == [:get_frozen, :get_frozen_blob]
    assert @schema.exposed == capabilities -- @schema.not_exposed
    assert [%{name: :rest, carries: :entities}] = @schema.targets
  end

  test "§8.1: the socket gets every work right, choose_slot included; TCP never choose_slot" do
    assert @schema.rights == [
             %{listener: :socket, rights: [:submit, :cancel, :read, :read_all, :choose_slot]},
             %{listener: :tcp, rights: [:submit, :cancel, :read, :read_all]}
           ]
  end

  test "§8.1: the TCP ceiling is within the socket's rights and excludes choose_slot" do
    rights = Map.new(@schema.rights, &{&1.listener, &1.rights})

    assert MapSet.subset?(MapSet.new(rights.tcp), MapSet.new(rights.socket))
    refute :choose_slot in rights.tcp
    # Every right a listener names is a client right of the boundary.
    [client_rights] =
      for %{name: :client, fields: fields} <- AtlasRuntimeBoundary.Work.__schema__().models,
          %{name: :rights, type: {:list, {:enum, values}}} <- fields,
          do: values

    for {_listener, list} <- rights, do: assert(list -- client_rights == [])
  end

  test "§8.2: the resources" do
    routes =
      for r <- @rest.resources,
          do: {r.method, r.path, r.capability, r.query, r.headers, r.body}

    assert routes == [
             {:post, "/v1/work", :submit, [], [{"idempotency-key", :client_key}],
              [
                :title,
                :instructions,
                :profile,
                :cost_class,
                :workspace,
                :resume_from,
                :slot,
                :after_check
              ]},
             {:get, "/v1/work/:work_id", :get_work, [], [], nil},
             {:get, "/v1/work", :find_work, [{"key", :client_key}], [], nil},
             {:get, "/v1/work", :list_work,
              [{"state", :state}, {"changed_since", :changed_since}], [], nil},
             {:post, "/v1/work/:work_id/attempts", :retry, [], [], [:resume]},
             {:post, "/v1/work/:work_id/cancel", :cancel, [], [], [:mode, :reason]},
             {:get, "/v1/capacity", :capacity, [], [], nil},
             {:get, "/v1/turns/:turn_id/output", :turn_output, [{"cursor", :cursor}], [], nil}
           ]
  end

  test "§8.3: the status of every outcome, with its headers and problem type" do
    statuses = Map.new(@rest.statuses, &{&1.outcome, {code(&1), &1.headers, &1.body}})

    assert statuses == %{
             accepted: {{201, nil}, [{"location", "/v1/work/{work.work_id}"}], :work},
             # S1: a plain 200, no Idempotent-Replayed.
             existing: {{200, nil}, [], :work},
             at_capacity: {{503, "at-capacity"}, [{"retry-after", :retry_after}], nil},
             refused:
               {{:reason,
                 %{
                   not_permitted: {403, "not-permitted"},
                   conflict: {409, "idempotency-conflict"},
                   invalid: {400, "invalid"},
                   unsupported_workspace: {422, "unsupported-workspace"},
                   policy_forbids: {422, "policy-forbids"},
                   no_permitted_option: {422, "no-permitted-option"},
                   resume_unavailable: {422, "resume-unavailable"}
                 }}, [], nil},
             pruned: {{410, "pruned"}, [], nil},
             not_found: {{404, "not-found"}, [], nil},
             # The body is the work; its attempt's cancel_stage holds the stage.
             cancelling: {{202, nil}, [], :work},
             ended: {{200, nil}, [], :work},
             # S1: no ETag.
             found: {{200, nil}, [], :work},
             works: {{200, nil}, [], nil},
             capacity: {{200, nil}, [{"retry-after", :retry_after}], nil},
             page: {{200, nil}, [], nil}
           }
  end

  test "§8.3: only at_capacity is a 503, and every error has a problem type" do
    codes =
      for s <- @rest.statuses, {code, type} <- codes(s), do: {s.outcome, code, type}

    assert for({outcome, 503, _} <- codes, do: outcome) == [:at_capacity]
    assert for({_outcome, code, nil} <- codes, code >= 400, do: code) == []

    assert Enum.sort(for e <- @rest.errors, do: {e.kind, e.status, e.type}) == [
             {:invalid, 400, "invalid"},
             {:no_route, 404, "no-route"},
             {:not_permitted, 403, "not-permitted"},
             {:origin_refused, 403, "origin-refused"},
             {:unauthenticated, 401, "unauthenticated"}
           ]
  end

  test "§8.4: the event stream" do
    assert [
             %{
               path: "/v1/events",
               capability: :subscribe,
               events: [:work, :capacity, :heartbeat, :reset],
               resume_header: "last-event-id",
               into: :from,
               open: [subscribed: nil, reset: :reset]
             }
           ] = @rest.streams

    assert @schema.events == [
             %{name: :work, model: :work_changed, id: :sequence},
             %{name: :capacity, model: :capacity_available, id: :sequence},
             %{name: :heartbeat, model: :heartbeat, id: nil},
             %{name: :reset, model: :reset, id: :current_sequence}
           ]
  end

  test "depends on the boundary contract and the generator only, never on the model" do
    mix = File.read!(Path.expand("../mix.exs", __DIR__))
    refute mix =~ "atlas_runtime_model"
    refute mix =~ "model/"
    assert mix =~ ~s({:atlas_runtime_boundary, path: "../../boundary/contract"})
  end

  defp code(%{by: nil, status: status, type: type}), do: {status, type}
  defp code(%{by: by, cases: cases}), do: {by, Map.new(cases, &{&1.value, {&1.status, &1.type}})}

  defp codes(%{by: nil, status: status, type: type}), do: [{status, type}]
  defp codes(%{cases: cases}), do: for(c <- cases, do: {c.status, c.type})
end
