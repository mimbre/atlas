# 0002: Pages and endpoints in the BFF contract

Status: accepted, 2026-11-03 (decision: "Pages should also be part of the BFF. which pages the Control layer should serve. and possibly also Endpoints for form submits"; "also look at mica-bff for pages in the BFF"). UC-Atlas-35; this record comes with IS-Atlas-70 (pages); IS-Atlas-71 (form submits) and IS-Atlas-72 (the session's other calls) follow it.

## Context

The contract (`bff/contract`, ADR 0001) said what a page looks like: blocks and markup. Which pages exist was hand-written in Control (`AtlasControl.Pages.route/1`), and a block's destination was a free string. A client learned what Control serves only by following links, and nothing checked that a destination led anywhere.

mica-bff's spec format (`~/projects/nova/mica-bff/docs/adr/0001-spec-format.md`) plans the next layers of its spec: `defpage` for the pages its BFF serves and `defendpoint` for every other call. Atlas takes the ideas over and shares nothing with it (d-0009).

## Decision

1. **`defpage` in the contract.** A page has a name and a path; a segment `:name` is a parameter (a string). A page is always fetched and always returns a view model. The contract lists every page Control serves:

   | Page | Path |
   |---|---|
   | `home` | `/` |
   | `kinds` | `/_kinds` |
   | `list` | `/k/:kind` |
   | `new` | `/k/:kind/new` |
   | `new_under` | `/k/:kind/new/:relation/:parent` |
   | `item` | `/k/:kind/:key` |
   | `edit`, `delete` | `/k/:kind/:key/edit`, `/k/:kind/:key/delete` |
   | `links`, `set`, `remove` | `/k/:kind/:key/links/:relation`, `…/set/:relation`, `…/remove/:relation` |
   | `answer` | `/k/:kind/:key/answer/:answer`: an owner's declared answer (a change it makes as itself), a confirm or, when the answer needs one, a note |

2. **Page and endpoint stay separate concepts** (as in mica). A page is a fetch of a view model; an endpoint is any call. The DSL expands each page into the endpoint that fetches it (`call: :open`), so `__schema__/0` and `blocks.json` have one list of endpoints. Form submits (IS-Atlas-71) and the session's other calls (IS-Atlas-72) join that list as their own `defendpoint`s.

   **`defendpoint name, path, call:, takes:, replies:`** (IS-Atlas-71). `call` is the message an endpoint travels in; names and paths are unique per call, and `:open` is the pages'. The form submits are endpoints of call `:submit`: `create`, `create_under`, `update`, `delete`, `link`, `accept`, `answer` and `reopen`, on the paths of the pages whose form or confirm they come from. Each takes `:values`, the form's inputs by name (what they hold comes from rela's description, at run time, so no kind is named), and replies `stored` (the page to go to next) or `refused` (the form again, with its errors). Control dispatches a submit by its endpoint (`endpoint(:submit, to)` in the targets); a `to` that is no submit endpoint is refused before anything is read or written. In IS-Atlas-71 `submit_to` and `confirm_to` stayed a path on the wire; IS-Atlas-72 makes them a `call`, `{"endpoint": "update", "params": {"kind": ..., "key": ...}}` (`params` a map of text, a type the DSL gains: `{:map, :string}`), which a client sends as it is: `{"op": "submit", "endpoint", "params", "values"}`. A test fails when a form submits anywhere but a contract endpoint.

   **The session's other calls** (IS-Atlas-72) are endpoints too, most without a path (`defendpoint name, call:, …`): `hello` (takes the `hello` model, replies `welcome` or `bye`), `refresh`, what Control sends unasked (`page` by hint, `notice`, `bye`), and the agent's `ask`, `run`, `cancel` and `stop` (replying the `plan` block and notices). Their messages are models of the contract (`hello`, `welcome`, `bye`, `notice`, `ask`, `run`, `run_step`). What an endpoint takes is a model or `values`; what it replies is a model, a block or a view model, checked at compile time.

6. **Every hello carries the contract version the client implements** (as mica plans, every call carries it; for a socket session, the hello is once per session). Control on a newer contract than the client's, or a client that says none, answers bye: `This client implements contract 0.10.0; Control test speaks 0.11.0. It is too old: …`, and closes, so an old client never breaks on what it cannot render. A newer client is welcomed; it renders what it knows and the rest as fallbacks. Rendering for an older version, content negotiation proper, is left until a client cannot simply be updated (an iOS app in the store).

3. **The rules are the generator's** (`AtlasBFF.Paths`): parse a path, match a path to a page, build a page's path. Where two pages could match one path, a literal beats a parameter at the first segment where they differ (`/k/:kind/new` over `/k/:kind/:key`), so the order pages are written in does not matter; two pages with the same literals in the same places are refused at compile time. Values are percent-encoded in a path and decoded when matched.

4. **The targets give every consumer the pages.** The server and client targets define `pages/0`, `match/1` and `path/2`; the JSON target lists `pages` and `endpoints`. Control's router is the contract: `Pages.route/1` and `Pages.path/1` go through `match/1` and `path/2`, and a path outside the contract gets a "No such page" page. The TUI asks only for destinations that are pages of the contract. A test fails when a page Control renders names a destination that matches no page.

5. **Navigation belongs to the client** (as in mica). A block carries only its destination. The contract's pages let a client recognise what Control serves; the client decides how to show it.

### Where Atlas differs from mica

- **Pages take parameters.** mica's pages are named and parameterless (`defpage :home` → `GET /bff/page/home`). Atlas's pages are generic, for any kind rela describes: kind, key, relation and parent are parameters, never kind names (BEAM runs, rela describes).
- **Atlas keeps its paths.** mica derives the path from the page name. Atlas keeps `/k/<kind>/<key>` and the rest, because stored facts name them (an agent request's `page`), and because `_` (a kind made out from a key's prefix) and `_parent` (a kind's one parent relation) are parameter values an agent passes, resolved by Control from the description.
- **No HTTP.** mica's pages are GETs at `/bff/page/…`. Atlas's clients speak JSON lines over a socket (`bff/README.md`, Protocol); a page is fetched with `{"op": "open", "to": path}`. The endpoint's `call` names that message.

## Alternatives

| Option | Why not |
|---|---|
| Keep the router in Control | Every client would go on learning the pages only by following links, and nothing would check a destination. |
| Paths from page names, as mica | Facts already store today's paths; a new path for every page would break them and the agent requests that name them. |
| Pages per kind (`defpage :scene, …`) | Names a kind in the contract; a new kind would be a contract change instead of data in rela. |
| Order-dependent matching | A contract whose meaning changes when two lines swap. The rank rule, with a compile-time check for pages that match the same paths, has no order to get wrong. |

## Consequences

- A new page is a `defpage` in the contract and a clause in Control's `route/1`; the test that every contract page is served fails until both are there.
- Clients in other languages read the pages from `blocks.json` and implement `AtlasBFF.Paths`'s rules.
- The contract is 0.9.0 with its pages, 0.10.0 with its submit endpoints, and 0.11.0 with the session's calls and `submit_to` as a call. 0.11.0 changes the wire: every client (the TUI, the agents' command line) moves with it, and an older one is told it is too old.
