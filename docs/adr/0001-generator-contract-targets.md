# 0001: Control's spec as generator, contract and targets

Status: accepted, 2026-11-03 (decision: "look at prism repo to see how 3 layers are seperated: the generator, design (or contract), targets"; for Atlas the middle layer is the contract: "design is not something i would use for atlas")

## Context

Control's spec was one Elixir DSL and its generators, all inside `atlas_control`, with the block catalogue in `spec/control/blocks.ex`. `mix atlas.gen` wrote three files: Control's builders, the TUI's decoder and `blocks.json`. The format (the DSL, the rules of markup, the generators) and Atlas's values (which blocks there are) were mixed in one place, and two of the three outputs were Elixir code generated into files for Elixir projects.

Prism (github.com/novasoftwarefoundation/prism) separates the same concerns into a generator, a design and targets. A future iOS client needs the contract as a Swift package, so a target that writes files for other languages stays.

## Decision

1. **Three parts under `bff/`.**
   - `bff/generator/` is its own Mix project (`atlas_bff`). It holds the DSL (`AtlasBFF.Schema`), the rules of markup (`AtlasBFF.Markup`), the header (`AtlasBFF.Header`), the targets and `mix atlas.gen`, and none of Atlas's values.
   - `bff/contract/` is its own Mix project (`atlas_bff_contract`). It depends on the generator by path. `AtlasBFFContract.Contract` composes separate presentation, payload-model and Control/Runtime wire declarations.
   - Generated files go under `bff/targets/<target>/`.
2. **One data function.** A contract compiles to `__schema__/0`, plain data documented in `AtlasBFF.Schema`. Targets read only that. A test fails when anything but the schema module calls into the DSL.
3. **Elixir consumers read the contract at compile time.** Control and the TUI depend on the contract by path. `use AtlasBFF.Targets.Server` / `use AtlasBFF.Targets.Client` build their modules when they compile, as prism's Phoenix target does. No Elixir code is generated into files, and changing the contract recompiles them.
4. **Other languages get files.** `AtlasBFF.Targets.Json` writes `bff/targets/json/blocks.json`. A Swift package for iOS will be the next file target, under `bff/targets/swift/`, with its own ADR.
5. **Generated files are guarded:**
   - Each one starts with a header naming the command and the contract file (in JSON, the first member `"$comment"`).
   - `mix atlas.gen` never overwrites a file without that header, and removes a file with it that no target writes any more.
   - `--check` fails on a file that would change and on a left-over one.
6. **CI keeps the parts apart:**
   - The generator is built and tested on its own, without the contract, on a neutral example contract.
   - A grep refuses Atlas's values in `bff/generator/`.
   - The contract job runs `mix atlas.gen --check`.
   - The JSON target has a golden test on the example contract.
   - The TUI's tests fail when the contract has a block or kind of markup the TUI does not know (`AtlasTui.View.known/0`).

## Copied from prism, and left out

Copied:
- the generator / contract / targets split, with path dependencies;
- one documented data function, and the test that targets read only it;
- the grep for project values in the generator, and the generator compiling and being tested without the contract;
- the header on every generated file, never overwriting a file without it;
- `--check` failing on stale and left-over files;
- a golden test;
- the unknown-target error;
- fail on an unknown name, as a TUI test over the contract's names;
- a compile-time target (prism's Phoenix);
- an ADR.

Left out, and why:
- **Per-platform bindings:** no value differs per platform yet.
- **Copied files and their folders:** no target bundles files such as fonts.
- **EEx templates:** the JSON target is data, and the compile-time targets are quoted code; templates pay off for the Swift target.
- **"Generation fails when a key is written nowhere":** prism's design has values that a target may forget to write. Atlas's targets write every entry and field of the schema generically, so nothing can be dropped silently.
- **Versioned golden files** (prism's 0.1.7 diff): there is no published release to compare against yet.
- **Per-target build tests on fixtures in other languages:** there is no Swift or React target yet. The Elixir targets are tested on the neutral example contract.
- **The generator as an optional-dependency host:** it has no optional dependencies.

## Consequences

- To change the contract, edit the owning declaration under `bff/contract/lib/` (composed by `contract.ex`), run `mix atlas.gen` in `bff/contract`, and commit `bff/targets/`. Control and the TUI pick the change up when they compile.
- The generator can be reused, or released, without Atlas's blocks.
- `bff/README.md` keeps the view model, the wire format and the protocol.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
