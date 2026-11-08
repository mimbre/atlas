defmodule AtlasRuntime.Execution.Identity do
  def valid_worker_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, id)

  def string_keys(run), do: Map.new(run, fn {key, value} -> {Atom.to_string(key), value} end)

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, id)
end
