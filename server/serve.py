#!/usr/bin/env python3

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import socket
from threading import Thread
import time
import traceback
import os
import sys
import struct

defaultport = 35355
magic = " \0\r\n  \x02\n \x08\rAnYgAmE \n\n"
version = "0.2.0"

if len(sys.argv) < 2:
    print("expecting a game directory as command-line argument")
    sys.exit(1)

gamedir = sys.argv[1]
if not Path(gamedir).exists():
    print("path '" + gamedir + "' does not exist")
    sys.exit(1)
gamename, _ = re.subn(r"[^a-zA-Z0-9_-]", "", Path(gamedir).name)


def packgame():
    zippath = Path.cwd().joinpath("game.zip")
    try:
        if zippath.exists():
            os.remove(zippath)
        out = subprocess.call(["zip", "-r", str(zippath), "."], cwd=gamedir)
        assert out == 0
        gamedata = zippath.read_bytes()
    finally:
        if zippath.exists():
            os.remove(zippath)
    return gamedata


def serialize(data):
    out = bytearray()
    out.extend(struct.pack("<H", len(data)))
    for key, value in data.items():
        k = key
        if isinstance(k, str):
            k = k.encode("utf-8")
        v = value
        if isinstance(v, str):
            v = v.encode("utf-8")
        out.extend(struct.pack("<H", len(k)))
        out.extend(k)
        out.extend(struct.pack("<H", len(v)))
        out.extend(v)
    return bytes(out)


def unserialize(data):
    out = {}
    (n,) = struct.unpack("<H", data[:2])
    offset = 2

    def read():
        nonlocal offset
        (vn,) = struct.unpack("<H", data[offset : offset + 2])
        offset += 2
        v = data[offset : offset + vn]
        offset += vn
        try:
            v = v.decode("utf-8")
        except UnicodeError:
            pass
        return v

    for i in range(n):
        k = read()
        v = read()
        out[k] = v

    return defaultdict(lambda: None, out)


clientlist = []
serving = set()
max_serving = 32


def check(cond, err):
    if not cond:
        raise ConnectionAbortedError(err or "Assertion failed")


def metadata(data):
    return serialize({"magic": magic, "version": version, **data})


@dataclass
class BroadcastAddr:
    ip: str
    asint: int
    bits: int

    def get(self, idx):
        idx &= (1 << self.bits) - 1
        if idx == 0 or idx == ((1 << self.bits) - 1):
            return None
        asint = self.asint & ~((1 << self.bits) - 1) | idx
        return f"{asint >> 24 & 0xFF}.{asint >> 16 & 0xFF}.{asint >> 8 & 0xFF}.{asint & 0xFF}"


def getbroadcastaddrs():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.connect(("1.1.1.1", 80))
        ownaddress, _ownport = sock.getsockname()
    parts = ownaddress.split(".")
    if not all(re.match(r"^[0-9]+$", part) for part in parts) or len(parts) != 4:
        return []
    parts = list(map(int, parts))
    if not all(0 <= part <= 255 for part in parts):
        return []
    out = []

    def add(ogbits):
        addr = list(parts)
        i = 3
        bits = ogbits
        while bits >= 8:
            addr[i] = 255
            i = i - 1
            bits = bits - 8
        if bits > 0:
            addr[i] = addr[i] | ((1 << bits) - 1)
        out.append(
            BroadcastAddr(
                ip=".".join(map(str, addr)),
                asint=parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3],
                bits=ogbits,
            )
        )

    if parts[0] == 192 and parts[1] == 168:
        add(8)
        add(12)
        add(16)
    elif parts[0] == 172 and parts[1] & 0xF == 16:
        add(8)
        add(12)
    elif parts[0] == 10:
        add(8)
        add(12)
        add(16)
        add(20)
        add(24)
    return out


def announce():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(("0.0.0.0", defaultport))
        targets = getbroadcastaddrs()
        lastbroad = -9999

        def send(to):
            sock.sendto(
                metadata({"name": gamename, "port": str(defaultport)}),
                (to, defaultport),
            )

        idx = 0
        freq = 100
        batchfreq = 4
        while True:
            try:
                now = time.monotonic()
                sentto = set()
                if now - lastbroad > 999999:
                    for target in targets:
                        send(target.ip)
                    lastbroad = now
                for _ in range(int(freq / batchfreq)):
                    for target in targets:
                        ip = target.get(idx)
                        if ip and ip not in sentto:
                            sentto.add(ip)
                            send(ip)
                    idx += 1
                time.sleep(1 / batchfreq)
            except OSError:
                traceback.print_exc()
                time.sleep(5)


def serve(peer, addr):
    try:
        print("serving connection from", addr)
        req = bytearray()
        while True:
            piece = peer.recv(4096)
            if len(piece) == 0:
                break
            req.extend(piece)
        if str(addr) not in clientlist:
            clientlist.append(addr[0] + ":" + str(addr[1]))
        req = unserialize(req)
        check(req["magic"] == magic, "invalid magic sequence")
        check(req["version"], "invalid version")
        if req["what"] == "head":
            peer.sendall(metadata({"name": gamename}))
        elif req["what"] == "get":
            print("serving game to", addr)
            peer.sendall(metadata({"name": gamename}))
            peer.sendall(packgame())
        else:
            check(False, f'unknown "what": {req["what"]}')
    except Exception:
        traceback.print_exc()
    finally:
        peer.close()
        serving.discard(str(addr))


Thread(target=announce).start()

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", defaultport))
    sock.listen()
    print("serving '" + gamedir + "'")
    while True:
        peer, addr = sock.accept()
        if len(serving) >= max_serving:
            peer.close()
        else:
            serving.add(str(addr))
            thread = Thread(target=serve, args=(peer, addr))
            thread.start()
