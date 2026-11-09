# Console action presentation (IS-Atlas-120)

Clients request `surface: "console"` in ordinary hello. Control echoes it in welcome
only after constructing a valid first projected page; a projection failure sends
bye instead. Omitted surface retains the existing 0.14.0 native page catalogue.
Unknown surfaces, wrong environments and old versions are refused. Actor identity
still comes from the existing client/as rules. Presentation never grants authority.
Native boot remains unchanged and contains no terminal actions.

Console pages keep native content and append actual `console_action` blocks:

```json
{"id":"action:<stable identity>","type":"console_action","props":{
  "label":"Next tab","keys":["Tab"],"operation":{"name":"tab_next"},
  "scope":{"page":"/k/scene","revision":"<fresh nonce>","context":"browse"},
  "available":true
}}
```

`legend` markup points start/end at these block IDs, with props `title` and
`context`. Scope context equals legend context. Scope may also contain `on` (native
source block ID) and `row` (list row id, otherwise its to). Existing page action
labels, keys and targets are projected without replacing their source identity.
Stable identity hashes page/context/source/row/operation, independent of label,
position and revision. Every projected page gets a fresh actions_revision nonce.

Operations are typed data from the finite vocabulary in
`AtlasBFFContract.Console.operations/0`. Local operations contain only name; open
requires canonical to; open_url requires HTTP(S) url; agent_ask optionally carries
intent. Submit/cancel operate on the current native form/confirm block and use its
existing typed call/cancel destination. No arbitrary functions, atoms or authority
are encoded. Ordinary submit and Facts authorization remain the enforcement path.

Contexts are browse, form, confirm, ask, plan_planning, plan_proposed, plan_running,
plan_done, step_form and legend. Named key tokens come from named_keys/0; a single
printable grapheme is also valid. Text entry retains literal question marks.
Clients render disabled commands with their optional reason; only available
commands become bindings. Unknown operations/tokens/scopes fail closed.

`Console.compile(page)` validates the whole projection and returns an index over
the original blocks/legend markup. `active(index, current)` and `bindings` share
these objects. Current is a local atom-key map containing path, context, generation
and optionally on/row. `capture(index, token, current)` records action identity,
projection revision, mode generation and selected row; `resolve(index,event,current)`
re-resolves it immediately before execution and denies any stale page, revision,
mode, generation, selection or unavailable action. Clients increment generation on
local mode transitions; this guard is client lifecycle protection, not server
mutation authority. A client must safely disable any operation it cannot execute;
it never substitutes handwritten keys or a second legend table.

Projection limits: native page 256 blocks; total 512 blocks, 256 action blocks and
256 markup entries; serialized page 3 MB; labels 256 UTF-8 bytes, reasons 512,
keys 1..8 unique tokens, paths/row refs 2048, IDs/revision 128. Expansion stops at
257 candidate source actions before materializing the full projection. References,
legend membership, duplicate IDs and overlapping enabled key bindings are checked.
The server declines invalid projections; it never acknowledges a false surface.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0026).</sub>
