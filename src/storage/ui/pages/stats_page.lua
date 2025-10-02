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

    -- Clickable regions
    o.backLink = {}
    o.tabRegions = {}

    -- Modal state
    o.showModal = false
    o.selectedPool = nil

    -- Uptime graph state
    o.uptimeData = {}
    o.uptimeGraphRegion = {}
    o.hoveredUptimeIndex = nil

    -- Render state
    o.needsFullRedraw = true

    return o
end

function StatsPage:onEnter()
    -- Load stats
    self:loadStats()

    -- Subscribe to updates
    self.eventBus:subscribe("stats%..*", function(event, data)
        self:updateStats(event, data)
    end)

    self.needsFullRedraw = true
    self:render()
end

function StatsPage:onLeave()
    -- Clean up
end

function StatsPage:render()
    -- Only clear screen on full redraw
    if self.needsFullRedraw then
        term.clear()
        self.needsFullRedraw = false
    end

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

    -- Modal (draw on top)
    if self.showModal and self.selectedPool then
        self:drawPoolModal()
    end
end

function StatsPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)

    -- Title on the left
    term.setCursorPos(2, 1)
    term.write("SYSTEM STATISTICS")

    -- Back link on the right
    local x = self.width - 6
    term.setCursorPos(x, 1)
    term.setTextColor(colors.yellow)
    term.write("Back")
    self.backLink = {x1 = x, x2 = x + 3, y = 1}

    term.setBackgroundColor(colors.black)
end

function StatsPage:drawTabs()
    term.setCursorPos(1, 3)
    self.tabRegions = {}

    local x = 1
    for i, tab in ipairs(self.tabs) do
        if tab == self.selectedTab then
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.yellow)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.lightGray)
        end

        local tabText = " " .. tab:upper() .. " "
        term.setCursorPos(x, 3)
        term.write(tabText)

        -- Store clickable region
        self.tabRegions[i] = {
            x1 = x,
            x2 = x + #tabText - 1,
            y = 3,
            tab = tab
        }

        x = x + #tabText

        term.setBackgroundColor(colors.black)
        term.write(" ")
        x = x + 1
    end
end

function StatsPage:drawOverview()
    local y = 5

    -- Uptime graph
    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("UPTIME:")

    -- Show hovered uptime value
    if self.hoveredUptimeIndex and self.uptimeData[self.hoveredUptimeIndex] then
        term.write(" ")
        term.setTextColor(colors.yellow)
        term.write(string.format("%.1f%%", self.uptimeData[self.hoveredUptimeIndex]))
    end

    y = y + 1

    self:drawUptimeGraph(1, y, self.width, 8)
    y = y + 9

    -- Key metrics
    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("KEY METRICS:")
    y = y + 1

    -- FIXED: Calculate total events properly
    local totalEvents = 0
    if type(self.stats.eventRates) == "table" then
        for _, eventData in pairs(self.stats.eventRates) do
            -- Check if eventData is a number or a table with count field
            if type(eventData) == "number" then
                totalEvents = totalEvents + eventData
            elseif type(eventData) == "table" and eventData.count then
                totalEvents = totalEvents + eventData.count
            end
        end
    end

    local metrics = {
        {"Total Events", totalEvents, colors.cyan},
        {"Events/sec", self:calculateEventRate(), colors.lime},
        {"Active Tasks", self:getActiveTasks(), colors.yellow},
        {"Items Indexed", self:getIndexedItems(), colors.orange},
        {"Storage Used", self:getStorageUsage() .. "%", colors.magenta}
    }

    -- Split metrics into two columns with evenly split rows
    local columnWidth = math.floor(self.width / 2)
    local leftColumnItems = math.ceil(#metrics / 2)  -- Favor left column

    -- Draw metrics in two columns
    local maxRows = leftColumnItems
    for row = 1, maxRows do
        local leftIdx = row
        local rightIdx = row + leftColumnItems

        -- Left column
        if metrics[leftIdx] then
            term.setCursorPos(2, y + row - 1)
            term.setTextColor(colors.lightGray)
            term.write(metrics[leftIdx][1] .. ": ")
            term.setTextColor(metrics[leftIdx][3])
            term.write(tostring(metrics[leftIdx][2]))
        end

        -- Right column
        if metrics[rightIdx] then
            term.setCursorPos(columnWidth + 2, y + row - 1)
            term.setTextColor(colors.lightGray)
            term.write(metrics[rightIdx][1] .. ": ")
            term.setTextColor(metrics[rightIdx][3])
            term.write(tostring(metrics[rightIdx][2]))
        end
    end
end

function StatsPage:drawUptimeGraph(x, y, width, height)
    -- ASCII art uptime graph
    local graphWidth = width - 10
    local graphHeight = height - 2

    -- Load uptime data
    self.uptimeData = self:loadUptimeData()

    -- Store graph region for hover detection
    self.uptimeGraphRegion = {
        x = x + 5,
        y = y,
        width = graphWidth,
        height = graphHeight
    }

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
    if #self.uptimeData > 0 then
        local dataPoints = math.min(#self.uptimeData, graphWidth)
        local startIdx = math.max(1, #self.uptimeData - dataPoints + 1)

        -- Draw columns from left to right (oldest to newest)
        -- But we want newest data on the RIGHT
        for i = 0, dataPoints - 1 do
            local dataIdx = startIdx + i
            local uptime = self.uptimeData[dataIdx] or 0
            local downtime = 100 - uptime

            -- Calculate bar heights
            local uptimeBarHeight = math.floor(uptime * graphHeight / 100)
            local downtimeBarHeight = math.floor(downtime * graphHeight / 100)

            -- Draw from bottom up: uptime (green) from bottom
            for h = 0, uptimeBarHeight - 1 do
                term.setCursorPos(x + 5 + i, y + graphHeight - h - 1)
                term.setTextColor(colors.green)
                term.write("#")
            end

            -- Draw downtime (red) stacked on top
            for h = 0, downtimeBarHeight - 1 do
                term.setCursorPos(x + 5 + i, y + graphHeight - uptimeBarHeight - h - 1)
                term.setTextColor(colors.red)
                term.write("#")
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

    -- Get top events (FIXED: Handle both formats)
    local events = {}

    if type(self.stats.eventRates) == "table" then
        for eventType, eventData in pairs(self.stats.eventRates) do
            local count = 0
            if type(eventData) == "number" then
                count = eventData
            elseif type(eventData) == "table" and eventData.count then
                count = eventData.count
            end

            table.insert(events, {type = eventType, count = count})
        end
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

function StatsPage:drawNetworkStats()
    local y = 5

    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("NETWORK STATISTICS:")
    y = y + 2

    -- Get network stats from NetPage
    local netStats = nil
    if self.context.router and self.context.router.pages and self.context.router.pages.net then
        netStats = self.context.router.pages.net:getNetworkStats()
    end

    if not netStats or netStats.totalConnections == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.lightGray)
        term.write("No network connections")
        return
    end

    -- Summary metrics
    term.setCursorPos(1, y)
    term.setTextColor(colors.cyan)
    term.write("== SUMMARY ==")
    y = y + 1

    -- Count online/offline
    local onlineCount = 0
    local offlineCount = 0
    for _, conn in ipairs(netStats.connections) do
        if conn.online then
            onlineCount = onlineCount + 1
        else
            offlineCount = offlineCount + 1
        end
    end

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Connections: ")
    term.setTextColor(colors.yellow)
    term.write(tostring(netStats.totalConnections))
    term.setTextColor(colors.lightGray)
    term.write(" (")
    term.setTextColor(colors.lime)
    term.write(tostring(onlineCount))
    term.setTextColor(colors.lightGray)
    term.write(" online, ")
    term.setTextColor(colors.red)
    term.write(tostring(offlineCount))
    term.setTextColor(colors.lightGray)
    term.write(" offline)")
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Packets Sent: ")
    term.setTextColor(colors.lime)
    term.write(tostring(netStats.totalPacketsSent))
    term.setCursorPos(30, y)
    term.setTextColor(colors.lightGray)
    term.write("Received: ")
    term.setTextColor(colors.lime)
    term.write(tostring(netStats.totalPacketsReceived))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Data Sent: ")
    term.setTextColor(colors.orange)
    term.write(netStats.totalBytesSent)
    term.setCursorPos(30, y)
    term.setTextColor(colors.lightGray)
    term.write("Received: ")
    term.setTextColor(colors.orange)
    term.write(netStats.totalBytesReceived)
    y = y + 1

    if netStats.averagePing then
        term.setCursorPos(2, y)
        term.setTextColor(colors.lightGray)
        term.write("Average Ping: ")
        term.setTextColor(colors.cyan)
        term.write(string.format("%dms", netStats.averagePing))
        y = y + 1
    end

    y = y + 1

    -- Connections list
    if #netStats.connections > 0 then
        term.setCursorPos(1, y)
        term.setTextColor(colors.cyan)
        term.write("== CONNECTIONS ==")
        y = y + 1

        -- Table header
        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
        term.clearLine()

        term.setCursorPos(2, y)
        term.write("NAME")
        term.setCursorPos(15, y)
        term.write("PACKETS")
        term.setCursorPos(28, y)
        term.write("DATA")
        term.setCursorPos(40, y)
        term.write("PING")
        y = y + 1

        -- Connections
        for i, conn in ipairs(netStats.connections) do
            if i % 2 == 0 then
                term.setBackgroundColor(colors.gray)
            else
                term.setBackgroundColor(colors.black)
            end

            term.setCursorPos(1, y)
            term.clearLine()

            -- Name with online status color
            term.setCursorPos(2, y)
            if conn.online then
                term.setTextColor(colors.lime)
            else
                term.setTextColor(colors.red)
            end
            local name = conn.name
            if #name > 10 then
                name = name:sub(1, 7) .. "..."
            end
            term.write(name)

            -- Packets (sent/received)
            term.setCursorPos(15, y)
            term.setTextColor(colors.lime)
            term.write(string.format("%d/%d", conn.packetsSent, conn.packetsReceived))

            -- Data
            term.setCursorPos(28, y)
            term.setTextColor(colors.orange)
            term.write(conn.dataFormatted)

            -- Ping
            if conn.ping then
                term.setCursorPos(40, y)
                term.setTextColor(colors.cyan)
                term.write(string.format("%dms", conn.ping))
            end

            y = y + 1

            -- Stop if we run out of space
            if y >= self.height - 2 then
                break
            end
        end

        term.setBackgroundColor(colors.black)
    end
end

function StatsPage:drawPoolStats()
    local y = 5

    term.setCursorPos(1, y)
    term.setTextColor(colors.white)
    term.write("THREAD POOL STATISTICS:")
    y = y + 2

    -- Draw table header with white background and black text
    term.setCursorPos(1, y)
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
    term.clearLine()

    term.setCursorPos(2, y)
    term.write("POOL NAME")
    term.setCursorPos(20, y)
    term.write("WORKERS")
    term.setCursorPos(32, y)
    term.write("ACTIVE")
    term.setCursorPos(43, y)
    term.write("QUEUE")
    y = y + 1

    -- Draw pools as table rows with alternating colors
    local pools = self.context.scheduler:getPools()
    self.poolRegions = {}

    local poolList = {}
    for name, pool in pairs(pools) do
        table.insert(poolList, {name = name, pool = pool})
    end
    table.sort(poolList, function(a, b) return a.name < b.name end)

    for i, poolData in ipairs(poolList) do
        local poolName = poolData.name
        local pool = poolData.pool

        -- Store clickable region
        table.insert(self.poolRegions, {
            x1 = 1,
            x2 = self.width,
            y = y,
            poolName = poolName,
            pool = pool
        })

        -- Alternating row colors
        if i % 2 == 0 then
            term.setBackgroundColor(colors.gray)
        else
            term.setBackgroundColor(colors.black)
        end

        term.setCursorPos(1, y)
        term.clearLine()

        -- Pool name
        term.setCursorPos(2, y)
        term.setTextColor(colors.cyan)
        term.write(poolName:upper())

        -- Workers
        term.setCursorPos(20, y)
        term.setTextColor(colors.white)
        term.write(tostring(pool.size))

        -- Active
        term.setCursorPos(32, y)
        term.setTextColor(colors.yellow)
        term.write(tostring(pool.active or 0))

        -- Queue
        term.setCursorPos(43, y)
        term.setTextColor(colors.orange)
        term.write(tostring(#pool.queue))

        y = y + 1
    end

    -- Reset background color
    term.setBackgroundColor(colors.black)

    -- Instructions
    y = y + 1
    term.setCursorPos(2, y)
    term.setTextColor(colors.gray)
    term.write("(Click on a pool to view details)")
end

function StatsPage:drawPoolModal()
    local pool = self.selectedPool.pool
    local poolName = self.selectedPool.poolName

    -- Modal dimensions (centered)
    local modalWidth = math.min(45, self.width - 4)
    local modalHeight = 15
    local modalX = math.floor((self.width - modalWidth) / 2)
    local modalY = math.floor((self.height - modalHeight) / 2)

    -- Draw shadow
    for y = modalY + 1, modalY + modalHeight do
        term.setCursorPos(modalX + 1, y)
        term.setBackgroundColor(colors.gray)
        term.write(string.rep(" ", modalWidth))
    end

    -- Draw modal background
    for y = modalY, modalY + modalHeight - 1 do
        term.setCursorPos(modalX, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.write(string.rep(" ", modalWidth))
    end

    -- Draw border
    term.setCursorPos(modalX, modalY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" " .. poolName:upper() .. " POOL DETAILS " .. string.rep(" ", modalWidth - #poolName - 15))

    -- Draw close button (red square with white X) in top right
    local closeX = modalX + modalWidth - 3
    term.setCursorPos(closeX, modalY)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" X ")

    -- Store close button region for click detection
    self.modalCloseBtn = {x1 = closeX, x2 = closeX + 2, y = modalY}

    -- Pool stats
    local y = modalY + 2
    local contentX = modalX + 2

    term.setCursorPos(contentX, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("Pool Name:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.cyan)
    term.write(poolName:upper())
    y = y + 1

    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Worker Threads:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.white)
    term.write(tostring(pool.size))
    y = y + 1

    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Active Workers:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.yellow)
    term.write(tostring(pool.active or 0))
    y = y + 1

    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Queued Tasks:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.orange)
    term.write(tostring(#pool.queue))
    y = y + 2

    -- Additional stats
    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Completed Tasks:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.green)
    term.write(tostring(pool.completed or 0))
    y = y + 1

    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Failed Tasks:")
    term.setCursorPos(contentX + 20, y)
    term.setTextColor(colors.red)
    term.write(tostring(pool.failed or 0))
    y = y + 1

    term.setCursorPos(contentX, y)
    term.setTextColor(colors.lightGray)
    term.write("Utilization:")
    term.setCursorPos(contentX + 20, y)
    local utilization = pool.size > 0 and math.floor((pool.active or 0) / pool.size * 100) or 0
    term.setTextColor(colors.lime)
    term.write(tostring(utilization) .. "%")
    y = y + 2

    -- Close instruction
    term.setCursorPos(modalX + 2, modalY + modalHeight - 2)
    term.setTextColor(colors.gray)
    term.write("Press ESC or click outside to close")

    term.setBackgroundColor(colors.black)
end

function StatsPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setTextColor(colors.gray)
    term.write("Updated: " .. os.date("%H:%M:%S"))
end

function StatsPage:loadStats()
    -- Load uptime data
    local uptimeFile = "/cfg/uptime.json"
    if fs.exists(uptimeFile) then
        local file = fs.open(uptimeFile, "r")
        if file then
            local content = file.readAll()
            file.close()

            local ok, data = pcall(textutils.unserialiseJSON, content)
            if ok and data then
                self.stats.downtimeEvents = data.downtimes or {}
            end
        end
    end

    -- Load event stats from events bridge
    if self.context.services and self.context.services.events then
        local eventStats = self.context.services.events:getStats()
        -- The stats might come in different formats, handle both
        if eventStats then
            if eventStats.topTypes then
                self.stats.eventRates = {}
                for _, typeData in ipairs(eventStats.topTypes) do
                    self.stats.eventRates[typeData.type] = typeData.count
                end
            elseif eventStats.byType then
                self.stats.eventRates = eventStats.byType
            end
        end
    end
end

function StatsPage:updateStats(event, data)
    -- Update stats based on event
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

function StatsPage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1

        -- Close modal on ESC
        if key == keys.escape and self.showModal then
            self.showModal = false
            self.selectedPool = nil
            self.needsFullRedraw = true
            self:render()
            return
        end

        -- Tab switching with number keys only
        if key >= keys.one and key <= keys.five then
            local tabIndex = key - keys.one + 1
            if self.tabs[tabIndex] then
                self.selectedTab = self.tabs[tabIndex]
                self.needsFullRedraw = true
                self:render()
            end
        end
    elseif event == "mouse_click" then
        -- param1 = button, param2 = x, param3 = y
        self:handleClick(param2, param3)
    elseif event == "mouse_move" or event == "mouse_drag" then
        -- param1 = x, param2 = y
        self:handleMouseMove(param1, param2)
    end
end

function StatsPage:handleMouseMove(x, y)
    -- Only track hover on overview tab
    if self.selectedTab ~= "overview" then
        return
    end

    -- Check if mouse is over uptime graph
    if self.uptimeGraphRegion and self.uptimeGraphRegion.width > 0 then
        local gx = self.uptimeGraphRegion.x
        local gy = self.uptimeGraphRegion.y
        local gw = self.uptimeGraphRegion.width
        local gh = self.uptimeGraphRegion.height

        if x >= gx and x < gx + gw and y >= gy and y < gy + gh then
            -- Calculate which data point is being hovered
            local columnIndex = x - gx + 1
            local dataPoints = math.min(#self.uptimeData, gw)
            local startIdx = math.max(1, #self.uptimeData - dataPoints + 1)
            local hoveredIdx = startIdx + columnIndex - 1

            if hoveredIdx ~= self.hoveredUptimeIndex and hoveredIdx <= #self.uptimeData then
                self.hoveredUptimeIndex = hoveredIdx
                self:render()
            end
        else
            -- Mouse left graph area
            if self.hoveredUptimeIndex then
                self.hoveredUptimeIndex = nil
                self:render()
            end
        end
    end
end

function StatsPage:handleClick(x, y)
    -- If modal is open, check for close button or outside click
    if self.showModal then
        -- Check close button click
        if self.modalCloseBtn and y == self.modalCloseBtn.y and
           x >= self.modalCloseBtn.x1 and x <= self.modalCloseBtn.x2 then
            self.showModal = false
            self.selectedPool = nil
            self.needsFullRedraw = true
            self:render()
            return
        end

        local modalWidth = math.min(45, self.width - 4)
        local modalHeight = 15
        local modalX = math.floor((self.width - modalWidth) / 2)
        local modalY = math.floor((self.height - modalHeight) / 2)

        -- Click outside modal closes it
        if x < modalX or x > modalX + modalWidth - 1 or y < modalY or y > modalY + modalHeight - 1 then
            self.showModal = false
            self.selectedPool = nil
            self.needsFullRedraw = true
            self:render()
            return
        end
        -- Click inside modal does nothing (modal stays open)
        return
    end

    -- Check back link
    if y == self.backLink.y and x >= self.backLink.x1 and x <= self.backLink.x2 then
        self.context.router:navigate("console")
        return
    end

    -- Check tab clicks
    for i, region in ipairs(self.tabRegions) do
        if y == region.y and x >= region.x1 and x <= region.x2 then
            self.selectedTab = region.tab
            self.needsFullRedraw = true
            self:render()
            return
        end
    end

    -- Check pool region clicks (only on pools tab)
    if self.selectedTab == "pools" and self.poolRegions then
        for _, region in ipairs(self.poolRegions) do
            if y == region.y and x >= region.x1 and x <= region.x2 then
                self.selectedPool = region
                self.showModal = true
                self:render()
                return
            end
        end
    end
end

return StatsPage