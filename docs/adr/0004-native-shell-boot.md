# Native shell boot (IS-Atlas-119)

`boot` is an ordinary typed endpoint in the existing DSL for terminal and future
native clients after hello. The legacy hello → welcome → initial page exchange
stays at contract 0.14.0. Consume that first page for compatibility; shell metadata
comes only from boot. Environment/version rejection still sends bye and closes
first. This additive endpoint does not force existing clients to update. A boot
client on an older server treats notices or a deadline without a boot reply as
unsupported, never as successful shell data.

Send `{"op":"boot","to":"/k/scene"}` (`to` is optional). Success returns `op: boot`,
`title`, `env`, `spec`, `revision`, ordered `tabs` (stable `id`, `label`, `to`),
`initial_to` and optional `active_tab`. No page blocks or terminal keys are returned.
Request/reply models and wire selectors use the existing DSL and transport.

The selected description's `shell` owns title and ordered index tabs. Composition
binds destinations; Control knows no workflow kinds. An `assigned: true` root tab
appears only for actors eligible for the configured assigned start. No Home chooser
or tab is added. Workers can add their index tab when that endpoint is available.
Assembly and Control reject unknown keys, duplicate ids/destinations, missing kinds
and non-index destinations. Limits: 64 tabs; UTF-8 byte lengths of 128 for title and
label, 64 for id, 2048 for destinations and requested targets.

Default `initial_to` is the first eligible tab. Explicit kind and resolvable
generic-key detail/form links retain a canonical target and matching index tab.
Valid details outside configured indexes have no active tab. An unknown target or
removed index falls back to the first tab. Boot reuses ordinary Session routing,
including Facts reads for ambiguous unprefixed generic keys. A failed lookup is a
typed error rather than an authoritative fallback. Ordinary open still owns page
existence/permissions. Boot never navigates, resets editing state, changes a draft
or writes facts. Both raw and canonical emitted targets obey the 2048-byte limit,
so a successful target can be reissued on reconnect after percent encoding.
Component key templates must be nonblank and within 2048 UTF-8 bytes at assembly
and runtime validation. Canonicalization validates every derived required path
parameter before calling the existing path builder. Invalid component keys,
relations, kinds or parent parameters return a typed boot error without replacing
the editing Session. Canonical tab destinations must also remain unique after
percent decoding/encoding.

Each boot reads the current description through Bus. Missing/invalid configuration
or Facts being unavailable returns `{"op":"boot","error":"..."}` without authoritative
empty tabs or successful cached metadata. Validate the nested entity, relation and
actor-resolution shapes before installation; keep the entire prior Session on a
boot error. Only a successful boot installs fresh metadata/listeners. Retain the
last good shell as stale
until a successful retry. The revision is an opaque deterministic SHA-256 of
emitted shell semantics: title, environment, contract version and ordered
actor-visible tabs. It is independent of requested content and fact activity;
compare for equality, never order. Reissue boot on successful reconnect and normal
reconciliation intervals to recover missed configuration changes. Updating shell
metadata does not navigate: accepting a returned fallback is a separate client
decision subject to draft protection. No invalidation push is introduced.

Clients keep one outstanding command per connection, consume welcome and the
compatibility page, and distinguish boot replies from interleaved notices/hint/
reconcile pages using declared selectors. Pushes never complete boot or extend its
bounded deadline. A typed error ends that read. Bye, malformed reply, EOF or
deadline ends the connection under existing client policy. No write is replayed.
IS-118 adopts boot for the persistent terminal shell. Action-block legends and
Prism presentation remain separate issues.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0026).</sub>
