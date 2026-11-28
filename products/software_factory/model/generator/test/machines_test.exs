defmodule RelaDSL.MachinesTest do
  @moduledoc """
  The machines a Runtime runs work on (`machines`): what a composition declares is
  compiled into the root module as plain data, and names that resolve to nothing are refused.
  """
  use ExUnit.Case, async: true

  # A machine with its upgrades, and attempts at jobs that are part of a case.
  @concept """
  type :step, values: [:fetching, :done, :failed]
  entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
    field :name, :string
  end
  entity :run, label: "Run", plural: "runs", id_type: :manual do
    field :flow, :string
    field :state, :string
  end
  entity :input, label: "Input", plural: "inputs", id_type: :manual do
    field :run, :string
  end
  entity :case, label: "Case", plural: "cases", id_type: :manual do
    field :title, :string
  end
  entity :machine, label: "Machine", plural: "machines", id_type: :manual do
    field :config, :string
    field :version, :string
  end
  entity :upgrade, label: "Upgrade", plural: "upgrades", id_type: :manual do
    field :build, :string
    field :step, :step
    field :failed_step, :string
    field :reason, :string
  end
  entity :job, label: "Job", plural: "jobs", id_type: :manual do
    field :outcome, :string
    field :stage, :string
  end
  entity :attempt, label: "Attempt", plural: "attempts", id_type: :manual do
    field :slot, :string
    field :host, :string
    field :started, :string
    field :ended, :string
    field :result, :string
  end
  relation :upgrade_of, label: "upgrade of", from: [:upgrade], to: [:machine], max_outgoing: 1
  relation :job_of, label: "job of", from: [:job], to: [:case], max_outgoing: 1
  relation :ran_on, label: "ran on", from: [:attempt], to: [:machine], max_outgoing: 1
  relation :attempt_of, label: "attempt of", from: [:attempt], to: [:job], max_outgoing: 1
  flow_runtime(runs: :run, writer: [sender: :flow, by: :flow], inputs: :input)
  subflow :case, subject: :case do
    owner default: {:clerk, :desk}
    start :create
    initial :open
    state :open do
      timer :t, "1d", to: :done
    end
    final :done
  end
  """

  @machines [
    kind: :machine,
    configuration: :config,
    policy_version: :version,
    upgrades: [
      kind: :upgrade,
      of: :upgrade_of,
      build: :build,
      step: :step,
      ended: [:done, :failed],
      failed_step: :failed_step,
      reason: :reason
    ],
    attempts: [
      kind: :attempt,
      on: :ran_on,
      of: :attempt_of,
      slot: :slot,
      machine: :host,
      started: :started,
      ended: :ended,
      result: :result
    ],
    work: [of: :job_of, stage: :stage]
  ]

  defp decl(machines), do: "machines(#{inspect(machines) |> String.slice(1..-2//1)})\n"

  defp model(composition) do
    p = "RelaDSL.MachinesTest.M#{System.unique_integer([:positive])}"

    source = """
    defmodule #{p}.Desk do
      use RelaDSL
      #{@concept}
    end
    defmodule #{p}.Mod do
      use RelaDSL.Module, path: "modules/m/schema.yaml", concepts: [#{p}.Desk]
    end
    defmodule #{p}.Comp do
      use RelaDSL.Composition, name: "c"
      schema version: "1.0"
      modules [#{p}.Mod]
      #{composition}
      defcomposition :c do
        subflows([#{p}.Desk])
      end
    end
    """

    modules = Code.compile_string(source, "machines.exs")
    {comp, _} = Enum.find(modules, fn {m, _} -> String.ends_with?(inspect(m), ".Comp") end)
    comp
  end

  defp refused(composition, message) do
    error = assert_raise CompileError, fn -> model(composition) end
    assert error.description =~ message
  end

  test "declared machines are compiled into machines/0, string-keyed; nil without" do
    assert model(decl(@machines)).machines() == %{
             "kind" => "machine",
             "configuration" => "config",
             "policy_version" => "version",
             "upgrades" => %{
               "kind" => "upgrade",
               "of" => "upgrade_of",
               "build" => "build",
               "step" => "step",
               "ended" => ["done", "failed"],
               "failed_step" => "failed_step",
               "reason" => "reason"
             },
             "attempts" => %{
               "kind" => "attempt",
               "on" => "ran_on",
               "of" => "attempt_of",
               "slot" => "slot",
               "machine" => "host",
               "started" => "started",
               "ended" => "ended",
               "result" => "result"
             },
             "work" => %{"of" => "job_of", "stage" => "stage"}
           }

    assert model("").machines() == nil
  end

  test "the machines' names resolve on the schema" do
    up = &Keyword.put(@machines, :upgrades, Keyword.merge(@machines[:upgrades], &1))
    at = &Keyword.put(@machines, :attempts, Keyword.merge(@machines[:attempts], &1))

    for {machines, message} <- [
          {Keyword.put(@machines, :kind, :ghost), "unknown kind: \"ghost\""},
          {Keyword.put(@machines, :configuration, :ghost), "machine: unknown field \"ghost\""},
          {up.(kind: :ghost), "unknown kind: \"ghost\""},
          {up.(reason: :ghost), "upgrade: unknown field \"ghost\""},
          {up.(ended: [:gone]), "upgrade.step: unknown value"},
          {up.(of: :ghost), "unknown relation: \"ghost\""},
          {up.(of: :job_of), "job_of: from does not contain upgrade"},
          {at.(on: :attempt_of), "attempt_of: to does not contain machine"},
          {at.(slot: :ghost), "attempt: unknown field \"ghost\""},
          {at.(of: :ran_on),
           "machines.attempts.of: \"ran_on\" must lead to a kind that has work.of"},
          {Keyword.put(@machines, :work, of: :ghost), "unknown relation: \"ghost\""},
          {Keyword.put(@machines, :work, of: :job_of, stage: :ghost),
           "job: unknown field \"ghost\""},
          {@machines ++ [colour: :red], "machines knows no colour"}
        ] do
      refused(decl(machines), message)
    end
  end

  test "the machines are given once" do
    refused(decl(@machines) <> decl(@machines), "machines is given more than once")
  end

  test "the shell rejects the obsolete assistant option" do
    shell = """
    shell(title: "Desk", tabs: [[id: :cases, label: "Cases", to: "/k/case"]], assistant: :coordinator)
    """

    refused(shell, "shell: unknown keys assistant")
  end

  test "a tab opens /machines only with machines" do
    shell = """
    shell(title: "Desk", tabs: [[id: :machines, label: "Machines", to: "/machines"]])
    """

    refused(shell, "shell.tabs: /machines requires machines")
    assert [%{"to" => "/machines"}] = model(shell <> decl(@machines)).shell(%{})["tabs"]
  end
end
