defmodule AtlasAgent.RuntimeAgentTest do
  # IS-Atlas-56, IS-Atlas-65: an agent a Runtime starts (ATLAS_AGENT_ENV and ATLAS_AS set by
  # the Runtime) runs get, actions and do as itself, and Control records its act as that
  # agent; with an identity Control does not know, the same commands fail naming it and the
  # environment, and nothing is read or done as it. ATLAS_* are global: one test at a time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias AtlasAgent.FakeControl

  @kinds [
    %{kind: "agent", title: "Agent", prefix: "AG-", asks: ~w(title), list_title: "Agents"},
    %{
      kind: "widget",
      title: "Widget",
      prefix: "WI-",
      asks: ~w(title description),
      list_title: "Widgets",
      update: true
    }
  ]

  setup do
    saved = for name <- ~w(ATLAS_AS ATLAS_AGENT_ENV), do: {name, System.get_env(name)}

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    control = FakeControl.start(@kinds)
    FakeControl.use_env_file(control)
    agent = FakeControl.put(control, "agent", %{"title" => "dev2"})
    widget = FakeControl.put(control, "widget", %{"title" => "A widget", "description" => "d"})
    System.put_env("ATLAS_AGENT_ENV", "test")
    %{control: control, agent: agent, widget: widget}
  end

  defp atlas(args) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {:status, AtlasAgent.CLI.main(args ++ ["--env", "test"])})
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  test "get, actions and do run as the agent; Control records the act as it", %{
    control: c,
    agent: agent,
    widget: widget
  } do
    System.put_env("ATLAS_AS", agent)

    assert {0, out, ""} = atlas(["get", widget])
    assert out =~ "A widget"

    assert {0, out, ""} = atlas(["actions", widget])
    assert out =~ "label: Update"

    assert {0, _out, ""} = atlas(["do", widget, "Update", "--description", "by the agent"])
    assert FakeControl.fact(c, widget).values["description"] == "by the agent"
    assert [{^agent, %{"endpoint" => "update"}}] = FakeControl.acts(c)
  end

  test "with a wrong identity each command fails, naming it and the environment", %{
    control: c,
    widget: widget
  } do
    System.put_env("ATLAS_AS", "ghost")

    for args <- [
          ["get", widget],
          ["actions", widget],
          ["do", widget, "Update", "--description", "x"]
        ] do
      assert {2, "", err} = atlas(args)
      assert err =~ "ATLAS_AS=ghost is no agent Control test knows", inspect(args)
      assert err =~ "(as ATLAS_AS=ghost, on test)", inspect(args)

      assert {2, out, _} = atlas(args ++ ["--json"])
      assert JSON.decode!(out)["error"] =~ "ATLAS_AS=ghost"
    end

    assert FakeControl.acts(c) == []
    assert FakeControl.fact(c, widget).values["description"] == "d"
  end

  test "an agent its Runtime starts without ATLAS_AS is refused", %{widget: widget} do
    System.delete_env("ATLAS_AS")
    assert {2, "", err} = atlas(["get", widget])
    assert err =~ "needs ATLAS_AS"
  end

  test "a connection failure names the identity and the environment it tried", %{agent: agent} do
    System.put_env("ATLAS_AS", agent)
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    file = Path.join(System.tmp_dir!(), "atlas-closed-#{System.unique_integer([:positive])}.json")

    File.write!(
      file,
      JSON.encode!(%{"env" => "test", "control" => %{"host" => "127.0.0.1", "port" => port}})
    )

    previous = System.get_env("ATLAS_ENV_FILE")
    System.put_env("ATLAS_ENV_FILE", file)

    try do
      assert {2, "", err} = atlas(["get", "WI-01"])
      assert err =~ "Control test does not answer"
      assert err =~ "(as ATLAS_AS=#{agent}, on test)"
    after
      File.rm(file)
      System.put_env("ATLAS_ENV_FILE", previous)
    end
  end
end
