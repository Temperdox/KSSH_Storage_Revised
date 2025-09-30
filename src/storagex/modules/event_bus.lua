-- modules/event_bus.lua
-- Event bus for inter-process communication with event logging

local EventBus = {}
EventBus.__index = EventBus

function EventBus:new()
    local self = setmetatable({}, EventBus)
    self.listeners = {}
    self.queue = {}
    self.processing = false
    self.eventLog = {}  -- Track recent events for debugging
    self.maxEventLog = 100  -- Keep last 100 events
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

    -- Log listener registration
    if _G.logger then
        _G.logger:debug(string.format("Registered listener for '%s' (priority: %d, total listeners: %d)",
                event, priority, #self.listeners[event]), "EventBus")
    end
end

function EventBus:off(event, callback)
    if not self.listeners[event] then
        return
    end

    for i, listener in ipairs(self.listeners[event]) do
        if listener.callback == callback then
            table.remove(self.listeners[event], i)

            -- Log listener removal
            if _G.logger then
                _G.logger:debug(string.format("Removed listener for '%s' (remaining: %d)",
                        event, #self.listeners[event]), "EventBus")
            end
            break
        end
    end
end

function EventBus:emit(event, ...)
    local args = {...}

    -- Log the event emission
    local eventInfo = {
        event = event,
        args = args,
        timestamp = os.epoch("utc"),
        listeners = self.listeners[event] and #self.listeners[event] or 0
    }

    -- Add to internal log
    table.insert(self.eventLog, eventInfo)
    if #self.eventLog > self.maxEventLog then
        table.remove(self.eventLog, 1)
    end

    -- Log to file via logger
    if _G.logger then
        local argStr = ""
        for i, arg in ipairs(args) do
            local argType = type(arg)
            if argType == "string" then
                argStr = argStr .. string.format('"%s"', arg)
            elseif argType == "number" or argType == "boolean" then
                argStr = argStr .. tostring(arg)
            elseif argType == "table" then
                -- Try to get table name/id if it has one
                if arg.name then
                    argStr = argStr .. string.format("table{name='%s'}", arg.name)
                elseif arg.displayName then
                    argStr = argStr .. string.format("table{displayName='%s'}", arg.displayName)
                elseif arg.id then
                    argStr = argStr .. string.format("table{id='%s'}", arg.id)
                else
                    argStr = argStr .. string.format("table{%d items}", #arg)
                end
            else
                argStr = argStr .. argType
            end
            if i < #args then
                argStr = argStr .. ", "
            end
        end

        _G.logger:debug(string.format("EVENT: '%s' emitted with %d args [%s] -> %d listeners",
                event, #args, argStr, eventInfo.listeners), "EventBus")
    end

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
    local args = {...}

    -- Log synchronous event
    if _G.logger then
        _G.logger:debug(string.format("SYNC EVENT: '%s' emitted with %d args", event, #args), "EventBus")
    end

    if not self.listeners[event] then
        if _G.logger then
            _G.logger:debug(string.format("No listeners for sync event '%s'", event), "EventBus")
        end
        return
    end

    local successCount = 0
    local errorCount = 0

    for _, listener in ipairs(self.listeners[event]) do
        local ok, err = pcall(listener.callback, ...)
        if ok then
            successCount = successCount + 1
        else
            errorCount = errorCount + 1
            if _G.logger then
                _G.logger:error(string.format("Event listener error for '%s': %s",
                        event, tostring(err)), "EventBus")
            end
        end
    end

    -- Log results
    if _G.logger then
        _G.logger:debug(string.format("SYNC EVENT '%s' complete: %d success, %d errors",
                event, successCount, errorCount), "EventBus")
    end
end

function EventBus:processQueue()
    self.processing = true

    local startTime = os.epoch("utc")
    local processedCount = 0

    while #self.queue > 0 do
        local item = table.remove(self.queue, 1)
        processedCount = processedCount + 1

        if self.listeners[item.event] then
            local listenerCount = #self.listeners[item.event]
            local successCount = 0
            local errorCount = 0

            for _, listener in ipairs(self.listeners[item.event]) do
                -- Run in coroutine for non-blocking
                local co = coroutine.create(function()
                    local ok, err = pcall(listener.callback, table.unpack(item.args))
                    if ok then
                        successCount = successCount + 1
                    else
                        errorCount = errorCount + 1
                        if _G.logger then
                            _G.logger:error(string.format("Event listener error for '%s': %s",
                                    item.event, tostring(err)), "EventBus")
                        end
                    end
                end)
                coroutine.resume(co)
            end

            -- Log processing result
            if _G.logger and (successCount > 0 or errorCount > 0) then
                _G.logger:debug(string.format("Processed event '%s': %d/%d listeners succeeded",
                        item.event, successCount, listenerCount), "EventBus")
            end
        else
            -- Log unhandled event
            if _G.logger then
                _G.logger:debug(string.format("Event '%s' has no listeners", item.event), "EventBus")
            end
        end
    end

    self.processing = false

    -- Log queue processing summary
    if _G.logger and processedCount > 0 then
        local duration = os.epoch("utc") - startTime
        _G.logger:debug(string.format("Processed %d events in %dms", processedCount, duration), "EventBus")
    end
end

function EventBus:waitFor(event, timeout)
    timeout = timeout or 10
    local received = false
    local data = nil

    -- Log wait start
    if _G.logger then
        _G.logger:debug(string.format("Waiting for event '%s' (timeout: %ds)", event, timeout), "EventBus")
    end

    local callback = function(...)
        received = true
        data = {...}
    end

    self:on(event, callback, 10)

    local timer = os.startTimer(timeout)
    local startTime = os.epoch("utc")

    while not received do
        local e, p1 = os.pullEvent()
        if e == "timer" and p1 == timer then
            break
        end
    end

    self:off(event, callback)

    -- Log wait result
    if _G.logger then
        local duration = os.epoch("utc") - startTime
        if received then
            _G.logger:debug(string.format("Received event '%s' after %dms", event, duration), "EventBus")
        else
            _G.logger:debug(string.format("Timeout waiting for event '%s' after %dms", event, duration), "EventBus")
        end
    end

    return received, data
end

function EventBus:getEventLog()
    return self.eventLog
end

function EventBus:getListenerCount(event)
    if event then
        return self.listeners[event] and #self.listeners[event] or 0
    else
        local total = 0
        for _, listeners in pairs(self.listeners) do
            total = total + #listeners
        end
        return total
    end
end

function EventBus:getEventStats()
    local stats = {
        totalListeners = self:getListenerCount(),
        queueSize = #self.queue,
        processing = self.processing,
        recentEvents = #self.eventLog,
        eventTypes = {}
    }

    -- Count listeners per event type
    for event, listeners in pairs(self.listeners) do
        stats.eventTypes[event] = #listeners
    end

    return stats
end

return EventBus