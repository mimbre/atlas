defmodule AtlasE2E.Pull.Seed do
  @moduledoc """
  The facts each scenario's work comes from, written into rela before the core's first
  start: one issue per scenario, its package (with instructions, so its run moves on to
  `authoring` at once), both Assignments, and the machinery the packages are handed to.

  Why straight into rela: a package, its fields and a machinery are Flow's alone
  (`set_by: [:flow]`, `by_hand(false)`; `Model.Package`, `Model.Machinery`), and on develop
  nothing outside Flow makes one yet (an Architect's plan comes with F4). Facts reads rela,
  and Flow's first round at boot admits every subject that has no run yet (`AtlasFlow.
  Runs.Store`, admission `[]` for both kinds), so the core starts with them as it would
  with ones Flow made. Each write is rela's own create; a shape rela refuses fails the
  setup with rela's answer.

  The keys follow the model's: `IS-Atlas-9<nn>`, `PK-<issue>-1`, `AS-<key>`; the author
  task Flow makes is `TK-<package>-1`, its attempts `TA-<task>-<n>`. The package's `title`
  carries the scenario's token (`pe-<scenario>`): Flow appends the title to the work's
  instructions (`activities/task.ex`), which is how the stub knows which scenario it is in.
  """

  @machinery "pe-bench"

  def machinery, do: @machinery

  @doc "The subjects of `scenarios` (ids such as `s1`, `s5a`): `%{id => subject}`."
  def plan(ids) do
    ids
    |> Enum.with_index(1)
    |> Map.new(fn {id, n} ->
      issue = "IS-Atlas-9#{String.pad_leading("#{n}", 2, "0")}"
      package = "PK-#{issue}-1"
      token = "pe-#{id}"

      {id,
       %{
         id: id,
         token: token,
         issue: issue,
         issue_title: "pull-e2e #{token} issue",
         package: package,
         title: "Build #{token}",
         task: "TK-#{package}-1"
       }}
    end)
  end

  @doc "Write the machinery and every subject into rela at `url` (`…/api/v1`)."
  def write!(url, subjects) do
    create!(url, "machineries", @machinery, %{"name" => @machinery}, %{})

    for {_id, s} <- Enum.sort(subjects) do
      create!(url, "assignments", "AS-" <> s.issue, %{"of" => s.issue}, %{})

      create!(url, "issues", s.issue, %{"title" => s.issue_title}, %{
        "assignment" => {"assignment", ["AS-" <> s.issue]}
      })

      create!(url, "assignments", "AS-" <> s.package, %{"of" => s.package}, %{
        "assigned_to" => {"machinery", [@machinery]}
      })

      create!(
        url,
        "packages",
        s.package,
        %{
          "title" => s.title,
          "instructions" => "Make the edits your gate gives you (#{s.token}).",
          "acceptance" => "The bench's assertions hold."
        },
        %{
          "package_of" => {"issue", [s.issue]},
          "assignment" => {"assignment", ["AS-" <> s.package]}
        }
      )
    end

    :ok
  end

  @doc false
  def body(key, props, targets) do
    relations =
      Map.new(targets, fn {relation, {kind, keys}} ->
        {relation, %{"data" => Enum.map(keys, &%{"type" => kind, "id" => &1})}}
      end)

    if relations == %{},
      do: %{"id" => key, "properties" => props},
      else: %{"id" => key, "properties" => props, "relations" => relations}
  end

  defp create!(url, plural, key, props, targets) do
    request =
      {String.to_charlist("#{url}/#{plural}"), [{~c"accept", ~c"application/json"}],
       ~c"application/json", JSON.encode!(body(key, props, targets))}

    case :httpc.request(:post, request, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in [200, 201] ->
        :ok

      {:ok, {{_, status, _}, _, answer}} ->
        raise "rela refused the seed #{plural}/#{key} (#{status}): #{answer}"

      {:error, reason} ->
        raise "rela did not answer the seed #{plural}/#{key}: #{inspect(reason)}"
    end
  end
end
