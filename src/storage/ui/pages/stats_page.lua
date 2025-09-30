local StatsPage = {}
StatsPage.__index = StatsPage

function StatsPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    -- Stats data
    o.stats = {
        uptime = 0,
        downtimeEvents = {},
        eventRates = {},
        poolStats = {},
        storageStats = {},
        networkStats = {}
    }

    -- UI state
    o.selectedTab = "overview"
    o.tabs = {"overview", "events", "storage", "network", "pools"}

    o.width, o.height = term.getSize()

    return o
end

function StatsPage:onEnter()
    -- Load stats
    self:loadStats()

    -- Subscribe to updates
    self.eventBus:subscribe("stats%..*", function(event, data)
        self:updateStats(event, data)
    end)

    self:render()
end

function StatsPage:render()
    term.clear()

    -- Header
    self:drawHeader()

    -- Tabs
    self:drawTabs()

    -- Content based on selected tab
    if self.selectedTab == "overview" then
        self:drawOverview()
    elseif self.selectedTab == "events" then
        self:drawEventStats()
    elseif self.selectedTab == "storage" then
        self:drawStorageStats()
    elseif self.selectedTab == "network" then
        self:drawNetworkStats()
    elseif self.selectedTab == "pools" then
        self:drawPoolStats()
    end

    -- Footer
    self:drawFooter()
end

function StatsPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)

    local title = " SYSTEM STATISTICS "
    term.setCursorPos(math.floor((self.width - #title) / 2), 1)
    term.write(title)

    -- Back link
    term.setCursorPos(self.width - 10, 1)
    term.setTextColor(colors.yellow)
    term.write("[B]ack")

    term.setBackgroundColor(colors.black)
end

function StatsPage:drawTabs()
    term.setCursorPos(1, 3)

    for _, tab in ipairs(self.tabs) do
        if tab == self.selectedTab then
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.yellow)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.lightGray)
        end

        term.write(" " .. tab:upper() .. " ")
        term.setBackgroundColor(colors.black)
        term.write(" ")
    end
end

function StatsPage:drawOverview()
    local y = 5

    -- Uptime graph
    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("UPTIME:")
    y = y + 1

    self:drawUptimeGraph(1, y, self.width, 8)
    y = y + 9

    -- Key metrics
    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("KEY METRICS:")
    y = y + 1

    -- Calculate metrics
    local totalEvents = 0
    for _, count in pairs(self.stats.eventRates) do
        totalEvents = totalEvents + count
    end

    local metrics = {
        {"Total Events", totalEvents, colors.cyan},
        {"Events/sec", self:calculateEventRate(), colors.lime},
        {"Active Tasks", self:getActiveTasks(), colors.yellow},
        {"Items Indexed", self:getIndexedItems(), colors.orange},
        {"Storage Used", self:getStorageUsage() .. "%", colors.magenta}
    }

    for _, metric in ipairs(metrics) do
        term.setCursorPos(2, y)
        term.setTextColor(colors.lightGray)
        term.write(metric[1] .. ": ")
        term.setTextColor(metric[3])
        term.write(tostring(metric[2]))
        y = y + 1
    end
end

function StatsPage:drawUptimeGraph(x, y, width, height)
    -- ASCII art uptime graph
    local graphWidth = width - 10
    local graphHeight = height - 2

    -- Load uptime data
    local uptimeData = self:loadUptimeData()

    -- Draw graph border
    for row = 0, graphHeight do
        term.setCursorPos(x, y + row)
        if row == 0 then
            term.setTextColor(colors.gray)
            term.write("100%|")
        elseif row == graphHeight then
            term.write("  0%|")
            term.write(string.rep("-", graphWidth))
        else
            term.write("    |")
        end
    end

    -- Plot uptime data
    if #uptimeData > 0 then
        local dataPoints = math.min(#uptimeData, graphWidth)
        local startIdx = math.max(1, #uptimeData - dataPoints + 1)

        for i = 0, dataPoints - 1 do
            local dataIdx = startIdx + i
            local uptime = uptimeData[dataIdx] or 0
            local barHeight = math.floor(uptime * graphHeight / 100)

            for h = 1, barHeight do
                term.setCursorPos(x + 5 + i, y + graphHeight - h)

                if uptime >= 99 then
                    term.setTextColor(colors.green)
                    term.write("#")
                elseif uptime >= 95 then
                    term.setTextColor(colors.yellow)
                    term.write("=")
                else
                    term.setTextColor(colors.red)
                    term.write("-")
                end
            end
        end
    end

    -- Time labels
    term.setCursorPos(x + 5, y + graphHeight + 1)
    term.setTextColor(colors.gray)
    term.write("24h ago" .. string.rep(" ", graphWidth - 13) .. "Now")
end

function StatsPage:drawEventStats()
    local y = 5

    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("EVENT STATISTICS:")
    y = y + 2

    -- Get top events
    local events = {}
    for eventType, count in pairs(self.stats.eventRates) do
        table.insert(events, {type = eventType, count = count})
    end

    table.sort(events, function(a, b) return a.count > b.count end)

    -- Display top 10
    for i = 1, math.min(10, #events) do
        local event = events[i]

        term.setCursorPos(2, y)
        term.setTextColor(colors.cyan)
        term.write(string.format("%2d. ", i))

        term.setTextColor(colors.white)
        local eventName = event.type
        if #eventName > 30 then
            eventName = eventName:sub(1, 27) .. "..."
        end
        term.write(eventName)

        term.setCursorPos(40, y)
        term.setTextColor(colors.green)
        term.write(tostring(event.count))

        y = y + 1
    end
end

function StatsPage:drawStorageStats()
    local y = 5

    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("STORAGE STATISTICS:")
    y = y + 2

    -- Storage metrics
    local items = self.context.services.storage:getItems()
    local totalItems = 0
    local uniqueItems = #items

    for _, item in ipairs(items) do
        totalItems = totalItems + (item.value.count or 0)
    end

    local storageMap = self.context.storageMap
    local totalSlots = 0
    local usedSlots = 0

    for _, storage in ipairs(storageMap) do
        totalSlots = totalSlots + storage.size
    end

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Total Items: ")
    term.setTextColor(colors.yellow)
    term.write(tostring(totalItems))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Unique Items: ")
    term.setTextColor(colors.cyan)
    term.write(tostring(uniqueItems))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Storage Inventories: ")
    term.setTextColor(colors.lime)
    term.write(tostring(#storageMap))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Total Slots: ")
    term.setTextColor(colors.orange)
    term.write(tostring(totalSlots))
    y = y + 2

    -- Top items by count
    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("TOP ITEMS:")
    y = y + 1

    table.sort(items, function(a, b)
        return (a.value.count or 0) > (b.value.count or 0)
    end)

    for i = 1, math.min(5, #items) do
        local item = items[i]
        term.setCursorPos(2, y)

        term.setTextColor(colors.white)
        local name = item.key:match("([^:]+)$") or item.key
        if #name > 25 then
            name = name:sub(1, 22) .. "..."
        end
        term.write(name)

        term.setCursorPos(30, y)
        term.setTextColor(colors.green)
        term.write("x" .. tostring(item.value.count))

        y = y + 1
    end
end

function StatsPage:drawPoolStats()
    local y = 5

    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("THREAD POOL STATISTICS:")
    y = y + 2

    local pools = self.context.scheduler:getPools()

    for poolName, pool in pairs(pools) do
        term.setCursorPos(2, y)

        -- Pool name
        term.setTextColor(colors.cyan)
        term.write(poolName:upper())

        -- Worker count
        term.setCursorPos(15, y)
        term.setTextColor(colors.lightGray)
        term.write("Workers: ")
        term.setTextColor(colors.white)
        term.write(tostring(pool.size))

        -- Active tasks
        term.setCursorPos(30, y)
        term.setTextColor(colors.lightGray)
        term.write("Active: ")
        term.setTextColor(colors.yellow)
        term.write(tostring(pool.active))

        -- Queued tasks
        term.setCursorPos(45, y)
        term.setTextColor(colors.lightGray)
        term.write("Queue: ")
        term.setTextColor(colors.orange)
        term.write(tostring(#pool.queue))

        y = y + 1
    end
end

function StatsPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setTextColor(colors.gray)
    term.write("Updated: " .. os.date("%H:%M:%S"))
end

function StatsPage:loadStats()
    -- Load uptime data
    local uptimeFile = "/storage/cfg/uptime.json"
    if fs.exists(uptimeFile) then
        local file = fs.open(uptimeFile, "r")
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data then
            self.stats.downtimeEvents = data.downtimes or {}
        end
    end

    -- Load event stats from events bridge
    if self.context.services and self.context.services.events then
        local eventStats = self.context.services.events:getStats()
        self.stats.eventRates = eventStats.topTypes or {}
    end
end

function StatsPage:loadUptimeData()
    -- Generate uptime percentages for last 24 hours
    local data = {}
    local now = os.epoch("utc")
    local hourMs = 60 * 60 * 1000

    for i = 23, 0, -1 do
        local hourStart = now - (i * hourMs)
        local hourEnd = hourStart + hourMs
        local downtime = 0

        -- Check downtime events in this hour
        for _, event in ipairs(self.stats.downtimeEvents) do
            if event.start < hourEnd and event.endTime > hourStart then
                local overlapStart = math.max(event.start, hourStart)
                local overlapEnd = math.min(event.endTime, hourEnd)
                downtime = downtime + (overlapEnd - overlapStart)
            end
        end

        local uptime = 100 * (1 - downtime / hourMs)
        table.insert(data, uptime)
    end

    return data
end

function StatsPage:calculateEventRate()
    -- Calculate events per second
    local recentEvents = self.context.eventBus:getRecentEvents(100)
    if #recentEvents < 2 then
        return 0
    end

    local duration = (recentEvents[#recentEvents].timestamp - recentEvents[1].timestamp) / 1000
    if duration <= 0 then
        return 0
    end

    return string.format("%.1f", #recentEvents / duration)
end

function StatsPage:getActiveTasks()
    local active = 0
    local pools = self.context.scheduler:getPools()

    for _, pool in pairs(pools) do
        active = active + pool.active
    end

    return active
end

function StatsPage:getIndexedItems()
    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()
        return #items
    end
    return 0
end

function StatsPage:getStorageUsage()
    -- Calculate storage utilization percentage
    local totalSlots = 0
    local usedSlots = 0

    for _, storage in ipairs(self.context.storageMap) do
        totalSlots = totalSlots + storage.size

        local inv = peripheral.wrap(storage.name)
        if inv then
            local items = inv.list()
            for _ in pairs(items) do
                usedSlots = usedSlots + 1
            end
        end
    end

    if totalSlots == 0 then
        return 0
    end

    return math.floor(100 * usedSlots / totalSlots)
end

function StatsPage:handleInput(event, key)
    if event == "key" then
        if key == keys.b then
            -- Go back to console
            self.context.viewFactory:switchTo("console")
        elseif key >= keys.one and key <= keys.five then
            -- Switch tabs with number keys
            local tabIndex = key - keys.one + 1
            if self.tabs[tabIndex] then
                self.selectedTab = self.tabs[tabIndex]
                self:render()
            end
        end
    end
end

return StatsPage