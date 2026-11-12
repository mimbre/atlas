defmodule AtlasFlowGenerator.Runtime do
  @moduledoc """
  How a running component reads the generated `flows.json`: at compile time, so a
  release carries the data it was built with and no file is read while it runs.

      defmodule MyApp.Flows do
        use AtlasFlowGenerator.Runtime, target: "../../flow/targets/atlas/flows.json"
      end

  `target` is relative to the file that uses it. The module gets

    * `flows/0` and `gates/0`: the file's `flows` and `gates`, by name, with string
      keys and values as written (`AtlasFlowGenerator.Atlas`);
    * `rela_flows_sha256/0`: the hash of the `flows.yaml` generated with it;
    * `check_rela_flows/1`: `:ok` when the given `flows.yaml` bytes are that file,
      otherwise `{:error, reason}`. A runner calls it on the deployed `flows.yaml`
      and refuses to start on an error, so the two targets are never used out of step.

  The module recompiles when the file changes. A file of another format or writer,
  or one that is not JSON, fails the compile.
  """

  @format 2
  @writer "system:atlas-flow"

  defmacro __using__(opts) do
    target = Keyword.fetch!(opts, :target)
    path = Path.expand(target, Path.dirname(__CALLER__.file))

    data =
      case read(path) do
        {:ok, data} ->
          data

        {:error, reason} ->
          raise CompileError, file: __CALLER__.file, line: __CALLER__.line, description: reason
      end

    quote do
      @external_resource unquote(path)

      @doc "The subflows of the generated target, by name."
      def flows, do: unquote(Macro.escape(data["flows"]))

      @doc "The gates of the generated target, by name."
      def gates, do: unquote(Macro.escape(data["gates"]))

      @doc "The SHA-256 of the flows.yaml generated with the target."
      def rela_flows_sha256, do: unquote(data["rela_flows_sha256"])

      @doc "`:ok` when `flows_yaml` is the flows.yaml generated with the target."
      def check_rela_flows(flows_yaml),
        do: AtlasFlowGenerator.Runtime.check_rela_flows(rela_flows_sha256(), flows_yaml)
    end
  end

  @doc "Reads a generated `flows.json`: `{:ok, data}` without its header key, or `{:error, reason}`."
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = data} <- JSON.decode(text),
         %{"format" => @format, "writer" => @writer, "rela_flows_sha256" => sha} <- data,
         true <- is_binary(sha) and is_map(data["flows"]) and is_map(data["gates"]) do
      {:ok, Map.delete(data, "_generated")}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{path}: cannot read it (#{:file.format_error(reason)})"}

      _ ->
        {:error,
         "#{path} is not a flows.json of format #{@format} by #{@writer}; run `mix atlas.flow.gen`"}
    end
  end

  @doc "`:ok` when `flows_yaml` hashes to `sha256`, otherwise `{:error, reason}`."
  def check_rela_flows(sha256, flows_yaml) do
    case AtlasFlowGenerator.Atlas.sha256(flows_yaml) do
      ^sha256 ->
        :ok

      other ->
        {:error,
         "flows.yaml (sha256 #{other}) is not the one generated with flows.json " <>
           "(rela_flows_sha256 #{sha256}); deploy both from the same run"}
    end
  end
end
