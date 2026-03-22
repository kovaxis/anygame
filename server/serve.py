#!/usr/bin/env python3

from collections import defaultdict
from pathlib import Path
import re
import subprocess
import socket
from threading import Thread
import traceback
import os
import sys
import struct

defaultport = 35355
magic = " \0\r\n  \x02\n \x08\rAnYgAmE \n\n"
version = "0.2"

if len(sys.argv) < 2:
    print("expecting a game directory as command-line argument")
    sys.exit(1)

gamedir = sys.argv[1]
if not Path(gamedir).exists():
    print("path '" + gamedir + "' does not exist")
    sys.exit(1)


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


def serve(peer, addr):
    gamename, _ = re.subn(r"[^a-zA-Z0-9_-]", "", Path(gamedir).name)
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
        if req["what"] == "list":
            peer.sendall(metadata({"names": gamename}))
        elif req["what"] == "get":
            check(
                req["name"] == gamename,
                f"expected game name to match {gamename}, got {req['name']}",
            )
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
