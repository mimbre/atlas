#!/usr/bin/env python3
"""The door to rela on an environment's Fly private network (IS-Atlas-80).

rela listens on loopback only; this passes a request on to it only when it carries the
core's credential, `Authorization: Bearer $ATLAS_RELA_TOKEN` (a Fly secret of both apps),
so nothing else on the private network reads or writes rela: Facts is its only client.
rela issues no credentials of its own; its way for a machine client is an edge that
authenticates it (rela's docs/server-security.md, "Sync clients and other machine clients").
`GET /api/v1/_schema` passes without one: Fly's health check asks for it, and the schema is
the repository's.

  rela-gate.py <port> <rela port>      # listens on [::]:<port>
"""
import hmac
import http.client
import http.server
import os
import socket
import sys

PUBLIC = ("GET", "/api/v1/_schema")
# Hop-by-hop, or this edge's own: never passed on.
DROP = {"connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding",
        "upgrade", "host", "authorization", "content-length"}


class Gate(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 120  # an idle kept-alive connection closes after this
    token = b""
    rela = 0

    def forward(self):
        if (self.command, self.path) != PUBLIC and not hmac.compare_digest(
                self.headers.get("Authorization", "").encode(), self.token):
            sys.stderr.write(f"rela-gate: refused {self.command} {self.path.split('?')[0]} from {self.client_address[0]}: no credential\n")
            return self.answer(401, [("Content-Type", "application/problem+json")],
                               b'{"title":"unauthenticated","status":401}', close=True)
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            return self.answer(411, [], b"", close=True)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP}
        # rela serves its change feed only to its own origin; the caller is checked above.
        if self.path.startswith("/api/v1/_events"):
            headers = {k: v for k, v in headers.items() if k.lower() != "origin"}
            headers["Origin"] = f"http://127.0.0.1:{self.rela}"
        rela = http.client.HTTPConnection("127.0.0.1", self.rela, timeout=60)
        try:
            rela.request(self.command, self.path, body, headers)
            answer = rela.getresponse()
            kept = [(k, v) for k, v in answer.getheaders() if k.lower() not in DROP]
            # rela's change feed (GET /api/v1/_events) never ends: passed on as it comes.
            if answer.getheader("Content-Type", "").startswith("text/event-stream"):
                return self.stream(answer.status, kept, answer)
            data = answer.read()
        except OSError as error:
            sys.stderr.write(f"rela-gate: rela did not answer: {error}\n")
            return self.answer(502, [], b"", close=True)
        finally:
            rela.close()
        self.answer(answer.status, kept, data)

    def stream(self, status, headers, answer):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.close_connection = True
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        try:
            while chunk := answer.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        except OSError:
            pass

    def answer(self, status, headers, data, close=False):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        if close:
            self.close_connection = True
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = forward

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


def main():
    port, rela = int(sys.argv[1]), int(sys.argv[2])
    token = os.environ.pop("ATLAS_RELA_TOKEN", "")
    if len(token) < 32:
        sys.exit("rela-gate: ATLAS_RELA_TOKEN (a Fly secret, 32+ characters) is required")
    Gate.token, Gate.rela = f"Bearer {token}".encode(), rela
    Server(("::", port), Gate).serve_forever()


if __name__ == "__main__":
    main()
