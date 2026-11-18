defmodule AtlasE2E.Pull.Scenario do
  @moduledoc """
  What a pull-e2e scenario file (`pull/scenarios/NN-*.exs`) evaluates to: its id, title,
  the subjects it works on (seeded before the core starts, `AtlasE2E.Pull.Seed`), its needs
  (`AtlasE2E.Pull.Needs`), the tree packages it requires, and its body, a function of the
  run's context. The body is a list of steps (`step/3`), each with its worst-case budget
  from the plan (§10); every wait inside is capped by what is left of it.
  """
  defstruct [:id, :title, :file, :run, subjects: [], needs: [], requires: []]

  def scenario(id, title, opts, run) when is_function(run, 1) do
    %__MODULE__{
      id: id,
      title: title,
      run: run,
      subjects: opts[:subjects] || [id],
      needs: opts[:needs] || [],
      requires: opts[:requires] || []
    }
  end

  @doc "One step: its name, its budget in seconds, and what it does and checks."
  defdelegate step(name, seconds, fun), to: AtlasE2E.Pull.Bench, as: :within

  defmodule Failure do
    defexception [:message]
  end

  @doc "Fail the step unless `ok?`; `what` names the structural check, `got` what was seen."
  def check!(ok?, what, got \\ nil) do
    unless ok?,
      do:
        raise(Failure,
          message:
            "#{what}" <>
              if(got == nil, do: "", else: ": #{inspect(got, limit: 30, printable_limit: 2_000)}")
        )

    :ok
  end

  # The verdict environment_too_slow (exit 4): a timing the environment, not the product, missed.
  defmodule TooSlow do
    defexception [:message]
  end

  @doc "Load the scenario files under `dir` whose id or file name contains one of `filters`."
  def load(dir, filters) do
    files = Path.wildcard(Path.join(dir, "*.exs")) |> Enum.sort()

    for file <- files,
        {scenario, _} = Code.eval_file(file),
        filters == [] or
          Enum.any?(filters, &(scenario.id == &1 or String.contains?(Path.basename(file), &1))) do
      %{scenario | file: file}
    end
  end
end
