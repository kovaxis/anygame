#!/usr/bin/env python3

from collections import defaultdict
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
magic = b" \0\r\n  \x02\n \x08\rAnYgAmE \n\n"
version = "0.2.0"
msglimit = 1024 * 1024 * 1024

options = {}

options["screenlogs"] = r"""
local ogprint = _G.print
local ogpresent = love.graphics.present

local fonth = nil
local font = nil
local logs = {}

_G.print = function(...)
    ogprint(...)
    logs[#logs+1] = table.concat({...}, ' ', 1, select('#', ...))
end

love.graphics.present = function()
    local ogfont = love.graphics.getFont()
    local r, g, b, a = love.graphics.getColor()
    love.graphics.push()

    local w, h = love.graphics.getDimensions()
    local wanth = math.floor(h * 0.01)
    if wanth ~= fonth then
        fonth = wanth
        font = love.graphics.newFont(fonth)
    end

    love.graphics.setFont(font)
    love.graphics.setColor(0, 0, 0)

    love.graphics.origin()
    local margin = h * 0.01
    local y = h - margin
    for i = #logs, 1, -1 do
        y = y - fonth
        if y <= -fonth then break end
        love.graphics.print(logs[i], margin, y)
    end

    love.graphics.pop()
    love.graphics.setColor(r, g, b, a)
    love.graphics.setFont(ogfont)
    return ogpresent()
end
"""

options["live"] = r"""
magic = " \0\r\n  \x02\n \x08\rAnYgAmE \n\n"
version = "0.2.0"


local args = ...
if not _G._anygame then _G._anygame = {} end

local threadSrc = [[
require 'love.timer'
local socket = require 'socket'

local function serialize(keyval)
    local n = 0
    for k, v in pairs(keyval) do
        n = n + 1
    end
    local s = love.data.pack('string', '<I2', n)
    for k, v in pairs(keyval) do
        s = s .. love.data.pack('string', '<s2s2', k, v)
    end
    return s
end

local function unserialize(s, i)
    i = i or 1
    local n
    n, i = love.data.unpack('<I2', s, i)
    local out = {}
    for j = 1, n do
        local k, v
        k, v, i = love.data.unpack('<s2s2', s, i)
        out[k] = v
    end
    return out, i
end

local ip, port, updates, control = ...

local quit = false

while true do
    local ok, err = pcall(function()
        local sock = socket.tcp()
        assert(sock:connect(args.ip, args.port))
        assert(sock:send(serialize {
            magic = magic,
            version = version,
            what = 'live',
        }))
        assert(sock:shutdown('send'))
        while not quit do
            while true do
                local ctrl = control:pop()
                if not ctrl then break end
                if ctrl == 'quit' then
                    quit = true
                end
            end
            if quit then break end

            local lenRaw = assert(sock:receive(2))
            local len = love.data.unpack('<I2', lenRaw)
            local metaRaw = assert(sock:receive(len))
            local meta = unserialize(metaRaw)
            assert(meta.magic == magic, 'invalid magic')
            assert(meta.version, 'no version')
            if meta.what == 'update' then
                local size = assert(tonumber(meta.size), 'no size')
                local zipstr = sock:receive(size)
                updates:push(zipstr)
            else
                print('received unknown "what": '..tostring(meta.what))
            end
        end
    end)
    if ok then
        break
    else
        print("_anygame.live error: "..tostring(err))
        love.timer.sleep(5)
    end
end
]]

function _anygame.live()
    if not args.ip or not args.port then
        return nil, 'no ip/port, cannot connect for live stream'
        return
    end
    local updates = love.thread.newChannel()
    local control = love.thread.newChannel()
    local thread = love.thread.newThread(threadSrc)
    thread:start(args.ip, args.port, updates, control)
    return {
        updates = updates,
        control = control,
        thread = thread,
    }
end
"""

args = sys.argv[1:]

if len(args) < 1:
    print("expecting a game directory as command-line argument")
    sys.exit(1)

preload = ""
for option in args[1:]:
    if not option.startswith("--"):
        print(f"unexpected argument {option}")
        sys.exit(1)
    key = option[2:]
    if key not in options:
        print(f"unknown option {option}")
        sys.exit(1)
    preload += options[key]

gamedir = args[0]
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
    data["version"] = version
    out = bytearray(magic)
    out.extend(b"----")
    for key, value in data.items():
        k = key
        if isinstance(k, str):
            k = k.encode("utf-8")
        v = value
        if isinstance(v, str):
            v = v.encode("utf-8")
        out.extend(struct.pack("<I", len(k)))
        out.extend(k)
        out.extend(struct.pack("<I", len(v)))
        out.extend(v)
    out[len(magic) : len(magic) + 4] = struct.pack("<I", len(out) - len(magic) - 4)
    return bytes(out)


def unserialize(data):
    out = {}
    offset = 0

    def read():
        nonlocal offset
        (vn,) = struct.unpack("<I", data[offset : offset + 4])
        offset += 4
        v = data[offset : offset + vn]
        offset += vn
        try:
            v = v.decode("utf-8")
        except UnicodeError:
            pass
        return v

    while offset < len(data):
        k = read()
        v = read()
        out[k] = v

    out = defaultdict(lambda: None, out)
    check(out["version"], "no version data")
    return out


def downloadn(sock, n):
    buf = b""
    while len(buf) < n:
        piece = sock.recv(n - len(buf))
        if len(piece) == 0:
            raise ConnectionError("unexpected eof")
        buf += piece
    return buf


def download(sock):
    prefix = downloadn(sock, len(magic) + 4)
    check(prefix[: len(magic)] == magic, "invalid magic")
    (length,) = struct.unpack("<I", prefix[len(magic) :])
    check(length <= msglimit, "too large")
    packet = downloadn(sock, length)
    return unserialize(packet)


def parse(packet):
    check(packet[: len(magic)] == magic, "invalid magic")
    (length,) = struct.unpack("<I", packet[len(magic) : len(magic) + 4])
    check(length == len(packet) - len(magic) - 4, f"invalid length {length}")
    return unserialize(packet[len(magic) + 4 :])


clientlist = []
serving = set()
max_serving = 32


def check(cond, err):
    if not cond:
        raise ConnectionAbortedError(err or "Assertion failed")


def announce():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.bind(("", defaultport))

        while True:
            try:
                packet, fromaddr = sock.recvfrom(4096)
            except OSError:
                traceback.print_exc()
                time.sleep(5)
                continue
            try:
                msg = parse(packet)
                check(msg["what"] == "scan", 'expected scan "what"')
                sock.sendto(
                    serialize({"name": gamename, "port": str(defaultport)}),
                    fromaddr,
                )
                print(f"scanned by {fromaddr}")
            except Exception:
                traceback.print_exc()


def serve(peer, addr):
    try:
        print("serving connection from", addr)
        req = download(peer)
        if str(addr) not in clientlist:
            clientlist.append(addr[0] + ":" + str(addr[1]))
        if req["what"] == "head":
            peer.sendall(serialize({"name": gamename}))
        elif req["what"] == "get":
            print("serving game to", addr)
            peer.sendall(
                serialize(
                    {
                        "name": gamename,
                        "zip": packgame(),
                        **({"preload": preload} if preload else {}),
                    }
                )
            )
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
