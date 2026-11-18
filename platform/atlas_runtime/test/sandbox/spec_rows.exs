defmodule AtlasRuntime.SpecRows do
  @moduledoc false
  # S6 package A2e: runs one row of test/fixtures/s6/spec/ through AtlasRuntime.Sandbox.Spec,
  # set up as the Go test sets it up (host/host/s6_render_parity_test.go setUpSpecRow; defaults
  # in test/fixtures/s6/spec/README.md). The facts come from the real helper
  # (`workspace facts launch`) run under the row's environment; the decision itself is pure.
  # Shared by spec_parity_test.exs and spec_security_test.exs (loaded with Code.require_file).

  alias AtlasRuntime.S6Fixture
  alias AtlasRuntime.Sandbox.{Facts, Spec}

  @tables ["codex.json", "claude.json", "codex_sandbox.json", "runtime_home.json"]

  def dir, do: Path.join(S6Fixture.dir(), "spec")

  def table_paths, do: Enum.map(@tables, &Path.join(dir(), &1))

  @doc "Every decision row, in table order: {table, row}."
  def rows do
    for path <- table_paths(),
        row <- S6Fixture.load_table!(path)["rows"],
        do: {Path.basename(path), row}
  end

  @doc "The Elixir rows (not legacy-only)."
  def elixir_rows, do: for({_, row} = entry <- rows(), not Map.has_key?(row, "elixir"), do: entry)

  @doc """
  Builds the row, fetches its facts under its environment and decides. Returns a map with the
  concrete `places`, `input`, `facts`, the concrete `result` and the abstracted `got`
  (`%{"spec" => spec}` or `%{"error" => text}`, the shape of the row's expect).
  """
  def run(row, overrides \\ %{}) do
    {places, input, environment} = set_up(row)
    facts = with_env(environment, fn -> Facts.fetch("launch", [], Spec.facts_input(input)) end)

    facts =
      if is_binary(input["platform"]),
        do: Map.put(facts, "platform", input["platform"]),
        else: facts

    facts = Map.merge(facts, overrides)
    places = abstraction(places, input, facts)
    result = decide(input, facts)

    got =
      case result do
        {:ok, spec} -> %{"spec" => abstract(places, spec)}
        {:error, text} -> %{"error" => abstract(places, text)}
      end

    %{places: places, input: input, facts: facts, result: result, got: got}
  end

  def decide(%{"decision" => "agent"} = input, facts), do: Spec.build(input, facts)

  def decide(%{"decision" => "codex_sandbox", "kind" => kind} = input, facts)
      when kind in ["setup", "pre_exec"],
      do: Spec.codex_sandbox(String.to_existing_atom(kind), input, facts)

  @doc "The row's expect parts that the Elixir decision produces."
  def want(row), do: Map.take(row["expect"], ["spec", "error"])

  # Set-up (setUpSpecRow)

  defp set_up(row) do
    root = outside_system_temp!()
    places = S6Fixture.default_places(root)
    raw = row["input"] || %{}
    length = raw["temporary_bytes"] || 40
    suffix = byte_size("/claude-" <> uid())
    if length < suffix + 2, do: raise("temporary_bytes #{length} is too short")
    places = Map.put(places, "temporary", "/" <> String.duplicate("t", length - suffix - 1))

    case S6Fixture.build(root, places, Map.get(row, "fs", [])) do
      :ok -> :ok
      {:error, text} -> raise "row #{row["id"]}: #{text}"
    end

    for dir <- [places["home"], places["user"], Path.join(root, "bin"), Path.join(root, "systmp")],
        File.lstat(dir) == {:error, :enoent},
        do: File.mkdir_p!(dir)

    environment =
      %{
        "HOME" => "{user}",
        "ATLAS_RUNTIME_HOME" => "{home}",
        "PATH" => "{tmp}/bin",
        "TMPDIR" => "{tmp}/systmp",
        "CODEX_HOME" => "",
        "CLAUDE_CONFIG_DIR" => ""
      }
      |> Map.merge(row["env"] || %{})
      |> Map.new(fn {name, value} -> {name, S6Fixture.substitute(places, value)} end)

    input = S6Fixture.substitute_value(places, raw)
    input = Map.put_new(input, "temporary", places["temporary"])

    # input.code_json is written as {home}/code.json after substitution.
    if Map.has_key?(input, "code_json") do
      path = Path.join(places["home"], "code.json")
      File.write!(path, JSON.encode!(input["code_json"]))
      File.chmod!(path, 0o600)
    end

    # The rebind marker and preparation result of a folder are named by the hash of its path
    # (snapshot.RebindMarker, snapshot.PreparationResult).
    for marker <- input["create_markers"] || [] do
      scope = input["scope"]
      path = marker_path(marker, scope["home"], scope["root"])
      File.mkdir_p!(Path.dirname(path))
      File.chmod!(Path.dirname(path), 0o700)
      File.write!(path, "{}\n")
      File.chmod!(path, 0o600)
    end

    {places, input, environment}
  end

  @doc "Where the helper puts a folder's marker: rebinds/<sha256>/done, preparations/<sha256>/result.json."
  def marker_path("rebind", home, root), do: Enum.join([home, "rebinds", hash(root), "done"], "/")

  def marker_path("preparation", home, root),
    do: Enum.join([home, "preparations", hash(root), "result.json"], "/")

  defp hash(root), do: Base.encode16(:crypto.hash(:sha256, root), case: :lower)

  defp uid do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid)
  end

  @doc "Runs fun with the environment applied (an empty value unsets), then restores it."
  def with_env(environment, fun) do
    previous = Map.new(environment, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(environment, &put_env/1)

    try do
      fun.()
    after
      Enum.each(previous, &put_env/1)
    end
  end

  defp put_env({name, value}) when value in [nil, ""], do: System.delete_env(name)
  defp put_env({name, value}), do: System.put_env(name, value)

  # A canonical root outside the system temp roots: Claude refuses projects inside them
  # (outsideSystemTemp, host/host/host_test.go:385).
  defp outside_system_temp! do
    root = S6Fixture.new_root!()
    system = Enum.map(["/tmp", "/var/tmp"], &physical/1)

    if Enum.any?(system, &String.starts_with?(root, &1 <> "/")) do
      home = physical(System.user_home!())
      root = Path.join(home, ".atlas-s6-test-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
      root
    else
      root
    end
  end

  defp physical(path) do
    {resolved, 0} = System.cmd("/bin/sh", ["-c", ~S(cd -P "$1" && pwd), "sh", path])
    String.trim(resolved)
  end

  # Abstraction (specPlaces.abstract): the placeholders, Claude rule paths "(/{name}", the
  # {sha256:<path>} of a folder, and the system temp roots {/tmp} and {/var/tmp}.

  defp abstraction(places, input, facts) do
    system =
      for path <- ["/tmp", "/var/tmp"],
          do: {"{" <> path <> "}", facts["resolved"][path]["resolved"]}

    hashes =
      case {input["create_markers"], input["scope"]} do
        {[_ | _], %{"root" => root}} ->
          [{"{sha256:" <> S6Fixture.abstract(places, root) <> "}", hash(root)}]

        _ ->
          []
      end

    %{places: places, system: system, hashes: hashes}
  end

  def abstract(%{places: places, system: system, hashes: hashes}, value) do
    places
    |> S6Fixture.abstract_value(value)
    |> map_strings(fn string ->
      string = abstract_rules(places, string)

      string =
        Enum.reduce(hashes, string, fn {token, hex}, s -> String.replace(s, hex, token) end)

      Enum.reduce_while(system, string, fn {token, resolved}, s ->
        if s == resolved,
          do: {:halt, token},
          else: {:cont, String.replace(s, ~s("#{resolved}"), ~s("#{token}"))}
      end)
    end)
  end

  defp abstract_rules(places, string) do
    names =
      ["tmp", "home", "user", "temporary"]
      |> Enum.sort_by(&(-byte_size(places[&1])))

    abstract_rules(string, places, names, [])
  end

  defp abstract_rules(<<>>, _places, _names, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp abstract_rules("(/" <> rest = string, places, names, acc) do
    match =
      Enum.find(names, fn name ->
        value = places[name]
        size = byte_size(value)

        value != "" and String.starts_with?(rest, value) and
          (byte_size(rest) == size or not name_byte?(:binary.at(rest, size)))
      end)

    case match do
      nil ->
        <<byte, tail::binary>> = string
        abstract_rules(tail, places, names, [<<byte>> | acc])

      name ->
        tail =
          binary_part(rest, byte_size(places[name]), byte_size(rest) - byte_size(places[name]))

        abstract_rules(tail, places, names, ["(/{" <> name <> "}" | acc])
    end
  end

  defp abstract_rules(<<byte, tail::binary>>, places, names, acc),
    do: abstract_rules(tail, places, names, [<<byte>> | acc])

  defp name_byte?(b), do: b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b in [?., ?_, ?-]

  defp map_strings(value, f) when is_binary(value), do: f.(value)
  defp map_strings(value, f) when is_list(value), do: Enum.map(value, &map_strings(&1, f))

  defp map_strings(value, f) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, map_strings(item, f)} end)

  defp map_strings(value, _f), do: value
end
