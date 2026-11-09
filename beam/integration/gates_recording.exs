# Gates records through a real Facts and rela, over the Bus (no stand-in):
#
#   GATES_RELA_URL=http://127.0.0.1:PORT/api/v1 MIX_ENV=test \
#     mix run integration/gates_recording.exs GATE EVIDENCE_FILE SUBJECT FINGERPRINT
#
# GATES_RELA_URL is a private, empty rela that serves rela/'s description: never a live store.
# It evaluates GATE on the evidence and records the verdict, asks the same again (nothing new),
# then asks on the evidence with its first declared field left out (uncertain: the safe
# verdict), following the first verdict; and reads each verdict back through Facts.
[gate, file, subject, fingerprint] = System.argv()
url = System.fetch_env!("GATES_RELA_URL")
root = Path.expand("../..", __DIR__)
data = Path.join(System.tmp_dir!(), "atlas-gates-facts-#{System.unique_integer([:positive])}")

{:ok, _facts} =
  AtlasFacts.Server.start_link(
    rela: {AtlasFacts.Rela.Http, url},
    data_dir: data,
    description_extra: Path.join(root, "rela/atlas.json")
  )

{:ok, facts} = AtlasGates.Facts.Bus.attach("gates")
bytes = File.read!(file)
evidence = JSON.decode!(bytes)

ask = fn evidence, digest, links ->
  {:ok, request} =
    AtlasGates.Request.new(gate, %{
      "subject" => subject,
      "fingerprint" => fingerprint,
      "evidence" => evidence,
      "evidence_digest" => digest,
      "links" => links
    })

  result = AtlasGates.decide(request, facts)
  verdict = elem(result, 1)
  IO.puts("#{elem(result, 0)}: " <> JSON.encode!(AtlasGates.Verdict.to_map(verdict)))
  verdict
end

recorded = fn key ->
  envelope = AtlasBus.Envelope.new("read", AtlasGates.Record.kind())
  id = envelope.id
  :ok = AtlasBus.send(envelope, %{"key" => key})

  receive do
    {:atlas_bus, %{id: ^id, class: "answer"}, %{"fact" => fact}} -> fact
  after
    5_000 -> raise "Facts did not answer"
  end
end

check = fn ok?, what -> unless ok?, do: raise("not so: #{what}") end

first = ask.(evidence, AtlasGates.Digest.of_bytes(bytes), %{})
check.(first.recorded_as == :new, "the first verdict is recorded now")

again = ask.(evidence, AtlasGates.Digest.of_bytes(bytes), %{})
check.(again.recorded == first.recorded and again.recorded_as == :again, "a repeat records nothing")

[field | _] = AtlasGates.Definitions.gates()[gate]["evidence"]
less = Map.delete(evidence, field)
uncertain = ask.(less, AtlasGates.Digest.of_term(less), %{"follows" => first.recorded})
check.(uncertain.unsettled == "uncertain" and uncertain.recorded_as == :new, "missing evidence is uncertain")

for key <- [first.recorded, uncertain.recorded] do
  fact = recorded.(key)
  IO.puts("#{key} in rela: " <> JSON.encode!(Map.take(fact, ["values", "links"])))
end

check.(recorded.(uncertain.recorded)["links"]["follows"] == [first.recorded], "it follows the first")
File.rm_rf!(data)
IO.puts("proof: ok")
