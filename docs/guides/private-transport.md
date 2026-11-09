# Private Control and Bus transport

Remote Control and Bus connections use server-authenticated TLS on the existing
private ports. No public service is added. DNS suffixes, tailnet membership,
TCP probes and protocol welcomes do not authenticate the destination.

Operational prerequisites remain unverified: actual full environment-specific
tailnet names, issued server certificates, protected key/certificate paths, trust
distribution where needed, and renewal ownership. This branch must not cut over
until those are supplied and verified. No certificate issuance, installation,
tailnet configuration or key/ACL changes are authorized by this guide.

`env/test.json` and `env/prod.json` deliberately have no destination hostname.
Set `ATLAS_CONTROL_TEST_HOST` and `ATLAS_CONTROL_PROD_HOST`, respectively, to the
confirmed full certificate names. They must be full `.ts.net` names. A missing
name refuses the connection; short names and remote plaintext are refused.
The exact configured hostname is used for SNI and normal certificate hostname
verification. OTP's system CA store supplies trust by default; `tls.cacertfile`
can name an explicitly provisioned CA file. Private proof CAs grant no live trust.

For each core, supply `ATLAS_TLS_CERTFILE` and `ATLAS_TLS_KEYFILE` as paths to
provisioned PEM files. The private key must be a regular file readable only by
its owner. Missing files, malformed TLS configuration, untrusted/expired
certificates and hostname mismatches fail closed. The core's Control and Bus
settings require TLS; listener addresses and ports remain private. Provisioning
must retain the absence of public Fly services and existing network boundaries.

A Runtime node's `bus_link` must have its real full `host`, private `port`, and
`"tls": {}` (system trust), or `"tls": {"cacertfile": "/protected/ca.pem"}`.
Keep its existing environment/machine/token bindings. Update every Runtime
client configuration separately after verification; configuration is read on
startup. Reconnects repeat certificate verification before evaluating/sending
the Bus token or replaying registrations.

The agent (including direct `atlas discover`), TUI and TUI output connection
authenticate before sending any hello, request, read grant or worker output.
Their protocol, environment, capability and authorization checks still apply.
The shell's `nc` probe is only a reachability hint; successful application TLS
authentication remains mandatory. Errors never select plaintext or another host.

Each listener admits at most 64 peers, including established sessions and pending
handshakes, under its own Task.Supervisor. Excess peers are closed immediately;
closing a session or timing out a handshake releases its slot. TLS handshakes have
the existing five-second deadline and run in the peer's process, so an idle peer
does not block admission of another client within the available capacity. Raw TCP
probes and failed handshakes close only that peer and never start a protocol
session. Unexpected acceptor loss is monitored and recovered while healthy
sessions remain connected. Listener shutdown closes its owned peers and tasks.

Standalone local instances may omit `tls` only when connecting/listening on a
literal loopback address (`127.0.0.1` or `::1`). This is a local configuration,
never a fallback after a failed remote connection. The Runtime viewer continues
to use its existing local Unix socket.

The shipped Swift SDK (`bff/targets/swift`) contains generated models, requests,
replies and `WireLine` JSON encoding/decoding, with no networking entrypoint.
It cannot authenticate a socket supplied by an application. The separate,
unmerged macOS S1 client is outside this branch: its future integration must use
Network.framework TLS with system trust and the exact configured full hostname,
wait for authentication before any protocol bytes, secure every output socket
and reconnect, and offer no trust override or plaintext fallback. iOS has the
same requirement. Neither app is claimed validated or activated here.
