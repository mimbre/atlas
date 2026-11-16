defmodule AtlasRuntime.Sandbox.Facts do
  @moduledoc """
  Raw facts from the native helper: `atlas-runtime workspace facts KIND ARG...` (S6, B4).

  The helper inspects (lstat, realpath, `git rev-parse`, snapshot verification) and decides
  nothing; the `AtlasRuntime.Sandbox` decision modules decide on what `fetch/3` returns and
  do no filesystem I/O themselves. Where a fact depends on a list of names, the list is
  `input`, written as JSON on the helper's stdin, so the helper holds no copy of it.
  """

  # Ports cannot close a child's stdin alone, so the input goes through a private file that
  # /bin/sh redirects; stderr is kept apart from the JSON on stdout the same way.
  @redirect ~S(input=$1; errors=$2; shift 2; exec "$@" 2>"$errors" <"$input")

  @doc """
  Runs the facts kind with `args` and, when `input` is not nil, `input` as JSON on stdin
  (otherwise stdin is empty). Returns the decoded JSON result. Raises with the helper's
  message when it exits non-zero, and when it prints no JSON.
  """
  def fetch(kind, args, input \\ nil) when is_binary(kind) and is_list(args) do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    dir = private_dir!()

    try do
      stdin = stdin!(dir, input)
      errors = Path.join(dir, "stderr")
      argv = ["-c", @redirect, "sh", stdin, errors, executable, "workspace", "facts", kind | args]

      case System.cmd("/bin/sh", argv) do
        {output, 0} ->
          case JSON.decode(output) do
            {:ok, facts} -> facts
            {:error, _} -> raise "workspace facts #{kind} printed no JSON: #{String.trim(output)}"
          end

        {_, status} ->
          case errors |> File.read!() |> String.trim() do
            "" -> raise "workspace facts #{kind} exited with status #{status}"
            message -> raise message
          end
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp stdin!(_dir, nil), do: "/dev/null"

  defp stdin!(dir, input) do
    path = Path.join(dir, "stdin")
    File.write!(path, JSON.encode!(input))
    path
  end

  defp private_dir! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "atlas-facts-#{suffix}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end
end
