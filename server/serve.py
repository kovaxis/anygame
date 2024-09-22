#!/usr/bin/env python3

from pathlib import Path
import subprocess
import socket
import traceback
import os
import sys

defaultport = 35355

if len(sys.argv) < 2:
    print("expecting a game directory as command-line argument")
    sys.exit(1)

gamedir = sys.argv[1]
if not Path(gamedir).exists():
    print("path '"+gamedir+"' does not exist")
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

clientlist = []

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", defaultport))
    sock.listen()
    print("serving '"+gamedir+"'")
    while True:
        peer, addr = sock.accept()
        try:
            if str(addr) not in clientlist:
                clientlist.append('"' + addr[0] + ":" + str(addr[1]) + '"')
            print("serving game to", addr)
            preload = "anygameClients={"+",".join(clientlist)+"}"
            peer.sendall(preload.encode()+b"\0")
            data = packgame()
            try:
                peer.sendall(data)
                print("served successfully")
            except Exception:
                traceback.print_exc()
        finally:
            peer.close()
