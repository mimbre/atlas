// Atlas Runtime viewer. Polls Runtime through this viewer's /api/read (runtime info, the
// history and turn output from backend.sock, the journal from runtime.sock) and shows what
// Runtime returns. Every Runtime value is placed with textContent, never as HTML.
// Cursors are Runtime's opaque values, kept only in memory and sent back unchanged.

const POLL_MS = 2000;
const REQUEST_MS = 12000;
const MAX_BACKOFF_MS = 15000;
const MAX_PAGES = 5;
// History pages of 100 turns read per poll; older turns beyond them are not shown.
const MAX_TURN_PAGES = 20;
const MAX_EVENTS = 500;
const MAX_OUTPUT = 2000;

const token = takeToken();
const view = {
  runtime: null,
  turns: null,
  turnsTruncated: false,
  events: [],
  eventsCursor: null,
  recordingStartedAt: null,
  selected: null,
  generation: 0,
  turn: null,
  output: null,
  connection: token ? { state: "connecting" } : { state: "no_token" },
  lastOk: null,
  failures: 0,
};

// The token arrives in the URL fragment, which is never sent to the server. It is removed
// from the address bar at once and lives only in this page.
function takeToken() {
  const match = /^#token=([A-Za-z0-9_-]+)$/.exec(window.location.hash);
  window.history.replaceState(null, "", window.location.pathname);
  return match ? match[1] : null;
}

class ReadError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

async function read(op, fields = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_MS);
  try {
    let response;
    try {
      response = await fetch("/api/read", {
        method: "POST",
        headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
        body: JSON.stringify({ op, ...fields }),
        cache: "no-store",
        credentials: "omit",
        signal: controller.signal,
      });
    } catch {
      throw new ReadError(
        "viewer_unreachable",
        controller.signal.aborted ? "The viewer backend did not answer in time." : "The viewer backend is not reachable.",
      );
    }
    let body;
    try {
      body = await response.json();
    } catch {
      throw new ReadError("bad_reply", `The viewer backend sent an unreadable reply (HTTP ${response.status}).`);
    }
    if (body.viewer_error) throw new ReadError(body.viewer_error.code, body.viewer_error.message);
    return body;
  } finally {
    clearTimeout(timer);
  }
}

// A Runtime error reply that the caller does not handle itself: a journal error, or a
// backend refusal, whose code is its problem type.
function expect(body) {
  if (body.error) throw new ReadError("runtime_" + body.error.code, `Runtime: ${body.error.message} (${body.error.code}).`);
  return body;
}

function describeReset(reset, what) {
  if (reset.reason === "retention_gap")
    return `${what} ${reset.from_sequence}–${reset.to_sequence} were dropped before this viewer read them.`;
  if (reset.reason === "epoch_changed") return `The ${what.toLowerCase()} stream was replaced; what was lost is unknown.`;
  return `${what} were lost (${reset.reason}).`;
}

function keepLast(list, max) {
  if (list.length > max) list.splice(0, list.length - max);
}

// ---- polling: one request chain at a time; selection changes restart it at once ----

let timer = null;
let running = false;
let again = false;

function schedule(ms) {
  clearTimeout(timer);
  timer = setTimeout(tick, ms);
}

async function tick() {
  if (running) {
    again = true;
    return;
  }
  running = true;
  again = false;
  const generation = view.generation;
  try {
    const runtime = expect(await read("runtime"));
    const turns = await readTurns();
    await readEvents();
    view.runtime = runtime;
    view.turns = turns.list;
    view.turnsTruncated = turns.truncated;
    if (view.selected !== null && generation === view.generation) await readSelected(generation);
    view.failures = 0;
    view.lastOk = new Date();
    view.connection = { state: "live" };
  } catch (error) {
    if (!(error instanceof ReadError)) throw error;
    view.failures += 1;
    view.connection =
      error.code === "unauthorized"
        ? { state: "unauthorized", error }
        : { state: "reconnecting", error, retryMs: Math.min(1000 * 2 ** (view.failures - 1), MAX_BACKOFF_MS) };
  } finally {
    running = false;
    render();
  }
  if (view.connection.state === "unauthorized") return;
  schedule(again ? 0 : view.connection.state === "live" ? POLL_MS : view.connection.retryMs);
}

// The history in its order (oldest first), page by page.
async function readTurns() {
  const list = [];
  let cursor = null;
  for (let page = 0; page < MAX_TURN_PAGES; page++) {
    const body = expect(await read("turns", cursor ? { cursor, limit: 100 } : { limit: 100 }));
    list.push(...body.turns);
    if (!body.more) return { list, truncated: false };
    cursor = body.cursor;
  }
  return { list, truncated: true };
}

async function readEvents() {
  for (let page = 0; page < MAX_PAGES; page++) {
    const fields = view.eventsCursor ? { cursor: view.eventsCursor, limit: 100 } : { limit: 100 };
    const body = await read("events", fields);
    if (body.error && body.error.code === "invalid_cursor") {
      view.eventsCursor = null;
      view.events = [{ gap: "Runtime no longer accepts this viewer's events cursor; reading again from the oldest retained event." }];
      continue;
    }
    expect(body);
    if (body.reset) view.events.push({ gap: describeReset(body.reset, "Events") });
    view.events.push(...body.events);
    keepLast(view.events, MAX_EVENTS);
    view.eventsCursor = body.cursor;
    view.recordingStartedAt = body.recording_started_at;
    if (!body.more) return;
  }
}

async function readSelected(generation) {
  const id = view.selected;
  const output = view.output;
  const body = await read("turn", { turn_id: id });
  if (generation !== view.generation) return;
  if (body.error && body.error.code === "not-found") {
    view.turn = { missing: true };
    return;
  }
  const turn = expect(body);
  for (let page = 0; page < MAX_PAGES; page++) {
    const reply = await read("output", output.cursor ? { turn_id: id, cursor: output.cursor } : { turn_id: id });
    if (generation !== view.generation) return;
    if (reply.error && reply.error.code === "not-found") {
      output.unavailable = true;
      break;
    }
    if (reply.error && reply.error.code === "invalid" && output.cursor) {
      output.cursor = null;
      output.events = [{ gap: "Runtime no longer accepts this viewer's output cursor; reading again from the oldest retained output." }];
      continue;
    }
    expect(reply);
    output.unavailable = false;
    output.events.push(...reply.events);
    keepLast(output.events, MAX_OUTPUT);
    output.cursor = reply.cursor;
    if (!reply.more) break;
  }
  view.turn = turn;
}

function select(turnId) {
  if (view.selected === turnId) return;
  view.generation += 1;
  view.selected = turnId;
  view.turn = null;
  view.output = { cursor: null, events: [], unavailable: false };
  render();
  if (running) again = true;
  else if (token && view.connection.state !== "unauthorized") schedule(0);
}

// ---- rendering: DOM nodes with text content only ----

function el(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) if (value !== null && value !== undefined) node.setAttribute(name, value);
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function text(value) {
  if (value === null || value === undefined) return "—";
  return typeof value === "string" ? value : JSON.stringify(value, null, 2);
}

function time(date) {
  return date ? date.toLocaleTimeString() : "never";
}

function stateTag(state) {
  return el("span", { class: state === "finished" ? "prism-tag prism-tag-success" : "prism-tag" }, el("span", { class: "prism-tag-inner" }, text(state)));
}

// A native button selecting a turn; `key` restores keyboard focus across renders.
function turnButton(key, turnId, children) {
  const button = el(
    "button",
    {
      type: "button",
      class: "prism-btn prism-btn-secondary w-full text-left flex flex-wrap items-center gap-2",
      "aria-pressed": String(view.selected === turnId),
      "data-key": key,
    },
    children,
  );
  button.addEventListener("click", () => select(turnId));
  return button;
}

function renderStatus() {
  const c = view.connection;
  const stale = view.lastOk
    ? `Showing what was read at ${time(view.lastOk)}; it may be out of date.`
    : "Nothing has been read from Runtime yet.";
  if (c.state === "no_token")
    return el("div", { class: "prism-alert prism-alert-error" },
      "No access token. Open the exact URL the viewer printed when it started; the token is kept only in the page, so reloading needs that URL again.");
  if (c.state === "unauthorized")
    return el("div", { class: "prism-alert prism-alert-error" },
      `${c.error.message}. The viewer may have been restarted with a new token. Polling has stopped. ${stale}`);
  if (c.state === "connecting")
    return el("p", { class: "flex items-center gap-2" }, el("span", { class: "prism-spinner", "aria-hidden": "true" }), "Connecting to Runtime…");
  if (c.state === "reconnecting")
    return el("div", { class: "prism-alert prism-alert-error space-y-1" },
      el("p", {}, el("strong", {}, disconnectedTitle(c.error.code)), " ", c.error.message),
      el("p", { class: "flex items-center gap-2" }, el("span", { class: "prism-spinner", "aria-hidden": "true" }),
        `Reconnecting in ${Math.round(c.retryMs / 1000)} s (attempt ${view.failures}).`),
      el("p", {}, stale));
  return el("p", { class: "flex flex-wrap items-center gap-2" },
    el("span", { class: "prism-tag prism-tag-success" }, el("span", { class: "prism-tag-inner" }, "Live")),
    `Updated ${time(view.lastOk)}.`,
    view.runtime && view.runtime.mode !== "open" ? stateTag(`Runtime ${view.runtime.mode}`) : null);
}

function disconnectedTitle(code) {
  if (code === "viewer_unreachable") return "Viewer disconnected.";
  if (code === "runtime_unreachable") return "Runtime not reachable.";
  if (code === "read_timeout") return "Runtime is not answering.";
  return "Read failed.";
}

// The newest turn on a slot that has not ended, from the history read this poll.
function openTurn(slot) {
  const open = (view.turns || []).filter((turn) => turn.slot === slot && !turn.ended_at);
  return open.length ? open[open.length - 1] : null;
}

function renderSlots() {
  if (view.runtime === null) return el("p", {}, "Not read yet.");
  if (view.runtime.slots.length === 0) return el("p", {}, "This Runtime has no slots in its policy.");
  return el("ul", { class: "space-y-2" }, view.runtime.slots.map((slot) => {
    const label = [el("span", { class: "font-semibold" }, slot.name), stateTag(slot.busy ? "busy" : "free")];
    const turn = openTurn(slot.name);
    return el("li", {}, turn
      ? turnButton("slot:" + slot.name, turn.turn_id, [...label, el("span", { class: "font-mono text-sm" }, turn.turn_id)])
      : el("p", { class: "flex items-center gap-2" }, ...label));
  }));
}

function renderTurns() {
  if (view.turns === null) return el("p", {}, "Not read yet.");
  if (view.turns.length === 0) return el("p", {}, "No turns recorded.");
  return el("div", { class: "space-y-2" },
    view.turnsTruncated ? el("p", { class: "text-sm" }, `Showing the oldest ${view.turns.length} turns; later ones are not read.`) : null,
    el("ul", { class: "space-y-2" }, [...view.turns].reverse().map((turn) =>
      el("li", {}, turnButton("turn:" + turn.turn_id, turn.turn_id, [
        el("span", { class: "font-mono text-sm" }, turn.turn_id),
        stateTag(turn.state),
        el("span", { class: "text-sm" }, `${text(turn.slot)} · started ${text(turn.started_at)}`),
      ])))));
}

const TURN_FIELDS = [
  ["turn_id", "Turn"], ["slot", "Slot"], ["native_outcome", "Native outcome"], ["harness", "Harness"],
  ["configured_model", "Configured model"], ["reported_model", "Reported model"], ["conversation_id", "Conversation"],
  ["started_at", "Started"], ["ended_at", "Ended"],
];

function renderTurn() {
  if (view.selected === null) return el("p", {}, "Select a slot's turn or a turn to see its details and output.");
  if (view.turn === null) return el("p", { class: "flex items-center gap-2" }, el("span", { class: "prism-spinner", "aria-hidden": "true" }), `Reading ${view.selected}…`);
  if (view.turn.missing) return el("div", { class: "prism-alert prism-alert-error" }, `Runtime has no turn ${view.selected}.`);
  const turn = view.turn;
  return el("div", { class: "space-y-4" },
    el("p", { class: "flex items-center gap-2" }, "State:", stateTag(turn.state)),
    el("dl", { class: "grid grid-cols-3 gap-x-4 gap-y-1 text-sm" },
      TURN_FIELDS.flatMap(([key, label]) => [el("dt", { class: "font-semibold" }, label), el("dd", { class: "col-span-2 font-mono break-words" }, text(turn[key]))])),
    el("p", { class: "text-sm" }, "The history holds a turn's metadata: its assignment, result, answer and questions are not part of it."),
    renderOutput());
}

function renderOutput() {
  const output = view.output;
  const lines = output.events.map((event) => {
    if (event.gap) return el("p", { class: "prism-alert" }, event.gap);
    if (event.kind === "activity") return el("p", { class: "font-mono text-sm" }, `activity: ${text(event.text)}`);
    return el("pre", { class: "font-mono text-sm whitespace-pre-wrap break-words" }, text(event.text));
  });
  return el("div", { class: "space-y-1" },
    el("h3", { class: "font-semibold" }, "Output"),
    output.unavailable
      ? el("p", { class: "prism-alert" },
          "Runtime has no output for this turn now: output is lost when the Runtime service exits and expires 15 minutes after a turn ends.",
          output.events.length ? " The lines below were read before that." : "")
      : null,
    lines.length ? el("div", { class: "space-y-1 overflow-auto max-h-96 p-2" }, lines) : output.unavailable ? null : el("p", { class: "text-sm" }, "No output yet."));
}

function renderEvents() {
  const intro = view.recordingStartedAt ? `Recorded since ${view.recordingStartedAt}; newest last.` : null;
  if (view.events.length === 0) return el("p", {}, view.lastOk ? "No execution events." : "Not read yet.");
  return el("div", { class: "space-y-1" },
    intro ? el("p", { class: "text-sm" }, intro, " execution_finished means the turn ended, not that its task was verified.") : null,
    el("ol", { class: "space-y-1 font-mono text-sm overflow-auto max-h-96" }, view.events.map((event) =>
      event.gap
        ? el("li", { class: "prism-alert" }, event.gap)
        : el("li", {}, Object.entries(event).map(([key, value]) => `${key}: ${text(value)}`).join(" · ")))));
}

function render() {
  const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
  document.getElementById("status").replaceChildren(renderStatus());
  document.getElementById("slots").replaceChildren(renderSlots());
  document.getElementById("turns").replaceChildren(renderTurns());
  document.getElementById("turn").replaceChildren(renderTurn());
  document.getElementById("events").replaceChildren(renderEvents());
  if (focused) {
    const target = document.querySelector(`[data-key="${CSS.escape(focused)}"]`);
    if (target) target.focus();
  }
}

render();
if (token) tick();
