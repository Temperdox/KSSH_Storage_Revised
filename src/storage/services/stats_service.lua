local StatsService = {}
StatsService.__index = StatsService

function StatsService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    o.uptimeFile = "/storage/cfg/uptime.json"
    o.statsFile = "/storage/data/stats.json"

    o.stats = {
        startTime = os.epoch("utc"),
        lastCheck = os.epoch("utc"),
        downtimes = {},
        eventCounts = {},
        performance = {
            tasksCompleted = 0,
            tasksFailed = 0,
            averageTaskTime = 0
        }
    }

    return o
end

function StatsService:start()
    -- Load existing stats
    self:loadStats()

    -- Subscribe to minute ticks
    self.eventBus:subscribe("stats.minuteTick", function()
        self:recordUptime()
    end)

    -- Subscribe to task events
    self.eventBus:subscribe("task%..*", function(event, data)
        self:updateTaskStats(event, data)
    end)

    -- Start uptime checker
    self.context.scheduler:submit("stats", function()
        self:uptimeLoop()
    end)

    self.logger:info("StatsService", "Service started")
end

function StatsService:uptimeLoop()
    while true do
        self:recordUptime()
        os.sleep(60)  -- Check every minute
    end
end

function StatsService:recordUptime()
    local now = os.epoch("utc")

    -- Load uptime data
    local data = {}
    if fs.exists(self.uptimeFile) then
        local file = fs.open(self.uptimeFile, "r")
        local content = file.readAll()
        file.close()

        local ok, loaded = pcall(textutils.unserialiseJSON, content)
        if ok and loaded then
            data = loaded
        end
    end

    -- Check for downtime
    if data.lastCheck then
        local gap = now - data.lastCheck
        if gap > 120000 then  -- More than 2 minutes
            table.insert(data.downtimes, {
                start = data.lastCheck,
                endTime = now,
                duration = gap
            })

            -- Keep only last 30 days
            local cutoff = now - (30 * 24 * 60 * 60 * 1000)
            local filtered = {}
            for _, downtime in ipairs(data.downtimes or {}) do
                if downtime.endTime > cutoff then
                    table.insert(filtered, downtime)
                end
            end
            data.downtimes = filtered
        end
    end

    -- Update last check
    data.lastCheck = now

    -- Calculate uptime percentage
    local totalTime = now - (data.startTime or now)
    local downTime = 0
    for _, dt in ipairs(data.downtimes or {}) do
        downTime = downTime + dt.duration
    end

    data.uptimePercent = 100 * (1 - downTime / totalTime)

    -- Save
    local file = fs.open(self.uptimeFile, "w")
    if file then
        local ok, json = pcall(textutils.serialiseJSON, data)

        if ok then
            file.write(json)
        else
            file.write(string.format("[ERROR] Failed to serialize uptime data: %s", tostring(json)))
        end
        file.close()
    end
end

function StatsService:updateTaskStats(event, data)
    if event == "task.end" then
        self.stats.performance.tasksCompleted = self.stats.performance.tasksCompleted + 1
    elseif event == "task.error" then
        self.stats.performance.tasksFailed = self.stats.performance.tasksFailed + 1
    end
end

function StatsService:loadStats()
    if fs.exists(self.statsFile) then
        local file = fs.open(self.statsFile, "r")
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data then
            self.stats = data
        end
    end
end

function StatsService:saveStats()
    local file = fs.open(self.statsFile, "w")
    if file then
        local ok, json = pcall(textutils.serialiseJSON, self.stats)

        if ok then
            file.write(json)
        else
            file.write(string.format("[ERROR] Failed to serialize stats: %s", tostring(json)))
        end
        file.close()
    end
end

function StatsService:stop()
    self:saveStats()
    self.logger:info("StatsService", "Service stopped")
end

function StatsService:getStats()
    return self.stats
end

return StatsService