local socket = require 'socket'
local utf8 = require 'utf8'
local lg = love.graphics
local defaultport = 35355
local magicstr = ' \0\r\n  \x02\n \x08\rAnYgAmE \n\n'
local version = "0.2.0"
local paths = { ip = 'ip.txt', saved = 'savedgames' }
local namepattern = '^[a-zA-Z0-9_%-]+$'
local ogloverun = love.run
local ogtextinput = love.keyboard.hasTextInput()
local framefunc

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

local buttons = {}
local fontcache = {}
local presses = {}

local function playgame(zipstring)
    print("playing " .. #zipstring .. " byte game")
    local zipdata = love.data.newByteData(zipstring)
    local success = love.filesystem.mount(zipdata, "gamezip", "", false)
    if not success then
        return false
    end
    love.keyboard.setTextInput(ogtextinput)
    love.run = ogloverun
    if love.filesystem.getInfo('_anygamepreload.lua') then
        require '_anygamepreload'
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

local function storegame(name, zipstring)
    local hash = love.data.hash('sha256', zipstring)
    hash = hash:sub(1, 12)
    hash = love.data.encode('string', 'base64', hash):gsub('%+', '-'):gsub('%/', '_')
    local path = paths.saved .. '/' .. name .. '.' .. hash .. '.love'
    love.filesystem.createDirectory(paths.saved)
    local ok, err = love.filesystem.write(path, zipstring)
    if ok then
        print('saved ' .. #zipstring .. ' byte game "' .. name .. '" to "' .. path .. '"')
    else
        print('error saving ' .. #zipstring .. ' byte game "' .. name .. '" to "' .. path .. '": ' .. tostring(err))
    end
end

local function metadata(data)
    data.magic = magicstr
    data.version = version
    return serialize(data)
end

local function framereset(handler)
    local events = coroutine.yield()
    lg.origin()
    lg.clear(0.1, 0.2, 0.3)
    presses = {}
    for _, ev in ipairs(events) do
        local name, a, b, c, d, e, f = ev[1], ev[2], ev[3], ev[4], ev[5], ev[6], ev[7]
        if name == 'mousereleased' then
            local x, y, but, istouch = a, b, c, d
            if not istouch then
                presses[#presses + 1] = {
                    x = x,
                    y = y,
                }
            end
        elseif name == 'touchreleased' then
            local id, x, y, dx, dy, pressure = a, b, c, d, e, f
            presses[#presses + 1] = {
                x = x,
                y = y,
            }
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

local function button(text, x, y, w, h)
    local f = lg.getFont()
    lg.printf(text, x, y + h / 2 - f:getHeight() / 2, w, 'center')
    lg.rectangle('line', x, y, w, h)
    for _, press in ipairs(presses) do
        if press.x >= x - w and press.x < x + w and press.y >= y - h and press.y < y + h then
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

local function showList(list)
    local w, h = lg.getDimensions()
    setFont(h * 0.1)
    local clicked = nil
    for i = 1, #list do
        if button(list[i], w * 0.1, 0.15 * h + h * 0.12 * (i - 1), w * 0.8, h * 0.1) then
            clicked = i
        end
    end
    return clicked
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

    if draw('Connecting...', 2) then return end
    local sock = socket.tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(ip, port or defaultport)
    if not ok then
        sock:close()
        return flowShowError('Connection error:\n' .. err)
    end
    ok, err = sock:send(metadata { what = "get" })
    if not ok then
        sock:close()
        return flowShowError('Connection error:\n' .. err)
    end
    sock:shutdown('send')

    sock:settimeout(0)
    local fulldata = ''
    while true do
        if draw("Downloading...") then
            sock:close()
            return
        end
        local all, err, piece = sock:receive('*a')
        if all then
            fulldata = fulldata .. all
            break
        elseif err == 'timeout' then
            fulldata = fulldata .. piece
        else
            return flowShowError('Error downloading game:\n' .. err)
        end
    end
    sock:close()
    if #fulldata == 0 then
        return flowShowError('Error downloading game:\nempty')
    end
    local ok, metadata, zipstring = pcall(function()
        local metadata, zipstart = unserialize(fulldata)
        assert(metadata.magic == magicstr, 'invalid magic sequence')
        validateVersion(metadata.version)
        assert(metadata.name and metadata.name:find(namepattern))
        local zipstring = fulldata:sub(zipstart)
        assert(#zipstring > 0, 'received empty .love file')
        return metadata, zipstring
    end)
    if not ok then
        return flowShowError('Error downloading game:\n' .. metadata)
    end
    storegame(metadata.name, zipstring)
    playgame(zipstring)
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

local function scanNetwork(available)
    local freq = 500
    local batchfreq = 5
    local rebindperiod = 3
    local broadperiod = 1.5

    local sock
    local nextbatch = love.timer.getTime()
    local nextbroad = love.timer.getTime()
    local nextrebind = love.timer.getTime()
    local scanidx = 0
    local baseip, bits
    while true do
        local now = love.timer.getTime()
        if now >= nextrebind then
            nextrebind = now + rebindperiod
            -- re-create udp socket to get new local ip (useful if ie. network connects/disconnects)
            if sock then sock:close() end
            sock = socket.udp()
            sock:settimeout(0)

            local ipsock = socket.udp()
            ipsock:setpeername('1.1.1.1', 80)
            local myip = parseip(ipsock:getsockname())
            ipsock:close()
            baseip, bits = nil, nil
            if math.floor(myip / 2 ^ 16) == 0xC0A8 then    -- 192.168.0.0
                baseip, bits = 0xC0A80000, 16
            elseif math.floor(myip / 2 ^ 20) == 0xAC1 then -- 172.16.0.0
                baseip, bits = 0xAC100000, 20
            elseif math.floor(myip / 2 ^ 24) == 0x0A then  -- 10.0.0.0
                baseip, bits = 0x0A000000, 24
            end
            if baseip and bits then
                print('scanning on subnet ' .. fmtip(baseip) .. '/' .. bits .. ' and subsubnets')
            else
                print('cannot scan: ip ' .. myip .. ' does not match private subnet pattern')
            end
        end
        if now >= nextbatch then
            nextbatch = nextbatch + 1 / batchfreq
            local dobroadcast = now >= nextbroad
            if dobroadcast then
                nextbroad = nextbroad + broadperiod
            end
            -- send out scan batches
            if baseip and bits then
                local packet = metadata { what = 'scan' }
                if dobroadcast then
                    for subbits = bits, 8, -4 do
                        local broadip = baseip + 2 ^ subbits - 1
                        sock:sendto(packet, fmtip(broadip), defaultport)
                    end
                end
                for j = 1, freq / batchfreq do
                    scanidx = scanidx + 1
                    for subbits = bits, 8, -4 do
                        local subip = scanidx % 2 ^ subbits
                        if subbits == 8 or subip ~= scanidx % 2 ^ (subbits - 4) then
                            if subip > 0 and subip < 2 ^ subbits - 1 then
                                sock:sendto(packet, fmtip(baseip + subip), defaultport)
                            end
                        end
                    end
                end
            end
        end

        -- receive replies
        for i = 1, 500 do
            local msg, ip, port = sock:receivefrom()
            if not msg then break end
            local ok, meta = pcall(function()
                local meta = unserialize(msg)
                assert(meta.magic == magicstr, 'invalid magic')
                validateVersion(meta.version)
                assert(meta.name and meta.name:find(namepattern), 'invalid name')
                return meta
            end)
            if ok then
                available[ip .. ':' .. port] = {
                    ip = ip,
                    port = tonumber(meta.port),
                    name = meta.name,
                    at = love.timer.getTime(),
                }
            else
                print('scan reply error: ' .. tostring(name))
            end
        end

        if not coroutine.yield() then
            sock:close()
            return
        end
    end
end

local function flowScanNetwork()
    local sock = socket.udp()
    sock:setoption('reuseaddr', true)
    sock:setoption('reuseport', true)
    sock:settimeout(0)
    sock:setsockname('*', defaultport)
    local available = {}
    local scanner = coroutine.wrap(scanNetwork)
    while true do
        framereset()
        local w, h = lg.getDimensions()
        local font = setFont(h * 0.1)
        if backbutton() then
            scanner()
            return
        end

        scanner(available)

        local list = {}
        for key, server in pairs(available) do
            list[#list + 1] = server
        end
        table.sort(list, function(a, b) return a.at > b.at end)
        local strlist = {}
        for i, server in ipairs(list) do
            strlist[i] = server.name
        end
        local chosen = showList(strlist)
        if chosen then
            local server = list[chosen]
            scanner()
            return flowConnectToAddress(server.ip, server.port)
        end
    end
end

local function flowLoadAddress()
    local ip = love.filesystem.read(paths.ip) or ''
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
                    love.filesystem.write(paths.ip, ip)
                    return flowConnectToAddress(ip)
                end
            end
        end)
        if next(presses) then
            love.keyboard.setTextInput(true)
        end
        local w, h = lg.getDimensions()
        local font = setFont(h * 0.1)
        lg.printf('Enter IP:', 0, h * 0.1, w, 'center')
        lg.printf(ip, 0, h * 0.2, w, 'center')
        if backbutton() then
            love.filesystem.write(paths.ip, ip)
            return
        end
    end
end

local function flowSavedGames()
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
                    modtime = info.modtime or 0,
                }
            end
        end
    end
    table.sort(games, function(a, b)
        if a.modtime ~= b.modtime then return a.modtime > b.modtime end
        if a.name ~= b.name then return a.name < b.name end
        return a.hash < b.hash
    end)
    local labels = {}
    for i = 1, #games do
        labels[i] = games[i].name
    end

    while true do
        framereset()
        if backbutton() then return end
        local i = showList(labels)
        if i then
            local game = games[i]
            local zipstring = love.filesystem.read(game.path)
            if zipstring then playgame(zipstring) end
        end
    end
end

local function flowMain()
    while true do
        framereset()
        local w, h = lg.getDimensions()
        setFont(h * 0.1)
        if button('Load from network', 0, h * 0.3, w, h * 0.1) then
            flowScanNetwork()
        end
        if button('Load from IP', 0, h * 0.4, w, h * 0.1) then
            flowLoadAddress()
        end
        if button('Saved games', 0, h * 0.5, w, h * 0.1) then
            flowSavedGames()
        end
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
