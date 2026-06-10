#!/usr/bin/env python3
"""Send a raw JSON command to the AgentBridge and print the reply.
Usage: python raw.py '{"cmd":"ui","action":"hub_gunsmith"}'
"""
import json
import os
import socket
import sys

HOST = "127.0.0.1"
# Port: argv[2] or $AGENT_PORT or default 24700 (for driving multiple instances).
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("AGENT_PORT", "24700"))


def main():
    payload = sys.argv[1] if len(sys.argv) > 1 else '{"cmd":"ping"}'
    # validate / normalize
    obj = json.loads(payload)
    line = (json.dumps(obj) + "\n").encode("utf-8")
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall(line)
        buf = bytearray()
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf.extend(chunk)
    raw = bytes(buf).split(b"\n", 1)[0]
    print(raw.decode("utf-8"))


if __name__ == "__main__":
    main()
