local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")
local UptimeGraph = require("ui.components.uptime_graph")
local DataTable = require("ui.components.data_table")

local StatsPage = setmetatable({}, {__index = BasePage})
StatsPage.__index = StatsPage

function StatsPage:new(context)
    local o = BasePage.new(self, context, "stats")
    o:setTitle("SYSTEM STATISTICS")

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
    o.tabButtons = {}

    -- Modal state
    o.showModal = false
    o.selectedPool = nil
    o.poolModal = nil

    -- Uptime graph
    o.uptimeGraph = nil
    o.uptimeData = {}

    return o
end

function StatsPage:onEnter()
    -- Load stats
    self:loadStats()

    -- Subscribe to updates
    self.eventBus:subscribe("stats%..*", function(event, data)
        self:updateStats(event, data)
    end)

    self:buildUI()
    self:render()
end

function StatsPage:buildUI()
    self.content:removeAll()

    -- Tabs row
    self:buildTabs()

    -- Content based on selected tab
    if self.selectedTab == "overview" then
        self:buildOverview()
    elseif self.selectedTab == "events" then
        self:buildEventStats()
    elseif self.selectedTab == "storage" then
        self:buildStorageStats()
    elseif self.selectedTab == "network" then
        self:buildNetworkStats()
    elseif self.selectedTab == "pools" then
        self:buildPoolStats()
    end

    self:setFooter("Updated: " .. os.date("%H:%M:%S") .. " | Use 1-5 keys to switch tabs")
end

function StatsPage:buildTabs()
    local tabPanel = UI.panel(1, 1, self.width, 1)
        :bg(colors.black)

    local tabLayout = UI.flexLayout("row", "start", "center"):setGap(1)
    tabPanel:setLayout(tabLayout)

    self.tabButtons = {}

    for i, tab in ipairs(self.tabs) do
        local tabText = " " .. tab:upper() .. " "
        local tabBtn = UI.label(tabText, 0, 0)
            :bg(tab == self.selectedTab and colors.gray or colors.black)
            :fg(tab == self.selectedTab and colors.yellow or colors.lightGray)
            :onClick(function()
                self.selectedTab = tab
                self:buildUI()
                self:render()
            end)

        table.insert(self.tabButtons, tabBtn)
        tabPanel:add(tabBtn)
    end

    self.content:add(tabPanel)
end

function StatsPage:buildOverview()
    local y = 3

    -- Uptime graph title and value
    local uptimeLabel = UI.label("UPTIME:", 1, y)
        :fg(colors.white)

    self.content:add(uptimeLabel)

    -- Hovered value label
    local hoveredLabel = UI.label("", 9, y)
        :fg(colors.yellow)

    self.hoveredLabel = hoveredLabel
    self.content:add(hoveredLabel)

    y = y + 1

    -- Uptime graph
    self.uptimeData = self:loadUptimeData()
    self.uptimeGraph = UptimeGraph:new(1, y, self.width, 8)
        :setData(self.uptimeData)

    self.content:add(self.uptimeGraph)

    y = y + 9

    -- Key metrics
    local metricsLabel = UI.label("KEY METRICS:", 1, y)
        :fg(colors.white)

    self.content:add(metricsLabel)

    y = y + 1

    -- Calculate metrics
    local totalEvents = 0
    if type(self.stats.eventRates) == "table" then
        for _, eventData in pairs(self.stats.eventRates) do
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

    -- Draw metrics in two columns
    local columnWidth = math.floor(self.width / 2)
    local leftColumnItems = math.ceil(#metrics / 2)

    for row = 1, leftColumnItems do
        local leftIdx = row
        local rightIdx = row + leftColumnItems

        -- Left column
        if metrics[leftIdx] then
            local leftLabel = UI.label(metrics[leftIdx][1] .. ": ", 2, y + row - 1)
                :fg(colors.lightGray)
            local leftValue = UI.label(tostring(metrics[leftIdx][2]), 2 + #(metrics[leftIdx][1]) + 2, y + row - 1)
                :fg(metrics[leftIdx][3])

            self.content:add(leftLabel)
            self.content:add(leftValue)
        end

        -- Right column
        if metrics[rightIdx] then
            local rightLabel = UI.label(metrics[rightIdx][1] .. ": ", columnWidth + 2, y + row - 1)
                :fg(colors.lightGray)
            local rightValue = UI.label(tostring(metrics[rightIdx][2]), columnWidth + 2 + #(metrics[rightIdx][1]) + 2, y + row - 1)
                :fg(metrics[rightIdx][3])

            self.content:add(rightLabel)
            self.content:add(rightValue)
        end
    end
end

function StatsPage:buildEventStats()
    local y = 3

    local title = UI.label("EVENT STATISTICS:", 1, y)
        :fg(colors.white)

    self.content:add(title)

    y = y + 2

    -- Get top events
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

        local indexLabel = UI.label(string.format("%2d. ", i), 2, y)
            :fg(colors.cyan)

        local eventName = event.type
        if #eventName > 30 then
            eventName = eventName:sub(1, 27) .. "..."
        end

        local nameLabel = UI.label(eventName, 6, y)
            :fg(colors.white)

        local countLabel = UI.label(tostring(event.count), 40, y)
            :fg(colors.green)

        self.content:add(indexLabel)
        self.content:add(nameLabel)
        self.content:add(countLabel)

        y = y + 1
    end
end

function StatsPage:buildStorageStats()
    local y = 3

    local title = UI.label("STORAGE STATISTICS:", 1, y)
        :fg(colors.white)

    self.content:add(title)

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

    for _, storage in ipairs(storageMap) do
        totalSlots = totalSlots + storage.size
    end

    -- Metrics labels
    local totalItemsLabel = UI.label("Total Items: ", 2, y)
        :fg(colors.lightGray)
    local totalItemsValue = UI.label(tostring(totalItems), 15, y)
        :fg(colors.yellow)

    self.content:add(totalItemsLabel)
    self.content:add(totalItemsValue)
    y = y + 1

    local uniqueItemsLabel = UI.label("Unique Items: ", 2, y)
        :fg(colors.lightGray)
    local uniqueItemsValue = UI.label(tostring(uniqueItems), 16, y)
        :fg(colors.cyan)

    self.content:add(uniqueItemsLabel)
    self.content:add(uniqueItemsValue)
    y = y + 1

    local inventoriesLabel = UI.label("Storage Inventories: ", 2, y)
        :fg(colors.lightGray)
    local inventoriesValue = UI.label(tostring(#storageMap), 23, y)
        :fg(colors.lime)

    self.content:add(inventoriesLabel)
    self.content:add(inventoriesValue)
    y = y + 1

    local slotsLabel = UI.label("Total Slots: ", 2, y)
        :fg(colors.lightGray)
    local slotsValue = UI.label(tostring(totalSlots), 15, y)
        :fg(colors.orange)

    self.content:add(slotsLabel)
    self.content:add(slotsValue)
    y = y + 2

    -- Top items by count
    local topItemsTitle = UI.label("TOP ITEMS:", 1, y)
        :fg(colors.white)

    self.content:add(topItemsTitle)
    y = y + 1

    table.sort(items, function(a, b)
        return (a.value.count or 0) > (b.value.count or 0)
    end)

    for i = 1, math.min(5, #items) do
        local item = items[i]
        local name = item.key:match("([^:]+)$") or item.key
        if #name > 25 then
            name = name:sub(1, 22) .. "..."
        end

        local itemLabel = UI.label(name, 2, y)
            :fg(colors.white)
        local itemCount = UI.label("x" .. tostring(item.value.count), 30, y)
            :fg(colors.green)

        self.content:add(itemLabel)
        self.content:add(itemCount)

        y = y + 1
    end
end

function StatsPage:buildNetworkStats()
    local y = 3

    local title = UI.label("NETWORK STATISTICS:", 1, y)
        :fg(colors.white)

    self.content:add(title)

    y = y + 2

    -- Get network stats from NetPage
    local netStats = nil
    if self.context.router and self.context.router.pages and self.context.router.pages.net then
        netStats = self.context.router.pages.net:getNetworkStats()
    end

    if not netStats or netStats.totalConnections == 0 then
        local noNetLabel = UI.label("No network connections", 2, y)
            :fg(colors.lightGray)

        self.content:add(noNetLabel)
        return
    end

    -- Summary section
    local summaryTitle = UI.label("== SUMMARY ==", 1, y)
        :fg(colors.cyan)

    self.content:add(summaryTitle)
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

    -- Connections count
    local connLabel = UI.label("Connections: ", 2, y)
        :fg(colors.lightGray)
    local connTotal = UI.label(tostring(netStats.totalConnections), 15, y)
        :fg(colors.yellow)
    local connOnline = UI.label(" (" .. tostring(onlineCount) .. " online, ", 15 + #tostring(netStats.totalConnections), y)
        :fg(colors.lightGray)
    local connOnlineNum = UI.label(tostring(onlineCount), 15 + #tostring(netStats.totalConnections) + 2, y)
        :fg(colors.lime)
    local connOffline = UI.label(" offline)", 15 + #tostring(netStats.totalConnections) + 2 + #tostring(onlineCount) + 9, y)
        :fg(colors.lightGray)

    self.content:add(connLabel)
    self.content:add(connTotal)

    y = y + 1

    -- Packets
    local pktSentLabel = UI.label("Packets Sent: ", 2, y)
        :fg(colors.lightGray)
    local pktSentValue = UI.label(tostring(netStats.totalPacketsSent), 16, y)
        :fg(colors.lime)
    local pktRecvLabel = UI.label("Received: ", 30, y)
        :fg(colors.lightGray)
    local pktRecvValue = UI.label(tostring(netStats.totalPacketsReceived), 40, y)
        :fg(colors.lime)

    self.content:add(pktSentLabel)
    self.content:add(pktSentValue)
    self.content:add(pktRecvLabel)
    self.content:add(pktRecvValue)

    y = y + 1

    -- Data
    local dataSentLabel = UI.label("Data Sent: ", 2, y)
        :fg(colors.lightGray)
    local dataSentValue = UI.label(netStats.totalBytesSent, 13, y)
        :fg(colors.orange)
    local dataRecvLabel = UI.label("Received: ", 30, y)
        :fg(colors.lightGray)
    local dataRecvValue = UI.label(netStats.totalBytesReceived, 40, y)
        :fg(colors.orange)

    self.content:add(dataSentLabel)
    self.content:add(dataSentValue)
    self.content:add(dataRecvLabel)
    self.content:add(dataRecvValue)

    y = y + 1

    -- Average ping
    if netStats.averagePing then
        local pingLabel = UI.label("Average Ping: ", 2, y)
            :fg(colors.lightGray)
        local pingValue = UI.label(string.format("%dms", netStats.averagePing), 16, y)
            :fg(colors.cyan)

        self.content:add(pingLabel)
        self.content:add(pingValue)

        y = y + 1
    end

    y = y + 1

    -- Connections table
    if #netStats.connections > 0 then
        local connTitle = UI.label("== CONNECTIONS ==", 1, y)
            :fg(colors.cyan)

        self.content:add(connTitle)
        y = y + 1

        -- Build table data
        local tableHeaders = {"NAME", "PACKETS", "DATA", "PING"}
        local tableRows = {}

        for _, conn in ipairs(netStats.connections) do
            local name = conn.name
            if #name > 10 then
                name = name:sub(1, 7) .. "..."
            end

            local row = {
                {text = name, color = conn.online and colors.lime or colors.red},
                {text = string.format("%d/%d", conn.packetsSent, conn.packetsReceived), color = colors.lime},
                {text = conn.dataFormatted, color = colors.orange},
                {text = conn.ping and string.format("%dms", conn.ping) or "", color = colors.cyan}
            }

            table.insert(tableRows, row)
        end

        local connTable = DataTable:new(1, y, self.width, math.min(10, #tableRows + 1))
            :setHeaders(tableHeaders)
            :setRows(tableRows)
            :setColumnWidths({2, 15, 28, 40})

        self.content:add(connTable)
    end
end

function StatsPage:buildPoolStats()
    local y = 3

    local title = UI.label("THREAD POOL STATISTICS:", 1, y)
        :fg(colors.white)

    self.content:add(title)

    y = y + 2

    -- Get pools
    local pools = self.context.scheduler:getPools()
    local poolList = {}

    for name, pool in pairs(pools) do
        table.insert(poolList, {name = name, pool = pool})
    end

    table.sort(poolList, function(a, b) return a.name < b.name end)

    -- Build table data
    local tableHeaders = {"POOL NAME", "WORKERS", "ACTIVE", "QUEUE"}
    local tableRows = {}

    for _, poolData in ipairs(poolList) do
        local pool = poolData.pool
        local row = {
            {text = poolData.name:upper(), color = colors.cyan},
            {text = tostring(pool.size), color = colors.white},
            {text = tostring(pool.active or 0), color = colors.yellow},
            {text = tostring(#pool.queue), color = colors.orange}
        }

        table.insert(tableRows, row)
    end

    local poolTable = DataTable:new(1, y, self.width, math.min(15, #tableRows + 1))
        :setHeaders(tableHeaders)
        :setRows(tableRows)
        :setColumnWidths({2, 20, 32, 43})
        :setOnRowClick(function(table, index, row)
            local poolData = poolList[index]
            self:showPoolModal(poolData.name, poolData.pool)
        end)

    self.content:add(poolTable)

    y = y + #tableRows + 2

    -- Instructions
    local instructions = UI.label("(Click on a pool to view details)", 2, y)
        :fg(colors.gray)

    self.content:add(instructions)
end

function StatsPage:showPoolModal(poolName, pool)
    -- Create modal window
    local modalWidth = math.min(45, self.width - 4)
    local modalHeight = 15

    local window = UI.window(poolName:upper() .. " POOL DETAILS", modalWidth, modalHeight)
        :setModal(true)
        :center(self.width, self.height)
        :onClose(function()
            self.showModal = false
            self.poolModal = nil
            self:render()
        end)

    -- Pool stats content
    local y = 2

    -- Pool name
    local nameLabel = UI.label("Pool Name:", 2, y)
        :fg(colors.lightGray)
    local nameValue = UI.label(poolName:upper(), 22, y)
        :fg(colors.cyan)

    window:add(nameLabel)
    window:add(nameValue)
    y = y + 1

    -- Worker threads
    local workersLabel = UI.label("Worker Threads:", 2, y)
        :fg(colors.lightGray)
    local workersValue = UI.label(tostring(pool.size), 22, y)
        :fg(colors.white)

    window:add(workersLabel)
    window:add(workersValue)
    y = y + 1

    -- Active workers
    local activeLabel = UI.label("Active Workers:", 2, y)
        :fg(colors.lightGray)
    local activeValue = UI.label(tostring(pool.active or 0), 22, y)
        :fg(colors.yellow)

    window:add(activeLabel)
    window:add(activeValue)
    y = y + 1

    -- Queued tasks
    local queuedLabel = UI.label("Queued Tasks:", 2, y)
        :fg(colors.lightGray)
    local queuedValue = UI.label(tostring(#pool.queue), 22, y)
        :fg(colors.orange)

    window:add(queuedLabel)
    window:add(queuedValue)
    y = y + 2

    -- Completed tasks
    local completedLabel = UI.label("Completed Tasks:", 2, y)
        :fg(colors.lightGray)
    local completedValue = UI.label(tostring(pool.completed or 0), 22, y)
        :fg(colors.green)

    window:add(completedLabel)
    window:add(completedValue)
    y = y + 1

    -- Failed tasks
    local failedLabel = UI.label("Failed Tasks:", 2, y)
        :fg(colors.lightGray)
    local failedValue = UI.label(tostring(pool.failed or 0), 22, y)
        :fg(colors.red)

    window:add(failedLabel)
    window:add(failedValue)
    y = y + 1

    -- Utilization
    local utilization = pool.size > 0 and math.floor((pool.active or 0) / pool.size * 100) or 0
    local utilizationLabel = UI.label("Utilization:", 2, y)
        :fg(colors.lightGray)
    local utilizationValue = UI.label(tostring(utilization) .. "%", 22, y)
        :fg(colors.lime)

    window:add(utilizationLabel)
    window:add(utilizationValue)

    -- Show modal
    self.showModal = true
    self.poolModal = window
    UI.windowManager:add(window)
    self:render()
end

function StatsPage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1

        -- Tab switching with number keys
        if key >= keys.one and key <= keys.five then
            local tabIndex = key - keys.one + 1
            if self.tabs[tabIndex] then
                self.selectedTab = self.tabs[tabIndex]
                self:buildUI()
                self:render()
            end
            return
        end
    elseif event == "mouse_move" or event == "mouse_drag" then
        -- Update uptime graph hover
        if self.uptimeGraph and self.selectedTab == "overview" then
            local oldHovered = self.uptimeGraph.hoveredIndex
            self.uptimeGraph:handleMouseMove(param1, param2)

            if oldHovered ~= self.uptimeGraph.hoveredIndex then
                -- Update hovered label
                local hoveredValue = self.uptimeGraph:getHoveredValue()
                if hoveredValue then
                    self.hoveredLabel:setText(string.format("%.1f%%", hoveredValue))
                else
                    self.hoveredLabel:setText("")
                end
                self:render()
            end
        end
        return
    end

    BasePage.handleInput(self, event, param1, param2, param3)
end

-- Helper functions from original

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

return StatsPage
