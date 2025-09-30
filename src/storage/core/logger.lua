local Logger = {}
Logger.__index = Logger

function Logger:new(eventBus, level)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.levels = {trace = 1, debug = 2, info = 3, warn = 4, error = 5}
    o.level = o.levels[level] or 3
    o.ringBuffer = {}
    o.maxRingSize = 1000
    o.basePath = "/storage/logs"
    return o
end

function Logger:log(level, source, message, data)
    if self.levels[level] < self.level then
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

    -- Write to file
    local date = os.date("%Y%m%d")
    local filename = string.format("%s/app-%s.log", self.basePath, date)
    local file = fs.open(filename, "a")
    if file then
        file.writeLine(textutils.serialiseJSON(entry))
        file.close()
    end

    -- Console output with colors
    local levelColors = {
        trace = colors.gray,
        debug = colors.lightGray,
        info = colors.white,
        warn = colors.yellow,
        error = colors.red
    }

    term.setTextColor(levelColors[level] or colors.white)
    print(string.format("[%s] %s: %s", entry.time, source, message))
    term.setTextColor(colors.white)

    -- Publish to event bus
    self.eventBus:publish("log." .. level, entry)
end

function Logger:trace(source, message, data) self:log("trace", source, message, data) end
function Logger:debug(source, message, data) self:log("debug", source, message, data) end
function Logger:info(source, message, data) self:log("info", source, message, data) end
function Logger:warn(source, message, data) self:log("warn", source, message, data) end
function Logger:error(source, message, data) self:log("error", source, message, data) end

function Logger:flush()
    -- Ensure all logs are written
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

return Logger