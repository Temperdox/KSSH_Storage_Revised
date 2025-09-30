local EventsBridge = {}
EventsBridge.__index = EventsBridge

function EventsBridge:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    -- Event statistics
    o.stats = {
        total = 0,
        byType = {},
        bySource = {},
        errors = 0
    }

    -- Event filtering
    o.filters = {
        logLevel = "info",
        sources = {},  -- Empty means all sources
        types = {}     -- Empty means all types
    }

    -- Ring buffer for recent events
    o.recentEvents = {}
    o.maxRecent = 500

    return o
end

function EventsBridge:start()
    -- Subscribe to all events
    self.eventBus:subscribe(".*", function(eventName, data)
        self:processEvent(eventName, data)
    end)

    -- Special handling for raw CC events
    self.eventBus:subscribe("raw%..*", function(eventName, data)
        self:processRawEvent(eventName, data)
    end)

    -- Subscribe to filter changes
    self.eventBus:subscribe("events.filter", function(event, data)
        self:updateFilters(data)
    end)

    self.logger:info("EventsBridge", "Service started")
end

function EventsBridge:stop()
    -- Save stats
    self:saveStats()
    self.logger:info("EventsBridge", "Service stopped")
end

function EventsBridge:processEvent(eventName, data)
    -- Update statistics
    self.stats.total = self.stats.total + 1
    self.stats.byType[eventName] = (self.stats.byType[eventName] or 0) + 1

    -- Extract source from event name (first part before dot)
    local source = eventName:match("^([^%.]+)")
    if source then
        self.stats.bySource[source] = (self.stats.bySource[source] or 0) + 1
    end

    -- Normalize event data
    local normalizedData = self:normalizeEventData(eventName, data)

    -- Add metadata
    normalizedData._meta = {
        timestamp = os.epoch("utc"),
        time = os.date("%H:%M:%S"),
        source = source,
        type = eventName,
        id = self.stats.total
    }

    -- Add to recent events
    table.insert(self.recentEvents, {
        name = eventName,
        data = normalizedData,
        timestamp = normalizedData._meta.timestamp
    })

    if #self.recentEvents > self.maxRecent then
        table.remove(self.recentEvents, 1)
    end

    -- Apply filters
    if self:shouldFilter(eventName, normalizedData) then
        return
    end

    -- Log event if appropriate
    self:logEvent(eventName, normalizedData)

    -- Mirror to specialized event streams
    self:mirrorEvent(eventName, normalizedData)
end

function EventsBridge:processRawEvent(eventName, data)
    local rawType = eventName:sub(5)  -- Remove "raw." prefix

    -- Convert raw CC events to normalized events
    local mappings = {
        ["char"] = "input.char",
        ["key"] = "input.key",
        ["key_up"] = "input.keyUp",
        ["mouse_click"] = "input.mouseClick",
        ["mouse_up"] = "input.mouseUp",
        ["mouse_scroll"] = "input.mouseScroll",
        ["mouse_drag"] = "input.mouseDrag",
        ["monitor_touch"] = "input.monitorTouch",
        ["monitor_resize"] = "display.monitorResize",
        ["term_resize"] = "display.termResize",
        ["redstone"] = "redstone.changed",
        ["peripheral"] = "peripheral.changed",
        ["peripheral_detach"] = "peripheral.detached",
        ["disk"] = "disk.inserted",
        ["disk_eject"] = "disk.ejected",
        ["rednet_message"] = "net.rednetMessage",
        ["modem_message"] = "net.modemMessage",
        ["timer"] = "system.timer",
        ["alarm"] = "system.alarm"
    }

    local mappedName = mappings[rawType]
    if mappedName then
        self.eventBus:publish(mappedName, data)
    end
end

function EventsBridge:normalizeEventData(eventName, data)
    if type(data) ~= "table" then
        return {value = data}
    end

    -- Clone data to avoid modifying original
    local normalized = {}
    for k, v in pairs(data) do
        normalized[k] = v
    end

    -- Event-specific normalizations
    if eventName:match("^storage%.") then
        -- Ensure storage events have required fields
        normalized.timestamp = normalized.timestamp or os.epoch("utc")
        normalized.success = normalized.success ~= false

    elseif eventName:match("^task%.") then
        -- Ensure task events have pool and worker info
        normalized.pool = normalized.pool or "unknown"
        normalized.worker = normalized.worker or 0

    elseif eventName:match("^net%.") then
        -- Ensure network events have protocol info
        normalized.protocol = normalized.protocol or "unknown"

    elseif eventName:match("^log%.") then
        -- Ensure log events have proper structure
        normalized.level = normalized.level or "info"
        normalized.source = normalized.source or "unknown"
        normalized.message = normalized.message or ""
    end

    return normalized
end

function EventsBridge:shouldFilter(eventName, data)
    -- Check type filter
    if #self.filters.types > 0 then
        local found = false
        for _, filterType in ipairs(self.filters.types) do
            if eventName:match(filterType) then
                found = true
                break
            end
        end
        if not found then return true end
    end

    -- Check source filter  
    if #self.filters.sources > 0 and data._meta and data._meta.source then
        local found = false
        for _, filterSource in ipairs(self.filters.sources) do
            if data._meta.source == filterSource then
                found = true
                break
            end
        end
        if not found then return true end
    end

    return false
end

function EventsBridge:logEvent(eventName, data)
    -- Determine log file based on event type
    local logFile = "events"

    if eventName:match("^storage%.") then
        logFile = "storage"
    elseif eventName:match("^net%.") or eventName:match("^api%.") then
        logFile = "network"
    elseif eventName:match("^test%.") then
        logFile = "tests"
    end

    -- Write to appropriate log file
    local date = os.date("%Y%m%d")
    local filename = string.format("/storage/logs/%s-%s.log", logFile, date)

    local file = fs.open(filename, "a")
    if file then
        file.writeLine(textutils.serialiseJSON({
            event = eventName,
            data = data
        }))
        file.close()
    end
end

function EventsBridge:mirrorEvent(eventName, data)
    -- Mirror to specialized streams for different consumers

    -- UI events stream (for visualization)
    if eventName:match("^task%.") or
            eventName:match("^storage%.moved") or
            eventName:match("^index%.") then
        self.eventBus:publish("ui.visualizer.event", {
            original = eventName,
            data = data
        })
    end

    -- Stats events stream
    if eventName:match("%.completed$") or
            eventName:match("%.failed$") or
            eventName:match("%.error$") then
        self.eventBus:publish("stats.track", {
            event = eventName,
            success = not (eventName:match("%.failed$") or eventName:match("%.error$"))
        })
    end

    -- Alert events stream (for critical events)
    if eventName:match("%.error$") or
            eventName:match("%.failed$") or
            eventName == "system.shutdown" then
        self.eventBus:publish("alert.critical", {
            event = eventName,
            data = data
        })
    end
end

function EventsBridge:updateFilters(filters)
    if filters.logLevel then
        self.filters.logLevel = filters.logLevel
    end

    if filters.sources then
        self.filters.sources = filters.sources
    end

    if filters.types then
        self.filters.types = filters.types
    end

    self.logger:debug("EventsBridge", "Filters updated")
end

function EventsBridge:getStats()
    return {
        total = self.stats.total,
        rate = self:calculateRate(),
        topTypes = self:getTopTypes(10),
        topSources = self:getTopSources(5),
        errors = self.stats.errors,
        recentCount = #self.recentEvents
    }
end

function EventsBridge:calculateRate()
    if #self.recentEvents < 2 then
        return 0
    end

    local first = self.recentEvents[1].timestamp
    local last = self.recentEvents[#self.recentEvents].timestamp
    local duration = (last - first) / 1000  -- Convert to seconds

    if duration <= 0 then
        return 0
    end

    return #self.recentEvents / duration
end

function EventsBridge:getTopTypes(limit)
    local sorted = {}
    for eventType, count in pairs(self.stats.byType) do
        table.insert(sorted, {type = eventType, count = count})
    end

    table.sort(sorted, function(a, b) return a.count > b.count end)

    local top = {}
    for i = 1, math.min(limit, #sorted) do
        table.insert(top, sorted[i])
    end

    return top
end

function EventsBridge:getTopSources(limit)
    local sorted = {}
    for source, count in pairs(self.stats.bySource) do
        table.insert(sorted, {source = source, count = count})
    end

    table.sort(sorted, function(a, b) return a.count > b.count end)

    local top = {}
    for i = 1, math.min(limit, #sorted) do
        table.insert(top, sorted[i])
    end

    return top
end

function EventsBridge:getRecentEvents(count, filter)
    count = count or 50
    local events = {}

    for i = #self.recentEvents, 1, -1 do
        local event = self.recentEvents[i]

        -- Apply optional filter
        if not filter or event.name:match(filter) then
            table.insert(events, event)

            if #events >= count then
                break
            end
        end
    end

    return events
end

function EventsBridge:saveStats()
    local statsFile = "/storage/data/event_stats.json"
    local data = {
        stats = self.stats,
        lastSave = os.epoch("utc")
    }

    local file = fs.open(statsFile, "w")
    if file then
        file.write(textutils.serialiseJSON(data))
        file.close()
    end
end

function EventsBridge:loadStats()
    local statsFile = "/storage/data/event_stats.json"

    if not fs.exists(statsFile) then
        return
    end

    local file = fs.open(statsFile, "r")
    if file then
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data and data.stats then
            self.stats = data.stats
        end
    end
end

return EventsBridge