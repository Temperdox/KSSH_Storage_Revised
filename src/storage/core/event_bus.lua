local EventBus = {}
EventBus.__index = EventBus

function EventBus:new()
    local o = setmetatable({}, self)
    o.listeners = {}
    o.queue = {}
    o.recentEvents = {}
    o.maxRecent = 1000
    o.eventTypes = {}
    return o
end

function EventBus:subscribe(pattern, callback)
    if not self.listeners[pattern] then
        self.listeners[pattern] = {}
    end
    table.insert(self.listeners[pattern], callback)
    return #self.listeners[pattern]
end

function EventBus:publish(eventName, data)
    -- Track event type
    self.eventTypes[eventName] = (self.eventTypes[eventName] or 0) + 1

    -- Add to recent events ring buffer
    table.insert(self.recentEvents, {
        name = eventName,
        data = data,
        timestamp = os.epoch("utc")
    })

    if #self.recentEvents > self.maxRecent then
        table.remove(self.recentEvents, 1)
    end

    -- Immediate dispatch
    for pattern, callbacks in pairs(self.listeners) do
        if eventName:match(pattern) then
            for _, callback in ipairs(callbacks) do
                local ok, err = pcall(callback, eventName, data)
                if not ok then
                    print("[EVENT ERROR]", err)
                end
            end
        end
    end

    -- Queued dispatch
    table.insert(self.queue, {name = eventName, data = data})
end

function EventBus:processQueue()
    while #self.queue > 0 do
        local event = table.remove(self.queue, 1)
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

return EventBus