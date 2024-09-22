
local socket = require 'socket'
local utf8 = require 'utf8'
local lg = love.graphics
local font = lg.newFont(50)
local defaultport = 35355
local magic_int = 5263748
local state = {
    name='input',
}
local host = ""
local ogloverun = love.run
local ogtextinput = love.keyboard.hasTextInput()
local framefunc

local function playgame(zipstring, preload)
    local zipdata = love.data.newByteData(zipstring)
    local success = love.filesystem.mount(zipdata, "gamezip", "", false)
    if not success then
        return false
    end
    love.keyboard.setTextInput(ogtextinput)
    love.textinput = nil
    love.keypressed = nil
    love.run = ogloverun
    local preload, err = loadstring(preload, "preload")
    if not preload then
        print("preload error: "..tostring(err))
        return false
    end
    preload()
    if love.filesystem.getInfo("conf.lua") then
        local t = {}
        t.audio = {}
        t.window = {}
        t.modules = {}

        t.identity = nil                    -- The name of the save directory (string)
        t.appendidentity = false            -- Search files in source directory before save directory (boolean)
        t.version = "11.3"                  -- The LÖVE version this game was made for (string)
        t.console = false                   -- Attach a console (boolean, Windows only)
        t.accelerometerjoystick = true      -- Enable the accelerometer on iOS and Android by exposing it as a Joystick (boolean)
        t.externalstorage = false           -- True to save files (and read from the save directory) in external storage on Android (boolean) 
        t.gammacorrect = false              -- Enable gamma-correct rendering, when supported by the system (boolean)

        t.audio.mic = false                 -- Request and use microphone capabilities in Android (boolean)
        t.audio.mixwithsystem = true        -- Keep background music playing when opening LOVE (boolean, iOS and Android only)

        t.window.title = "Untitled"         -- The window title (string)
        t.window.icon = nil                 -- Filepath to an image to use as the window's icon (string)
        t.window.width = 800                -- The window width (number)
        t.window.height = 600               -- The window height (number)
        t.window.borderless = false         -- Remove all border visuals from the window (boolean)
        t.window.resizable = false          -- Let the window be user-resizable (boolean)
        t.window.minwidth = 1               -- Minimum window width if the window is resizable (number)
        t.window.minheight = 1              -- Minimum window height if the window is resizable (number)
        t.window.fullscreen = false         -- Enable fullscreen (boolean)
        t.window.fullscreentype = "desktop" -- Choose between "desktop" fullscreen or "exclusive" fullscreen mode (string)
        t.window.vsync = 1                  -- Vertical sync mode (number)
        t.window.msaa = 0                   -- The number of samples to use with multi-sampled antialiasing (number)
        t.window.depth = nil                -- The number of bits per sample in the depth buffer
        t.window.stencil = nil              -- The number of bits per sample in the stencil buffer
        t.window.display = 1                -- Index of the monitor to show the window in (number)
        t.window.highdpi = false            -- Enable high-dpi mode for the window on a Retina display (boolean)
        t.window.usedpiscale = true         -- Enable automatic DPI scaling when highdpi is set to true as well (boolean)
        t.window.x = nil                    -- The x-coordinate of the window's position in the specified display (number)
        t.window.y = nil                    -- The y-coordinate of the window's position in the specified display (number)

        t.modules.audio = true              -- Enable the audio module (boolean)
        t.modules.data = true               -- Enable the data module (boolean)
        t.modules.event = true              -- Enable the event module (boolean)
        t.modules.font = true               -- Enable the font module (boolean)
        t.modules.graphics = true           -- Enable the graphics module (boolean)
        t.modules.image = true              -- Enable the image module (boolean)
        t.modules.joystick = true           -- Enable the joystick module (boolean)
        t.modules.keyboard = true           -- Enable the keyboard module (boolean)
        t.modules.math = true               -- Enable the math module (boolean)
        t.modules.mouse = true              -- Enable the mouse module (boolean)
        t.modules.physics = true            -- Enable the physics module (boolean)
        t.modules.sound = true              -- Enable the sound module (boolean)
        t.modules.system = true             -- Enable the system module (boolean)
        t.modules.thread = true             -- Enable the thread module (boolean)
        t.modules.timer = true              -- Enable the timer module (boolean), Disabling it will result 0 delta time in love.update
        t.modules.touch = true              -- Enable the touch module (boolean)
        t.modules.video = true              -- Enable the video module (boolean)
        t.modules.window = true             -- Enable the window module (boolean)
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
                    fullscreen=t.window.fullscreen,
                    fullscreentype=t.window.fullscreentype,
                    vsync=t.window.vsync,
                    msaa=t.window.msaa,
                    stencil=t.window.stencil,
                    depth=t.window.depth,
                    resizable=t.window.resizable,
                    borderless=t.window.borderless,
                    display=t.window.display,
                    minwidth=t.window.minwidth,
                    minheight=t.window.minheight,
                    highdpi=t.window.highdpi,
                    x=t.window.x,
                    y=t.window.y,
                    usedpiscale=t.window.usedpiscale,
                })
                print("set window")
            end
        end
    end
    package.loaded["main"] = nil
    require "main"
    framefunc = love.run()
end

local function draw()
    lg.origin()
    lg.clear(0.1, 0.2, 0.3)
    local w, h = lg.getDimensions()
    local y = math.floor(h*0.1)
    local function write(txt)
        lg.printf(txt, 0, y, w, 'center')
        y = y + lg.getFont():getHeight()
    end
    lg.setFont(font)
    if state.name == 'input' then
        if state.msg then
            write(state.msg)
        end
        write("Ingresa la IP del host:")
        write(host)
    elseif state.name == 'connecting' then
        write("Conectando...")
    elseif state.name == 'downloading' then
        write("Descargando juego...")
    end
    lg.present()
end

local function tryConnection()
    love.filesystem.remove("autoconnect.txt")
    host = host:match("^%s*(.-)%s*$")
    state = {
        name='connecting',
    }
    draw()
    local sock = socket.tcp()
    local ok = sock:connect(host, defaultport)
    if not ok then
        state = {
            name='input',
            msg="Error de conexión",
        }
        return
    end
    state = {
        name='downloading',
        sock=sock,
    }
    draw()
    local fulldata, err = sock:receive("*a")
    sock:close()
    if not fulldata or not fulldata:find("\0", 1, true) then
        state = {
            name='input',
            msg="Error descargando juego",
        }
        return
    end
    local split = fulldata:find("\0", 1, true)
    local predata = fulldata:sub(1, split-1)
    local zipdata = fulldata:sub(split+1)
    love.filesystem.write("lastinput.txt", host)
    love.filesystem.write("autoconnect.txt", "")
    print("playing "..#zipdata.." byte game with "..#predata.." bytes of predata")
    playgame(zipdata, predata)
    state = {
        name='input',
        msg="Error iniciando juego",
    }
end

function love.textinput(txt)
    if state.name == 'input' then
        host = host .. txt
    end
end

function love.keypressed(key)
    if key == 'escape' then
        love.event.quit()
    end
    if state.name == 'input' then
        if key == 'backspace' then
            local offset = utf8.offset(host, -1)
            if offset then
                host = host:sub(1, offset-1)
            end
        elseif key == 'return' then
            tryConnection()
        end
    end
end

function love.run()
    love.filesystem.setIdentity('anygame', true)

    local func = function()
        if state.name == 'input' then
            local w, h = love.graphics.getDimensions()
            love.keyboard.setTextInput(true, 0, 0, w, h/3)
        end

        love.event.pump()
        for name, a,b,c,d,e,f in love.event.poll() do
            if name == "quit" then
                if not love.quit or not love.quit() then
                    return a or 0
                end
            end
            love.handlers[name](a,b,c,d,e,f)
        end

        draw()

        love.timer.sleep(1/144)
    end

    framefunc = function()
        framefunc = func

        host = love.filesystem.read("lastinput.txt") or ""
        if host and love.filesystem.getInfo("autoconnect.txt") then
            tryConnection()
        end

        return framefunc()
    end

    return function() return framefunc() end
end
