-- ============================================================================
-- PROPER STARTUP WITH PRINT OVERRIDE AND FULL TERMINAL UI
-- ============================================================================

-- /storage/startup.lua
-- Full startup with print redirection to UI console

local function startup()
    -- Save original print function
    local originalPrint = print
    local printBuffer = {}
    local maxPrintBuffer = 100

    -- Override global print to capture output
    function print(...)
        local args = {...}
        local str = ""
        for i, v in ipairs(args) do
            str = str .. tostring(v)
            if i < #args then str = str .. "\t" end
        end

        -- Add to buffer
        table.insert(printBuffer, {
            time = os.date("%H:%M:%S"),
            text = str
        })

        -- Trim buffer
        while #printBuffer > maxPrintBuffer do
            table.remove(printBuffer, 1)
        end

        -- DO NOT print to actual console - it will break the UI
    end

    -- System paths
    local BASE_PATH = "/storage"
    package.path = package.path .. ";" .. BASE_PATH .. "/?.lua"
    package.path = package.path .. ";" .. BASE_PATH .. "/?/init.lua"

    -- Load core modules
    local fsx = require("core.fsx")
    local EventBus = require("core.event_bus")
    local Scheduler = require("core.scheduler")
    local Logger = require("core.logger")
    local TimeWheel = require("core.timewheel")

    -- Create directories
    fsx.ensureDir(BASE_PATH .. "/cfg")
    fsx.ensureDir(BASE_PATH .. "/cfg/themes")
    fsx.ensureDir(BASE_PATH .. "/data")
    fsx.ensureDir(BASE_PATH .. "/logs")

    -- Load settings
    local settingsPath = BASE_PATH .. "/cfg/settings.json"
    local settings = fsx.readJson(settingsPath) or {
        theme = "dark",
        logLevel = "error",
        inputSide = "right",
        outputSide = "left",
        soundEnabled = true,
        soundVolume = 0.5,
        pools = {
            io = 4,
            index = 2,
            ui = 2,
            net = 2
        },
        ui = {
            maxLogs = 50,
            autoScroll = true,
            showTimestamps = true
        }
    }
    fsx.writeJson(settingsPath, settings)

    -- Initialize core systems
    local eventBus = EventBus:new()

    -- Create logger that uses the print buffer
    local logger = Logger:new(eventBus, settings.logLevel)
    logger.printBuffer = printBuffer  -- Share the print buffer

    -- Initialize scheduler
    local scheduler = Scheduler:new(eventBus)
    scheduler:createPool("io", settings.pools.io)
    scheduler:createPool("index", settings.pools.index)
    scheduler:createPool("ui", settings.pools.ui)
    scheduler:createPool("net", settings.pools.net)
    scheduler:createPool("api", 2)
    scheduler:createPool("stats", 1)
    scheduler:createPool("tests", 2)
    scheduler:createPool("sound", 1)

    -- Load services
    local Bootstrap = require("services.bootstrap")
    local StorageService = require("services.storage_service")
    local MonitorService = require("services.monitor_service")
    local ApiService = require("services.api_service")
    local StatsService = require("services.stats_service")
    local TestsService = require("services.tests_service")
    local SettingsService = require("services.settings_service")
    local SoundService = require("services.sound_service")
    local EventsBridge = require("services.events_bridge")

    -- Bootstrap storage
    logger:info("Bootstrap", "Discovering storage inventories...")
    local bootstrap = Bootstrap:new(eventBus, logger)
    local storageMap, bufferInventory = bootstrap:discover()

    if not bufferInventory then
        -- Use original print for critical errors before UI loads
        originalPrint("[ERROR] No suitable buffer inventory found!")
        return
    end

    logger:info("Bootstrap", string.format(
            "Found %d storage inventories, buffer: %s",
            #storageMap, bufferInventory.name
    ))

    -- Initialize time wheel
    local timeWheel = TimeWheel:new(eventBus)

    -- Create service context
    local context = {
        eventBus = eventBus,
        scheduler = scheduler,
        logger = logger,
        settings = settings,
        storageMap = storageMap,
        bufferInventory = bufferInventory,
        timeWheel = timeWheel,
        basePath = BASE_PATH,
        running = true,
        startTime = os.epoch("utc"),
        printBuffer = printBuffer  -- Pass print buffer to context
    }

    -- Initialize services
    context.services = {
        events = EventsBridge:new(context),
        storage = StorageService:new(context),
        monitor = MonitorService:new(context),
        api = ApiService:new(context),
        stats = StatsService:new(context),
        tests = TestsService:new(context),
        settings = SettingsService:new(context),
        sound = SoundService:new(context)
    }

    -- Start services in specific order to ensure proper event flow
    local serviceOrder = {"events", "monitor", "storage", "api", "stats", "tests", "settings", "sound"}
    for _, name in ipairs(serviceOrder) do
        local service = context.services[name]
        if service and service.start then
            service:start()
            logger:info("System", string.format("Service '%s' initialized", name))
        end
    end

    -- Initialize Terminal UI Router and Pages
    local Router = require("ui.router")
    local router = Router:new(context)
    context.router = router

    -- Load command factory
    local CommandFactory = require("factories.command_factory")
    local commandFactory = CommandFactory:new(context)
    context.commandFactory = commandFactory

    -- Register pages
    local ConsolePage = require("ui.pages.console_page")
    local StatsPage = require("ui.pages.stats_page")
    local TestsPage = require("ui.pages.tests_page")
    local SettingsPage = require("ui.pages.settings_page")

    router:register("console", ConsolePage:new(context))
    router:register("stats", StatsPage:new(context))
    router:register("tests", TestsPage:new(context))
    router:register("settings", SettingsPage:new(context))

    -- Navigate to console page
    router:navigate("console")

    -- Load commands
    local CommandLoader = require("commands.init")
    CommandLoader.loadAll(commandFactory, context)

    logger:info("System", "All services initialized!")
    eventBus:publish("system.ready", {
        timestamp = os.epoch("utc")
    })

    -- ========================================================================
    -- PARALLEL PROCESSES
    -- ========================================================================

    local processes = {}

    -- Process 1: Terminal UI and Input Handler
    table.insert(processes, function()
        while context.running do
            local event = {os.pullEvent()}

            if event[1] == "terminate" then
                context.running = false
                break
            end

            -- Route to current page
            if router:getCurrentPage() and router:getCurrentPage().handleInput then
                router:getCurrentPage():handleInput(table.unpack(event))
            end

            -- Publish event
            eventBus:publish("raw." .. event[1], {
                type = event[1],
                params = {table.unpack(event, 2)}
            })
        end
    end)

    -- Process 2: UI Render Loop
    table.insert(processes, function()
        while context.running do
            if router:getCurrentPage() and router:getCurrentPage().render then
                router:getCurrentPage():render()
            end
            os.sleep(0.1)  -- 10 FPS
        end
    end)

    -- Process 3: Storage Input Monitor
    table.insert(processes, function()
        while context.running do
            if context.services.storage and context.services.storage.monitorInput then
                context.services.storage:monitorInput()
            end
            os.sleep(0.5)
        end
    end)

    -- Process 4: Storage Buffer Processor
    table.insert(processes, function()
        while context.running do
            if context.services.storage and context.services.storage.processBuffer then
                context.services.storage:processBuffer()
            end
            os.sleep(1)
        end
    end)

    -- Process 5: Monitor Service (if available)
    if context.services.monitor and peripheral.find("monitor") then
        table.insert(processes, function()
            context.services.monitor:run()
        end)
    end

    -- Process 6: API Service
    if context.services.api and context.services.api.modem then
        table.insert(processes, function()
            context.services.api:run()
        end)
    end

    -- Process 7: Scheduler Workers
    table.insert(processes, function()
        scheduler:runWorkers()
    end)

    -- Process 8: Event Queue Processor
    table.insert(processes, function()
        while context.running do
            eventBus:processQueue()
            os.sleep(0.05)
        end
    end)

    -- Process 9: Time Wheel
    table.insert(processes, function()
        timeWheel:start()
    end)

    -- Process 10: Stats Ticker
    table.insert(processes, function()
        -- Stats service handles its own timing internally
        while context.running do
            os.sleep(60)
        end
    end)

    -- ========================================================================
    -- RUN ALL PROCESSES IN PARALLEL
    -- ========================================================================

    parallel.waitForAny(table.unpack(processes))

    -- Cleanup
    for name, service in pairs(context.services) do
        if service.stop then
            service:stop()
        end
    end

    -- Restore original print
    _G.print = originalPrint
    print("[SHUTDOWN] Storage system stopped")
end

-- Run startup
startup()