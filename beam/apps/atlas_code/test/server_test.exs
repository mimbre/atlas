defmodule AtlasCode.ServerTest do
  # Not async: it traps SIGTERM in the test VM and reads ATLAS_CODE_HOME.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup {AtlasCode.TestDir, :tmp_dir}

  test "serve/1 starts Code for the home, owns it and prints the ready line", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    File.mkdir!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"port" => 0, "repositories" => %{}})
    )

    token = Path.join(home, "runtime.token")
    File.write!(token, "runtime-secret-token\n")
    File.chmod!(token, 0o600)

    output =
      capture_io(fn ->
        {:ok, pid, port} = AtlasCode.Server.serve(home)
        send(self(), {:served, pid, port})
      end)

    assert_received {:served, pid, port}

    on_exit(fn ->
      System.untrap_signal(:sigterm, :atlas_code)
      AtlasCode.stop(pid)
    end)

    assert output == "Code ready on 127.0.0.1:#{port}\n"
    assert File.exists?(Path.join([home, "service.owner", "owner.json"]))

    assert {:ok, {{_, 401, _}, _, _}} =
             :httpc.request(:get, {~c"http://127.0.0.1:#{port}/v1/health", []}, [ssl: []], [])

    assert :ok = AtlasCode.stop(pid)
    refute File.exists?(Path.join(home, "service.owner"))
  end

  test "run/0 refuses to start without ATLAS_CODE_HOME" do
    previous = System.get_env("ATLAS_CODE_HOME")
    System.delete_env("ATLAS_CODE_HOME")
    on_exit(fn -> if previous, do: System.put_env("ATLAS_CODE_HOME", previous) end)

    assert_raise RuntimeError, ~r/ATLAS_CODE_HOME/, fn -> AtlasCode.Server.run() end
  end
end
