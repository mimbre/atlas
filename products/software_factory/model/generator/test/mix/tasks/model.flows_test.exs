defmodule Mix.Tasks.Model.FlowsTest do
  # Sets the shell, so not async.
  use ExUnit.Case

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp flows(args), do: Mix.Tasks.Model.Flows.run(["--contract", "RelaDSL.Office" | args])

  test "prints each subflow of the environment with its states, as JSON" do
    for env <- ~w(prod test) do
      flows(["--env", env])
      assert_received {:mix_shell, :info, [json]}
      assert JSON.decode!(json) == %{"letter" => ~w(dropped sent stuck write)}
    end
  end

  test "an environment the model does not declare is refused" do
    assert_raise Mix.Error, ~r/--env is one of prod, test; got "staging"/, fn ->
      flows(["--env", "staging"])
    end

    assert_raise Mix.Error, ~r/--env is one of prod, test; got nil/, fn -> flows([]) end
  end
end
