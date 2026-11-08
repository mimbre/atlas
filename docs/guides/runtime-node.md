# A private Runtime node (IS-Atlas-91)

Runtime can run on a separate machine without Erlang distribution. Its Bus connects
through a private TCP link, forwarding envelopes and replaying endpoints and listeners
after reconnect. The node starts only Runtime and Bus. Runtime endpoints include
`runtime@<machine>`, `runtime@<machine>/<turn>` and `runtime@<machine>/output`;
Control discovers exact machine endpoints for failure actions. A node with no
configured agents starts no Runtime engine, but still starts its output endpoint.

Tracked test core settings enable the private Bus listener on `::`, port `7694`;
the Fly configuration declares no public service for it. Production remains opt-in.
The coordinator must install the test machine-token secret before deploying this
configuration: missing or malformed `ATLAS_BUS_LINK_TOKEN` prevents core startup.
Connecting a node does not start a worker or authorize model turns.

The test core configuration is:

```json
{"bus_link": {"host": "::", "port": 7694}}
```

The core secret `ATLAS_BUS_LINK_TOKEN` is a JSON object mapping machine names to distinct
random tokens. Binding the token to a machine prevents one admitted machine from
attaching another machine's endpoints. The local keychain item has service
`atlas-bus-link-test`, account `<machine>`, and that machine's token as its password.
Never put tokens in tracked settings. Test and prod use separate secrets and keychain
services. The wire is JSON lines over the encrypted `fly proxy` tunnel, not public TCP.

Create `~/.local/share/atlas/test-runtime/runtime.json` locally:

```json
{
  "env": "test",
  "bus_link": {"mode": "client", "host": "127.0.0.1", "port": 7695,
               "remote_port": 7694, "machine": "macbook"},
  "runtime": {"machine": "macbook", "agents": {}}
}
```

This connection-only example uses local tunnel port `7695` to test's private Bus
port `7694`, with a token bound to `macbook`. With `agents: {}`, it connects without
creating workers: after Bus authentication it registers `runtime@macbook/output`,
but no engine registers `runtime@macbook`. Configuring agents or assigning work
requires separate authorization; an authenticated connection is not a running worker.

`atlas runtime --env test` starts the tunnel and node in the background;
`atlas runtime-status --env test` reports its process and log;
`atlas runtime-stop --env test` stops that node and its tunnel. A started process can be
waiting to reconnect; process status proves neither authenticated remote registration
nor a running worker. Consult its log for link progress and, when work is running,
the turn's lease in Control.
The token is removed from Runtime's process environment before agent ports start.
Agents' CLI calls still use the ordinary environment file and reach Control.

The separate standalone `atlas-runtime` CLI runs native workers through a local Runtime
service and Unix socket ([service guide](../../tools/runtime/README.md)). By default it
has no Atlas Server connection. Optional `server.json` configuration reports allowlisted
workers' lifecycle to Server for Console visibility; output streaming is not available
in this mode yet. Server does not gain orchestration or worker controls through this
connection. Local `status` and `output` remain usable without Server and do not establish
registration of the connected `atlas runtime` node described here.

Private test instances use `ATLAS_RUNTIME_FILE` and `ATLAS_RUNTIME_HOME` pointing inside
their temporary directory, a loopback link, and an ephemeral `ATLAS_BUS_LINK_TOKEN` in
the launching environment. They need no keychain or Fly. The e2e runner uses this path:
UC-07's turns run in a separate OS process; restarting the core cuts the link and
registrations return. Restarting Runtime ends orphaned turns and starts new ones.

Readonly machine status (IS135): `atlas runtime status --env test
--machine macbook --json` inspects the selected local node. The existing
`runtime-status` alias derives an omitted machine from Runtime configuration.
Missing identity fails explicitly. The shared DSL generates options, machine DTO,
codecs and validators; exact worker identity remains separate.

Status creates no Runtime directories or bytecode cache, starts no service, opens
no Control/Bus/Fly connection and reads no keychain token. Shared contract codecs
must already be built; run `mix compile` in bff/contract as explicit setup. Missing
codecs fail visibly. JSON reports absent, stale, unverified or unsupported with
exact target, evidence basis and optional PID/log. A live legacy PID is unverified,
because PID existence cannot establish Runtime role/instance/start ownership or
health. Wrong environment/machine is explicit; no worker identity is invented.

Verified local lifecycle (IS136) uses `atlas runtime start|stop --env test
--machine macbook --json` through the same generated machine contract. Bare
`atlas runtime` remains the start alias; `runtime-stop` remains the stop alias.
These are explicit same-user local operations. Machine lifecycle never attaches a
viewer or selects a worker. Remote status remains unsupported; IS127 stays open
for authorized availability through existing Control. Self-reported client identity
does not grant remote access.

Start binds the canonical checkout, instance directory, configuration path,
environment, machine and fresh instance nonce in the Runtime boot arguments and
retained record. OS UID, process birth, exact role arguments and retained PID must
agree before a repeated start returns the existing node or stop sends SIGTERM.
Lifecycle requests serialize with an exclusive instance lock. PID-only legacy,
stale/reused, out-of-range, wrong-role and mismatched records refuse actions.
Stop never signals a process group or escalates to SIGKILL. Each exact process is
rechecked immediately before its individual signal; exit must be confirmed before
its PID record is removed. This is same-user OS process management, not an atomic
kernel identity-and-signal primitive or protection against a malicious same-user
process modifying records concurrently.

A startup receipt confirms that the existing IS91 node started Runtime and Bus
without State/Flow/Control. Owned process status does not assert Bus connectivity,
worker health or model readiness. A partial startup, unknown OS identity or
unconfirmed exit fails visibly and preserves records; there is no blind cleanup
or PID-only recovery. The lock is never cleared by guessing whether its PID is
alive. Inspect the retained evidence before manual recovery. Logs, configuration,
startup receipts and completed process birth records survive stop and restart;
a new start archives the prior stopped instance record.

Status still performs only reads. The local lifecycle capability flags describe
supported actions for the observed/configured instance, not credential or remote
availability. No credentials are probed by status. No listener, guidance pipeline
or model is added. Successful diagnostic exit means a report was produced, not
that Runtime is ready. Contract codecs must be built explicitly before any CLI
operation; start uses the existing Mix node boot, which can compile that checkout.

Authorized discovery (remaining IS127): `atlas runtime discover --env test
--machine macbook --json` uses the ordinary generated agent client and existing
Control listener. It never opens/manages a proxy, starts a service or signals a
process. Supply already-authorized Control connectivity. A missing connection,
timeout or unsupported older Control remains an error, never machine absence.

A separate explicit read capability is required on every request. For a private
server, opt in with `control.runtime_read_token_env` naming an environment variable
whose JSON object maps exact machine names to their read tokens. Leave this field
absent for default denial. The client reads its one token from
`ATLAS_RUNTIME_READ_TOKEN`, never an argument or hello/as. Use independent random
read tokens; never reuse the Bus link writer credential. This change installs none.
Only private synthetic examples/configurations were used to verify it.

Control revalidates normal hello admission, exact environment/machine and the
read grant before accessing the Bus registry. It reuses the existing Bus token
comparison primitive, with a separate configured read realm. No actor string,
migration claim, person/role lookup or Bus writer token implicitly grants this
operation. Missing, malformed, wildcard, wrong-scope or revoked grants fail closed;
revocation is checked each request. Configured variable names must be ASCII
identifiers (letters/underscore first, then letters/digits/underscore); malformed
names deny before lookup, preserving the session without logging the bearer. This is a machine-scoped bearer capability,
not authenticated human sign-in or a new role engine. No live defaults change.

The reply contains only the requested exact machine's `registered` flag and
`bus_endpoint_registry` basis. An exact `runtime@machine` entry counts; neither a
turn endpoint nor `runtime@machine/output` alone counts. Thus a connection-only
node with `agents: {}` can be authenticated and connected while discovery returns
`registered: false`. This is a point-in-time endpoint observation, not a probe
of link responsiveness, worker lifecycle, models or leases. There is no global
machine enumeration. Typed refusals, registry failure and transport/malformed or
identity-mismatched replies are distinct from a successful unregistered result.
Result/error correlation and nested target are checked; ordinary hint traffic
remains independent under one fixed request deadline. The CLI may compile its
ordinary client as usual, but never builds/starts Runtime. Local status does not
probe credentials or infer remote access from the existence of this command.
The read token is stripped before configuration/build/lifecycle helper children,
including keychain, Fly proxy and Runtime startup, and restored only to the final
explicit discovery transport. Direct lifecycle helpers independently sanitize all
their child environments.

Delivery remains the Bus's best effort contract: reads/facts retry and reconcile from
State. Machine leases and Flow failover across machines remain follow-up work; this
link does not end a sleeping machine's turns on another machine's behalf.

Control keeps one read envelope/ID across its three attempts, so a late answer from
an earlier attempt still satisfies the current logical read. Ordinary reads retain
three two-second waits; Open work scales each wait by its collection count.
Unrelated answers do not reset those waits. A later logical read gets a new ID and
reads current data. Retries remain necessary because delivery is not guaranteed;
State may still execute queued duplicate reads. This does not add read deduplication
or concurrency, and durable fact replay is unchanged.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0015).</sub>

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
