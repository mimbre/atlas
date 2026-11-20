# Driving Atlas from an agent

Agents use the same Control as the TUI, from the command line: `atlas help`, `put`, `set`, `delete`, `get`, `list`. Nothing writes rela directly. The same rules, refusals and generated codes apply, and an open TUI shows each change at once. `atlas help` (or `atlas put --help`) lists the kinds, what a create asks, how ids are made, what a kind belongs under and its fields, all from rela's description. Every command takes `--json` and then prints one JSON value: the item, the list, or `{"refused": [...]}`. The exit status is 0 when done, 1 when refused (the reasons also go to stderr) and 2 on an error. Like `atlas`, it works on prod unless given `--env test`.

```sh
atlas put use_case --in SC-Atlas-05 --title "Read items from the command line" --description-file uc.md --env test --json
atlas set IS-Atlas-33 stage=development --env test --json
atlas set IS-Atlas-33 stage=design --cause "the design is not settled" --env test --json   # why, kept with it
atlas put pull_request --url https://github.com/mimbre/atlas/pull/14 --in IS-Atlas-33 --env test --json
```

`--in <code>` names the parent, `--<field>-file <path>` or `--<field> -` (stdin) reads text of several lines, and `atlas get <code>` and `atlas list <kind> [--in <code>]` read.

Control connections optionally accept
`ATLAS_CONTROL_ENDPOINT=tls://<full-node-name>.tail8263c4.ts.net:<port>`. This selection
also reaches discovery, the TUI's `steer` child and worker-output sockets. System CA
trust and the complete hostname/SNI are checked before hello or any grant/request.
An explicit empty/invalid value or TLS failure fails closed without opening a Fly
tunnel or trying plaintext. Unset the variable to preserve the existing settings and
shared Fly tunnel behavior. This does not select a new environment or change Bus or
Runtime transport. Optional server activation requires the separate policy review in
[prod.md](prod.md#optional-control-tls-ingress-not-activated); real Fly certificates,
enrollment and Serve ingress remain unverified.

An agent that plans gets the same actions as tools: `atlas tools` lists them, made from rela's description through Control. `atlas plan --on <code> "<request>"` asks the environment's planner (`agent.planner` in `products/software_factory/environments/<env>.json`: a local `claude -p` that may only read, or any command) what it would do on that page. It answers steps, each checked against the form it would fill, and writes nothing ([uc-atlas-16.md](uc-atlas-16.md)). In the TUI, `:` asks the same agent (`atlas steer`, which the TUI starts) about the page you are on; you keep, edit or drop each step, and the kept ones run through Control ([uc-atlas-17.md](uc-atlas-17.md)).

`atlas put <kind> ... --link <association>=<key>[,<key>]` (repeatable) links the new fact right after it is made, each through its association's own form. When a link is refused, the fact stays made and the refusal names its key (`GV-0007 is made, but not linked`), so `atlas set GV-0007 about=PR-12` finishes it.

## A page's actions

Whatever a page in the TUI offers works from the command line too, without a command of its own. `atlas actions <code>` lists the actions Control offers on its page (label, key and where it goes). `atlas do <code> "<label or key>"` does one as the TUI does: it opens the action's page and submits its confirm, or its form with the values the form holds and those given as `--<input> <text>` (`--<input>-file <path>` and `-` read as for `put`). It prints the page Control shows after it, its blocks as the contract lays them out, or with `--json` the page as Control sent it. `--help` prints the action's page, with the inputs its form asks, and submits nothing; a name the form does not ask is answered with the inputs it does.

```sh
atlas actions IS-Atlas-07
atlas do IS-Atlas-07 "Pick up"
atlas do IS-Atlas-07 "Hand to…" --to mac-mini
```

`actions` and `do` without `ATLAS_AS` act as the person at the TUI (the environment's `tui_user`): the command line on Melle's own machine runs for him, so an action only a person may take, as Pick up, is his. An agent always sets `ATLAS_AS=<agent key>`; `actions` and `do` then act as that agent, and Control offers and allows what it offers and allows an agent. The other commands stay an agent's. A Runtime starts every agent with `ATLAS_AS` set to its slot, so the slots in a Runtime's `policy.json` are agent keys the environment knows and lists in `assists` (the mini's `dev1`…`dev6`).

An agent is always a person's assistant, never a supervisor itself. Whom each agent assists is the environment's `assists` setting (`"assists": {"coordinator": "melle", …}` in `products/software_factory/environments/<env>/core.json`). An agent that assists someone gets Pick up and picks a flow up on that person's behalf: the input is the agent's (`by` names it), and Flow makes the person the supervisor, so its questions and "Merge it" go to them. The item then shows who did it:

```sh
ATLAS_AS=coordinator atlas do IS-Atlas-07 "Pick up"
atlas get IS-Atlas-07
#   Supervised by: melle (since …, by flow: Picked up by coordinator on behalf of melle)
```

Hand over… stays the supervisor's own; an agent that assists nobody picks nothing up.

## Retrying or removing a stuck scene, use case or issue

Its supervisor (or an agent that assists them) handles a stuck or failed item from its page, in the Console or with `atlas do` (IS-Atlas-09):

```sh
ATLAS_AS=coordinator atlas do IS-Atlas-07 Retry    # back to its working step, fresh agent work
ATLAS_AS=coordinator atlas do IS-Atlas-07 Remove   # deleted, with its tasks and their attempts
```

- **Retry** (`y`), while its flow is in a supervised part: the run goes back to the first step of that part (an issue to Working, a scene or use case to its break-down), the task it held is cancelled, and a fresh task is offered to the supervisor's Runtimes. Facts and Flow check again that it comes from the supervisor.
- **Remove** (`m`), in any state: its tasks and their attempts are deleted, then the item itself, which ends its run (IS-Atlas-16). While nobody supervises it, the environment's decider removes it. An item with anything else under it (the issues of a use case, the use cases of a scene) is refused: remove those first. Its pull request, if it has one, stays open on GitHub: close it there.

## Restarting a completed scene or use case

Reopening a scene or use case after its flow run has completed does not start the run again. Use its item page in the TUI: as the current Assignment owner, when one is linked, or the environment's configured decider, choose **Restart** (`g`), then confirm **Restart**. Opening the confirmation or cancelling it sends no restart request. From the command line it is `atlas do <code> Restart`.

Control reads the item again at confirmation, and Facts independently checks who may restart it. The request must name the latest completed generation and the item must still match that flow's selection. An active run cannot be restarted; an unauthorized actor or a stale request naming an older generation is refused. Refresh the item page after a refusal to see its current run and owner.

An accepted request starts a fresh generation of that subflow from its initial state, using the item's current facts; its branches may move it on immediately. The previous generation retains its completed state and history. The new generation supplies the current work and owner. Retrying the same recorded request, including recovery after Facts or Flow restarts, does not create an extra generation.

## Recording a gate verdict

Every gate decision is a `gate_verdict` in Rela: which gate (`gate`, `gate_version`, `flavor` rule or smart, `purpose` flow or decider), what it decided on (`subject` and its `fingerprint`, `evidence` references and the `evidence_digest` of the immutable evidence snapshot), how it came about (`rule_outcome`, `rule_version`; for a smart gate also `advisor`, `model`, `rationale` and `scores` per outcome), the outcome (`verdict`, `allowed_outcomes`, `unsettled` when uncertain or an error), `cost`, `duration_ms` and `decided_at`. A rule gate must give its rule outcome and version; a smart gate also its advice. Its links are `about` (the fact it decided on), `follows` (the previous verdict on the same subject, so an episode can be read as a whole) and, later, `overruled_by` (the person who overruled it, in the TUI, as themselves).

Facts keeps it as a record (`sealed` on the gate verdict in `products/software_factory/model/contract/foundation/gate_verdict.ex`, generated into `products/software_factory/model/targets/rela/atlas.json`): never deleted or edited; record a new verdict that `follows` it instead. Only the later outcomes stay open, each set once and never changed: `overrule_reason`, `rework_after`, `defect_after`, `effort`, and every link while it is empty. Sending a value that is there already changes nothing.

Gates (`platform/atlas_gates`) evaluates a gate and records its verdict; nobody writes a verdict by hand. Until Flow asks Gates itself, the coordinator asks it for today's rule gate, integrate (green CI on the integrated head and a matching fingerprint), once per decision:

```sh
cd products/software_factory && mix atlas.gates.evaluate --gate integrate --subject PR-12 \
  --fingerprint "$fingerprint" --evidence-file /abs/evidence.json --env test \
  --link about=PR-12 --link follows=GV-0006            # [--allowed integrate,refuse] [--json]
atlas set GV-0007 rework_after="CI failed on main after integrating (run 4711)"   # later, once
```

The evidence file is one JSON object of named fields, as the coordinator collects them (`ci_conclusion`, `ci_head`, `integration_head`, `review_fingerprint`, `integration_fingerprint`, …); keep it, its `sha256:` digest is recorded. Gates applies the gate's definition from the model it is wired to (`products/software_factory/model/contract`, compiled into the umbrella; its rule, decide map and version: data, not code), records the verdict through Control with the `atlas` client, and prints it with its key:

```
integrate: GV-0007 recorded now
  gate integrate version 1, rule outcome pass, rule sha256:f0b4f0febb34c851
  subject PR-12 at fpr_767c…, evidence sha256:f006…
  request GR-d768…, evaluated in 0 ms
```

A field the rule needs that is missing or empty, or one the gate does not declare, is `uncertain`; it and any error give `person`. Asking the same again (same gate and rule version, subject, fingerprint and evidence) prints the first verdict, `recorded before, nothing new`. Exit status 0 when the verdict is recorded; 2 when it could not be evaluated or recorded: the printed verdict is then `person` (an error), and nothing may integrate on it. Leave out `follows` for the first verdict on a subject.

It is a mix task, not an `atlas` command: `atlas` is Control's client and knows no gate; Gates is a BEAM component, and a component in a node with the core's Bus records over the Bus directly (`AtlasGates.Facts.Bus`).

## A turn reads decisions first

`atlas turn` names the running turn and its item, then, before the item itself, what the worker reads first: the decisions the item is `based_on`, each with the decisions it `follows_from`, and first the accepted principles, whatever their scope (they are never broken), and after the based-on decisions the accepted guidelines and guardrails whose scope applies (`platform` and `software` here). One short line each: id, title, force and status, and the rule. `atlas turn --json` gives the same text as `read_first`; it is left out when nothing applies. Runtime puts the same text at the top of the worker's fixed context, above the commands it may use, so a worker starts from the ledger instead of searching markdown.

```text
Turn TU-mini-AS-SC-Atlas-07-1 on SC-Atlas-07

Read these decisions first.
Principles, never broken:
- D-0050 An agent never accepts its own work (principle, Accepted): …
Based on:
- D-0040 Every interaction is a message in a Rela Channel (direction, Accepted): …
  follows from D-0024 Atlas builds Atlas (direction, Accepted): …
Guidelines and guardrails that apply:
- D-0066 Screaming architecture (guideline, Accepted): Code is structured by what it does …
```

What it reads is data, not code: `read_first` in `products/software_factory/model/contract/compositions/atlas_eyra.ex` (generated into `products/software_factory/model/targets/rela/atlas.json`) names the relations, the standing values (status, force, scope) and the fields shown.

Two more things follow from `based_on`. An accepted decision that no work is based on yet waits in Open work, with its consequences as what is expected, until a scene or use case is `based_on` it, or someone records that none is needed (`atlas set D-0040 no_work=true`, the one change an accepted decision still takes). Work based on a superseded decision shows `Review: based on a superseded decision` with that decision's id on its page and in lists; it is worked out on every read and never stored, so it goes once the work is based on the new decision instead.
