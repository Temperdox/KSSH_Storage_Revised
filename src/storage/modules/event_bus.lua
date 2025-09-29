-- modules/event_bus.lua
-- Event bus for inter-process communication

local EventBus = {}
EventBus.__index = EventBus

function EventBus:new()
    local self = setmetatable({}, EventBus)
    self.listeners = {}
    self.queue = {}
    self.processing = false
    return self
end

function EventBus:on(event, callback, priority)
    priority = priority or 5

    if not self.listeners[event] then
        self.listeners[event] = {}
    end

    table.insert(self.listeners[event], {
        callback = callback,
        priority = priority
    })

    -- Sort by priority (higher priority first)
    table.sort(self.listeners[event], function(a, b)
        return a.priority > b.priority
    end)
end

function EventBus:off(event, callback)
    if not self.listeners[event] then
        return
    end

    for i, listener in ipairs(self.listeners[event]) do
        if listener.callback == callback then
            table.remove(self.listeners[event], i)
            break
        end
    end
end

function EventBus:emit(event, ...)
    local args = {...}

    -- Add to queue
    table.insert(self.queue, {
        event = event,
        args = args,
        timestamp = os.epoch("utc")
    })

    -- Process queue if not already processing
    if not self.processing then
        self:processQueue()
    end
end

function EventBus:emitSync(event, ...)
    if not self.listeners[event] then
        return
    end

    for _, listener in ipairs(self.listeners[event]) do
        local ok, err = pcall(listener.callback, ...)
        if not ok then
            -- Log error but don't stop other listeners
            if _G.logger then
                _G.logger:error("Event listener error: " .. tostring(err))
            end
        end
    end
end

function EventBus:processQueue()
    self.processing = true

    while #self.queue > 0 do
        local item = table.remove(self.queue, 1)

        if self.listeners[item.event] then
            for _, listener in ipairs(self.listeners[item.event]) do
                -- Run in coroutine for non-blocking
                local co = coroutine.create(function()
                    local ok, err = pcall(listener.callback, table.unpack(item.args))
                    if not ok and _G.logger then
                        _G.logger:error("Event listener error: " .. tostring(err))
                    end
                end)
                coroutine.resume(co)
            end
        end
    end

    self.processing = false
end

function EventBus:waitFor(event, timeout)
    timeout = timeout or 10
    local received = false
    local data = nil

    local callback = function(...)
        received = true
        data = {...}
    end

    self:on(event, callback, 10)

    local timer = os.startTimer(timeout)
    while not received do
        local e, p1 = os.pullEvent()
        if e == "timer" and p1 == timer then
            break
        end
    end

    self:off(event, callback)

    return received, data
end

return EventBus