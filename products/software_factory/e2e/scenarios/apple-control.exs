# The Apple clients' session against this run's Control (docs/design/apple-clients.md §7):
# `swift test --filter ControlIntegration` in platform/clients/apple, with ATLAS_ENV_FILE naming this
# run's settings, as a child of the scenario, so it ends with the run. It builds against the
# Swift package `bin/generate atlas` writes from this tree's contract (ATLAS_SWIFT_PACKAGE),
# the version this run's Control speaks, published or not. Network.framework is
# on Apple's platforms only: elsewhere, or without swift, the step says so and passes.
import AtlasE2E.Scenario

scenario "Apple clients: the Swift session against Control", fn %{instance: i} ->
  step "swift test --filter ControlIntegration on this run's Control", fn ->
    swift = System.find_executable("swift")

    if match?({:unix, :darwin}, :os.type()) and swift do
      {out, status} =
        System.cmd(Path.join(i.root, "bin/generate"), ["atlas"],
          cd: i.root,
          env: [{"MIX_ENV", "dev"}],
          stderr_to_stdout: true
        )

      status == 0 || raise "bin/generate atlas failed:\n#{out}"

      {out, status} =
        System.cmd(swift, ["test", "--filter", "ControlIntegration"],
          cd: Path.join(i.root, "platform/clients/apple"),
          env: [
            {"ATLAS_ENV_FILE", i.file},
            {"ATLAS_SWIFT_PACKAGE",
             Path.join(i.root, "platform/atlas_control/backend/targets/swift")}
          ],
          stderr_to_stdout: true
        )

      status == 0 || raise "swift test failed:\n#{out}"
      # A skip means it did not reach Control: that is a failure here.
      out =~ ~r/skipped/ && raise "ControlIntegration was skipped:\n#{out}"
      out =~ ~r/Executed [1-9]\d* tests?, with 0 failures/ || raise "no test ran:\n#{out}"
    else
      Process.put(:e2e_notes, ["not on macOS with swift: not run" | Process.get(:e2e_notes)])
    end
  end
end
