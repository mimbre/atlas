defmodule Mix.Tasks.Model.Flows do
  @shortdoc "Print each subflow of the configured model and its states"
  @moduledoc """
      mix model.flows --env prod
      mix model.flows --env test --contract MyModel.Office

  Prints one JSON object: each subflow the composition (`config :rela_dsl, contract:`,
  or `--contract`) runs in that environment, by name, with the names of its states,
  sorted:

      {"letter": ["dropped", "sent", "stuck", "write"]}

  It reads the compiled model (`subflows/1`), so it needs neither rela nor a generated
  file. A run names its subflow and its state, so this is what an update has to keep
  for the runs that are in them.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [env: :string, contract: :string])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    contract = contract!(opts[:contract])

    unless function_exported?(contract, :__rela__, 1),
      do: Mix.raise("#{inspect(contract)} is no composition: it runs no subflows")

    environments = contract.__rela__(:description).environments
    names = Enum.map(environments, &to_string/1)

    env =
      case Enum.find_index(names, &(&1 == opts[:env])) do
        nil -> Mix.raise("--env is one of #{Enum.join(names, ", ")}; got #{inspect(opts[:env])}")
        i -> Enum.at(environments, i)
      end

    flows = Map.new(contract.subflows(env), &{&1.name(), &1.states()})
    Mix.shell().info(JSON.encode!(flows))
  end

  defp contract!(nil) do
    case Application.get_env(:rela_dsl, :contract) do
      nil -> Mix.raise("no contract: set `config :rela_dsl, contract: MyModel`")
      contract -> Code.ensure_loaded!(contract)
    end
  end

  defp contract!(name) do
    module = Module.concat([name])

    case Code.ensure_compiled(module) do
      {:module, ^module} -> module
      {:error, reason} -> Mix.raise("--contract #{name} is #{reason}")
    end
  end
end
