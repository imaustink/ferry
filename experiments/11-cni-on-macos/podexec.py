#!/usr/bin/env python3
"""Run a command in a ferry pod with NET_ADMIN, over ferry-cri's exec socket."""
import json
import socket
import struct
import sys

sock_path, container, *cmd = sys.argv[1:]
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.connect(sock_path)
header = {
    "op": "exec",
    "containerID": container,
    "cmd": cmd,
    "caps": ["NET_ADMIN"],
    "env": ["PATH=/opt/cni/bin:/.ferry:/usr/sbin:/usr/bin:/sbin:/bin"],
    "stdin": True,
    "tty": False,
}
conn.sendall(json.dumps(header).encode() + b"\n")
conn.sendall(struct.pack(">BI", 0, 0))

while True:
    head = b""
    while len(head) < 5:
        part = conn.recv(5 - len(head))
        if not part:
            sys.exit(0)
        head += part
    channel = head[0]
    (length,) = struct.unpack(">I", head[1:])
    payload = b""
    while len(payload) < length:
        part = conn.recv(length - len(payload))
        if not part:
            break
        payload += part
    if channel in (1, 2):
        sys.stdout.write(payload.decode(errors="replace"))
    elif channel == 3:
        sys.stdout.flush()
        sys.exit(payload[0] if payload else 0)
