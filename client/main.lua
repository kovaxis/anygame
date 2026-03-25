local function mkprint()
    local ogprint = print
    local ogpresent = love.graphics.present

    local fonth = nil
    local font = nil
    local maxlog = 64
    local head = 0
    local logs = {}

    local function newprint(...)
        ogprint(...)
        local t = { ... }
        local n = select('#', ...)
        for i = 1, n do
            t[i] = tostring(t[i])
        end
        t[n + 1] = '\n'
        local log = table.concat(t, ' ', 1, n + 1)
        for line in log:gmatch('[^\n]*\n') do
            head = head + 1
            if head > maxlog then head = 1 end
            logs[head] = log
        end
    end

    local function newpresent()
        local ogfont = love.graphics.getFont()
        local r, g, b, a = love.graphics.getColor()
        love.graphics.push()

        local dpi = love.window.getDPIScale()
        local fw, fh = love.graphics.getDimensions()
        local sx, sy, sw, sh = love.window.getSafeArea()
        local wanth = math.ceil(fh / maxlog * dpi) / dpi
        if wanth ~= fonth then
            fonth = wanth
            font = love.graphics.newFont(fonth)
        end

        love.graphics.setFont(font)
        love.graphics.setColor(1, 1, 1)

        love.graphics.origin()
        local margin = sh * 0.01
        local y = sy + sh - margin
        for i = 1, maxlog do
            if y <= 0 then break end
            local j = head + 1 - i
            if j <= 0 then
                j = j + maxlog
            end
            local log = logs[j]
            if log then
                y = y - fonth
                love.graphics.print(log, sx + margin, y)
            end
        end

        love.graphics.pop()
        love.graphics.setColor(r, g, b, a)
        love.graphics.setFont(ogfont)
        return ogpresent()
    end

    return newprint, newpresent
end

local print, presentwrap = mkprint()

local socket = require 'socket'
local utf8 = require 'utf8'
local lg = love.graphics
local defaultport = 35355
local magicstr = ' \0\r\n  \x02\n \x08\rAnYgAmE \n\n'
local version = "0.2.0"
local maxsavedgamecache = 3
local paths = { ip = 'ip.txt', saved = 'savedgames', fav = "favorites.txt", last = "last.txt" }
local namepattern = '^[a-zA-Z0-9_%-]+$'
local ogloverun = love.run
local ogtextinput = love.keyboard.hasTextInput()
local framefunc
local msglimit = 1024 * 1024 * 1024

print('anygame version: ' .. tostring(version))
print('luasocket version: ' .. tostring(socket._VERSION))

local function mesh(verts)
    local tris = love.math.triangulate(verts)
    local verts = {}
    for _, tri in ipairs(tris) do
        for i = 0, 2 do
            verts[#verts + 1] = { tri[i * 2 + 1], tri[i * 2 + 2] }
        end
    end
    return love.graphics.newMesh(verts, 'triangles', 'static')
end
local starmesh = mesh { 0.000, -1.000, 0.294, -0.405, 0.951, -0.309, 0.476, 0.155, 0.588, 0.809, 0.000, 0.500, -0.588, 0.809, -0.476, 0.155, -0.951, -0.309, -0.294, -0.405 }

local function check(...)
    local ok, warn = ...
    if not ok then
        if warn == nil then
            warn = 'check failed'
        else
            warn = 'check failed: ' .. tostring(warn)
        end
        print(debug.traceback(warn), 2)
    end
    return ...
end

local function validateVersion(v)
    if type(v) ~= 'string' then error('received no version info', 2) end
    local ownPieces = { version:match('^([0-9]+)%.([0-9]+)%.([0-9]+)$') }
    for i = 1, 3 do
        ownPieces[i] = tonumber(ownPieces[i])
    end
    assert(ownPieces[1] and ownPieces[2] and ownPieces[3])
    local themPieces = { version:match('^([0-9]+)%.([0-9]+)%.([0-9]+)$') }
    for i = 1, 3 do
        themPieces[i] = tonumber(themPieces[i])
    end
    if not (themPieces[1] and themPieces[2] and themPieces[3]) then
        error('invalid version ' .. v, 2)
    end
    local omaj, omin, opat = ownPieces[1], ownPieces[2], ownPieces[3]
    local tmaj, tmin, tpat = themPieces[1], themPieces[2], themPieces[3]
    local ok = omaj == tmaj and (omaj > 0 or omin == tmin)
    if not ok then error('server version ' .. v .. ' is incompatible with version ' .. version, 2) end
end

local function serialize(keyval)
    keyval.version = version
    local t = { magicstr, '' }
    local n = 0
    for k, v in pairs(keyval) do
        n = n + 4 + #k + 4 + #v
        assert(n <= msglimit, 'too large')
        local s = love.data.pack('string', '<s4s4', k, v)
        t[#t + 1] = s
    end
    t[2] = love.data.pack('string', '<I4', n)
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

local function download(sock, wait)
    local prefix = downloadn(sock, #magicstr + 4, wait)
    assert(prefix:sub(1, #magicstr) == magicstr, 'invalid magic')
    local len = love.data.unpack('<I4', prefix:sub(#magicstr + 1))
    assert(len <= msglimit, 'too large')
    local payload = downloadn(sock, len, wait)
    local data = unserialize(payload)
    validateVersion(data.version)
    return data
end

local function parse(packet)
    local m = #magicstr
    assert(packet:sub(1, m) == magicstr, 'invalid magic')
    assert(love.data.unpack('<I4', packet:sub(m + 1, m + 4)) == #packet - m - 4, 'invalid length')
    local data = unserialize(packet, m + 4 + 1)
    validateVersion(data.version)
    return data
end

local function upload(sock, data, wait)
    local packet = data
    if type(data) ~= 'string' then
        packet = serialize(data)
    end
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

local buttons = {}
local fontcache = {}
local events = {}
local pointers = {}
local presses = {}

local function playgame(zipstring, preload, preloadArgs)
    print("playing " .. #zipstring .. " byte game")
    local zipdata = love.data.newByteData(zipstring)
    local success = love.filesystem.mount(zipdata, "gamezip", "", false)
    if not success then
        print('failed to mount game zip')
        return false
    end
    love.keyboard.setTextInput(ogtextinput)
    love.run = ogloverun
    if preload then
        print('loading ' .. #preload .. '-byte preload:')
        print(preload)
        local preloadfn = assert(load(preload, 'preload'))
        preloadfn(preloadArgs or {})
    end
    if love.filesystem.getInfo("conf.lua") then
        local t = {}
        t.audio = {}
        t.window = {}
        t.modules = {}

        t.identity = nil               -- The name of the save directory (string)
        t.appendidentity = false       -- Search files in source directory before save directory (boolean)
        t.version = "11.3"             -- The LÖVE version this game was made for (string)
        t.console = false              -- Attach a console (boolean, Windows only)
        t.accelerometerjoystick = true -- Enable the accelerometer on iOS and Android by exposing it as a Joystick (boolean)
        t.externalstorage = false      -- True to save files (and read from the save directory) in external storage on Android (boolean)
        t.gammacorrect = false         -- Enable gamma-correct rendering, when supported by the system (boolean)

        t.audio.mic = false            -- Request and use microphone capabilities in Android (boolean)
        t.audio.mixwithsystem = true   -- Keep background music playing when opening LOVE (boolean, iOS and Android only)

        t.window.title = "Untitled"    -- The window title (string)
        t.window.icon = nil            -- Filepath to an image to use as the window's icon (string)
        t.window.width = 800           -- The window width (number)
        t.window.height = 600          -- The window height (number)
        t.window.borderless = false    -- Remove all border visuals from the window (boolean)
        t.window.resizable = false     -- Let the window be user-resizable (boolean)
        t.window.minwidth = 1          -- Minimum window width if the window is resizable (number)
        t.window.minheight = 1         -- Minimum window height if the window is resizable (number)
        t.window.fullscreen = false    -- Enable fullscreen (boolean)
        t.window.fullscreentype =
        "desktop"                      -- Choose between "desktop" fullscreen or "exclusive" fullscreen mode (string)
        t.window.vsync = 1             -- Vertical sync mode (number)
        t.window.msaa = 0              -- The number of samples to use with multi-sampled antialiasing (number)
        t.window.depth = nil           -- The number of bits per sample in the depth buffer
        t.window.stencil = nil         -- The number of bits per sample in the stencil buffer
        t.window.display = 1           -- Index of the monitor to show the window in (number)
        t.window.highdpi = false       -- Enable high-dpi mode for the window on a Retina display (boolean)
        t.window.usedpiscale = true    -- Enable automatic DPI scaling when highdpi is set to true as well (boolean)
        t.window.x = nil               -- The x-coordinate of the window's position in the specified display (number)
        t.window.y = nil               -- The y-coordinate of the window's position in the specified display (number)

        t.modules.audio = true         -- Enable the audio module (boolean)
        t.modules.data = true          -- Enable the data module (boolean)
        t.modules.event = true         -- Enable the event module (boolean)
        t.modules.font = true          -- Enable the font module (boolean)
        t.modules.graphics = true      -- Enable the graphics module (boolean)
        t.modules.image = true         -- Enable the image module (boolean)
        t.modules.joystick = true      -- Enable the joystick module (boolean)
        t.modules.keyboard = true      -- Enable the keyboard module (boolean)
        t.modules.math = true          -- Enable the math module (boolean)
        t.modules.mouse = true         -- Enable the mouse module (boolean)
        t.modules.physics = true       -- Enable the physics module (boolean)
        t.modules.sound = true         -- Enable the sound module (boolean)
        t.modules.system = true        -- Enable the system module (boolean)
        t.modules.thread = true        -- Enable the thread module (boolean)
        t.modules.timer = true         -- Enable the timer module (boolean), Disabling it will result 0 delta time in love.update
        t.modules.touch = true         -- Enable the touch module (boolean)
        t.modules.video = true         -- Enable the video module (boolean)
        t.modules.window = true        -- Enable the window module (boolean)
        require "conf"
        if love.conf then
            love.conf(t)
            if t.identity then
                love.filesystem.setIdentity(t.identity, t.appendidentity)
            end
            if t.window then
                love.window.setTitle(t.window.title)
                if t.window.icon then
                    love.window.setIcon(t.window.icon)
                end
                love.window.setMode(t.window.width, t.window.height, {
                    fullscreen = t.window.fullscreen,
                    fullscreentype = t.window.fullscreentype,
                    vsync = t.window.vsync,
                    msaa = t.window.msaa,
                    stencil = t.window.stencil,
                    depth = t.window.depth,
                    resizable = t.window.resizable,
                    borderless = t.window.borderless,
                    display = t.window.display,
                    minwidth = t.window.minwidth,
                    minheight = t.window.minheight,
                    highdpi = t.window.highdpi,
                    x = t.window.x,
                    y = t.window.y,
                    usedpiscale = t.window.usedpiscale,
                })
                print("set window mode due to game conf.lua")
            end
        end
    end
    package.loaded["main"] = nil
    require "main"
    framefunc = love.run()
end

local function playstoredgame(path)
    local zipstring = assert(love.filesystem.read(path))
    local file = check(love.filesystem.newFile(path, 'a'))
    if file then
        -- noop write (love doesnt expose a touch function)
        file:setBuffer('none')
        file:seek(0)
        file:write(zipstring:sub(1, 1))
        file:close()
    end
    check(love.filesystem.write(paths.last, path))
    playgame(zipstring)
end

local function loadGameList()
    local rawFiles = love.filesystem.getDirectoryItems(paths.saved)
    local games = {}
    for _, filename in ipairs(rawFiles) do
        local path = paths.saved .. '/' .. filename
        local info = love.filesystem.getInfo(path)
        if info then
            local name, hash = filename:match('^([^.]+)%.([a-zA-Z0-9_%-]+)%.love$')
            if name and hash then
                games[#games + 1] = {
                    path = path,
                    hash = hash,
                    name = name,
                    id = name .. '.' .. hash,
                    modtime = info.modtime,
                }
            end
        end
    end

    local favorites = {}
    local s = love.filesystem.read(paths.fav)
    if s then
        for sfav in s:gmatch('[^\n]+') do
            local id, at = sfav:match('^([^:]+):([0-9]+)$')
            at = tonumber(at)
            if id and at then
                for _, game in ipairs(games) do
                    if game.id == id then
                        favorites[id] = at
                        break
                    end
                end
            end
        end
    end

    return games, favorites
end

local function sortGameList(games, favorites)
    table.sort(games, function(a, b)
        if favorites[a.id] ~= favorites[b.id] then
            return (favorites[a.id] or 0) > (favorites[b.id] or 0)
        end
        if a.modtime ~= b.modtime then return (a.modtime or 0) > (b.modtime or 0) end
        if a.name ~= b.name then return a.name < b.name end
        return a.hash < b.hash
    end)
end

local function storegame(name, zipstring)
    local hash = love.data.hash('sha256', zipstring)
    hash = hash:sub(1, 12)
    hash = love.data.encode('string', 'base64', hash):gsub('%+', '-'):gsub('%/', '_')
    local id = name .. '.' .. hash
    local path = paths.saved .. '/' .. id .. '.love'

    -- make space for new game
    local games, favorites = loadGameList()
    sortGameList(games, favorites)
    local isrepeat = false
    for i = #games, 1, -1 do
        if favorites[games[i].id] then
            table.remove(games, i)
        end
        if games[i].id == id then
            isrepeat = true
        end
    end
    if not isrepeat then
        while #games >= maxsavedgamecache do
            local ok = check(love.filesystem.remove(games[#games].path))
            if not ok then break end
            games[#games] = nil
        end
    end

    -- actually store game
    check(love.filesystem.createDirectory(paths.saved))
    local ok, err = love.filesystem.write(path, zipstring)
    if ok then
        print('saved ' .. #zipstring .. ' byte game "' .. name .. '" to "' .. path .. '"')
    else
        print('error saving ' .. #zipstring .. ' byte game "' .. name .. '" to "' .. path .. '": ' .. tostring(err))
    end

    return path
end

local function framereset(handler)
    events = coroutine.yield()
    lg.origin()
    lg.clear(0.1, 0.2, 0.3)
    presses = {}
    for _, ev in ipairs(events) do
        local name, a, b, c, d, e, f = ev[1], ev[2], ev[3], ev[4], ev[5], ev[6], ev[7]
        if name == 'mousepressed' then
            local x, y, but, istouch = a, b, c, d
            if not istouch then
                pointers[but] = love.timer.getTime()
            end
        elseif name == 'touchpressed' then
            local id, x, y, dx, dy, pressure = a, b, c, d, e, f
            pointers[id] = love.timer.getTime()
        elseif name == 'mousereleased' then
            local x, y, but, istouch = a, b, c, d
            if not istouch and pointers[but] and love.timer.getTime() - pointers[but] < 0.300 then
                presses[#presses + 1] = {
                    x = x,
                    y = y,
                }
            end
        elseif name == 'touchreleased' then
            local id, x, y, dx, dy, pressure = a, b, c, d, e, f
            if pointers[id] and love.timer.getTime() - pointers[id] < 0.300 then
                presses[#presses + 1] = {
                    x = x,
                    y = y,
                }
            end
        end
        if handler then
            handler(name, a, b, c, d, e, f)
        end
    end
end

local function setFont(size)
    size = math.floor(size)
    local font = fontcache[size]
    if not font then
        font = lg.newFont(size)
        fontcache[size] = font
    end
    lg.setFont(font)
    return font
end

local function button(text, x, y, w, h, xalign, yalign)
    xalign, yalign = xalign or 0.5, yalign or 0.5
    local f = lg.getFont()
    lg.print(text, x + w * xalign - f:getWidth(text) * xalign, y + h * yalign - f:getHeight() * yalign)
    lg.rectangle('line', x, y, w, h)
    for _, press in ipairs(presses) do
        if press.x >= x and press.x < x + w and press.y >= y and press.y < y + h then
            return true
        end
    end
    return false
end

local function backbutton()
    local w, h = lg.getDimensions()
    local font = lg.getFont()
    return button("Back", w * 0.02, h * 0.02, font:getWidth("Back"), font:getHeight())
end

local function getScroll(current, height)
    local w, h = lg.getDimensions()
    for _, ev in ipairs(events) do
        local name, a, b, c, d, e, f = ev[1], ev[2], ev[3], ev[4], ev[5], ev[6], ev[7]
        if name == 'touchmoved' then
            local id, x, y, dx, dy, pressure = a, b, c, d, e, f
            current = current + dy
        elseif name == 'wheelmoved' then
            local dx, dy = a, b
            current = current + dy * h * 0.03
        end
    end
    return math.min(0, math.max(current, -height + h * 0.9))
end

local function flowShowError(err)
    while true do
        framereset()
        local w, h = lg.getDimensions()
        local font = setFont(h * 0.1)
        lg.printf(err, 0, h * 0.35, w, 'center')
        if backbutton() then
            return
        end
    end
end

local function flowConnectToAddress(ip, port)
    local function draw(msg, n)
        for i = 1, n or 1 do
            framereset()
            local w, h = lg.getDimensions()
            setFont(h * 0.1)
            if backbutton() then return true end
            lg.printf(msg, 0, h * 0.3, w, 'center')
        end
    end
    ip = ip:match("^%s*(.-)%s*$")
    port = port or defaultport

    if draw('Connecting...', 2) then return end
    local sock = socket.tcp()
    check(sock:settimeout(5))
    local ok, err = sock:connect(ip, port)
    if not ok then
        sock:close()
        return flowShowError('Connection error:\n' .. err)
    end
    check(sock:settimeout(0))
    local ok, msg = pcall(function()
        local status = 'Preparing...'
        local function wait()
            if draw(status) then
                error(sock)
            end
        end
        upload(sock, { what = 'get' }, wait)
        status = 'Downloading...'
        local msg = download(sock, wait)
        assert(msg.name and msg.name:find(namepattern), 'invalid name')
        assert(msg.zip and #msg.zip > 0, 'invalid zip')
        return msg
    end)
    if not ok then
        sock:close()
        if msg == sock then
            return
        else
            return flowShowError('Connection error\n' .. tostring(msg))
        end
    end
    if not msg.keep then
        sock:close()
    end
    local path = storegame(msg.name, msg.zip)
    check(love.filesystem.write(paths.last, path .. ';' .. ip .. ';' .. port))
    playgame(msg.zip, msg.preload, {
        ip = ip,
        port = port,
        socket = msg.keep and sock or nil,
        magic = magicstr,
        version = version,
    })
    return flowShowError('Failed to start game')
end

local function parseip(ip)
    local a, b, c, d = ip:match('^([0-9]+)%.([0-9]+)%.([0-9]+)%.([0-9]+)$')
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d then return nil end
    if a < 0 or a > 255 or b < 0 or b > 255 or c < 0 or c > 255 or d < 0 or d > 255 then return nil end
    return tonumber(a) * 2 ^ 24 + tonumber(b) * 2 ^ 16 + tonumber(c) * 2 ^ 8 + tonumber(d)
end

local function fmtip(ip)
    local a = math.floor(ip / 2 ^ 24 % 256)
    local b = math.floor(ip / 2 ^ 16 % 256)
    local c = math.floor(ip / 2 ^ 8 % 256)
    local d = math.floor(ip % 256)
    return a .. '.' .. b .. '.' .. c .. '.' .. d
end

local function scanNetwork(scan)
    local unifreq = 10
    local batchfreq = 5
    local rebindperiod = 5
    local broadperiod = 1.5

    local sock
    local scanpacket = serialize { what = 'scan' }
    local nextbatch = love.timer.getTime()
    local nextuni = love.timer.getTime()
    local nextbroad = love.timer.getTime()
    local nextrebind = love.timer.getTime()
    local scanidx = 10
    local scanbits = 100
    local baseip, bits
    scan.available = {}
    scan.active = false
    while true do
        local now = love.timer.getTime()
        if now >= nextrebind then
            nextrebind = now + rebindperiod
            -- re-create udp socket to get new local ip (useful if ie. network connects/disconnects)
            if sock then sock:close() end
            sock = socket.udp()
            check(sock:settimeout(0))
            check(sock:setsockname('0.0.0.0', 0))
            print('scanning from socket:', sock:getsockname())
            check(sock:setoption('broadcast', true))

            local ipsock = socket.udp()
            ipsock:setpeername('1.1.1.1', 80)
            local mystrip = check(ipsock:getsockname()) or 0
            ipsock:close()
            local myip = parseip(mystrip) or 0
            baseip, bits = nil, nil
            if math.floor(myip / 2 ^ 16) == 0xC0A8 then    -- 192.168.0.0
                baseip, bits = 0xC0A80000, 16
            elseif math.floor(myip / 2 ^ 20) == 0xAC1 then -- 172.16.0.0
                baseip, bits = 0xAC100000, 20
            elseif math.floor(myip / 2 ^ 24) == 0x0A then  -- 10.0.0.0
                baseip, bits = 0x0A000000, 24
            end
            if baseip and bits then
                print('scanning on subnet ' ..
                    fmtip(baseip) .. '/' .. bits .. ' and subsubnets (own ip is ' .. mystrip .. ')')
            else
                print('cannot scan: ip ' .. mystrip .. ' does not match private subnet pattern')
            end
            scan.active = baseip and bits
        end
        if now >= nextbroad then
            nextbroad = math.max(now, nextbroad + broadperiod)
            -- send out messages to broadcast ips
            if baseip and bits then
                for subbits = bits, 8, -4 do
                    local broadip = baseip + 2 ^ subbits - 1
                    local ip = fmtip(broadip)
                    local ok, err = sock:sendto(scanpacket, ip, defaultport)
                    if not ok then print('broadcast to ' .. ip .. ' failed: ' .. tostring(err)) end
                end
            end
        end
        if now >= nextbatch then
            nextbatch = math.max(now, nextbatch + 1 / batchfreq)
            -- send out unicast scans
            if baseip and bits then
                local batchsize = 0
                while now >= nextuni do
                    nextuni = math.max(now - math.max(1 / batchfreq, 1 / unifreq), nextuni + 1 / unifreq)

                    ::retry::
                    scanbits = scanbits + 4
                    if scanbits > bits then
                        scanbits = 8
                        scanidx = scanidx + 1
                    end
                    local subip = scanidx % 2 ^ scanbits
                    if scanbits > 8 and subip == scanidx % 2 ^ (scanbits - 4) then
                        goto retry
                    end
                    if subip == 0 or subip == 2 ^ scanbits - 1 then
                        goto retry
                    end

                    local ip = fmtip(baseip + subip)
                    local ok, err = sock:sendto(scanpacket, ip, defaultport)
                    batchsize = batchsize + 1
                    if not ok then
                        -- slow down
                        unifreq = unifreq / 2
                        nextuni = math.max(nextuni, now)
                        print('unicast failure, reduced unicast freq to ' .. unifreq)
                        print('  ip:', ip)
                        print('  batch size:', batchsize)
                        print('  sockname:', sock:getsockname())
                        print('  peername:', pcall(sock.getpeername, sock))
                        print('  error:', err)
                        goto skipscan
                    end
                end
                incrpersec = 5
                unifreq = unifreq + incrpersec / batchfreq
                ::skipscan::
            end
        end

        -- receive replies
        for i = 1, 500 do
            local packet, ip, port = sock:receivefrom()
            if not packet then break end
            local ok, msg = pcall(function()
                local msg = parse(packet)
                assert(msg.name and msg.name:find(namepattern), 'invalid name')
                return msg
            end)
            if ok then
                scan.available[ip .. ':' .. port] = {
                    ip = ip,
                    port = tonumber(msg.port),
                    name = msg.name,
                    at = love.timer.getTime(),
                }
            else
                print('scan reply error: ' .. tostring(name))
            end
        end

        if not coroutine.yield() then
            if sock then sock:close() end
            return
        end
    end
end

local function flowScanNetwork()
    local scan = {}
    local scanner = coroutine.wrap(scanNetwork)
    local scroll = 0
    while true do
        framereset()
        local w, h = lg.getDimensions()
        setFont(h * 0.1)
        if backbutton() then
            scanner()
            return
        end

        scanner(scan)
        for key, server in pairs(scan.available) do
            if love.timer.getTime() - server.at > 8 then
                scan.available[key] = nil
            end
        end

        local list = {}
        for key, server in pairs(scan.available) do
            list[#list + 1] = server
        end
        table.sort(list, function(a, b) return a.at > b.at end)

        local basey = 0.2 * h
        local itemh = h * 0.15
        local stride = itemh + h * 0.02
        local statush = h * 0.05
        scroll = getScroll(scroll, basey + #list * stride + statush)
        local y = basey + scroll
        for i = 1, #list do
            local server = list[i]
            setFont(h * 0.08)
            if button(server.name, w * 0.1, y, w * 0.8, itemh, .5, 0) then
                scanner()
                return flowConnectToAddress(server.ip, server.port)
            end
            do
                local subtexth = h * 0.03
                local margin = h * 0.01
                setFont(subtexth)
                lg.printf(server.ip, w * 0.1 + margin, y + itemh - subtexth - margin,
                    w * 0.8 - 2 * margin, 'right')
            end
            y = y + stride
        end

        setFont(statush)
        local status = 'No network detected'
        if scan.active then
            local t = math.floor(love.timer.getTime() / 0.5) % 3
            status = 'Scanning local network' .. ('.'):rep(1 + t)
        end
        lg.printf(status, 0, y, w, 'center')
    end
end

local function flowEnterIp()
    local ip = love.filesystem.read(paths.ip) or ''
    love.keyboard.setTextInput(true)
    while true do
        framereset(function(ev, a, b, c, d, e, f)
            if ev == 'textinput' then
                local input = a
                ip = ip .. a
            elseif ev == 'keypressed' then
                local key = a
                if key == 'backspace' then
                    local offset = utf8.offset(ip, -1)
                    if offset then
                        ip = ip:sub(1, offset - 1)
                    end
                elseif key == 'return' then
                    love.keyboard.setTextInput(false)
                    check(love.filesystem.write(paths.ip, ip))
                    return flowConnectToAddress(ip)
                end
            end
        end)
        if next(presses) then
            love.keyboard.setTextInput(true)
        end
        local w, h = lg.getDimensions()
        setFont(h * 0.1)
        lg.printf('Enter IP:', 0, h * 0.1, w / 2 - w * 0.01, 'right')
        lg.printf(ip, w / 2 + w * 0.01, h * 0.1, w / 2 - w * 0.01, 'left')
        if backbutton() then
            check(love.filesystem.write(paths.ip, ip))
            love.keyboard.setTextInput(false)
            return
        end
    end
end

local function fmttime(time)
    local function fmt(dt)
        local function ss(n)
            return n == 1 and '' or 's'
        end
        if dt < 60 then return dt .. ' second' .. ss(dt) end
        dt = math.floor(dt / 60)
        if dt < 60 then return dt .. ' minute' .. ss(dt) end
        dt = math.floor(dt / 60)
        if dt < 24 then return dt .. ' hour' .. ss(dt) end
        dt = math.floor(dt / 24)
        if dt < 7 then return dt .. ' day' .. ss(dt) end
        if dt < 30 then return math.floor(dt / 7) .. ' week' .. ss(math.floor(dt / 7)) end
        if dt <= 365 then return math.floor(dt / 30) .. ' month' .. ss(math.floor(dt / 7)) end
        return math.floor(dt / 365.25) .. ' year' .. ss(math.floor(dt / 7))
    end

    local diff = os.time() - time
    if diff == 0 then return 'Now' end
    if diff > 0 then
        return fmt(diff) .. ' ago'
    else
        return 'In ' .. fmt(-diff)
    end
end

local function shareGame(game)
    local data = assert(love.filesystem.read(game.path))
    print('sharing ' .. #data .. '-byte game ' .. game.path)
    local headpacket = serialize { name = game.name }
    local tcp = socket.tcp()
    check(tcp:settimeout(0))
    check(tcp:bind('0.0.0.0', defaultport))
    check(tcp:listen(8))
    print('tcp listening on', tcp:getsockname())
    local udp = socket.udp()
    check(udp:settimeout(0))
    check(udp:setsockname('0.0.0.0', defaultport))
    print('udp listening on', udp:getsockname())
    local clients = {}

    local function handleClient(peer)
        local ip, port = peer:getpeername()
        coroutine.yield()

        local msg = download(peer, coroutine.yield)
        if msg.what == 'head' then
            upload(peer, headpacket, coroutine.yield)
            print('served head for ' .. ip .. ':' .. port)
        elseif msg.what == 'get' then
            upload(peer, { name = game.name, zip = data }, coroutine.yield)
            print('served game for ' .. ip .. ':' .. port)
        else
            error('received unknown "what"')
        end
    end

    while true do
        game = coroutine.yield()
        if not game then
            for _, client in pairs(clients) do
                client.peer:close()
            end
            tcp:close()
            udp:close()
            return
        end

        for i = 1, 128 do
            local packet, ip, port = udp:receivefrom()
            if not packet then break end
            local ok, err = pcall(function()
                local msg = parse(packet)
                assert(msg.what == 'scan', 'unknown "what", expected "scan"')
                assert(udp:sendto(headpacket, ip, port))
                print('scanned by ' .. ip .. ':' .. port)
            end)
            if not ok then
                print('error handling udp scan from ' .. ip .. ':' .. port .. ': ' .. tostring(err))
            end
        end

        for i = 1, 8 do
            local peer = tcp:accept()
            if not peer then break end
            local ip, port = check(peer:getpeername())
            local key = ip .. ':' .. port
            local co = coroutine.create(handleClient)
            assert(coroutine.resume(co, peer))
            check(not clients[key], 'duplicate client ' .. key)
            clients[key] = {
                co = co,
                peer = peer,
            }
            print('new connection from ' .. key)
        end

        for key, client in pairs(clients) do
            local ok, err = coroutine.resume(client.co)
            if not ok then
                print('error serving client ' .. key .. ': ' .. err)
            end
            if coroutine.status(client.co) == 'dead' then
                client.peer:close()
                clients[key] = nil
            end
        end
    end
end

local function flowSavedGames()
    local games, favorites = loadGameList()

    local countByName = {}
    for _, game in ipairs(games) do
        countByName[game.name] = (countByName[game.name] or 0) + 1
    end

    local sharing = nil
    local sharer = nil

    local scroll = 0

    while true do
        framereset()
        local w, h = lg.getDimensions()
        setFont(h * 0.1)
        if backbutton() then
            if sharer then sharer() end
            return
        end

        if sharer then sharer(sharing) end

        sortGameList(games, favorites)
        local basey = h * 0.17
        local buth = h * 0.15
        local butstride = buth + 0.02 * h
        scroll = getScroll(scroll, butstride * #games + basey)
        local y = scroll + basey
        for _, game in ipairs(games) do
            setFont(h * 0.08)
            lg.setColor(1, 1, 1, favorites[game.id] and 1 or 0.1)
            lg.draw(starmesh, w * 0.1 + buth / 2, y + buth / 2, 0, .9 * buth / 2)
            lg.setColor(1, 1, 1)
            if button("", w * 0.1, y, buth, buth) then
                if favorites[game.id] then
                    favorites[game.id] = nil
                else
                    favorites[game.id] = os.time()
                end
                local s = {}
                for id, at in pairs(favorites) do
                    s[#s + 1] = id .. ':' .. at
                end
                check(love.filesystem.write(paths.fav, table.concat(s, '\n')))
            end
            if button(game.name, w * 0.1 + buth, y, w * 0.8 - 2 * buth, buth, 0.5, 0) then
                if sharer then sharer() end
                playstoredgame(game.path)
                return flowShowError('Failed to start game')
            end
            do
                local subtexth = h * 0.03
                local margin = h * 0.01
                setFont(subtexth)
                if countByName[game.name] > 1 then
                    lg.printf(game.hash, w * 0.1 + buth + margin, y + buth - subtexth - margin, w * 0.8 - 2 * buth - 2 *
                        margin, 'left')
                end
                if game.modtime then
                    lg.printf(fmttime(game.modtime), w * 0.1 + buth + margin, y + buth - subtexth - margin,
                        w * 0.8 - 2 * buth - 2 *
                        margin, 'right')
                end
            end
            setFont(h * 0.035)
            local shareText = 'SHARE'
            if sharing == game then
                local t = math.floor(love.timer.getTime() / 0.5) % 3
                shareText = 'STOP\n' .. ('.'):rep(1 + t)
            end
            if button(shareText, w * 0.9 - buth, y, buth, buth) then
                if sharer then sharer() end
                if sharing == game then
                    sharing = nil
                    sharer = nil
                else
                    sharing = game
                    sharer = coroutine.wrap(shareGame)
                end
            end
            y = y + butstride
        end
    end
end

local function loadLast()
    local laststr = check(love.filesystem.read(paths.last))
    if not laststr then return {} end
    local parts = {}
    for part in laststr:gmatch('[^;]+') do parts[#parts + 1] = part end
    local path, ip, port = parts[1], parts[2], parts[3]
    local ret = {
        path = path,
        ip = ip,
        port = port,
    }
    if ip and port then
        local sock = socket.tcp()
        check(sock:settimeout(0.5))
        local ok = sock:connect(ip, port)
        sock:close()
        if ok then
            ret.type = 'net'
            return ret
        end
    end
    if path then
        if love.filesystem.getInfo(path) then
            ret.type = 'path'
            return ret
        end
    end
    return ret
end

local function flowMain()
    local last = loadLast()

    while true do
        framereset()
        local w, h = lg.getDimensions()
        setFont(h * 0.2)
        lg.printf("Anygame", 0, h * 0.1, w, 'center')
        for _, ev in ipairs(events) do
            local name, x, y, presses = ev[1], ev[2], ev[3], ev[6]
            if name == 'mousepressed' and y < h * 0.4 and presses >= 7 then
                if _G.print ~= print then
                    _G.print = print
                    love.graphics.present = presentwrap
                    print('showing logs on-screen')
                end
            end
        end
        setFont(h * 0.1)
        local itemh = h * 0.1
        local stride = itemh + h * 0.02
        local y = h * 0.52
        if last.type then
            local text = 'Continue'
            if last.type == 'path' and last.ip then
                text = text .. ' offline'
            elseif last.type == 'net' then
                text = 'Reconnect'
            end
            if button(text, w * 0.1, y - stride, w * 0.8, itemh) then
                if last.type == 'net' then
                    flowConnectToAddress(last.ip, last.port)
                elseif last.type == 'path' then
                    playstoredgame(last.path)
                    flowShowError('Failed to start game')
                end
            end
        end
        if button('Load from network', w * 0.1, y, w * 0.8, itemh) then
            flowScanNetwork()
        end
        y = y + stride
        if button('Load from IP', w * 0.1, y, w * 0.8, itemh) then
            flowEnterIp()
        end
        y = y + stride
        if button('Saved games', w * 0.1, y, w * 0.8, itemh) then
            flowSavedGames()
        end
        y = y + stride
    end
end

function love.run()
    love.filesystem.setIdentity('anygame', true)
    local flowCo = coroutine.wrap(flowMain)
    flowCo()

    framefunc = function()
        love.event.pump()
        local events = {}
        for name, a, b, c, d, e, f in love.event.poll() do
            if name == "quit" then
                return a or 0
            end
            events[#events + 1] = { name, a, b, c, d, e, f }
        end
        flowCo(events)
        lg.present()
        love.timer.sleep(1 / 144)
    end

    return function() return framefunc() end
end
