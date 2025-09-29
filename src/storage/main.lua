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

-- Initialize logger (also expose globally for convenience)
local logger = Logger:new("logs/storage.log")
_G.logger = logger

-- Global singletons other modules expect
_G.processManager = ProcessManager:new()
_G.eventBus       = EventBus:new()
_G.config         = Config:new()

-- Keep a handle to the API server if enabled
local api = nil

-- Graceful shutdown handler
local running = true
local function shutdown()
    if not running then return end
    running = false

    logger:info("Initiating graceful shutdown...")

    -- Stop processes
    if processManager then
        pcall(function() processManager:stopAll() end)
    end

    -- Stop API
    if api then
        pcall(function() api:stop() end)
        api = nil
    end

    -- Save config
    if config then
        pcall(function() config:save() end)
    end

    logger:info("Shutdown complete")
    term.setCursorBlink(false)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_NAME .. " stopped")
end

-- Trap Ctrl+T and route to graceful shutdown
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

-- Boot/initialization
local function init()
    logger:info(("Starting %s v%s..."):format(APP_NAME, VERSION))

    -- Load configuration (creates defaults if missing)
    config:load()

    -- Terminal UI process
    local terminal = Terminal:new(APP_NAME, VERSION, logger)
    processManager:register("terminal", function()
        terminal:run()
    end)

    -- Storage manager process
    processManager:register("storage", function()
        local StorageManager = require("modules.storage_manager")
        local storage = StorageManager:new(logger, eventBus)
        storage:run()
    end)

    -- Display manager process
    processManager:register("display", function()
        local DisplayManager = require("modules.display_manager")
        local display = DisplayManager:new(logger, eventBus)
        display:run()
    end)

    -- Optional API server
    if config:get("api.enabled", true) then
        api = API:new(logger, eventBus, config:get("api.port", 9001))
        processManager:register("api", function()
            api:run()
        end)
    end

    -- Start all registered processes
    processManager:startAll()

    logger:info("All systems initialized")
end

-- Main scheduler loop (ticks the ProcessManager so coroutines resume)
local function main()
    init()
    while running do
        processManager:tick()
        -- Pull event with no filter, short timeout
        local event = {os.pullEventRaw(0.1)}
        if event[1] == "terminate" then
            break
        end
    end
end

-- Run with error handling
local ok, err = pcall(main)
if not ok then
    logger:error("Fatal error: " .. tostring(err))
    shutdown()
end
