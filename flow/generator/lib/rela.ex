defmodule AtlasFlowGenerator.Rela do
  @moduledoc """
  The Rela target: subflows, as `__flows__/0` gives them, written as Rela 26.11.2's
  `flows.yaml`; and the state diagram of each, as Rela draws it.

  ## flows.yaml

  All subflows go into one file, because Rela reads one `flows.yaml`. Only keys from
  Rela's flows format are written; what Rela has no key for (the owner, the channel,
  the mechanism behind a state) stays out, for the Atlas target.

  The style is fixed and part of the contract: Rela's flow version hashes the YAML,
  including scalar style (quoting one label changes it; a comment does not). So:
  block mappings for flows and states, flow mappings for branches and timers, plain
  scalars where that is certainly safe, `when` always double-quoted. The golden file
  `test/golden/example.flows.yaml` pins it; changing it gives every flow a new
  version and needs an ADR note.

  ## The project Rela checks against

  Rela checks a `flows.yaml` only inside a project, against its `schema.yaml` and
  `acl.yaml`. Until the Rela description (`rela/`) has the fields the subflows read
  and write (slice 4 of the Flow DSL design adds them, and switches the check to the
  real `rela/` description), `check_project/1` derives a small scratch project from
  the subflows themselves: each subject type with the properties the subflows read in
  `when` or set, every role a branch names, and `run_as` mapped to a role that may
  update the subjects. Rela then checks what the description cannot yet: that each
  `when` compiles, that outputs name properties, that roles exist and `run_as` has
  the grants, and the timers. It does not yet check the properties against the real
  schema.

  ## Diagrams

  `diagram/1` turns what `rela flow show <name> -o json` gives into a Markdown page
  with the Mermaid state diagram in a fenced block, so a change to a flow shows its
  diagram in the pull request.
  """

  @doc "The subflows as the body of `flows.yaml` (without the generated header)."
  def flows_yaml(flows), do: "flows:\n" <> Enum.map_join(flows, "", &flow/1)

  defp flow(f) do
    "  #{f.name}:\n" <>
      opt("    label", f.label) <>
      "    subject: #{f.subject}\n" <>
      opt("    run_as", f.run_as) <>
      "    per_subject: #{f.per_subject}\n" <>
      "    start:\n" <>
      Enum.map_join(f.start, "", &start/1) <>
      "    initial: #{f.initial}\n" <>
      "    states:\n" <> Enum.map_join(f.states, "", &state/1)
  end

  defp start(s) do
    [{k0, v0} | rest] =
      [on: s.on] ++
        if(s.when, do: [when: {:qq, s.when}], else: []) ++
        if(s.permission, do: [permission: s.permission], else: []) ++
        if(s.every, do: [every: {:q, s.every}], else: [])

    "      - #{k0}: #{scalar(v0)}\n" <>
      Enum.map_join(rest, "", fn {k, v} -> "        #{k}: #{scalar(v)}\n" end)
  end

  defp state(s) do
    "      #{s.name}:\n" <>
      opt("        label", s.label) <>
      if(s.final, do: "        final: true\n", else: "") <>
      if(s.status, do: "        status: #{s.status}\n", else: "") <>
      if(s.waiting_for != [],
        do: "        waiting_for: #{scalar({:list, s.waiting_for})}\n",
        else: ""
      ) <>
      outputs(s) <> branches(s) <> timers(s)
  end

  defp outputs(%{set: [], creates: []}), do: ""

  defp outputs(s) do
    set = if s.set == [], do: [], else: ["          - set: " <> inline(properties: s.set) <> "\n"]

    creates =
      for c <- s.creates do
        "          - create:\n" <>
          "              type: #{c.type}\n" <>
          "              properties: " <>
          inline(Enum.map(c.properties, fn {k, v} -> {k, {:q, v}} end)) <>
          "\n" <>
          if(c.relate, do: "              relate: " <> inline(type: c.relate) <> "\n", else: "")
      end

    "        outputs:\n" <> Enum.join(set ++ creates)
  end

  defp branches(%{branches: []}), do: ""

  defp branches(s) do
    "        on:\n          change:\n" <>
      Enum.map_join(s.branches, "", fn b ->
        kv =
          [to: b.to] ++
            if(b.roles != [], do: [roles: {:list, b.roles}], else: []) ++
            if(b.label, do: [label: {:q, b.label}], else: []) ++
            if(b.when, do: [when: {:qq, b.when}], else: [])

        "            - " <> inline(kv) <> "\n"
      end)
  end

  defp timers(%{timers: []}), do: ""

  defp timers(s) do
    "        after:\n" <>
      Enum.map_join(s.timers, "", fn t ->
        kv =
          [period: t.period, to: t.to] ++
            if(t.since, do: [since: t.since], else: []) ++
            if(t.label, do: [label: {:q, t.label}], else: [])

        "          #{t.name}: " <> inline(kv) <> "\n"
      end)
  end

  defp opt(_key, nil), do: ""
  defp opt(key, value), do: "#{key}: #{scalar({:q, value})}\n"

  defp inline(kv),
    do: "{ " <> Enum.map_join(kv, ", ", fn {k, v} -> "#{k}: #{scalar(v)}" end) <> " }"

  # Plain only where that is certainly safe in a YAML flow mapping; double-quoted
  # (JSON escaping is valid YAML) otherwise.
  @plain ~r/^[A-Za-z][A-Za-z0-9 '.;:-]*[A-Za-z0-9.]$/
  @reserved ~w(true false yes no on off null y n)

  defp scalar({:q, v}) do
    v = to_string(v)

    if Regex.match?(@plain, v) and String.downcase(v) not in @reserved and
         not String.contains?(v, [": ", " #"]),
       do: v,
       else: JSON.encode!(v)
  end

  defp scalar({:qq, v}), do: JSON.encode!(to_string(v))
  defp scalar({:list, vs}), do: "[" <> Enum.join(vs, ", ") <> "]"
  defp scalar(kv) when is_list(kv), do: inline(kv)
  defp scalar(v), do: to_string(v)

  # -- The scratch project Rela checks against (until slice 4) ---------------------

  @runner "flow-runner"
  @read ~r/entity\.([a-z][a-z0-9_]*)(?:\s*[!=]=\s*(true|false)\b)?/

  @doc """
  The `schema.yaml` and `acl.yaml` of a small project in which Rela can check and
  draw `flows`, as `[{file, body}]`. Derived from the subflows only; see the moduledoc.
  """
  def check_project(flows) do
    subjects = for f <- flows, do: {f.subject, subject_properties(f)}
    creates = for f <- flows, s <- f.states, c <- s.creates, do: {f.subject, c}
    created = for {_, c} <- creates, do: {c.type, Enum.map(c.properties, &typed/1)}
    types = Enum.reduce(subjects ++ created, [], &add_type/2)
    generated = creates |> Enum.map(&elem(&1, 1).type) |> Enum.uniq()
    relations = for {subject, c} <- creates, c.relate, uniq: true, do: {c.relate, c.type, subject}

    [
      {"schema.yaml", schema(types, generated, relations)},
      {"acl.yaml", acl(flows, Enum.map(types, &elem(&1, 0)))}
    ]
  end

  # The properties a subflow reads in `when` or sets: [{name, :string | :boolean}].
  defp subject_properties(f) do
    whens = Enum.map(f.start, & &1.when) ++ for(s <- f.states, b <- s.branches, do: b.when)

    read =
      for w <- whens, w, [_, field | bool] <- Regex.scan(@read, w) do
        {String.to_atom(field), if(bool in [["true"], ["false"]], do: :boolean, else: :string)}
      end

    Enum.reduce(read ++ for(s <- f.states, p <- s.set, do: typed(p)), [], &add_property/2)
  end

  defp typed({k, v}) when is_boolean(v), do: {k, :boolean}
  defp typed({k, _}), do: {k, :string}

  defp add_type({type, props}, types) do
    case List.keyfind(types, type, 0) do
      nil ->
        types ++ [{type, Enum.reduce(props, [], &add_property/2)}]

      {_, old} ->
        List.keyreplace(types, type, 0, {type, Enum.reduce(props, old, &add_property/2)})
    end
  end

  # A property is boolean only when every use of it is.
  defp add_property({k, t}, props) do
    case List.keyfind(props, k, 0) do
      nil -> props ++ [{k, t}]
      {_, ^t} -> props
      _ -> List.keyreplace(props, k, 0, {k, :string})
    end
  end

  # Types a flow creates need generated ids; a created subject relates to the subject
  # that created it.
  defp schema(types, generated, relations) do
    entities =
      types
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {{type, props}, i} ->
        ids =
          if type in generated,
            do: "    id_type: short\n    id_prefix: T#{i}-\n",
            else: "    id_type: manual\n"

        "  #{type}:\n    label: #{type}\n    plural: #{type}s\n" <>
          ids <>
          if(props == [],
            do: "",
            else:
              "    properties:\n" <>
                Enum.map_join(props, "", fn {k, t} -> "      #{k}: {type: #{t}}\n" end)
          )
      end)

    "version: '1.0'\niri: https://example.org/flow-check#\nentities:\n" <>
      entities <>
      if(relations == [],
        do: "",
        else:
          "relations:\n" <>
            Enum.map_join(relations, "", fn {name, from, to} ->
              "  #{name}:\n    from: [#{from}]\n    to: [#{to}]\n"
            end)
      )
  end

  # Every role a branch names may read all and change the types; `run_as` maps to one
  # more role that may.
  defp acl(flows, types) do
    roles =
      Enum.uniq(
        for f <- flows,
            s <- f.states,
            r <- s.waiting_for ++ Enum.flat_map(s.branches, & &1.roles),
            do: r
      )

    grant =
      "    read: [\"*\"]\n    create: [#{Enum.join(types, ", ")}]\n    update: [#{Enum.join(types, ", ")}]\n"

    runners = flows |> Enum.map(& &1.run_as) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    "roles:\n" <>
      Enum.map_join([@runner | roles -- [@runner]], "", &"  #{&1}:\n#{grant}") <>
      if(runners == [],
        do: "",
        else: "assignments:\n" <> Enum.map_join(runners, "", &"  #{&1}: #{@runner}\n")
      )
  end

  # -- Running Rela ---------------------------------------------------------------

  @version "rela version 26.11.2"

  @doc """
  Runs the pinned Rela `binary` on `flows_yaml` (the file's exact bytes) in a scratch
  project built by `check_project(flows)`, in a temporary folder removed afterwards.
  Returns `{:ok, shown}`, `shown` being what `rela flow show <name> -o json` gives
  for each subflow, in order; or `{:error, message}` with Rela's own words when the
  binary is not 26.11.2 or `rela flow validate` refuses the file.
  """
  def check(binary, flows_yaml, flows) do
    case version(binary) do
      @version -> in_project(flows_yaml, flows, &validate_and_show(binary, &1, flows))
      other -> {:error, "expected #{@version} at #{binary}, got #{other}"}
    end
  end

  defp version(binary) do
    {out, _status} = System.cmd(binary, ["version"], stderr_to_stdout: true)
    String.trim(out)
  rescue
    e in ErlangError -> "an error: #{inspect(e.original)}"
  end

  defp in_project(flows_yaml, flows, fun) do
    dir = Path.join(System.tmp_dir!(), "atlas-flow-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      for {file, body} <- [{"flows.yaml", flows_yaml} | check_project(flows)],
          do: File.write!(Path.join(dir, file), body)

      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp validate_and_show(binary, dir, flows) do
    case System.cmd(binary, ["--project", dir, "--quiet", "flow", "validate"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Enum.reduce_while(flows, {:ok, []}, fn f, {:ok, shown} ->
          case show(binary, dir, f.name) do
            {:ok, one} -> {:cont, {:ok, shown ++ [one]}}
            error -> {:halt, error}
          end
        end)

      {out, _} ->
        {:error, "rela flow validate refused flows.yaml:\n" <> without_logs(out)}
    end
  end

  defp show(binary, dir, name) do
    args = ["--project", dir, "--quiet", "-o", "json", "flow", "show", to_string(name)]
    {out, status} = System.cmd(binary, args, stderr_to_stdout: true)

    with 0 <- status,
         json when json != nil <-
           Enum.find(String.split(out, "\n"), &String.starts_with?(&1, "{")),
         {:ok, shown} <- JSON.decode(json) do
      {:ok, shown}
    else
      _ -> {:error, "rela flow show #{name} failed:\n" <> without_logs(out)}
    end
  end

  # Rela logs (time=… level=…) go to stderr next to its findings; keep the findings.
  defp without_logs(out) do
    out
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^time=\S+ level=(DEBUG|INFO|WARN) /))
    |> Enum.join("\n")
    |> String.trim()
  end

  # -- Diagrams -------------------------------------------------------------------

  @doc """
  The diagram page of one subflow (without the generated header), from what
  `rela flow show <name> -o json` gives: `name`, `label`, `version` and `mermaid`.
  """
  def diagram(%{"name" => name, "label" => label, "version" => version, "mermaid" => mermaid}) do
    """
    # #{label} (`#{name}`)

    The state diagram as `rela flow show #{name}` draws it. Rela flow version: `#{version}`.

    ```mermaid
    #{String.trim_trailing(mermaid)}
    ```
    """
  end
end
