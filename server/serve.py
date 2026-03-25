#!/usr/bin/env python3

from collections import defaultdict
from pathlib import Path
import random
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

# this is keepconnection line 0
keepconnection = r"""
local anygame = ...

_G._anygame = anygame

if anygame.ip and anygame.port then
    local send = love.thread.newChannel()
    local recv = love.thread.newChannel()

    local thread = love.thread.newThread(love.filesystem.newFileData([[ -- this is thread line 0
        require 'love.timer'
        require 'love.data'
        local socket = require 'socket'
        local args = ...
        local sock
        if args.socketfd then
            sock = socket.tcp()
            sock:close()
            sock:setfd(args.socketfd)
        end

        local function check(ok, warn)
            if not ok then
                print(debug.traceback('check failed: '..tostring(warn), 2))
            end
        end

        local function serialize(keyval, hello)
            local t = { '' }
            if hello then
                keyval.version = args.version
                t[1] = args.magic
                t[2] = ''
            end
            local n = 0
            for k, v in pairs(keyval) do
                n = n + 4 + #k + 4 + #v
                assert(n <= 2^30, 'too large')
                local s = love.data.pack('string', '<s4s4', k, v)
                t[#t + 1] = s
            end
            t[hello and 2 or 1] = love.data.pack('string', '<I4', n)
            return table.concat(t)
        end

        local function unserialize(s, i)
            i = i or 1
            local out = {}
            while i <= #s do
                local k, v
                k, v, i = love.data.unpack('<s4s4', s, i)
                out[k] = v
            end
            return out
        end

        local function downloadn(sock, n, wait)
            local buf = ''
            while #buf < n do
                local all, err, piece = sock:receive(n - #buf)
                if all then
                    buf = buf .. all
                    return buf
                elseif err == 'timeout' then
                    buf = buf .. piece
                    if wait then wait() end
                else
                    error(err, 2)
                end
            end
        end

        local function download(sock, wait, hello)
            local m = hello and args.magic or ''
            local prefix = downloadn(sock, #m + 4, wait)
            assert(prefix:sub(1, #m) == m, 'invalid magic')
            local len = love.data.unpack('<I4', prefix:sub(#m + 1))
            assert(len <= 2^30, 'too large')
            local payload = downloadn(sock, len, wait)
            local data = unserialize(payload)
            if hello then assert(data.version, 'no version') end
            return data
        end

        local function upload(sock, data, wait, hello)
            packet = serialize(data, hello)
            local i = 1
            while true do
                local ok, err, sent = sock:send(packet, i)
                if ok then
                    return
                elseif err == 'timeout' then
                    i = sent + 1
                    if wait then wait() end
                else
                    error(err, 2)
                end
            end
        end

        local function downloadloop()
            while true do
                local msg = download(sock, coroutine.yield)
                args.recv:push(msg)
                coroutine.yield()
            end
        end

        local function uploadloop()
            while true do
                local msg = args.send:demand(0.100)
                if msg == 'quit' then
                    return true
                elseif msg then
                    upload(sock, msg, coroutine.yield)
                end
                coroutine.yield()
            end
        end

        local function cycle()
            if not sock then
                assert(args.ip and args.port, 'no ip/port?')
                print('reopening anygame connection to ' .. args.ip .. ':' .. args.port)
                sock = socket.tcp()
                check(sock:settimeout(5))
                assert(sock:connect(args.ip, args.port))
                upload(sock, { what = 'stream' }, nil, true)
                local hello = download(sock, nil, true)
                assert(hello.what == 'stream', 'invalid "what", expected "stream"')
            end

            sock:settimeout(0.100)
            local uploadco = coroutine.wrap(uploadloop)
            local downloadco = coroutine.wrap(downloadloop)
            while true do
                local sdeadline = love.timer.getTime() + 0.090
                while love.timer.getTime() <= sdeadline do
                    if uploadco() then break end
                end
                local rdeadline = love.timer.getTime() + 0.090
                while love.timer.getTime() <= rdeadline do
                    downloadco()
                end
            end
        end

        while true do
            local ok, err = pcall(cycle)
            if sock then sock:close() end
            sock = nil
            if ok then break end
            print('anygame network thread error: '..tostring(err))
            love.timer.sleep(5)
        end
        print('exiting anygame network thread')
    ]], 'anygame-network-thread'))

    local socketfd
    if anygame.socket then
        print('socket is ', anygame.socket)
        socketfd = anygame.socket:getfd()
        anygame.socket:setfd(-1)
        anygame.socket:close()
        anygame.socket = nil
    end

    thread:start {
        magic = anygame.magic,
        version = anygame.version,
        send = send,
        recv = recv,
        ip = anygame.ip,
        port = anygame.port,
        socketfd = socketfd,
    }

    anygame.send = send
    anygame.receive = recv
    anygame.networkthread = thread
else
    print('no ip/port, cannot connect back to anygame server')
end
"""

options["logs"] = r"""
do
    local ogprint = _G.print
    _G.print = function(...)
        ogprint(...)
        local log = table.concat({...}, ' ', 1, select('#', ...))
        anygame.send:push({ what = 'log', log = log })
    end
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
if preload:
    preload = keepconnection + preload

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


def serialize(data, stream=False):
    m = b""
    if not stream:
        data["version"] = version
        m = magic
    out = bytearray(m)
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
    out[len(m) : len(m) + 4] = struct.pack("<I", len(out) - len(m) - 4)
    return bytes(out)


def unserialize(data, stream=False):
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
    if not stream:
        check(out["version"], "no version data")
    return out


def downloadn(sock, n):
    buf = b""
    while len(buf) < n:
        piece = sock.recv(n - len(buf))
        if len(piece) == 0:
            if len(buf) > 0:
                raise ConnectionError("unexpected eof")
            else:
                raise EOFError()
        buf += piece
    return buf


def download(sock, stream=False):
    m = b"" if stream else magic
    prefix = downloadn(sock, len(m) + 4)
    check(prefix[: len(m)] == m, "invalid magic")
    (length,) = struct.unpack("<I", prefix[len(m) :])
    check(length <= msglimit, "too large")
    packet = downloadn(sock, length)
    return unserialize(packet, stream)


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
                        **({"preload": preload, "keep": "true"} if preload else {}),
                    }
                )
            )
        elif req["what"] == "stream":
            print("serving stream to ", addr)
            peer.sendall(serialize({"what": "stream"}))
        else:
            check(False, f'unknown "what": {req["what"]}')

        colors = [31, 32, 33, 34, 35, 36, 37, 91, 92, 93, 94, 95, 96, 97]
        c = colors[random.randint(0, len(colors) - 1)]
        prefix = str(addr[0]) + ":" + str(addr[1])
        prefix = f"\033[1;{c}m[{prefix}]\033[0m "

        while True:
            try:
                msg = download(peer, True)
            except EOFError:
                break
            if msg["what"] == "log":
                check(msg["log"], 'expected "log" field')
                for line in msg["log"].splitlines():
                    print(f"{prefix}{line}")
            else:
                print(f'unknown "what": {req["what"]}')
        print(f"closing connection to {addr}")
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
