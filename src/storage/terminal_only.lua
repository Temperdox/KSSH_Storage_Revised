-- terminal_only.lua
-- Standalone terminal that can interact with background storage system

local VERSION = "2.0.0"
local APP_NAME = "Storage Terminal"

-- Simple terminal without blocking processes
local running = true
local commandHistory = {}
local historyIndex = 0
local currentInput = ""

-- Basic commands
local commands = {
    help = function()
        print("Storage System Commands:")
        print("  status - Show system status")
        print("  reload - Reload storage data")
        print("  sort - Sort storage")
        print("  reformat - Reformat storage")
        print("  stop - Stop background system")
        print("  restart - Restart background system")
        print("  exit - Exit terminal")
        print("  clear - Clear screen")
    end,

    status = function()
        if _G.storageStatus then
            _G.storageStatus()
        else
            print("Background storage system not running")
            print("Run 'background.lua' first")
        end
    end,

    reload = function()
        if _G.eventBus then
            _G.eventBus:emit("storage:reload")
            print("Reload requested")
        else
            print("Storage system not available")
        end
    end,

    sort = function()
        if _G.eventBus then
            _G.eventBus:emit("storage:sort", true)
            print("Sort requested")
        else
            print("Storage system not available")
        end
    end,

    reformat = function()
        if _G.eventBus then
            _G.eventBus:emit("storage:reformat")
            print("Reformat requested")
        else
            print("Storage system not available")
        end
    end,

    stop = function()
        if _G.storageStop then
            _G.storageStop()
        else
            print("Background system not found")
        end
    end,

    restart = function()
        if _G.storageRestart then
            _G.storageRestart()
        else
            print("Background system not found")
        end
    end,

    clear = function()
        term.clear()
        term.setCursorPos(1, 1)
    end,

    exit = function()
        running = false
    end
}

local function executeCommand(input)
    local parts = {}
    for part in input:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then return end

    local cmdName = parts[1]
    local cmd = commands[cmdName]

    if cmd then
        local ok, err = pcall(cmd)
        if not ok then
            print("Error: " .. tostring(err))
        end
    else
        print("Unknown command: " .. cmdName)
        print("Type 'help' for available commands")
    end
end

-- Simple input handling
local function getInput()
    write("> ")
    local input = read()
    return input
end

-- Main terminal loop
local function main()
    term.clear()
    term.setCursorPos(1, 1)

    print(APP_NAME .. " v" .. VERSION)
    print("Type 'help' for commands")
    print("Type 'status' to check background system")
    print("")

    while running do
        local input = getInput()
        if input and input:len() > 0 then
            table.insert(commandHistory, input)
            executeCommand(input)
        end
    end

    print("Terminal closed")
end

-- Run terminal
local ok, err = pcall(main)
if not ok then
    print("Terminal error: " .. tostring(err))
end