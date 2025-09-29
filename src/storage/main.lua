-- main.lua
-- Storage System v2.0.0
-- Main entry point and process manager

local VERSION = "2.0.0"
local APP_NAME = "Storage System"

-- Load core modules
local Logger = require("modules.logger")
local ProcessManager = require("modules.process_manager")
local EventBus = require("modules.event_bus")
local Terminal = require("modules.terminal")
local Config = require("modules.config")
local API = require("modules.api")

-- Initialize logger
local logger = Logger:new("logs/storage.log")

-- Global process manager
_G.processManager = ProcessManager:new()
_G.eventBus = EventBus:new()
_G.config = Config:new()

-- Graceful shutdown handler
local running = true
local function shutdown()
    running = false
    logger:info("Initiating graceful shutdown...")

    -- Stop all processes
    processManager:stopAll()

    -- Close API
    if api then
        api:stop()
    end

    -- Save config
    config:save()

    logger:info("Shutdown complete")
    term.clear()
    term.setCursorPos(1, 1)
    print("Storage System stopped")
end

-- Override terminate handler
local oldPullEvent = os.pullEvent
os.pullEvent = function(...)
    local event, p1 = oldPullEvent(...)
    if event == "terminate" then
        shutdown()
        os.pullEvent = oldPullEvent
        error("Terminated", 0)
    end
    return event, p1
end

-- Main initialization
local function init()
    logger:info("Starting " .. APP_NAME .. " v" .. VERSION)

    -- Load configuration
    config:load()

    -- Initialize terminal UI
    local terminal = Terminal:new(APP_NAME, VERSION, logger)
    processManager:register("terminal", function()
        terminal:run()
    end)

    -- Initialize storage manager process
    processManager:register("storage", function()
        local StorageManager = require("modules.storage_manager")
        local storage = StorageManager:new(logger, eventBus)
        storage:run()
    end)

    -- Initialize display manager process
    processManager:register("display", function()
        local DisplayManager = require("modules.display_manager")
        local display = DisplayManager:new(logger, eventBus)
        display:run()
    end)

    -- Initialize API server
    if config:get("api.enabled", true) then
        api = API:new(logger, eventBus, config:get("api.port", 9001))
        processManager:register("api", function()
            api:run()
        end)
    end

    -- Start all processes
    processManager:startAll()

    logger:info("All systems initialized")
end

-- Main loop
local function main()
    init()

    -- Keep main thread alive
    while running do
        sleep(1)
    end
end

-- Run with error handling
local ok, err = pcall(main)
if not ok then
    logger:error("Fatal error: " .. tostring(err))
    shutdown()
end