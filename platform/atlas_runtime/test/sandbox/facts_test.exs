defmodule AtlasRuntime.Sandbox.FactsTest do
  # S6 package F: AtlasRuntime.Sandbox.Facts through the real helper command. The default
  # binary (test_helper.exs) has no test kind; a second build with -tags s6facts adds kind
  # s6-echo (host/workspace/facts_s6echo.go), which echoes its arguments and stdin.
  # Not async: the echo tests point ATLAS_RUNTIME_EXECUTABLE at that build.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Sandbox.Facts

  setup_all do
    folder = Path.join(System.tmp_dir!(), "s6-facts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)
    echo = Path.join(folder, "atlas-runtime-s6facts")
    host = Path.expand("../../host", __DIR__)

    case System.cmd("go", ["-C", host, "build", "-tags", "s6facts", "-o", echo, "."],
           stderr_to_stdout: true
         ) do
      {_, 0} -> %{echo: echo}
      {output, _} -> raise "Building the s6facts helper failed:\n#{output}"
    end
  end

  defp with_executable(executable, fun) do
    previous = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    System.put_env("ATLAS_RUNTIME_EXECUTABLE", executable)

    try do
      fun.()
    after
      System.put_env("ATLAS_RUNTIME_EXECUTABLE", previous)
    end
  end

  test "an unknown kind raises the helper's refusal" do
    assert_raise RuntimeError, "unknown facts kind: nope", fn -> Facts.fetch("nope", []) end
  end

  test "input reaches a registered kind as JSON on stdin, with the arguments", %{echo: echo} do
    input = %{"names" => ["code.json", "a&b<c>"], "nested" => %{"n" => 1}}

    facts = with_executable(echo, fn -> Facts.fetch("s6-echo", ["/one path", "two"], input) end)

    assert facts["args"] == ["/one path", "two"]
    assert JSON.decode!(facts["stdin"]) == input
  end

  test "without input the kind reads an empty stdin", %{echo: echo} do
    assert with_executable(echo, fn -> Facts.fetch("s6-echo", []) end) ==
             %{"args" => [], "stdin" => ""}
  end

  test "a kind's refusal raises its text", %{echo: echo} do
    assert_raise RuntimeError, "s6-echo refused", fn ->
      with_executable(echo, fn -> Facts.fetch("s6-echo", ["refuse"]) end)
    end
  end

  test "an executable that prints no JSON raises" do
    folder = Path.join(System.tmp_dir!(), "s6-facts-raw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)
    fake = Path.join(folder, "not-json")
    File.write!(fake, "#!/bin/sh\necho not json\n")
    File.chmod!(fake, 0o700)

    assert_raise RuntimeError, "workspace facts any printed no JSON: not json", fn ->
      with_executable(fake, fn -> Facts.fetch("any", []) end)
    end
  end
end
