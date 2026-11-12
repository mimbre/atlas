defmodule Mix.Tasks.Atlas.Gates.Evaluate do
  @shortdoc "Asks a gate for its verdict on evidence and records it once"
  @moduledoc """
  Evaluates a gate on an evidence file, records the verdict through Control and prints it
  with its key. The coordinator runs it where it used to record a verdict by hand:

      cd beam/apps/atlas_gates && mix atlas.gates.evaluate --gate NAME --subject KEY \\
        --fingerprint FPR --evidence-file /abs/evidence.json --env test \\
        [--allowed a,b] [--link about=KEY] [--link follows=KEY] [--atlas EXECUTABLE] [--json] [--no-record]

  Use `--gate NAME --from-subject KEY --env test` to derive evidence and fingerprint
  from stored facts. This also links the verdict about its subject and to its predecessor.

  The evidence file is one JSON object of named fields; its digest (`sha256:` of the file
  as it is) is recorded with it, so keep the file. `--env` (`test` or `prod`) is the
  environment whose Control the `atlas` client writes to. Asking the same again (same
  gate, subject, fingerprint and evidence) prints the verdict recorded the first time and
  records nothing.

  With `--no-record`, evaluates and settles without writing a verdict. File evidence
  needs no environment or connection; `--from-subject` still reads through Control and
  needs `--env`. The printed `recorded` and `recorded_as` values are null.

  Exit status 0 when the verdict is recorded (or evaluated with `--no-record`); 2 when it could not be evaluated or recorded:
  then the printed verdict is the gate's safe one, and nothing may act as if it passed.
  """
  use Mix.Task

  alias AtlasGates.{Request, Verdict}
  alias AtlasBus.Digest

  @switches [
    gate: :string,
    gate_version: :string,
    subject: :string,
    from_subject: :string,
    fingerprint: :string,
    evidence_file: :string,
    allowed: :string,
    link: :keep,
    env: :string,
    atlas: :string,
    json: :boolean,
    no_record: :boolean
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("Unknown arguments: #{inspect(rest ++ invalid)}")

    env = opts[:env]

    if (opts[:no_record] != true or is_binary(opts[:from_subject])) and
         env not in ["test", "prod"],
       do: Mix.raise("Give --env test or --env prod")

    # No app.start: the umbrella runtime config belongs to deployed nodes.
    Mix.Task.run("loadconfig")
    Mix.Task.run("compile")
    facts = AtlasGates.Facts.Control.new(env || "test", executable: opts[:atlas] || "atlas")

    request =
      if opts[:from_subject] do
        if Enum.any?(
             [:subject, :fingerprint, :evidence_file, :link, :allowed, :gate_version],
             &Keyword.has_key?(opts, &1)
           ),
           do:
             Mix.raise(
               "--from-subject builds the request; do not supply evidence, fingerprint, links or version"
             )

        case AtlasGates.Decider.request(opts[:gate], opts[:from_subject], facts) do
          {:ok, request} -> request
          {:error, why} -> Mix.raise("No verdict: #{why}")
        end
      else
        manual_request(opts)
      end

    {status, verdict} =
      if opts[:no_record] do
        result =
          case request.definition["flavor"] do
            "rule" -> AtlasGates.Rules.evaluate(request.definition, request.evidence)
            _ -> {"error", ["this flavor has no evaluator yet"]}
          end

        verdict = Verdict.settle(request, result, 0)
        {if(verdict.unsettled == "error", do: 2, else: 0), verdict}
      else
        facts = AtlasGates.Facts.Control.new(env, executable: opts[:atlas] || "atlas")

        case AtlasGates.decide(request, facts) do
          {:ok, verdict} -> {0, verdict}
          {:error, verdict, _why} -> {2, verdict}
        end
      end

    if opts[:json],
      do: IO.puts(JSON.encode!(Verdict.to_map(verdict))),
      else: IO.puts(text(verdict, request))

    if status != 0, do: exit({:shutdown, status})
  end

  defp manual_request(opts) do
    file = opts[:evidence_file] || Mix.raise("Give --evidence-file PATH")
    bytes = File.read!(Path.expand(file))

    evidence =
      case JSON.decode(bytes) do
        {:ok, %{} = map} -> map
        _ -> Mix.raise("#{file} is not one JSON object of named fields")
      end

    attrs = %{
      "subject" => opts[:subject],
      "fingerprint" => opts[:fingerprint],
      "gate_version" => opts[:gate_version],
      "evidence" => evidence,
      "evidence_digest" => Digest.of_bytes(bytes),
      "allowed_outcomes" => opts[:allowed] && String.split(opts[:allowed], ",", trim: true),
      "links" => links(Keyword.get_values(opts, :link))
    }

    request =
      case Request.new(opts[:gate], attrs) do
        {:ok, request} -> request
        {:error, why} -> Mix.raise("No verdict: #{why}")
      end

    request
  end

  defp links(pairs) do
    Map.new(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [relation, key] when relation != "" and key != "" -> {relation, key}
        _ -> Mix.raise("--link takes RELATION=KEY, not #{inspect(pair)}")
      end
    end)
  end

  defp text(%Verdict{} = v, %Request{} = r) do
    recorded =
      case v.recorded_as do
        :new -> "#{v.recorded} recorded now"
        :again -> "#{v.recorded} recorded before, nothing new"
        nil -> "NOT RECORDED"
      end

    lines = [
      "#{v.outcome}#{if v.unsettled, do: " (#{v.unsettled})"}: #{recorded}",
      "  gate #{r.gate} version #{r.gate_version}, rule outcome #{v.rule_outcome}, rule #{v.rule_version}",
      "  subject #{r.subject} at #{r.fingerprint}, evidence #{r.evidence_digest}",
      "  request #{v.request_id}, evaluated in #{v.duration_ms} ms"
      | Enum.map(v.reasons, &("  - " <> &1))
    ]

    Enum.join(lines, "\n")
  end
end
