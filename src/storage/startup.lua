local function startup()
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

    -- Initialize core systems
    print("[STARTUP] CC:Storage System Starting...")

    -- Create directory structure
    fsx.ensureDir(BASE_PATH .. "/cfg")
    fsx.ensureDir(BASE_PATH .. "/cfg/themes")
    fsx.ensureDir(BASE_PATH .. "/data")
    fsx.ensureDir(BASE_PATH .. "/logs")

    -- Load or create settings
    local settingsPath = BASE_PATH .. "/cfg/settings.json"
    local settings = fsx.readJson(settingsPath) or {
        theme = "dark",
        logLevel = "info",
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

    -- Initialize event bus
    local eventBus = EventBus:new()

    -- Initialize logger
    local logger = Logger:new(eventBus, settings.logLevel)

    -- Initialize scheduler with named pools
    local scheduler = Scheduler:new(eventBus)
    scheduler:createPool("io", settings.pools.io)
    scheduler:createPool("index", settings.pools.index)
    scheduler:createPool("ui", settings.pools.ui)
    scheduler:createPool("net", settings.pools.net)
    scheduler:createPool("api", 2)
    scheduler:createPool("stats", 1)
    scheduler:createPool("tests", 2)
    scheduler:createPool("sound", 1)

    -- Bootstrap storage discovery
    logger:info("Bootstrap", "Discovering storage inventories...")
    local bootstrap = Bootstrap:new(eventBus, logger)
    local storageMap, bufferInventory = bootstrap:discover()

    if not bufferInventory then
        error("[ERROR] No suitable buffer inventory found!")
    end

    logger:info("Bootstrap", string.format(
            "Found %d storage inventories, buffer: %s",
            #storageMap, bufferInventory.name
    ))

    -- Initialize time wheel for scheduled tasks
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
        startTime = os.epoch("utc")
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

    -- Start all services (non-blocking initialization)
    logger:info("System", "Starting services...")

    for name, service in pairs(context.services) do
        if service.start then
            service:start()
            logger:info("System", string.format("Service '%s' initialized", name))
            eventBus:publish("system.serviceStarted", {service = name})
        end
    end

    logger:info("System", "[OK] All services initialized!")
    eventBus:publish("system.ready", {
        timestamp = os.epoch("utc"),
        services = context.services
    })

    -- Start time wheel
    timeWheel:start()

    -- ========================================================================
    -- PARALLEL PROCESS EXECUTION
    -- ========================================================================

    local processes = {}

    -- Process 1: Storage Service Handler
    table.insert(processes, function()
        logger:debug("Process", "Storage handler starting...")
        while context.running do
            if context.services.storage and context.services.storage.monitorInput then
                context.services.storage:monitorInput()
            end
            os.sleep(0.1)
        end
    end)

    -- Process 2: Storage Buffer Processor
    table.insert(processes, function()
        logger:debug("Process", "Buffer processor starting...")
        while context.running do
            if context.services.storage and context.services.storage.processBuffer then
                context.services.storage:processBuffer()
            end
            os.sleep(0.5)
        end
    end)

    -- Process 3: Monitor Service
    if context.services.monitor then
        table.insert(processes, function()
            logger:debug("Process", "Monitor service starting...")
            context.services.monitor:run()
        end)
    end

    -- Process 4: API Service
    if context.services.api then
        table.insert(processes, function()
            logger:debug("Process", "API service starting...")
            context.services.api:run()
        end)
    end

    -- Process 5: Event Bridge Processor
    table.insert(processes, function()
        logger:debug("Process", "Event bridge starting...")
        while context.running do
            context.eventBus:processQueue()
            os.sleep(0.05)
        end
    end)

    -- Process 6: Stats Service
    if context.services.stats then
        table.insert(processes, function()
            logger:debug("Process", "Stats service starting...")
            while context.running do
                context.services.stats:tick()
                os.sleep(60)  -- Tick every minute
            end
        end)
    end

    -- Process 7: Scheduler Worker Manager
    table.insert(processes, function()
        logger:debug("Process", "Scheduler workers starting...")
        scheduler:runWorkers()
    end)

    -- Process 8: Terminal UI (if available)
    local Router = require("ui.router")
    local router = Router:new(context)

    -- Register pages
    router:register("console", require("ui.pages.console_page"):new(context))
    router:register("stats", require("ui.pages.stats_page"):new(context))
    router:register("tests", require("ui.pages.tests_page"):new(context))
    router:register("settings", require("ui.pages.settings_page"):new(context))

    -- Navigate to console
    router:navigate("console")

    table.insert(processes, function()
        logger:debug("Process", "Terminal UI starting...")
        while context.running do
            local event = {os.pullEvent()}

            -- Handle termination
            if event[1] == "terminate" then
                context.running = false
                logger:info("System", "Shutdown signal received")
                break
            end

            -- Route to current page
            router:handleInput(table.unpack(event))

            -- Publish raw event
            eventBus:publish("raw." .. event[1], {
                type = event[1],
                params = {table.unpack(event, 2)}
            })
        end
    end)

    -- Process 9: Time Wheel Ticker
    table.insert(processes, function()
        logger:debug("Process", "Time wheel starting...")
        timeWheel:runTicker()
    end)

    -- Process 10: Command Handler (if commands registered)
    local CommandFactory = require("factories.command_factory")
    local commandFactory = CommandFactory:new(context)

    -- Load commands
    local CommandLoader = require("commands.init")
    CommandLoader.loadAll(commandFactory, context)

    context.commandFactory = commandFactory

    -- ========================================================================
    -- RUN ALL PROCESSES IN PARALLEL
    -- ========================================================================

    logger:info("System", "Starting parallel processes...")

    -- Run all processes in parallel
    parallel.waitForAny(table.unpack(processes))

    -- Cleanup on shutdown
    logger:info("System", "Shutting down...")

    -- Stop all services
    for name, service in pairs(context.services) do
        if service.stop then
            service:stop()
            logger:debug("System", string.format("Service '%s' stopped", name))
        end
    end

    -- Flush logs
    logger:flush()

    print("[SHUTDOWN] Storage system stopped")
end

-- Run startup
startup()