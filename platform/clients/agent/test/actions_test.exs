defmodule AtlasAgent.ActionsTest do
  use ExUnit.Case, async: false

  setup do
    saved = for name <- ~w(ATLAS_AS ATLAS_ENV_FILE), do: {name, System.get_env(name)}
    System.delete_env("ATLAS_AS")

    file =
      Path.join(System.tmp_dir!(), "atlas-actions-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(file)

      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    File.write!(
      file,
      JSON.encode!(%{"env" => "test", "control" => %{"host" => "127.0.0.1", "port" => port}})
    )

    System.put_env("ATLAS_ENV_FILE", file)
    %{listener: listener}
  end

  @item %{
    "type" => "item",
    "props" => %{
      "title" => "Widget W-1",
      "fields" => [],
      "actions" => [%{"label" => "Pick up", "key" => "p", "to" => "/k/widget/W-1/pick_up/R-1"}]
    }
  }

  test "do follows an offered action to its confirm and submits it, as the TUI's user", %{
    listener: listener
  } do
    call = %{"endpoint" => "pick_up", "params" => %{"kind" => "widget", "key" => "W-1"}}

    peer =
      control(listener, fn socket ->
        assert %{"op" => "hello", "client" => "tui"} = hello = receive_line(socket)
        refute Map.has_key?(hello, "as")
        welcome(socket)
        assert receive_line(socket) == %{"op" => "open", "to" => "/k/_/W-1"}
        page(socket, "open", "/k/widget/W-1", [@item])
        assert receive_line(socket) == %{"op" => "open", "to" => "/k/widget/W-1/pick_up/R-1"}

        confirm = %{
          "type" => "confirm",
          "props" => %{
            "title" => "Pick up W-1?",
            "text" => "W-1",
            "cancel_to" => "/k/widget/W-1",
            "confirm_to" => call
          }
        }

        page(socket, "open", "/k/widget/W-1/pick_up/R-1", [confirm])

        assert receive_line(socket) ==
                 %{
                   "op" => "submit",
                   "endpoint" => "pick_up",
                   "params" => call["params"],
                   "values" => %{}
                 }

        page(socket, "stored", "/k/widget/W-1", [@item])
      end)

    {status, stdout} = cli(["do", "W-1", "Pick up"])
    assert status == 0

    assert stdout =~
             "W-1\nitem:\n  title: Widget W-1\n  actions:\n    - label: Pick up\n      key: p\n"

    Task.await(peer)
  end

  test "do fills a form from --<input> options; an agent stays an agent", %{listener: listener} do
    System.put_env("ATLAS_AS", "coordinator")
    call = %{"endpoint" => "link", "params" => %{"key" => "W-1"}}

    form = %{
      "type" => "form",
      "props" => %{
        "title" => "Hand to…",
        "submit_label" => "Save",
        "submit_to" => call,
        "inputs" => [
          %{"name" => "to", "label" => "To", "kind" => "choice", "value" => "ada"},
          %{"name" => "note", "label" => "Note", "kind" => "multiline"}
        ]
      }
    }

    peer =
      control(listener, fn socket ->
        assert %{"client" => "agent", "as" => "coordinator"} = receive_line(socket)
        welcome(socket)
        assert %{"to" => "/k/_/W-1"} = receive_line(socket)

        page(socket, "open", "/k/widget/W-1", [
          put_in(@item["props"]["actions"], [%{"label" => "Hand to…", "key" => "h", "to" => "/h"}])
        ])

        assert %{"to" => "/h"} = receive_line(socket)
        page(socket, "open", "/h", [form])

        assert %{"endpoint" => "link", "values" => %{"to" => "bob", "note" => ""}} =
                 receive_line(socket)

        page(socket, "stored", "/k/widget/W-1", [@item])
      end)

    {status, stdout} = cli(["do", "W-1", "h", "--to", "bob", "--json"])
    assert status == 0
    assert %{"path" => "/k/widget/W-1", "blocks" => [@item]} = JSON.decode!(stdout)
    Task.await(peer)
  end

  defp cli(args) do
    parent = self()

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        send(parent, {:status, AtlasAgent.CLI.main(args ++ ["--env", "test"])})
      end)

    assert_received {:status, status}
    {status, stdout}
  end

  defp control(listener, script) do
    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)

      try do
        script.(socket)
      after
        :gen_tcp.close(socket)
      end
    end)
  end

  defp welcome(socket) do
    send_line(socket, %{
      "op" => "welcome",
      "env" => "test",
      "spec" => AtlasAgent.Protocol.version()
    })

    page(socket, "open", "/", [])
  end

  defp page(socket, reason, path, blocks),
    do:
      send_line(socket, %{
        "op" => "page",
        "reason" => reason,
        "path" => path,
        "title" => List.last(String.split(path, "/")),
        "blocks" => blocks,
        "markup" => []
      })

  defp receive_line(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    JSON.decode!(line)
  end

  defp send_line(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])
end
