defmodule AtlasFlow.WorkSource.RegisteredTest do
  # IS-Atlas-116: a Runtime installed through Control is admitted by the credential
  # registered on its machinery fact (credential_sha256, runs_for), next to the core
  # secret's, without a restart; and its polls show it linked (runtime_build,
  # runtime_incarnation). Asserted on clients, statuses and stored values.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.Backend.{Listener, Router}
  alias AtlasFlow.{FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.{Configuration, Credentials, Registered}

  @token "token-of-the-new-mac"
  @sha Credentials.token_sha256(@token)

  defp machinery(key, values, links),
    do: %{"key" => key, "values" => values, "links" => links, "version" => 1}

  defp start(read, ttl \\ 10_000) do
    name = :"registered-#{System.unique_integer([:positive])}"
    start_supervised!({Registered, name: name, read: read, ttl: ttl})
    name
  end

  # A read that answers what the test's process dictionary-free agent holds.
  defp facts_read(agent) do
    fn "machinery", %{"linked" => %{}, "plain" => true} ->
      case Agent.get(agent, & &1) do
        :down -> %{"error" => "unavailable"}
        facts -> %{"facts" => facts}
      end
    end
  end

  test "a machinery with a credential digest and one supervisor is a credential" do
    facts = [
      machinery("new-mac", %{"name" => "new-mac", "credential_sha256" => @sha}, %{
        "runs_for" => ["ada"]
      }),
      # No supervisor, a malformed digest, or none at all: no credential.
      machinery("orphan", %{"credential_sha256" => @sha}, %{}),
      machinery("upper", %{"credential_sha256" => String.upcase(@sha)}, %{"runs_for" => ["ada"]}),
      machinery("mini", %{"name" => "mini"}, %{"runs_for" => ["ada"]})
    ]

    assert Registered.from_facts(facts) == %{
             "new-mac" => %{holder: "ada", token_sha256: @sha}
           }
  end

  test "read at most once per ttl; while Facts is down the last ones stay" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    test = self()

    read = fn kind, content ->
      send(test, :read)
      facts_read(agent).(kind, content)
    end

    name = start(read, 50)
    assert Registered.credentials(name) == %{}
    assert_received :read

    # Registered meanwhile: seen once the ttl passed, not before.
    Agent.update(agent, fn _ ->
      [machinery("new-mac", %{"credential_sha256" => @sha}, %{"runs_for" => ["ada"]})]
    end)

    assert Registered.credentials(name) == %{}
    refute_received :read
    Process.sleep(60)
    assert %{"new-mac" => %{holder: "ada"}} = Registered.credentials(name)
    assert Registered.digests(name) == [:crypto.hash(:sha256, @token)]

    Agent.update(agent, fn _ -> :down end)
    Process.sleep(60)
    assert %{"new-mac" => _} = Registered.credentials(name)

    # Cleared: turned away at the next read.
    Agent.update(agent, fn _ -> [] end)
    Process.sleep(60)
    assert Registered.credentials(name) == %{}
  end

  test "without its table there are none" do
    assert Registered.credentials(:no_such_table) == %{}
    assert Registered.digests(:no_such_table) == []
  end

  describe "the listener" do
    defmodule Source do
      @moduledoc "Tells the test who polled."
      def poll(client, _input, opts) do
        send(opts[:test], {:poll, client})

        {:polled,
         %{leases: [], cancel: [], lease_lost: [], timing: %{lease_ttl: 900, poll_max: 25}}}
      end
    end

    defp poll(state, token) do
      body = JSON.encode!(%{"runtime_id" => "x", "offer" => %{}, "holdings" => []})

      Plug.Test.conn(:post, "/v1/poll", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Listener.call(state)
    end

    test "a token the secret does not know is looked up among the registered ones" do
      {:ok, agent} =
        Agent.start_link(fn ->
          [machinery("new-mac", %{"credential_sha256" => @sha}, %{"runs_for" => ["ada"]})]
        end)

      name = start(facts_read(agent))
      static = %{"mini" => %{holder: "bea", token_sha256: Credentials.token_sha256("tok-mini")}}
      router = Router.init(source: Source, source_opts: [test: self()])
      state = %{credentials: static, registered: name, router: router}

      poll(state, @token)
      assert_received {:poll, {"new-mac", "ada"}}

      poll(state, "tok-mini")
      assert_received {:poll, {"mini", "bea"}}

      assert poll(state, "someone-else").status == 401
      refute_received {:poll, _}

      # Without the registered table only the secret's are admitted.
      assert poll(%{state | registered: nil}, @token).status == 401
    end
  end

  describe "linked" do
    setup do
      dir = Path.join(System.tmp_dir!(), "registered-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      L.start(dir)
    end

    test "a poll records the build and incarnation it came from, once each change" do
      FakeFacts.put(Configuration.kind(), %{
        "key" => "new-mac",
        "values" => %{"name" => "new-mac", "credential_sha256" => @sha},
        "version" => 1
      })

      input = L.poll_input("new-mac")
      {:polled, _} = WorkSource.poll({"new-mac", "ada"}, input)
      values = FakeFacts.get(Configuration.kind(), "new-mac")["values"]

      assert %{
               "runtime_build" => "test",
               "runtime_incarnation" => "inc-1",
               "applied_version" => 1
             } =
               values

      version = FakeFacts.get(Configuration.kind(), "new-mac")["version"]
      {:polled, _} = WorkSource.poll({"new-mac", "ada"}, input)
      assert FakeFacts.get(Configuration.kind(), "new-mac")["version"] == version

      {:polled, _} = WorkSource.poll({"new-mac", "ada"}, %{input | incarnation: "inc-2"})

      assert FakeFacts.get(Configuration.kind(), "new-mac")["values"]["runtime_incarnation"] ==
               "inc-2"
    end
  end
end
