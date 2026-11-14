#!/usr/bin/env python3
"""Check Control through a proxy, not merely its local listening socket.

A welcome or explicit hello refusal proves transport works. Leave refusals (such
as an old client contract) to the actual client; restarting a proxy cannot fix
those. This sends no commands that write data and never replays client requests.

Usage: control-ready.py SETTINGS CONTRACT [TIMEOUT_SECONDS]  (default 3)
"""
import json
import socket
import sys
import time
from pathlib import Path


def probe(settings, version, timeout=3):
    deadline = time.monotonic() + timeout
    control = settings["control"]
    hello = {"op": "hello", "env": settings["env"], "client": "agent", "spec": version}
    with socket.create_connection((control["host"], control["port"]), timeout=timeout) as sock:
        sock.settimeout(max(0.001, deadline - time.monotonic()))
        sock.sendall(json.dumps(hello).encode() + b"\n")
        line = bytearray()
        while b"\n" not in line:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("Control handshake timed out")
            sock.settimeout(left)
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("proxy closed before Control answered")
            line.extend(chunk)
            if len(line) > 65536:
                raise ValueError("Control handshake exceeds 64 KiB")
        answer = json.loads(line.split(b"\n", 1)[0])
        if isinstance(answer, dict):
            if (answer.get("op") == "welcome" and answer.get("env") == settings["env"]
                    and isinstance(answer.get("spec"), str)):
                return
            if answer.get("op") == "bye" and isinstance(answer.get("text"), str):
                return
        raise ValueError("endpoint did not answer with a Control handshake for this environment")


if __name__ == "__main__":
    try:
        settings = json.loads(Path(sys.argv[1]).read_text())
        contract = json.loads(Path(sys.argv[2]).read_text())
        timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 3
        probe(settings, contract["version"], timeout)
    except (OSError, ValueError, KeyError) as error:
        print(f"Control is not reachable: {error}", file=sys.stderr)
        sys.exit(1)
