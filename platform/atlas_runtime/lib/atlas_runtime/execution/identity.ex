defmodule AtlasRuntime.Execution.Identity do
  # A slot (worker) id never starts with `work-`: `<home>/workers/work-<work_id>` is the work
  # folder of a `base` or `from_work` work (design §3.9 RQ7; s5a-plan B6, F21).
  def valid_worker_id?(id),
    do:
      is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, id) and
        not String.starts_with?(id, "work-")

  def string_keys(run), do: Map.new(run, fn {key, value} -> {Atom.to_string(key), value} end)

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, id)
end
