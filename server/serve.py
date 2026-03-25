#!/usr/bin/env python3

from collections import defaultdict
from io import BytesIO
from pathlib import Path
import random
import re
import zipfile
import socket
from threading import Thread
import time
import traceback
import sys
import struct

defaultport = 35355
magic = b" \0\r\n  \x02\n \x08\rAnYgAmE \n\n"
version = "0.2.0"
msglimit = 1024 * 1024 * 1024

options = {}

keepconnection = r"""
assert(_options)
local anygame = ...

_G._anygame = anygame

if anygame.ip and anygame.port then
    local thread = love.thread.newThread(love.filesystem.newFileData([[
        require 'love.timer'
        require 'love.data'
        local socket = require 'socket'
        local args = ...
        local sock
        local mtime = args.mtime

        local cooldown = 1

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

        local patchVersion = 0
        local function downloadloop()
            while true do
                local msg = download(sock, coroutine.yield)
                if args.options.files and msg.what == 'patch' and msg.zip then
                    patchVersion = patchVersion + 1
                    local data = love.data.newByteData(msg.zip)
                    local success = love.filesystem.mount(data, "gamezip_patch"..patchVersion, "", false)
                    if success then
                        mtime = msg.mtime
                        print('applied '..#msg.zip..'-byte anygame live patch')
                    else
                        print('anygame failed to mount '..#msg.zip..' live patch')
                    end
                    if args.onpatch:getCount() < 1024 then
                        args.onpatch:push(true)
                    end
                end
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
                upload(sock, { what = 'stream', mtime = mtime }, nil, true)
                local hello = download(sock, nil, true)
                assert(hello.what == 'stream', 'invalid "what", expected "stream"')
                cooldown = 1
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
            love.timer.sleep(cooldown)
            cooldown = math.min(cooldown + 1, 7)
        end
        print('exiting anygame network thread')
    ]], 'anygame-network-thread'))

    local send = love.thread.newChannel()
    local onpatch = love.thread.newChannel()

    thread:start {
        magic = anygame.magic,
        version = anygame.version,
        send = send,
        onpatch = onpatch,
        ip = anygame.ip,
        port = anygame.port,
        mtime = anygame.message.mtime,
        options = _options,
    }

    anygame.networkthread = thread

    if _options.logs then
        local ogprint = _G.print
        _G.print = function(...)
            ogprint(...)
            local log = table.concat({...}, ' ', 1, select('#', ...))
            send:push({ what = 'log', log = log })
        end
    end

    if _options.files then
        function anygame.checkForPatches()
            local patched = false
            while true do
                local p = onpatch:pop()
                if not p then break end
                patched = true
            end
            return patched
        end
    end
else
    print('no ip/port, cannot connect back to anygame server')
end
"""

options = {"logs", "files"}

args = sys.argv[1:]

if len(args) < 1:
    print("expecting a game directory as command-line argument")
    sys.exit(1)

preload = ""
for option in args[1:]:
    if not option.startswith("--no-"):
        print(f"unexpected argument {option}")
        sys.exit(1)
    key = option[5:]
    if key not in options:
        print(f"unknown option {option}")
        sys.exit(1)
    options.discard(key)
if options:
    preload = (
        f"local _options = {{{','.join(f'{opt} = true' for opt in options)}}}"
        + keepconnection
    )

gamedir = Path(args[0])
if not gamedir.exists():
    print("path '" + gamedir + "' does not exist")
    sys.exit(1)
gamename, _ = re.subn(r"[^a-zA-Z0-9_-]", "", gamedir.name)


def scangame():
    dirs = []
    files = []
    newest = 0

    def visit(src: Path, dst):
        nonlocal newest
        if src.name.startswith("."):
            return -1
        mtime = src.stat().st_mtime or 0
        if src.is_dir():
            for itemsrc in src.iterdir():
                itemdst = itemsrc.name if dst == "" else dst + "/" + itemsrc.name
                item_mtime = visit(itemsrc, itemdst)
                mtime = max(mtime, item_mtime)
            dirs.append((mtime, "dir", dst))
            newest = max(newest, mtime)
            return mtime
        elif src.is_file():
            files.append((mtime, "file", src, dst))
            newest = max(newest, mtime)
            return mtime
        return -1

    visit(gamedir, "")

    return dirs + files, newest


def packgame(scan, since=-1):
    encodedzip = BytesIO()
    with zipfile.ZipFile(encodedzip, mode="w", compression=zipfile.ZIP_DEFLATED) as zip:
        for item in scan:
            if item[0] > since:
                if item[1] == "dir":
                    zip.mkdir(item[2])
                elif item[1] == "file":
                    zip.write(item[2], item[3])

    return encodedzip.getvalue()


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
curscan = scangame()


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


def scanner():
    global curscan
    while True:
        time.sleep(2)
        curscan = scangame()


def serve(peer, addr):
    try:
        print("serving connection from", addr)
        peer.settimeout(5)
        try:
            req = download(peer)
        except EOFError:
            print(f"empty connection from {addr}")
            return
        if str(addr) not in clientlist:
            clientlist.append(addr[0] + ":" + str(addr[1]))
        if req["what"] == "head":
            peer.sendall(serialize({"name": gamename}))
            return
        elif req["what"] == "get":
            print("serving game to", addr)
            scan = curscan
            mtime = scan[1]
            peer.sendall(
                serialize(
                    {
                        "name": gamename,
                        "zip": packgame(scan[0]),
                        "mtime": str(scan[1]),
                        **({"preload": preload} if preload else {}),
                    }
                )
            )
        elif req["what"] == "stream":
            print("serving stream to ", addr)
            try:
                mtime = float(req["mtime"] or "")
            except ValueError:
                mtime = time.time() - 5
            peer.sendall(serialize({"what": "stream"}))
        else:
            return check(False, f'unknown "what": {req["what"]}')

        colors = [31, 32, 33, 34, 35, 36, 37, 91, 92, 93, 94, 95, 96, 97]
        c = colors[random.randint(0, len(colors) - 1)]
        prefix = str(addr[0]) + ":" + str(addr[1])
        prefix = f"\033[1;{c}m[{prefix}]\033[0m "

        peer.settimeout(0.5)
        while True:
            try:
                msg = download(peer, True)
            except TimeoutError:
                scan = curscan
                if scan[1] > mtime:
                    print(f"sending updates to {addr} from {mtime} to {scan[1]}")
                    peer.sendall(
                        serialize(
                            {
                                "what": "patch",
                                "zip": packgame(scan[0], mtime),
                                "mtime": str(scan[1]),
                            },
                            True,
                        )
                    )
                    mtime = scan[1]
                continue
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


if "files" in options:
    Thread(target=scanner).start()
Thread(target=announce).start()

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", defaultport))
    sock.listen()
    print("serving '" + str(gamedir) + "'")
    while True:
        peer, addr = sock.accept()
        if len(serving) >= max_serving:
            peer.close()
        else:
            serving.add(str(addr))
            thread = Thread(target=serve, args=(peer, addr))
            thread.start()
