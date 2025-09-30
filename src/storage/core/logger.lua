-- /storage/core/logger.lua
-- Optimized logger that only logs important events and errors

local Logger = {}
Logger.__index = Logger

function Logger:new(eventBus, level)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.levels = {trace = 1, debug = 2, info = 3, warn = 4, error = 5, critical = 6}
    o.level = o.levels[level] or 4  -- Default to WARN level
    o.ringBuffer = {}
    o.maxRingSize = 100  -- Reduced from 1000
    o.basePath = "/storage/logs"

    -- Events to completely ignore (too noisy)
    o.ignoredEvents = {
        "raw.timer",
        "raw.key",
        "raw.char",
        "raw.key_up",
        "raw.mouse_click",
        "raw.mouse_up",
        "raw.mouse_scroll",
        "raw.mouse_drag",
        "system.timer",
        "task.start",
        "task.end",
        "ui.monitor.update",
        "events.filter",
        "ui.visualizer.event",
        "stats.track",
        "sound.played"
    }

    -- Only log these at debug level or lower
    o.debugOnlyEvents = {
        "scheduler.poolCreated",
        "storage.itemIndexed",
        "index.update",
        "storage.movedToBuffer",
        "storage.movedToStorage",
        "net.rpc.request",
        "net.rpc.response"
    }

    return o
end

function Logger:shouldLog(level, source, message)
    -- Check level threshold
    if self.levels[level] < self.level then
        return false
    end

    -- Check if source is an ignored event
    for _, ignored in ipairs(self.ignoredEvents) do
        if source == ignored or source:match("^" .. ignored:gsub("%.", "%%.")) then
            return false
        end
    end

    -- Check if it's a debug-only event and we're above debug level
    if self.level > self.levels.debug then
        for _, debugEvent in ipairs(self.debugOnlyEvents) do
            if source == debugEvent or source:match("^" .. debugEvent:gsub("%.", "%%.")) then
                return false
            end
        end
    end

    return true
end

function Logger:log(level, source, message, data)
    -- Filter out noisy events
    if not self:shouldLog(level, source, message) then
        return
    end

    local entry = {
        level = level,
        source = source,
        message = message,
        data = data,
        timestamp = os.epoch("utc"),
        time = os.date("%H:%M:%S")
    }

    -- Add to ring buffer
    table.insert(self.ringBuffer, entry)
    if #self.ringBuffer > self.maxRingSize then
        table.remove(self.ringBuffer, 1)
    end

    -- Only write important events to file (warn and above)
    if self.levels[level] >= self.levels.warn then
        local date = os.date("%Y%m%d")
        local filename = string.format("%s/app-%s.log", self.basePath, date)
        local file = fs.open(filename, "a")
        if file then
            file.writeLine(textutils.serialiseJSON(entry))
            file.close()
        end
    end

    -- Only publish important log events to prevent event bus flooding
    if self.levels[level] >= self.levels.warn then
        self.eventBus:publish("log." .. level, entry)
    end
end

function Logger:trace(source, message, data)
    self:log("trace", source, message, data)
end

function Logger:debug(source, message, data)
    self:log("debug", source, message, data)
end

function Logger:info(source, message, data)
    self:log("info", source, message, data)
end

function Logger:warn(source, message, data)
    self:log("warn", source, message, data)
end

function Logger:error(source, message, data)
    self:log("error", source, message, data)
end

function Logger:critical(source, message, data)
    self:log("critical", source, message, data)
end

function Logger:getRecent(count)
    count = count or 50
    local start = math.max(1, #self.ringBuffer - count + 1)
    local logs = {}
    for i = start, #self.ringBuffer do
        table.insert(logs, self.ringBuffer[i])
    end
    return logs
end

-- Clean up old log files to save disk space
function Logger:cleanupOldLogs(daysToKeep)
    daysToKeep = daysToKeep or 7
    local cutoffTime = os.epoch("utc") - (daysToKeep * 24 * 60 * 60 * 1000)

    local files = fs.list(self.basePath)
    for _, filename in ipairs(files) do
        if filename:match("^app%-%d+%.log$") then
            local path = fs.combine(self.basePath, filename)
            local file = fs.open(path, "r")
            if file then
                local firstLine = file.readLine()
                file.close()

                if firstLine then
                    local ok, entry = pcall(textutils.unserialiseJSON, firstLine)
                    if ok and entry and entry.timestamp and entry.timestamp < cutoffTime then
                        fs.delete(path)
                    end
                end
            end
        end
    end
end

return Logger