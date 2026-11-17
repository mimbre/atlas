defmodule AtlasCodeBoundary.Generator.ContractFirstTest do
  # The implementation is checked against the generated behaviour when a project
  # compiles: a missing capability, or one with another arity, fails compilation. First
  # through `use F.Implementation` (a @before_compile check while the implementation
  # compiles), and as a backstop through the facade's @after_verify. Each case compiles in
  # an `elixirc` of its own, as a project would, without --warnings-as-errors.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @contract """
  defmodule Neutral.Contract do
    use AtlasCodeBoundary.Generator.Schema
    version "1"

    defmodel :ask do
      field :q, :string, required: true
    end

    defcapability :answer, input: :ask, outcomes: [said: :ask], right: :talk
    defcapability :ping, outcomes: [pong: nil], right: :talk
  end
  """

  @facade """
  defmodule Neutral.Facade do
    use AtlasCodeBoundary.Generator.Targets.Boundary,
      contract: Neutral.Contract,
      implementation: Neutral.Impl
  end
  """

  @answer "def answer(_client, %Neutral.Facade.Ask{q: q}), do: %Neutral.Facade.Outcome.Said{q: q}"

  test "a complete implementation compiles, and may use the generated structs", %{tmp_dir: dir} do
    assert {_out, 0} =
             compile(dir, """
             @behaviour Neutral.Facade.Implementation
             #{@answer}
             def ping(_client), do: %Neutral.Facade.Outcome.Pong{}
             """)
  end

  test "a missing capability fails compilation", %{tmp_dir: dir} do
    assert {out, status} = compile(dir, "@behaviour Neutral.Facade.Implementation\n#{@answer}")
    assert status != 0

    assert out =~
             "facade.ex:2: Neutral.Impl does not implement capability ping/1 of Neutral.Facade.Implementation"
  end

  test "a capability with another arity fails compilation", %{tmp_dir: dir} do
    assert {out, status} =
             compile(dir, """
             @behaviour Neutral.Facade.Implementation
             #{@answer}
             def ping(_client, _extra), do: %Neutral.Facade.Outcome.Pong{}
             """)

    assert status != 0
    assert out =~ "does not implement capability ping/1 (it has ping/2)"
  end

  test "an implementation that does not declare the behaviour fails compilation", %{tmp_dir: dir} do
    assert {out, status} =
             compile(dir, "#{@answer}\ndef ping(_client), do: %Neutral.Facade.Outcome.Pong{}")

    assert status != 0
    assert out =~ "Neutral.Impl does not declare @behaviour Neutral.Facade.Implementation"
  end

  test "a missing implementation module fails compilation", %{tmp_dir: dir} do
    assert {out, status} = compile(dir, nil)
    assert status != 0
    assert out =~ "implementation Neutral.Impl is not available"
  end

  @use "use Neutral.Facade.Implementation"

  describe "use Neutral.Facade.Implementation" do
    test "a complete implementation compiles, with @behaviour added", %{tmp_dir: dir} do
      assert {_out, 0} =
               compile(
                 dir,
                 "#{@use}\n#{@answer}\ndef ping(_client), do: %Neutral.Facade.Outcome.Pong{}"
               )

      assert Neutral.Facade.Implementation in behaviours(dir)
    end

    test "a missing capability fails at the use line", %{tmp_dir: dir} do
      assert {out, status} = compile(dir, "#{@use}\n#{@answer}")
      assert status != 0

      assert out =~
               "impl.ex:2: Neutral.Impl does not implement capability ping/1 of Neutral.Facade.Implementation"
    end

    test "a capability with another arity fails at the use line", %{tmp_dir: dir} do
      assert {out, status} =
               compile(dir, """
               #{@use}
               #{@answer}
               def ping(_client, _extra), do: %Neutral.Facade.Outcome.Pong{}
               """)

      assert status != 0
      assert out =~ "impl.ex:2: Neutral.Impl does not implement capability ping/1 (it has ping/2)"
    end

    # Only the implementation recompiles, as in an incremental build where the facade is
    # unchanged: the facade's @after_verify does not run, so only the use's own
    # @before_compile check can fail it.
    test "fails the implementation's own compilation, without the facade", %{tmp_dir: dir} do
      assert {_out, 0} =
               compile(
                 dir,
                 "#{@use}\n#{@answer}\ndef ping(_client), do: %Neutral.Facade.Outcome.Pong{}"
               )

      File.write!(
        Path.join(dir, "impl.ex"),
        "defmodule Neutral.Impl do\n#{@use}\n#{@answer}\nend\n"
      )

      assert {out, status} = elixirc(dir, ["-pa", "ebin", "impl.ex"])
      assert status != 0
      assert out =~ "impl.ex:2: Neutral.Impl does not implement capability ping/1"
    end

    test "takes no options", %{tmp_dir: dir} do
      assert {out, status} =
               compile(dir, "#{@use}, strict: false\n#{@answer}\ndef ping(_c), do: nil")

      assert status != 0
      assert out =~ "use Neutral.Facade.Implementation takes no options"
    end
  end

  defp behaviours(dir) do
    {:ok, {_, [attributes: attributes]}} =
      :beam_lib.chunks(String.to_charlist(Path.join(dir, "ebin/Elixir.Neutral.Impl.beam")), [
        :attributes
      ])

    attributes |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  defp compile(dir, implementation) do
    File.write!(Path.join(dir, "contract.ex"), @contract)
    File.write!(Path.join(dir, "facade.ex"), @facade)
    files = ["contract.ex", "facade.ex"]

    files =
      if implementation do
        File.write!(
          Path.join(dir, "impl.ex"),
          "defmodule Neutral.Impl do\n#{implementation}\nend\n"
        )

        files ++ ["impl.ex"]
      else
        files
      end

    File.mkdir_p!(Path.join(dir, "ebin"))
    elixirc(dir, files)
  end

  defp elixirc(dir, args) do
    System.cmd(
      System.find_executable("elixirc"),
      ["-pa", Mix.Project.compile_path(), "-o", "ebin" | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end
end
