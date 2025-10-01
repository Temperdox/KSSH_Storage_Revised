-- /core/event_bus.lua
-- Optimized event bus that doesn't flood the system with events

local EventBus = {}
EventBus.__index = EventBus

function EventBus:new()
    local o = setmetatable({}, self)
    o.listeners = {}
    o.queue = {}
    o.recentEvents = {}
    o.maxRecent = 100  -- Reduced from 1000
    o.eventTypes = {}

    -- Events to not store in recent events (too noisy)
    o.transientEvents = {
        "raw%..*",           -- All raw events
        "ui%..*",            -- UI updates
        "sound%..*",         -- Sound events
        "task%.start",       -- Task lifecycle
        "task%.end",
        "log%.trace",        -- Low level logs
        "log%.debug",
        "stats%.track",
        "events%.filter"
    }

    return o
end

function EventBus:subscribe(pattern, callback)
    if not self.listeners[pattern] then
        self.listeners[pattern] = {}
    end
    table.insert(self.listeners[pattern], callback)
    return #self.listeners[pattern]
end

function EventBus:isTransient(eventName)
    for _, pattern in ipairs(self.transientEvents) do
        if eventName:match(pattern) then
            return true
        end
    end
    return false
end

function EventBus:publish(eventName, data)
    -- Track event type count (but not for transient events)
    if not self:isTransient(eventName) then
        self.eventTypes[eventName] = (self.eventTypes[eventName] or 0) + 1

        -- Only store non-transient events in recent events
        table.insert(self.recentEvents, {
            name = eventName,
            data = data,
            timestamp = os.epoch("utc")
        })

        if #self.recentEvents > self.maxRecent then
            table.remove(self.recentEvents, 1)
        end
    end

    -- Immediate dispatch to all listeners
    for pattern, callbacks in pairs(self.listeners) do
        if eventName:match(pattern) then
            for _, callback in ipairs(callbacks) do
                -- Use pcall to prevent one bad listener from breaking everything
                local ok, err = pcall(callback, eventName, data)
                -- Only log errors for actual problems, not normal events
                if not ok and not eventName:match("^raw%.") then
                    -- Don't use the logger here to avoid recursion
                    -- Just print critical errors
                    if eventName:match("error") or eventName:match("fail") then
                        print("[EVENT ERROR]", eventName, err)
                    end
                end
            end
        end
    end

    -- Only queue non-transient events
    if not self:isTransient(eventName) then
        table.insert(self.queue, {name = eventName, data = data})

        -- Keep queue size limited
        if #self.queue > 50 then
            table.remove(self.queue, 1)
        end
    end
end

function EventBus:processQueue()
    local processed = 0
    while #self.queue > 0 and processed < 10 do  -- Process max 10 events per tick
        local event = table.remove(self.queue, 1)
        processed = processed + 1

        -- Process without re-queueing
        for pattern, callbacks in pairs(self.listeners) do
            if event.name:match(pattern) then
                for _, callback in ipairs(callbacks) do
                    pcall(callback, event.name, event.data)
                end
            end
        end
    end
end

function EventBus:getRecentEvents(count)
    count = count or 50
    local start = math.max(1, #self.recentEvents - count + 1)
    local events = {}
    for i = start, #self.recentEvents do
        table.insert(events, self.recentEvents[i])
    end
    return events
end

function EventBus:getEventTypes()
    local types = {}
    for eventType, count in pairs(self.eventTypes) do
        table.insert(types, {type = eventType, count = count})
    end
    table.sort(types, function(a, b) return a.count > b.count end)
    return types
end

-- Clean up old events periodically
function EventBus:cleanup()
    -- Clear very old events from recent events
    local cutoff = os.epoch("utc") - 60000  -- Keep only last minute
    local newRecent = {}
    for _, event in ipairs(self.recentEvents) do
        if event.timestamp > cutoff then
            table.insert(newRecent, event)
        end
    end
    self.recentEvents = newRecent

    -- Reset event type counts if they get too large
    for eventType, count in pairs(self.eventTypes) do
        if count > 10000 then
            self.eventTypes[eventType] = 1000  -- Reset to reasonable number
        end
    end
end

return EventBus