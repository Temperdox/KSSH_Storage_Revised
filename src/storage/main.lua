-- main.lua
-- Storage System v2.0.0
-- Main entry point and process manager

local VERSION  = "2.0.0"
local APP_NAME = "Storage System"

-- Load core modules
local Logger         = require("modules.logger")
local ProcessManager = require("modules.process_manager")
local EventBus       = require("modules.event_bus")
local Terminal       = require("modules.terminal")
local Config         = require("modules.config")
local API            = require("modules.api")
local StorageManager = require("modules.storage_manager")
local DisplayManager = require("modules.display_manager")

-- Initialize logger
local logger = Logger:new("logs/storage.log")
_G.logger = logger

-- Global singletons
_G.processManager = ProcessManager:new()
_G.eventBus       = EventBus:new()
_G.config         = Config:new()

-- Process references
local terminal = nil
local storage = nil
local display = nil
local api = nil

-- Running flag
local running = true

-- Graceful shutdown handler
local function shutdown()
    if not running then return end
    running = false

    logger:info("Initiating graceful shutdown...")

    -- Stop all processes
    _G.processManager:stopAll()

    -- Stop API if running
    if api then
        pcall(function() api:stop() end)
    end

    -- Save config
    pcall(function() _G.config:save() end)

    logger:info("Shutdown complete")
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_NAME .. " stopped")
end

-- Trap Ctrl+T for graceful shutdown
local oldPullEvent = os.pullEvent
os.pullEvent = function(...)
    local e, p1, p2, p3, p4, p5 = oldPullEvent(...)
    if e == "terminate" then
        shutdown()
        os.pullEvent = oldPullEvent
        error("Terminated", 0)
    end
    return e, p1, p2, p3, p4, p5
end

-- Initialize components
local function init()
    logger:info(string.format("Starting %s v%s...", APP_NAME, VERSION))

    -- Load configuration
    _G.config:load()

    -- Create process instances
    terminal = Terminal:new(APP_NAME, VERSION, logger)
    storage = StorageManager:new(logger, _G.eventBus)
    display = DisplayManager:new(logger, _G.eventBus)

    -- Initialize API if enabled
    if _G.config:get("api.enabled", true) then
        api = API:new(logger, _G.eventBus, _G.config:get("api.port", 9001))
    end

    -- Register processes with ProcessManager
    _G.processManager:register("terminal", function()
        terminal:run()
    end)

    _G.processManager:register("storage", function()
        storage:run()
    end)

    _G.processManager:register("display", function()
        display:run()
    end)

    if api then
        _G.processManager:register("api", function()
            api:run()
        end)
    end

    logger:info("All systems initialized")
end

-- Main execution
local function main()
    init()

    -- Run all processes in parallel using ProcessManager
    local processes = {}

    -- Terminal process
    table.insert(processes, function()
        if terminal then
            terminal:run()
        end
    end)

    -- Storage process
    table.insert(processes, function()
        if storage then
            storage:run()
        end
    end)

    -- Display process
    table.insert(processes, function()
        if display then
            display:run()
        end
    end)

    -- API process
    if api then
        table.insert(processes, function()
            api:run()
        end)
    end

    -- Process manager tick loop
    table.insert(processes, function()
        while running do
            _G.processManager:tick()
            sleep(0.05)
        end
    end)

    -- Run all processes in parallel
    parallel.waitForAny(table.unpack(processes))
end

-- Run with error handling
local ok, err = pcall(main)
if not ok then
    logger:error("Fatal error: " .. tostring(err))
    shutdown()
    error(err, 0)
end