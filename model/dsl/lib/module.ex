defmodule RelaDSL.Module do
  @moduledoc """
  A module of a model: concepts that go together into one Rela file, which a
  composition includes or leaves out as a whole.

      defmodule MyModel.Post do
        use RelaDSL.Module,
          path: "modules/post/schema.yaml",
          concepts: [MyModel.Letter, MyModel.Clerk]
      end

  The file holds the concepts' types, then their entities, then their relations, each
  in the order the concepts are listed. A module may also hold the description's
  root constructs (`RelaDSL.Description`) that belong to it as a whole. It gets
  `__rela__(:module)`.
  """

  defmacro __using__(opts) do
    quote do
      use RelaDSL.Description, :root
      @rela_module unquote(opts)
      @before_compile RelaDSL.Module
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :rela_module)
    unknown = Keyword.keys(opts) -- [:path, :concepts]

    problem =
      cond do
        unknown != [] ->
          "use RelaDSL.Module knows no #{Enum.join(unknown, ", ")} (only path:, concepts:)"

        not is_binary(opts[:path]) ->
          "a module needs path: its file in the Rela project"

        not match?([_ | _], opts[:concepts]) ->
          "a module needs concepts: the modules that use RelaDSL"

        true ->
          nil
      end

    if problem, do: raise(CompileError, file: env.file, line: 1, description: problem)

    data = %{
      module: env.module,
      file: env.file,
      path: opts[:path],
      concepts: opts[:concepts],
      items: RelaDSL.Description.items(env.module)
    }

    quote do
      @doc "The module, as plain data: `__rela__(:module)`."
      def __rela__(:module), do: unquote(Macro.escape(data))
    end
  end
end
