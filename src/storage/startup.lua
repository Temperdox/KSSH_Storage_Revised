-- ============================================================================
-- PART 1: STARTUP.LUA
-- ============================================================================

-- /storage/startup.lua
-- Main entry point that orchestrates the entire storage system

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
    local TestsService = require("services.tecdsts_service")
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

    -- Publish scheduler pools on event bus
    eventBus:publish("system.poolsCreated", {
        pools = scheduler:getPools()
    })

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
        basePath = BASE_PATH
    }

    -- Initialize services
    local services = {
        events = EventsBridge:new(context),
        storage = StorageService:new(context),
        monitor = MonitorService:new(context),
        api = ApiService:new(context),
        stats = StatsService:new(context),
        tests = TestsService:new(context),
        settings = SettingsService:new(context),
        sound = SoundService:new(context)
    }

    -- Start all services in parallel
    logger:info("System", "Starting services...")

    local startTasks = {}
    for name, service in pairs(services) do
        table.insert(startTasks, scheduler:submit("io", function()
            service:start()
            logger:info("System", string.format("Service '%s' started", name))
            eventBus:publish("system.serviceStarted", {service = name})
        end))
    end

    -- Wait for all services to start
    for _, task in ipairs(startTasks) do
        task:await()
    end

    logger:info("System", "[OK] All services started successfully!")
    eventBus:publish("system.ready", {
        timestamp = os.epoch("utc"),
        services = services
    })

    -- Start time wheel (begins per-minute ticks)
    timeWheel:start()

    -- Main event loop
    while true do
        local event = {os.pullEvent()}

        -- Distribute raw events to event bus
        eventBus:publish("raw." .. event[1], {
            type = event[1],
            params = {table.unpack(event, 2)}
        })

        -- Handle system shutdown
        if event[1] == "terminate" then
            logger:info("System", "Shutting down...")

            -- Stop all services
            for name, service in pairs(services) do
                if service.stop then
                    service:stop()
                end
            end

            -- Flush logs
            logger:flush()

            break
        end
    end
end

-- Run startup
startup()