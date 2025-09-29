-- background.lua
-- Runs storage system as background processes, leaves terminal free

local VERSION  = "2.0.0"
local APP_NAME = "Storage System"

-- Load core modules
local Logger         = require("modules.logger")
local ProcessManager = require("modules.process_manager")
local EventBus       = require("modules.event_bus")
local Config         = require("modules.config")
local API            = require("modules.api")

-- Initialize globals
local logger = Logger:new("logs/storage.log")
_G.logger = logger
_G.processManager = ProcessManager:new()
_G.eventBus = EventBus:new()
_G.config = Config:new()

-- Background processes only (no terminal)
local api = nil
local running = true

-- Storage and display coroutines
local storageCoroutine = nil
local displayCoroutine = nil
local processes = {}

local function createStorageProcess()
    return coroutine.create(function()
        local StorageManager = require("modules.storage_manager")
        local storage = StorageManager:new(logger, _G.eventBus)
        storage:run()
    end)
end

local function createDisplayProcess()
    return coroutine.create(function()
        local DisplayManager = require("modules.display_manager")
        local display = DisplayManager:new(logger, _G.eventBus)
        display:run()
    end)
end

local function init()
    logger:info(("Starting %s v%s (Background Mode)..."):format(APP_NAME, VERSION))

    -- Load configuration
    _G.config:load()

    -- Create background processes
    processes.storage = {
        name = "storage",
        coroutine = createStorageProcess(),
        status = "running"
    }

    processes.display = {
        name = "display",
        coroutine = createDisplayProcess(),
        status = "running"
    }

    -- Optional API server
    if _G.config:get("api.enabled", true) then
        api = API:new(logger, _G.eventBus, _G.config:get("api.port", 9001))
        processes.api = {
            name = "api",
            coroutine = coroutine.create(function() api:run() end),
            status = "running"
        }
    end

    logger:info("Background processes initialized")
    print("Storage system running in background")
    print("Terminal is free for other use")
    print("Type 'fg storage' to bring to foreground")
end

local function tickProcess(process)
    if not process.coroutine then return end

    local status = coroutine.status(process.coroutine)
    if status == "suspended" then
        local ok, err = coroutine.resume(process.coroutine)
        if not ok then
            logger:error("Process " .. process.name .. " error: " .. tostring(err))
            process.status = "crashed"
            process.error = err
        end
    elseif status == "dead" then
        process.status = "stopped"
    end
end

-- Main background loop
local function backgroundLoop()
    init()

    -- Set up a timer for regular ticks
    local tickTimer = os.startTimer(0.1)

    while running do
        local event, p1 = os.pullEventRaw(0.05) -- Very short timeout

        if event == "timer" and p1 == tickTimer then
            -- Tick all processes
            for _, process in pairs(processes) do
                if process.status == "running" then
                    tickProcess(process)
                end
            end

            tickTimer = os.startTimer(0.1)
        elseif event == "storage_stop" then
            running = false
            break
        end
    end

    -- Cleanup
    if api then
        api:stop()
    end

    logger:info("Background storage system stopped")
end

-- Global functions for controlling the system
_G.storageStatus = function()
    print("Storage System Status:")
    for name, process in pairs(processes) do
        local status = process.status
        if process.error then
            status = status .. " (" .. process.error .. ")"
        end
        print("  " .. name .. ": " .. status)
    end
end

_G.storageStop = function()
    running = false
    os.queueEvent("storage_stop")
    print("Stopping storage system...")
end

_G.storageRestart = function()
    storageStop()
    sleep(1)
    shell.run("background.lua")
end

-- Run the background system
local ok, err = pcall(backgroundLoop)
if not ok then
    logger:error("Fatal error: " .. tostring(err))
    print("Storage system crashed: " .. tostring(err))
end