# Page freshness: precise, prompt, read-your-writes

Architect design. No product code changes. Paths are relative to `atlas/`. Platform names only: examples use the neutral test kinds `widget` and `part` and the relation `of_widget`, as `beam/apps/atlas_control/test/session_test.exs` does.

## 0. Problem and decisions

Today (`beam/apps/atlas_control/lib/atlas_control/session.ex`):

- Facts sends one `stored` per write. It names only the main fact's kind and `{op, key, by, cause}`. A `replaces` write also changes other facts (`atlas_facts/server.ex` `replace/6`), but sends no hint for them.
- A session listens to every kind. `Pages.shows?/3` matches a hint against the page on screen *by kind*, interpreting the description (`progress_from`, `completion_from`, `counts`, `components`). Home and the assigned page match every hint.
- A submit sends the page once Facts says `stored`. Flow's follow-up writes (state, owner, Assignment) are later writes. So the first page is often half-updated, and each follow-up re-reads the page again.
- Pages in the client's history or tabs are never refreshed. The TUI drops `hint` pages for other paths (`clients/tui/lib/atlas_tui/console.ex:147`). Every 5 s, `refresh` re-reads `_description` plus the whole page.
- When the TUI shows a new page for the same path, it keeps the old selection index and clamps it to the list (`model.ex` `keep_selection/2`). If rows move, the selection lands on a different row.

| # | Decision |
| --- | --- |
| 1 | **Facts says what a read depended on and what a write changed.** Read answers carry `deps`; `stored` carries `changes`. Control stores `deps` without interpreting them and matches `changes` against them. Control does not interpret the description for freshness, so `Pages.shows?/3` and `progress_from/3` are deleted. Because of this, the design works whatever the description source is (JSON today, the compiled `AtlasControl.Model` after Rela DSL slice 5). |
| 2 | **Flow says when it has caught up.** Flow tracks a *settled position*: every hint at or before it has been looked at, and its follow-up writes are stored. Each session asks Flow for it (`_settled`) with the existing `request`/`answer` classes. No new Bus class (coordinator). |
| 3 | **Control decides; the client only caches.** Control pushes re-read pages for the path on screen and for the **3 most recently viewed** affected paths (coordinator). The client keeps the newest page per path and re-opens a path on back/tab switch. |
| 4 | **On a settle timeout, the page goes out now and the timeout is logged** (coordinator). There is no generic notice; the pending marker (decision 5) shows that work is still under way. |
| 5 | **Control marks unsettled rows.** After a stored write, Control marks every row that stands for a fact the write changed as `pending` on every page it sends. It removes the marker once Flow has settled past the write. The client renders the flag and never guesses an outcome. |
| 6 | **Selection follows keys, mechanically.** When a page replaces the list on screen, the TUI keeps the selected key, or else keeps the index. It is a pure rule over row keys and indexes, with no meaning attached. |
| 7 | **One path.** No fallback to kind matching. A lost hint is still covered by reconcile, as it is today. Nothing reads generated JSON (D-0083). |

## 1. Read sets

### 1.1 What Facts returns

Every read answer, plain and `_page`, gets `deps`. `_page` already shares one snapshot and one `position`. All page reads move to `_page`, so a page has one `as_of` position and one dependency set.

| Dep | Wire form | Facts records it for | Matches a change `c` when |
| --- | --- | --- | --- |
| key | `["key", kind, key, fields]` (`fields` = `"*"` or a list) | each fact returned; derived inputs with the fields the rule reads | `c.kind == kind and c.key == key` and (`fields == "*"` or `c.op != "change"` or `c.fields ∩ fields ≠ ∅` or `c.relinked ≠ []`) |
| linked | `["linked", relation, target, fields]` | a `linked: {relation => target}` read (children, what is assigned to someone); derived inputs over a relation (after Rela slice 6, §6) | `target ∈ c.links[relation]` (before ∪ after) and (`relation ∈ c.relinked` or `c.op != "change"` or fields match as above) |
| kind | `["kind", kind]` | a whole-kind read; derived inputs until Rela slice 6 | `c.kind == kind` |
| until | `"until": instant` | the earliest instant at which a time-derived value in the answer changes (`late`, a shown deadline) | Control's clock reaches it |

How deps are captured: Facts wraps the `list`/`lookup` function that its derived-value code already receives (`server.ex` `with_progress/3`: `list = fn of -> collection(...)`). Every call is recorded. This is the same lookup that the compiled `AtlasFacts.Model.derived/3` receives (rela-dsl.md §2), so dependency capture survives the Facts cutover without changes. Until then the interpreters call `list.(kind)`, which records a `kind` dep. After the cutover, `lookup` asks for `linked` sets, so the dep becomes `linked` and precise.

### 1.2 What a hint carries

`stored` content keeps `op, key, by, cause` and gains `changes`, one entry per fact the write changed. That includes facts changed by `replaces` and components, and the fact a delete removed:

```json
{"op":"change","key":"W-1","by":"tui","changes":[
  {"kind":"widget","key":"W-1","op":"change","fields":["status"],"relinked":[],
   "links":{"of_widget":["W-0"]}},
  {"kind":"widget","key":"W-0","op":"change","fields":["status"],"relinked":[],"links":{}}]}
```

- `fields`: the values that actually differ. Facts already holds the prior version for its checks.
- `relinked`: the relations whose targets differ.
- `links`: per outgoing relation, the targets before ∪ after. With these, a field-only change of a child still matches its parent's `linked` dep.
- The position is the envelope's (exists). Old listeners ignore `changes`.

### 1.3 What Control keeps per session (`AtlasControl.Freshness`)

New folder `beam/apps/atlas_control/lib/atlas_control/freshness/`, named by purpose:

| Module | Holds / does |
| --- | --- |
| `read_set.ex` | `of(route, answers, view_model)`: the page's deps, narrowed (below), and per row the keys of the facts it stands for (§2.3). Pure. |
| `recent.ex` | path → `%{route, deps, row_keys, view, as_of, until, last_sent}`. `view` is the last view model sent for the path. The path on screen plus the last **N = 8** distinct paths sent, least recently used out. Pure. |
| `affected.ex` | `affected(recent, changes_by_position)`: the paths to re-read. A change at position ≤ `as_of` is already shown and is skipped. Pure. |
| `batch.ex` | Collects hints until a flush (§4). Pure, with time passed in. |
| `marks.ex` | The session's pending marks and the overlay of `pending` flags on a view model (§2.3). Pure. |

**Narrowing (precision).** Each `Pages.reads/2` entry is tagged `:rows` (its facts are the page's rows, so membership matters) or `:lookup` (it only resolves facts that other reads point at; the assigned page's owner kinds, cause fields). A `:lookup` read keeps `key` deps only for the facts a row links to, or that link to a row. If no row links to any of its facts, it keeps its `kind` dep, so narrowing never under-invalidates. Example: accepting a widget that is not assigned to you no longer touches your assigned page. Today every hint re-reads it.

**On a flush:** the on-screen path is re-read and sent (`reason: "hint"`) unless it is a form. A form keeps today's notice, now only on a real match. Affected recent paths are re-read and pushed, the most recently viewed first, at most **K = 3** per flush. The rest are dropped from `recent`; they are re-read when the client re-opens them. The `count` header has its own read set (the assignment reads) and replaces `count_stale`.

## 2. Read-your-writes, derived effects included

### 2.1 Flow's settled position (`AtlasFlow.Settled`, pure, plus engine wiring)

| Step | Who | What |
| --- | --- | --- |
| 1 | Engine | For each non-Flow hint at position `p`, it pokes items as it does today (`engine.ex`). The poke carries ticket `p`: `Item.poke(pid, description, p)`. With no item to poke, `p` is settled at once. |
| 2 | Item | After its look, with every write it made acknowledged (`Talk.put` waits), it reports `{:looked, self(), max_ticket, wrote: max_position}` to the engine. |
| 3 | Engine | `settled = min(outstanding tickets) − 1`. With nothing outstanding it is the highest position seen, including `wrote`. The engine therefore needs no assumptions about message order between Router and Item. |
| 4 | Engine | Answers `request` kind `_settled`, content `{"position": P}`, addressed to `flow`, with `{"settled": S}`. It answers at once if `S ≥ P`; otherwise it keeps the waiter and answers when the value is reached. A waiter left over when the engine restarts is lost; the asker's budget covers it. |

Order is sound. The Router delivers both the hint at `P` and the later `_settled` request to the engine, and the request leaves only after the session has the `stored` for `P`. So the engine has always seen `P` first. Flow passes over its own hints, so Flow's writes do not cascade and the frontier is final. If cascades are ever added, an own-write hint just becomes a new ticket.

The clock is injected (`AtlasFlow.Runs.Clock`; tests use `ManualClock`).

### 2.2 Control after a submit

```
submit ─▶ fact ─▶ stored(P) ─▶ mark the changed keys (§2.3); re-send marked recent pages (0 reads)
                             ─▶ request _settled(P) to flow ─┬─ answer(S ≥ P) ─▶ clear marks ≤ S ─▶ one _page read ─▶ page "stored"
                                                             └─ budget timeout ─▶ log; marks stay ─▶ one _page read ─▶ page "stored", rows still pending
hints arriving meanwhile are batched and handled in the same read (and their recent paths after it)
```

- The wait does not block. The session state gets `settling: %{position, route, ref}`, and the timeout is a message, `{:settle_timeout, ref}`, from `Process.send_after`. Its budget is `settle_ms` (default **1000**, configured). Tests send the message directly, so no real timer runs. Opens and other ops still work while it waits. An `open` during the wait changes the route; the `stored` notice still comes.
- **On timeout** Control sends the page as Facts has it now. Rows of unsettled keys keep `pending` (§2.3), and there is no generic notice. Control logs one line per timeout, with no domain words:
  `[warning] control: settle timeout position=P budget_ms=1000 settled=S marked_keys=N`
  Here `S` is the last settled value Flow reported, or `none`. Flow's later writes arrive as hints and refresh the page through §1. The marker goes once a later `_settled` answer covers `P` (§2.3).
- Without Flow running, every submit times out and the rows stay marked. Prod refuses boot without Flow anyway.
- **Others' writes**: a flush whose batch holds a non-Flow hint first asks `_settled(max position)` with a shorter budget, `hint_settle_ms` (default **250**). Other users then also see the finished world, in one read. Writes by others put no marks in this session; marks belong to the writer's session.

### 2.3 Pending marker (server-driven)

| Question | Answer |
| --- | --- |
| What is marked | Each key in the `changes` of this session's `stored(P)` (§1.2), including facts changed as side effects: `marks[key] = P`. A refused write marks nothing. Nothing is marked before Facts has stored the write, so the marker never claims something that did not happen. |
| Where it lives | **In the page payload, per row.** A row gets the optional field `pending: true`. Control sets it on every row whose `row_keys` (from `read_set.ex`: the fact the row opens plus the lookup facts joined into it) include a marked key. Rows also get `key`: the key of the fact the row opens, taken from its `to` path. The client uses `key` only as an opaque identity (§3.1) and never compares it with anything a write said. |
| Which pages | **Every** page Control sends while marks are held: the current page, the stored page, pushes, re-opens and hint pages. At `stored(P)`, Control also re-sends each recent path whose last `view` has a newly marked row. It overlays the flag onto that view and sends it with the **same `position`**, `reason: "pending"`, at most K = 3 pages. This costs 0 Facts reads. |
| Who clears it | Control only. When a `_settled` answer has `S ≥ P`, it drops every mark with position ≤ S. The next pages, the settled stored page and the affected pushes, are read from Facts at `as_of ≥ S` and carry no flag for those keys. A recent page that had a marked row but no dep matched gets its `view` re-sent without the flag, with the same `position`, at 0 reads. |
| On timeout | Marks stay; the log line in §2.2 is written. Afterwards, while any mark is held, each flush and each reconcile `refresh` asks `_settled(min marked P)` with `hint_settle_ms`. The first answer that covers `P` clears the mark as above. Marks do not expire by time: the marker shows until Flow has really settled, or the session ends. A reconnect starts a new session without marks, and its pages show Facts' state as it is. |
| Against "replace unless older" | Overlay pages carry the `position` of the view they overlay, which is the newest sent for that path. So under `≥` they replace the cached page and never go backwards. A page that clears a mark is read at `as_of ≥ S ≥ P`, newer than or equal to any marked page for the path, so it replaces it. Every page leaves the session in send order, with the session's current marks applied. Therefore no page sent after the clear can carry the old mark. |
| Client | Renders a row with `pending` as `⋯ being processed` next to its label. It does not hide, reorder or restyle the row's values, and it never sets or clears the flag itself. |

The marker reaches the client through the 0.15.0 row fields (`key`, `pending`), which F6 adds. F7 sets them (`freshness/marks.ex`).

## 3. Client protocol (minimal)

| | Before (0.14.0) | After (0.15.0) |
| --- | --- | --- |
| `row` model | `id, label, detail, to, links` | adds optional `key` (the fact the row opens, an opaque identity) and `pending` (boolean, set only by Control) |
| `page` fields | `position` = the stored position or the first answer's | `position` = the page's `as_of` (its one `_page` snapshot), the page version per path |
| Unasked `page` | only for the path on screen | also for a recently viewed path (`reason: "hint"`), and marker overlays (`reason: "pending"`) |
| Client on `page` | renders if the path is current, drops it otherwise | keeps it in a per-path cache if `position ≥ cached position`, or if either is nil (worker and fault pages); renders it if the path is current, selecting by §3.1 |
| Back / tab switch | `open` and wait | shows the cached page at once (status: from cache), selecting by §3.1 from that path's remembered selection, and sends `open`; the answer replaces the cached page under the same rule |
| Reconcile | `refresh` every 5 s | unchanged (the client stays dumb); Control makes it cheap (§4) |

The TUI change sits on the history-stack fix (in progress). Each history entry remembers the path and its selection `{identity, index}`; `back` pops an entry and re-opens it as above. The per-tab `selections` map stores the same pair. The cache is bounded (16 paths, LRU) and survives a reconnect, because positions are global.

Additive fields are tolerated by readers (`bff/README.md`, compile-time payloads), and an old client ignores pages for other paths (`console.ex:147`). The version still goes to 0.15.0 in F6, because Control's payloads validate against the contract's row model. `clients/agent` ignores both fields.

### 3.1 Selection rule (pure, `clients/tui/lib/atlas_tui/selection.ex`)

`Selection.after_replace(before, rows) :: index | nil`. `before` is `{identity, index}` or nil; `rows` is the new page's rows in display order (`Model.rows/1`, all list blocks flattened). A row's identity is `key`, else `to` (today's `row_identity/1`, with `key` first).

| # | Case | Result |
| --- | --- | --- |
| 1 | `rows == []` | `nil` (nothing selected) |
| 2 | `before == nil` (a different path, or a first open) | `0` (today's behaviour for a new path) |
| 3 | `identity` occurs in `rows` | its index; if it occurs more than once, the occurrence nearest `index`, the lower one on a tie |
| 4 | `identity` left the list, `index < length(rows)` | `index`: the row now at the same place |
| 5 | `identity` left the list, `index ≥ length(rows)` | `length(rows) − 1`: the last row |

It applies whenever a page for the **path on screen** replaces the one shown: a hint, a push, a marker overlay, the stored page, the answer to a re-open, or a cached page followed by its fresh copy. On back or tab switch, `before` is the pair that path's history entry or tab remembered. The rule reads only identities and indexes; it knows nothing about what a write meant. Scroll then moves the least needed to keep the selection visible (existing behaviour). Focus, cursor and part stay as today for the same path.

Working through a list, for example rows `[A, B, C]` with B selected:

1. Open B and answer `a`. Control stores the write and marks B.
2. `back` shows the cached list with B marked `⋯ being processed`. B is still in the list, so the selection stays on B (case 3). The person moves to C.
3. The settled list `[A, C]` arrives. C is still in the list, so the selection stays on C (case 3).
4. Had the person not moved, B would have left the list and index 1 would now select C (case 4).

## 4. Cost

`h` = 1 + f hints per user write (f Flow follow-up writes, typically 1–3). `R` = reads per page (1 once everything goes through `_page`). S = sessions.

| Situation | Today: Facts reads | After |
| --- | --- | --- |
| A submit, the submitter's own pages | `R` (stored page) + `R·f` (its follow-up hints) | 1 `_settled` request + 1 `_page` + ≤ K pushes, each 1 `_page`, only if affected; marker overlays and clears: 0 reads |
| One hint, another session on home, the assigned page or an open-work list | `R` every time (`shows?` is true for every kind) | 0 unless its deps match; then 1 per flush |
| One hint, a session on an item or list page | `R` if the kind is listed or rolls up | 0 unless key, linked or kind matches; then 1 per flush |
| Sweep: 50 writes in about 500 ms, plus Flow's follow-ups | `50·h·R` per matching session | ≤ 5 flushes × (1 + K) per matching session, often 1 |
| After a settle timeout, while marks are held | — | 1 `_settled` request per flush or reconcile, no extra Facts reads |
| Reconcile, every 5 s per session | 1 `_description` + `R` | 1 `_position` read; the page is re-read only if Facts' position is past the last hint the session saw, or if `until` has passed (F9) |
| Flow per non-Flow hint | `look_all` (1 `_description` + one read per flow kind) + `up` reads | unchanged; settled tracking adds no reads. `look_all` per hint is the largest remaining cost; it is measured in F8 and left out of scope |

**Batching**: trailing debounce of 20 ms, with a flush at the latest 100 ms after the first hint. Both are configured. Flushing is a `:flush` message, so tests send it themselves. One flush re-reads each affected path once, whatever the number of hints. Memory: `view` per recent path, at most N = 8 view models per session.

## 5. Proof

| Level | Test (neutral `widget`/`part`, no real-timer waits) | Shows |
| --- | --- | --- |
| Facts unit | `atlas_facts/test/read_deps_test.exs`: key, linked and kind deps per read kind; `until` for late; `_page` gives one position. `hint_changes_test.exs`: fields, relinked, links before ∪ after, `replaces` side effect, delete | Facts says exactly what was read and what was changed |
| Control pure | `freshness/affected_test.exs`, table-driven: each dep form matches, a field filter rejects, an unrelated key, linked target or kind does not match, a change at or before `as_of` is skipped, lookup narrowing, LRU and K bounds | invalidation is precise |
| Control pure | `freshness/marks_test.exs`: `stored(P)` marks every key in `changes`, side effects included; a refusal marks nothing; the overlay flags a row whose opened or joined key is marked and no other row; it keeps `position`; settled `S ≥ P` clears and `S < P` does not; with marks P1 < P2 and S between them only P1 clears; a timeout keeps the marks; `row_keys` and `key` come from the view model and the read set | the marker means "written, not yet settled", and only Control sets or clears it |
| Flow pure + engine | `settled_test.exs`: the frontier waits for every poked item; `wrote` advances it; a waiter is answered at once or later; a hint with no item settles at once (`ManualClock`) | the settled meaning |
| Control session | fake `flow` and Facts endpoints on the Bus (as `session_test.exs` does): a submit sends one `_settled` and then exactly one `_page`; after `stored`, recent pages with the key are re-sent with `pending` and no read; the settled answer gives the stored page without `pending`; a sent `{:settle_timeout, ref}` gives the page with `pending` still set and the log line (`capture_log`), and no notice; the next flush's `_settled` answer clears it; 50 hints and one `:flush` give one read; an unrelated hint gives no read; an affected recent path is pushed | read-your-writes, marker lifecycle, batching, no wasted reads |
| TUI pure | `clients/tui/test/selection_test.exs`, table-driven over cases 1–5 of §3.1: empty list, no previous selection, key kept at a new index, duplicate key nearest the old index (and the tie), key gone at the same index, key gone past the end, a row without `key` identified by `to` | the selection rule, on keys and indexes only |
| TUI model | `model_test.exs`: an off-screen page is cached if not older, and an older position does not replace; back shows the cached page with the remembered selection and sends `open`, and the fresh copy applies the rule again; a `pending` row renders `⋯ being processed`; after a submit and before any page, the rows are unchanged (no optimistic outcome); the walk-through of §3.1 as page messages | the client stays dumb |
| e2e | `e2e/test/page_freshness_test.exs`. It starts rela-server, Facts, Flow and Control in the test process, on the composition profile. A client opens the assigned page, then an item, submits the accept answer, and stamps the monotonic time `t0` before sending. `t1`: the `stored` page for the assigned path no longer lists the row and the count dropped. `t2`: the pushed page for the item path shows the final state. Before `t1`, every page that lists the changed key shows its row with `pending`, and none shows it removed. Then `back` and the next row, as in §3.1. 20 runs | the user's case end to end. The test prints p50/p95 of `t1 − t0` and `t2 − t0`. On the test environment it asserts p95 < 300 ms; locally it asserts correctness and only reports the times |

Before delivering each slice, run its tests once with `TMPDIR` reached through a symlink, comparing canonical paths, and run CI's boundary greps.

## 6. Slices

Each slice can be merged alone and is green. Steps F1–F8 do not depend on the description source.

| # | Slice | Contract | Deletes | Waits for |
| --- | --- | --- | --- | --- |
| F1 | **Facts: `changes` on `stored`**, side effects included | — | — | — |
| F2 | **Facts: `deps` and `until` on reads** (lookup recording; derived inputs as `kind`) | — | — | — |
| F3 | **Flow: settled position** (`AtlasFlow.Settled`, ticketed pokes, `_settled` answered) | — | — | — |
| F4 | **Control: read sets and precise invalidation.** `Freshness.*` (without marks), every page through `_page`, recent paths (N = 8, K = 3), batching, count read set | 0.14.0 | `Pages.shows?/3`, `progress_from/3`, `completion_from/2`, `count_stale` | F1, F2 |
| F5 | **Control: read-your-writes** after a submit; the settled wait on a flush; the timeout log line, with no notice | 0.14.0 | — | F3, F4 |
| F6 | **TUI and contract: page cache, re-open on back/tab, selection rule (§3.1), rendering of `pending`.** The row model gains `key` and `pending`; Control fills `key` from `to` | **0.15.0** (`bff/contract`, `bff/README.md`) | the drop of off-screen pages; `keep_selection/2` | the history-stack fix |
| F7 | **Control: pending marker** (§2.3): `marks.ex`, overlay on every page, re-send of marked recent views, clear on settled, re-ask while marks are held | 0.15.0 (no change) | — | F5, F6 |
| F8 | **e2e latency, marker and precision proof** | — | — | F7 |
| F9 | **Cheap reconcile**: a `_position` read; no `_description` read on refresh | — | `describe/1` on `refresh` | **Rela DSL slice 5**: until then, refresh is how Control picks up a changed description |
| F10 | **Precise derived deps**: `derived/3`'s `lookup` asks for `linked` sets, so derived inputs become `linked` deps instead of `kind` | — | — | **Rela DSL slice 6** (Facts cutover). Doing it earlier would mean rewriting interpreters that slice 6 deletes |

F4 and Rela slice 5 both touch `pages.ex`, but different parts: F4 deletes the freshness predicates and slice 5 replaces rendering. They can land in either order. `row_keys` and `key` come from the view model and the read set, not from the renderer, so slice 5 keeps them.

## 7. Decisions taken and open question

| Question | Decision (coordinator) |
| --- | --- |
| Push off-screen pages, or only re-read them on re-open? | Push the 3 most recently viewed affected pages. |
| Settled by request per session, or broadcast by Flow? | Each session asks Flow (`_settled`); no new Bus class. |
| On a settle timeout? | Send the page now and log each timeout. The pending marker replaces the generic notice. |

Open: **should the item page of a marked fact show a page-level marker, too?** Today only rows carry the marker. *Recommendation:* rows only for now. The item page's own fields come from Facts and are true as stored. A page-level flag would be a second marker field, and it can be added in a later minor version if people miss it.
