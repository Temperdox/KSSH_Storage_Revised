-- Lightweight logging system for turtle
local LogPrint = {}

-- Configuration
local LOG_DIR = "logs"
local MAX_QUEUE_SIZE = 500  -- Smaller for turtle
local WRITE_INTERVAL = 1    -- Write more frequently
local MAX_BATCH_SIZE = 50
local ROTATE_SIZE = 250000  -- 250KB - smaller for turtle
local MAX_LOG_FILES = 5     -- Keep fewer logs on turtle

-- State
local initialized = false
local queue = {}
local currentLogFile = nil
local currentLogPath = nil
local consoleCallback = nil  -- UI console callback
local enableConsole = false  -- Disable console by default
local originalPrint = _G.print  -- Store original print

-- Generate log filename with timestamp
local function getLogFilename()
    local time = os.date("*t")
    return string.format("%s/turtle_%04d%02d%02d_%02d%02d%02d.log",
            LOG_DIR, time.year, time.month, time.day, time.hour, time.min, time.sec)
end

-- Format log entry with timestamp
local function formatLogEntry(...)
    local args = {...}
    local message = ""
    for i, v in ipairs(args) do
        if i > 1 then message = message .. " " end
        message = message .. tostring(v)
    end

    local timestamp = os.date("%H:%M:%S")  -- Shorter timestamp for turtle
    return string.format("[%s] %s", timestamp, message)
end

-- Check and rotate log file if needed
local function checkRotation()
    if currentLogPath and fs.exists(currentLogPath) then
        local size = fs.getSize(currentLogPath)
        if size > ROTATE_SIZE then
            if currentLogFile then
                currentLogFile.close()
                currentLogFile = nil
            end

            currentLogPath = getLogFilename()
            cleanOldLogs()
        end
    end
end

-- Clean up old log files
local function cleanOldLogs()
    if not fs.exists(LOG_DIR) then return end

    local files = fs.list(LOG_DIR)
    local logFiles = {}

    for _, file in ipairs(files) do
        if file:match("^turtle_.*%.log$") then
            local path = fs.combine(LOG_DIR, file)
            table.insert(logFiles, {
                path = path,
                name = file
            })
        end
    end

    -- Sort by filename (which includes timestamp)
    table.sort(logFiles, function(a, b) return a.name > b.name end)

    -- Delete old files beyond MAX_LOG_FILES
    for i = MAX_LOG_FILES + 1, #logFiles do
        fs.delete(logFiles[i].path)
    end
end

-- Write batch of messages to file
local function writeBatch()
    if #queue == 0 then return end

    checkRotation()

    if not currentLogFile then
        currentLogFile = fs.open(currentLogPath, "a")
        if not currentLogFile then
            -- Can't open file, discard messages
            for i = 1, math.min(#queue, MAX_BATCH_SIZE) do
                table.remove(queue, 1)
            end
            return
        end
    end

    local written = 0
    while #queue > 0 and written < MAX_BATCH_SIZE do
        local entry = table.remove(queue, 1)
        currentLogFile.writeLine(entry)
        written = written + 1
    end

    currentLogFile.flush()
end

-- Initialize logging system
function LogPrint.init(uiConsoleCallback)
    if initialized then return end

    -- Create log directory
    if not fs.exists(LOG_DIR) then
        fs.makeDir(LOG_DIR)
    end

    -- Set initial log file
    currentLogPath = getLogFilename()

    -- Store console callback if provided
    consoleCallback = uiConsoleCallback

    initialized = true

    LogPrint.info("Turtle logging system initialized")
    LogPrint.debug("Log file:", currentLogPath)
    LogPrint.debug("Turtle ID:", os.getComputerID())
    LogPrint.debug("Label:", os.getComputerLabel() or "unlabeled")
end

-- Start the writer task (to be called after executor is available)
function LogPrint.startWriter(executor)
    if executor then
        executor:submitRecurring(writeBatch, WRITE_INTERVAL, "log_writer", 2)
        LogPrint.debug("Log writer task submitted to executor")
    else
        -- Fallback: create a simple coroutine
        LogPrint.warn("No executor, using fallback writer")
        local function fallbackWriter()
            while true do
                writeBatch()
                sleep(WRITE_INTERVAL)
            end
        end
        return fallbackWriter
    end
end

-- Set UI console callback
function LogPrint.setConsoleCallback(callback)
    consoleCallback = callback
end

-- Enable/disable terminal console (for debugging)
function LogPrint.setConsoleEnabled(enabled)
    enableConsole = enabled
end

-- Main print function
function LogPrint.print(...)
    -- Convert all arguments to strings properly
    local args = {...}
    local stringArgs = {}
    for i, v in ipairs(args) do
        stringArgs[i] = tostring(v)
    end

    -- Send to UI console if callback is set
    if consoleCallback then
        -- Pass the concatenated message to UI
        local message = table.concat(stringArgs, " ")
        consoleCallback(message)
    elseif enableConsole then
        -- Only print to terminal if explicitly enabled and no UI
        originalPrint(...)
    end

    -- Queue for file writing
    if initialized then
        local entry = formatLogEntry(...)

        if #queue < MAX_QUEUE_SIZE then
            table.insert(queue, entry)
        else
            -- Queue overflow - try to write immediately
            if currentLogFile then
                currentLogFile.writeLine(entry)
                currentLogFile.flush()
            end
        end
    end
end

-- Log levels
function LogPrint.info(...)
    LogPrint.print("[INFO]", ...)
end

function LogPrint.warn(...)
    LogPrint.print("[WARN]", ...)
end

function LogPrint.error(...)
    LogPrint.print("[ERROR]", ...)
end

function LogPrint.debug(...)
    LogPrint.print("[DEBUG]", ...)
end

-- Get queue size
function LogPrint.getQueueSize()
    return #queue
end

-- Force flush
function LogPrint.flush()
    while #queue > 0 do
        writeBatch()
    end
    if currentLogFile then
        currentLogFile.flush()
    end
end

-- Close log file
function LogPrint.close()
    LogPrint.flush()
    if currentLogFile then
        currentLogFile.close()
        currentLogFile = nil
    end
end

-- Make callable like print
setmetatable(LogPrint, {
    __call = function(_, ...)
        LogPrint.print(...)
    end
})

return LogPrint