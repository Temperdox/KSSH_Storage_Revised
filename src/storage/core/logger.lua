-- /storage/core/logger.lua
-- Optimized logger that only logs important events and errors

local Logger = {}
Logger.__index = Logger

function Logger:new(eventBus, level, fileLevel)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.levels = {trace = 1, debug = 2, info = 3, warn = 4, error = 5, critical = 6}
    o.level = o.levels[level] or 4  -- Default to WARN level for console
    o.fileLevel = o.levels[fileLevel or "warn"] or 4  -- Default to WARN level for file
    o.ringBuffer = {}
    o.maxRingSize = 100  -- Reduced from 1000
    o.diskManager = nil  -- Will be set by startup
    o.basePath = "/storage/logs"  -- Fallback path if no disk manager

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

function Logger:shouldLog(level, source, message, forFile)
    -- Use appropriate level threshold
    local threshold = forFile and self.fileLevel or self.level

    -- Check level threshold
    if self.levels[level] < threshold then
        return false
    end

    -- Check if source is an ignored event
    for _, ignored in ipairs(self.ignoredEvents) do
        if source == ignored or source:match("^" .. ignored:gsub("%.", "%%.")) then
            return false
        end
    end

    -- Check if it's a debug-only event and we're above debug level
    if threshold > self.levels.debug then
        for _, debugEvent in ipairs(self.debugOnlyEvents) do
            if source == debugEvent or source:match("^" .. debugEvent:gsub("%.", "%%.")) then
                return false
            end
        end
    end

    return true
end

function Logger:log(level, source, message, data)
    -- Check if we should log to console (ring buffer)
    local shouldLogConsole = self:shouldLog(level, source, message, false)

    -- Check if we should log to file
    local shouldLogFile = self:shouldLog(level, source, message, true)

    -- If neither console nor file logging is enabled for this level, skip entirely
    if not shouldLogConsole and not shouldLogFile then
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

    -- Add to ring buffer only if console logging is enabled
    if shouldLogConsole then
        table.insert(self.ringBuffer, entry)
        if #self.ringBuffer > self.maxRingSize then
            table.remove(self.ringBuffer, 1)
        end
    end

    -- Write to file only if file logging is enabled
    if shouldLogFile then
        local date = os.date("%Y%m%d")

        -- Try to serialize the full entry, but fall back to simplified version if it fails
        local logLine
        local ok, serialized = pcall(textutils.serialiseJSON, entry)

        if ok then
            logLine = serialized
        else
            -- Serialization failed (likely circular reference in data)
            -- Create a simplified entry without the complex data field
            local simpleEntry = {
                level = entry.level,
                source = entry.source,
                message = entry.message,
                timestamp = entry.timestamp,
                time = entry.time,
                data = type(entry.data) == "table" and "[Complex Object]" or entry.data
            }
            logLine = textutils.serialiseJSON(simpleEntry)
        end

        if self.diskManager then
            -- Use disk manager for automatic failover
            local levelFilename = string.format("app_%s-%s.log", level, date)
            local combinedFilename = string.format("app_all-%s.log", date)

            -- Write to level-specific log
            self.diskManager:appendFile("logs", levelFilename, logLine)

            -- Write to combined log
            self.diskManager:appendFile("logs", combinedFilename, logLine)
        else
            -- Fallback to local filesystem
            local filename = string.format("%s/app_%s-%s.log", self.basePath, level, date)
            local file = fs.open(filename, "a")
            if file then
                file.writeLine(logLine)
                file.close()
            end

            local combinedFilename = string.format("%s/app_all-%s.log", self.basePath, date)
            local combinedFile = fs.open(combinedFilename, "a")
            if combinedFile then
                combinedFile.writeLine(logLine)
                combinedFile.close()
            end
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

    if self.diskManager then
        -- Clean logs on all disks
        for _, disk in ipairs(self.diskManager.disks) do
            local logsPath = fs.combine(disk.mountPath, "logs")
            if fs.exists(logsPath) and fs.isDir(logsPath) then
                local files = fs.list(logsPath)
                for _, filename in ipairs(files) do
                    if filename:match("^app.*%-%d+%.log$") then
                        local path = fs.combine(logsPath, filename)
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
        end
    else
        -- Fallback to local filesystem
        if fs.exists(self.basePath) and fs.isDir(self.basePath) then
            local files = fs.list(self.basePath)
            for _, filename in ipairs(files) do
                if filename:match("^app.*%-%d+%.log$") then
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
    end
end

return Logger