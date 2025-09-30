-- modules/logger.lua
-- Logger with file and console output

local Logger = {}
Logger.__index = Logger

-- Log levels
Logger.LEVELS = {
    DEBUG = {level = 1, color = colors.gray, name = "DEBUG"},
    INFO = {level = 2, color = colors.white, name = "INFO"},
    SUCCESS = {level = 3, color = colors.green, name = "OK"},
    WARNING = {level = 4, color = colors.yellow, name = "WARN"},
    ERROR = {level = 5, color = colors.red, name = "ERROR"},
    CRITICAL = {level = 6, color = colors.purple, name = "CRIT"}
}

function Logger:new(filepath)
    local self = setmetatable({}, Logger)
    self.filepath = filepath
    self.minLevel = Logger.LEVELS.INFO
    self.listeners = {}
    self.buffer = {}
    self.maxBufferSize = 100

    -- Ensure log directory exists
    local dir = fs.getDir(filepath)
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    return self
end

function Logger:addListener(callback)
    table.insert(self.listeners, callback)
end

function Logger:removeListener(callback)
    for i, listener in ipairs(self.listeners) do
        if listener == callback then
            table.remove(self.listeners, i)
            break
        end
    end
end

function Logger:setLevel(level)
    self.minLevel = level
end

function Logger:log(level, message, thread)
    if level.level < self.minLevel.level then
        return
    end

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local threadPrefix = thread and ("["..thread.."] ") or ""
    local logEntry = {
        timestamp = timestamp,
        level = level,
        message = threadPrefix .. message,
        thread = thread,
        raw = message
    }

    -- Add to buffer
    table.insert(self.buffer, logEntry)
    if #self.buffer > self.maxBufferSize then
        table.remove(self.buffer, 1)
    end

    -- Write to file
    local file = fs.open(self.filepath, "a")
    if file then
        file.writeLine(string.format("[%s] [%s] %s",
                timestamp, level.name, logEntry.message))
        file.close()
    end

    -- Notify listeners
    for _, listener in ipairs(self.listeners) do
        listener(logEntry)
    end
end

-- Convenience methods
function Logger:debug(message, thread)
    self:log(Logger.LEVELS.DEBUG, message, thread)
end

function Logger:info(message, thread)
    self:log(Logger.LEVELS.INFO, message, thread)
end

function Logger:success(message, thread)
    self:log(Logger.LEVELS.SUCCESS, message, thread)
end

function Logger:warning(message, thread)
    self:log(Logger.LEVELS.WARNING, message, thread)
end

function Logger:error(message, thread)
    self:log(Logger.LEVELS.ERROR, message, thread)
end

function Logger:critical(message, thread)
    self:log(Logger.LEVELS.CRITICAL, message, thread)
end

function Logger:getBuffer()
    return self.buffer
end

return Logger