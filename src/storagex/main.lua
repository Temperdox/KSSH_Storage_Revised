-- main.lua
-- Storage System v2.0.0
-- Main entry point with input monitoring

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
local InputMonitor   = require("modules.input_monitor")
local SoundManager   = require("modules.sound_manager")

-- Initialize logger
local logger = Logger:new("logs/storage.log")
logger:setLevel(Logger.LEVELS.INFO) -- Set to INFO to reduce spam (can be changed to DEBUG if needed)
_G.logger = logger

-- Global singletons
_G.processManager = ProcessManager:new()
_G.eventBus       = EventBus:new()
_G.config         = Config:new()
_G.sound          = SoundManager:new(logger)

-- Process references
local terminal = nil
local storage = nil
local display = nil
local api = nil
local inputMonitor = nil

-- Running flag
local running = true

-- Graceful shutdown handler
local function shutdown()
    if not running then return end
    running = false

    logger:info("Initiating graceful shutdown...")

    -- Stop input monitor
    if inputMonitor then
        pcall(function() inputMonitor:stop() end)
    end

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

    -- Initialize input monitor if we have an input chest
    if storage.inputChest then
        inputMonitor = InputMonitor:new(logger, _G.eventBus, storage.inputChest)

        -- Register event handler for when items are detected
        _G.eventBus:on("input:items_detected", function(count)
            logger:info(string.format("Input monitor detected %d items, triggering deposit", count), "Main")
            _G.eventBus:emit("storage:trigger_deposit")
        end, 10) -- High priority

        -- Also handle items present event (for periodic checks)
        _G.eventBus:on("input:items_present", function(count)
            -- Only trigger periodic check if we have empty slots
            if storage.emptySlots > 0 then
                _G.eventBus:emit("storage:check_deposit")
            end
        end, 5)
    else
        logger:warning("No input chest found - deposit monitoring disabled", "Main")
    end

    -- Add terminal command to toggle debug logging
    terminal:registerCommand("debug", function(args)
        if args[1] == "on" then
            logger:setLevel(Logger.LEVELS.DEBUG)
            logger:info("Debug logging enabled")
        elseif args[1] == "off" then
            logger:setLevel(Logger.LEVELS.INFO)
            logger:info("Debug logging disabled")
        else
            local currentLevel = logger.minLevel.name
            logger:info("Current log level: " .. currentLevel .. " (use 'debug on' or 'debug off')")
        end
    end, "Toggle debug logging (on/off)")

    -- Add terminal command to manually trigger deposit
    terminal:registerCommand("deposit", function(args)
        logger:info("Manually triggering deposit...")
        _G.eventBus:emit("storage:trigger_deposit")
    end, "Manually trigger deposit from input chest")

    -- Add terminal command to reset deposit state
    terminal:registerCommand("reset", function(args)
        logger:info("Resetting deposit state...")
        if storage then
            storage.depositBusy = false
            storage.depositQueue = {}
            storage.depositStuckCounter = 0
            logger:success("Deposit state reset - try deposit command again")
        end
    end, "Reset stuck deposit state")

    logger:info("All systems initialized")
end

-- Main execution
local function main()
    init()

    -- Run all processes in parallel
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

    -- Input monitor process (separate high-priority monitor)
    if inputMonitor then
        table.insert(processes, function()
            inputMonitor:run()
        end)
    end

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