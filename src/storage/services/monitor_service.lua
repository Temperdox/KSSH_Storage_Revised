-- ============================================================================
-- MONITOR SERVICE - Flicker-free UI with double buffering
-- ============================================================================
-- Architecture:
-- 1. Frame buffer system - builds complete frame in memory before writing
-- 2. Layered rendering - base layer + modal overlay
-- 3. Cached expensive operations (peripheral calls)
-- 4. Separate data fetching from rendering
-- ============================================================================

local MonitorService = {}
MonitorService.__index = MonitorService

-- ============================================================================
-- FRAME BUFFER - Double buffering system to prevent flicker
-- ============================================================================
local FrameBuffer = {}
FrameBuffer.__index = FrameBuffer

function FrameBuffer:new(width, height)
    local o = setmetatable({}, self)
    o.width = width
    o.height = height
    o.buffer = {}

    -- Initialize buffer
    for y = 1, height do
        o.buffer[y] = {}
        for x = 1, width do
            o.buffer[y][x] = {
                char = " ",
                textColor = colors.white,
                bgColor = colors.black
            }
        end
    end

    return o
end

function FrameBuffer:setPixel(x, y, char, textColor, bgColor)
    if x >= 1 and x <= self.width and y >= 1 and y <= self.height then
        self.buffer[y][x] = {
            char = char,
            textColor = textColor or colors.white,
            bgColor = bgColor or colors.black
        }
    end
end

function FrameBuffer:writeText(x, y, text, textColor, bgColor)
    for i = 1, #text do
        self:setPixel(x + i - 1, y, text:sub(i, i), textColor, bgColor)
    end
end

function FrameBuffer:fillRect(x, y, width, height, char, textColor, bgColor)
    for dy = 0, height - 1 do
        for dx = 0, width - 1 do
            self:setPixel(x + dx, y + dy, char or " ", textColor, bgColor)
        end
    end
end

function FrameBuffer:clear(bgColor)
    bgColor = bgColor or colors.black
    for y = 1, self.height do
        for x = 1, self.width do
            self.buffer[y][x] = {
                char = " ",
                textColor = colors.white,
                bgColor = bgColor
            }
        end
    end
end

function FrameBuffer:flush(monitor)
    -- Write entire buffer to monitor in one pass
    -- This minimizes flicker by batching all writes
    for y = 1, self.height do
        monitor.setCursorPos(1, y)

        local currentBg = nil
        local currentText = nil
        local lineBuffer = {}

        for x = 1, self.width do
            local pixel = self.buffer[y][x]

            -- Only change colors when needed
            if pixel.bgColor ~= currentBg then
                if #lineBuffer > 0 then
                    monitor.write(table.concat(lineBuffer))
                    lineBuffer = {}
                end
                monitor.setBackgroundColor(pixel.bgColor)
                currentBg = pixel.bgColor
            end

            if pixel.textColor ~= currentText then
                if #lineBuffer > 0 then
                    monitor.write(table.concat(lineBuffer))
                    lineBuffer = {}
                end
                monitor.setTextColor(pixel.textColor)
                currentText = pixel.textColor
            end

            table.insert(lineBuffer, pixel.char)
        end

        if #lineBuffer > 0 then
            monitor.write(table.concat(lineBuffer))
        end
    end
end

-- ============================================================================
-- MONITOR SERVICE
-- ============================================================================

function MonitorService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.scheduler = context.scheduler
    o.logger = context.logger

    -- Find monitor
    o.monitor = peripheral.find("monitor")
    if not o.monitor then
        o.logger:warn("MonitorService", "No monitor found, using terminal")
        o.monitor = term.current()
    end

    o.monitor.setTextScale(0.5)
    o.width, o.height = o.monitor.getSize()
    o.running = false

    -- Frame buffer for double buffering
    o.frameBuffer = FrameBuffer:new(o.width, o.height)

    -- UI state
    o.currentPage = 1
    o.sortBy = "name"
    o.showStatsModal = false
    o.currentView = "storage"  -- "storage" or "network"

    -- Storage page state
    o.currentLetter = nil

    -- Order modal state
    o.showOrderModal = false
    o.selectedItem = nil
    o.orderAmount = 1
    o.selectedLocation = "local"  -- Default to local

    -- Locations modal state
    o.showLocationsModal = false
    o.locationsPage = 1

    -- Network page state
    o.connectionName = ""
    o.showWarningModal = false
    o.warningMessage = ""

    -- Pairing state
    o.pairingState = "idle"  -- "idle", "generating", "waiting_response"
    o.currentPairingCode = nil
    o.pairingVerificationCode = nil
    o.pairingCodeExpiry = 0
    o.pairingRotationTimer = 0
    o.incomingPairRequest = nil  -- {computerID, computerName, code}

    -- Paired computers list
    o.pairedComputers = {}

    -- Cached data (updated by background threads)
    o.itemCache = {}
    o.cacheLastUpdate = 0

    -- Cached stats (expensive to calculate)
    o.cachedStats = {
        freeSlots = 0,
        totalSlots = 0,
        usedSlots = 0,
        inventoryCount = 0,
        bufferChest = "None",
        lastUpdate = 0
    }

    -- Cached locations (from network service)
    o.connectedLocations = {
        {id = "local", name = "Output Chest", available = true}
    }

    -- Item display state
    o.itemColors = {}
    o.itemTimers = {}

    -- Visualizer state
    o.visualizer = {
        pools = {},
        stacks = {},
        maxHeight = 10,
        colors = {
            IO = colors.cyan,
            INDEX = colors.yellow,
            UI = colors.magenta,
            NET = colors.blue,
            API = colors.orange,
            STATS = colors.green,
            TESTS = colors.pink,
            SOUND = colors.purple
        },
        labels = {
            IO = "IO",
            INDEX = "IDX",
            UI = "UI",
            NET = "NET",
            API = "API",
            STATS = "STA",
            TESTS = "TST",
            SOUND = "SND"
        },
        taskColors = {
            input_monitor = colors.cyan,
            input_transfer = colors.cyan,
            buffer_process = colors.lightBlue,
            monitor_sync = colors.blue,
            item_move = colors.lime,
            index_rebuild = colors.yellow,
            item_scan = colors.orange,
            index_update = colors.yellow,
            api_request = colors.orange,
            api_response = colors.red,
            test_run = colors.pink,
            test_check = colors.magenta,
            uptime_check = colors.green,
            stats_save = colors.lime,
            play_sound = colors.purple,
            generic = colors.white,
            error = colors.red
        }
    }

    -- Load I/O configuration
    o.inputSide = "right"
    o.outputSide = "left"
    o:loadIOConfig()

    -- Load paired computers
    o:loadPairedComputers()

    -- Open rednet for pairing
    o:openRednet()

    return o
end

function MonitorService:loadIOConfig()
    local configPath = "/cfg/io_config.json"
    if fs.exists(configPath) then
        local file = fs.open(configPath, "r")
        local config = textutils.unserialiseJSON(file.readAll())
        file.close()

        if config.input and config.input.side then
            self.inputSide = config.input.side
        end
        if config.output and config.output.side then
            self.outputSide = config.output.side
        end
    end
end

function MonitorService:loadPairedComputers()
    local pairsPath = "/cfg/paired_computers.json"
    if fs.exists(pairsPath) then
        local file = fs.open(pairsPath, "r")
        local data = textutils.unserialiseJSON(file.readAll())
        file.close()

        if data and type(data) == "table" then
            self.pairedComputers = data
            self:updateConnectedLocations()
        end
    end
end

function MonitorService:savePairedComputers()
    local pairsPath = "/cfg/paired_computers.json"
    local dir = fs.getDir(pairsPath)
    if not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file = fs.open(pairsPath, "w")
    file.write(textutils.serialiseJSON(self.pairedComputers))
    file.close()

    self:updateConnectedLocations()
end

function MonitorService:updateConnectedLocations()
    -- Rebuild locations list
    self.connectedLocations = {
        {id = "local", name = "Output Chest", available = true}
    }

    for _, paired in ipairs(self.pairedComputers) do
        table.insert(self.connectedLocations, {
            id = paired.computerID,
            name = string.format("\"%s\" (%s)", paired.customName, paired.computerName),
            available = true
        })
    end
end

function MonitorService:openRednet()
    -- Find and open WIRELESS modem for rednet (wired modems don't work for rednet)
    local modem = peripheral.find("modem", function(name, wrapped)
        return wrapped.isWireless()
    end)

    if modem then
        local modemName = peripheral.getName(modem)
        if not rednet.isOpen(modemName) then
            rednet.open(modemName)
            self.logger:info("MonitorService", "Rednet opened on wireless modem: " .. modemName)
        else
            self.logger:info("MonitorService", "Rednet already open on: " .. modemName)
        end
    else
        self.logger:error("MonitorService", "No WIRELESS modem found! Turtle communication requires a wireless modem.")
        self.logger:error("MonitorService", "Please attach a wireless modem to communicate with turtles.")
    end
end

function MonitorService:start()
    self.running = true

    -- Initialize visualizer pools
    self:initializeVisualizer()

    -- Subscribe to events
    self.eventBus:subscribe("task.start", function(event, data)
        self:onTaskStart(data)
    end)

    self.eventBus:subscribe("task.end", function(event, data)
        self:onTaskEnd(data)
    end)

    self.eventBus:subscribe("storage.itemIndexed", function(event, data)
        self:onItemAdded(data)
        -- Don't refresh here during bulk operations
    end)

    self.eventBus:subscribe("index.updated", function(event, data)
        self:onItemUpdated(data)
        self:refreshCache()  -- Immediate refresh for individual updates
    end)

    self.eventBus:subscribe("storage.indexRebuilt", function(event, data)
        self:onIndexRebuilt(data)
        self:refreshCache()  -- Immediate refresh after full rebuild
        self.logger:info("MonitorService", "Cache refreshed after index rebuild")
    end)

    self.eventBus:subscribe("storage.itemAdded", function(event, data)
        self:onItemAdded(data)
        self:refreshCache()  -- Immediate refresh
        self.logger:info("MonitorService", string.format(
            "Item added: %s x%d - cache refreshed",
            data.item, data.count
        ))
    end)

    self.eventBus:subscribe("storage.itemRemoved", function(event, data)
        self:onItemUpdated(data)
        self:refreshCache()  -- Immediate refresh
        self.logger:info("MonitorService", string.format(
            "Item removed: %s x%d - cache refreshed",
            data.item, data.count
        ))
    end)

    -- Start stack decay timer
    self.scheduler:submit("ui", function()
        self:stackDecayLoop()
    end)

    -- Do initial setup
    self:refreshCache()
    self:updateStats()

    self.logger:info("MonitorService", "Service started")
end

function MonitorService:stackDecayLoop()
    while self.running do
        local now = os.epoch("utc") / 1000
        local changed = false

        -- Remove old stack items
        for poolName, pool in pairs(self.visualizer.pools) do
            for _, worker in ipairs(pool.workers) do
                local newStack = {}
                for _, item in ipairs(worker.stack) do
                    if now - item.time < 5 then
                        table.insert(newStack, item)
                    else
                        changed = true
                    end
                end
                worker.stack = newStack
            end
        end

        -- Reset item colors after timeout
        for itemName, colorTime in pairs(self.itemTimers) do
            if now - colorTime > 2 then
                self.itemColors[itemName] = nil
                self.itemTimers[itemName] = nil
                changed = true
            end
        end

        os.sleep(0.1)
    end
end

function MonitorService:run()
    local processes = {}

    -- UI RENDER THREAD - Pure rendering from cached data
    table.insert(processes, function()
        while self.running do
            self:render()
            os.sleep(0.05)  -- 20fps
        end
    end)

    -- CACHE UPDATE THREAD - Updates item cache
    table.insert(processes, function()
        while self.running do
            self:refreshCache()
            os.sleep(0.5)
        end
    end)

    -- STATS UPDATE THREAD - Expensive peripheral calls
    table.insert(processes, function()
        while self.running do
            self:updateStats()
            os.sleep(2)  -- Update every 2 seconds
        end
    end)

    -- PAIRING CODE ROTATION THREAD - Rotates pairing code every 30 seconds
    table.insert(processes, function()
        while self.running do
            if self.pairingState == "waiting_response" then
                local now = os.epoch("utc") / 1000
                if now >= self.pairingCodeExpiry then
                    self:rotatePairingCode()
                end
            end
            os.sleep(1)
        end
    end)

    -- REDNET MESSAGE HANDLER - Listens for pairing messages
    table.insert(processes, function()
        while self.running do
            if rednet.isOpen() then
                local senderID, message, protocol = rednet.receive("storage_pairing", 1)

                if senderID and message and type(message) == "table" then
                    if message.type == "pair_request" then
                        -- Verify the verification code matches
                        if message.verificationCode == self.pairingVerificationCode then
                            self.incomingPairRequest = {
                                computerID = message.senderID,
                                computerName = message.senderName,
                                code = message.verificationCode
                            }
                            self.logger:info("MonitorService", string.format(
                                "Received valid pair request from computer %d",
                                message.senderID
                            ))
                        else
                            self.logger:warn("MonitorService", string.format(
                                "Received pair request with invalid code from computer %d",
                                message.senderID
                            ))
                        end
                    elseif message.type == "pair_accept" then
                        -- Other computer accepted our pairing request
                        if self.pairingState == "waiting_response" then
                            table.insert(self.pairedComputers, {
                                computerID = message.senderID,
                                computerName = message.senderName,
                                customName = self.connectionName
                            })
                            self:savePairedComputers()

                            self.logger:info("MonitorService", string.format(
                                "Pairing accepted by computer %d",
                                message.senderID
                            ))

                            -- Clear pairing state
                            self.pairingState = "idle"
                            self.currentPairingCode = nil
                            self.pairingVerificationCode = nil
                            self.connectionName = ""
                        end
                    elseif message.type == "pair_deny" then
                        -- Other computer denied our pairing request
                        if self.pairingState == "waiting_response" then
                            self.logger:info("MonitorService", string.format(
                                "Pairing denied by computer %d",
                                message.senderID
                            ))

                            -- Show warning
                            self.showWarningModal = true
                            self.warningMessage = "Pairing request was denied by the other computer."

                            -- Clear pairing state
                            self.pairingState = "idle"
                            self.currentPairingCode = nil
                            self.pairingVerificationCode = nil
                        end
                    end
                end
            else
                os.sleep(1)
            end
        end
    end)

    -- Input handler
    table.insert(processes, function()
        while self.running do
            local event, side, x, y = os.pullEvent("monitor_touch")
            if side == peripheral.getName(self.monitor) then
                self:handleClick(x, y)
            end
        end
    end)

    parallel.waitForAny(table.unpack(processes))
end

-- ============================================================================
-- MAIN RENDER - Build frame then flush
-- ============================================================================

function MonitorService:render()
    -- Clear frame buffer
    self.frameBuffer:clear(colors.black)

    -- Draw base UI
    self:drawBaseUI()

    -- Draw modals in order (bottom to top)
    if self.showStatsModal then
        self:drawStatsModal()
    end

    if self.showOrderModal then
        self:drawOrderModal()

        -- Locations modal overlays on top of order modal
        if self.showLocationsModal then
            self:drawLocationsModal()
        end
    end

    -- Pairing modals
    if self.pairingState == "waiting_response" and not self.incomingPairRequest then
        self:drawPairingModal()
    end

    if self.incomingPairRequest then
        self:drawAcceptDenyModal()
    end

    if self.showWarningModal then
        self:drawWarningModal()
    end

    -- Flush complete frame to screen (single operation, no flicker)
    self.frameBuffer:flush(self.monitor)
end

function MonitorService:drawBaseUI()
    -- Draw all base UI elements to frame buffer
    self:drawHeader()

    if self.currentView == "storage" then
        self:drawTableHeaders()
        self:drawItemsTable()
        self:drawProgressBar()
        self:drawLetterFilter()
        self:drawPagination()
    elseif self.currentView == "network" then
        self:drawNetworkPage()
    end

    self:drawSeparator()
    self:drawVisualizer()
    self:drawIOIndicators()
end

-- ============================================================================
-- UI COMPONENTS
-- ============================================================================

function MonitorService:drawHeader()
    -- Build header line with page navigation
    local title
    if self.currentView == "storage" then
        title = " STORAGE | [Stats] | Net"
    else
        title = " Storage | NET"
    end

    -- Sort buttons (only show on storage page)
    local sortX = self.width - 19
    local sortText = ""
    if self.currentView == "storage" then
        sortText = "Sort: "
        if self.sortBy == "name" then
            sortText = sortText .. "[Name]  Count "
        else
            sortText = sortText .. " Name  [Count]"
        end
    end

    local line = title .. string.rep(" ", sortX - #title - 1) .. sortText

    -- Write to buffer
    self.frameBuffer:fillRect(1, 1, self.width, 1, " ", colors.white, colors.gray)
    self.frameBuffer:writeText(1, 1, line, colors.white, colors.gray)
end

function MonitorService:drawTableHeaders()
    local columnWidth = math.floor(self.width / 2)
    local nameWidth = columnWidth - 13
    local countWidth = 6

    -- Build header line
    local chars = {}
    for i = 1, self.width do chars[i] = " " end

    -- Left column headers
    local leftHeaders = " ITEM" .. string.rep(" ", nameWidth - 5) .. "COUNT" .. string.rep(" ", countWidth - 4) .. "STACK"
    for i = 1, #leftHeaders do
        chars[i] = leftHeaders:sub(i, i)
    end

    -- Right column headers
    local offset = columnWidth + 2
    local rightHeaders = "ITEM" .. string.rep(" ", nameWidth - 5) .. "COUNT" .. string.rep(" ", countWidth - 4) .. "STACK"
    for i = 1, math.min(#rightHeaders, self.width - offset) do
        chars[offset + i] = rightHeaders:sub(i, i)
    end

    local line = table.concat(chars)

    -- Write to buffer
    self.frameBuffer:fillRect(1, 2, self.width, 1, " ", colors.white, colors.gray)
    self.frameBuffer:writeText(1, 2, line, colors.white, colors.gray)
end

function MonitorService:drawItemsTable()
    local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

    if #items == 0 then
        local text = "NO ITEMS"
        local x = math.floor(self.width / 2) - 4
        local y = math.floor(self.height / 2)
        self.frameBuffer:writeText(x, y, text, colors.gray, colors.black)
        return
    end

    -- Two-column layout
    local columnWidth = math.floor(self.width / 2)
    local nameWidth = columnWidth - 13
    local countWidth = 6
    local stacksWidth = 5

    -- Calculate available rows
    local startY = 3
    local endY = self.height - 19
    local maxRows = endY - startY + 1

    -- Calculate items per page
    local itemsPerPage = maxRows * 2
    local startIdx = (self.currentPage - 1) * itemsPerPage + 1
    local endIdx = math.min(startIdx + itemsPerPage - 1, #items)

    -- Build row/column mapping
    local rowItems = {}
    for i = startIdx, endIdx do
        local item = items[i]
        local itemOffset = i - startIdx
        local leftColumnItems = math.ceil((endIdx - startIdx + 1) / 2)

        local row, column
        if itemOffset < leftColumnItems then
            column = "left"
            row = itemOffset + 1
        else
            column = "right"
            row = itemOffset - leftColumnItems + 1
        end

        if row >= 1 and row <= maxRows then
            if not rowItems[row] then
                rowItems[row] = {}
            end
            rowItems[row][column] = item
        end
    end

    -- Draw each row
    for row = 1, maxRows do
        local y = startY + row - 1
        local bgColor = (row % 2 == 0) and colors.lightGray or colors.white

        -- Draw left column item
        if rowItems[row] and rowItems[row].left then
            local item = rowItems[row].left
            local xOffset = 0

            -- Background
            self.frameBuffer:fillRect(xOffset + 1, y, columnWidth, 1, " ", colors.black, bgColor)

            -- Item name
            local name = item.key:match("([^:]+)$") or item.key
            if #name > nameWidth - 1 then
                name = name:sub(1, nameWidth - 3) .. "..."
            end
            self.frameBuffer:writeText(xOffset + 2, y, name, colors.black, bgColor)

            -- Count
            local count = item.value and item.value.count or 0
            local countStr = tostring(count)
            if #countStr > countWidth then
                countStr = countStr:sub(1, countWidth)
            end
            local countColor = (count == 0) and colors.red or colors.lime
            self.frameBuffer:writeText(xOffset + nameWidth + 3, y, countStr, countColor, bgColor)

            -- Stacks
            local stackSize = item.value and item.value.stackSize or 64
            local stacks = math.ceil(count / stackSize)
            local stackStr = tostring(stacks)
            if #stackStr > stacksWidth then
                stackStr = stackStr:sub(1, stacksWidth)
            end
            self.frameBuffer:writeText(xOffset + nameWidth + countWidth + 4, y, stackStr, colors.orange, bgColor)
        end

        -- Draw right column item
        if rowItems[row] and rowItems[row].right then
            local item = rowItems[row].right
            local xOffset = columnWidth + 1

            -- Background
            self.frameBuffer:fillRect(xOffset + 1, y, columnWidth, 1, " ", colors.black, bgColor)

            -- Item name
            local name = item.key:match("([^:]+)$") or item.key
            if #name > nameWidth - 1 then
                name = name:sub(1, nameWidth - 3) .. "..."
            end
            self.frameBuffer:writeText(xOffset + 2, y, name, colors.black, bgColor)

            -- Count
            local count = item.value and item.value.count or 0
            local countStr = tostring(count)
            if #countStr > countWidth then
                countStr = countStr:sub(1, countWidth)
            end
            local countColor = (count == 0) and colors.red or colors.lime
            self.frameBuffer:writeText(xOffset + nameWidth + 3, y, countStr, countColor, bgColor)

            -- Stacks
            local stackSize = item.value and item.value.stackSize or 64
            local stacks = math.ceil(count / stackSize)
            local stackStr = tostring(stacks)
            if #stackStr > stacksWidth then
                stackStr = stackStr:sub(1, stacksWidth)
            end
            self.frameBuffer:writeText(xOffset + nameWidth + countWidth + 4, y, stackStr, colors.orange, bgColor)
        end
    end
end

function MonitorService:drawProgressBar()
    local y = self.height - 17

    local totalSlots = self.cachedStats.totalSlots
    local freeSlots = self.cachedStats.freeSlots
    local freePercent = totalSlots > 0 and math.floor((freeSlots / totalSlots) * 100) or 0
    local usedPercent = 100 - freePercent

    -- Build progress bar
    local barWidth = self.width - 4
    local usedWidth = math.floor((usedPercent / 100) * barWidth)

    -- Build overlay text
    local overlayText = string.format("Free space remaining: %d%%", freePercent)
    local textStartX = math.floor((self.width - #overlayText) / 2) + 1

    -- Draw progress bar
    for i = 1, barWidth do
        local globalX = i + 2
        local charInText = globalX >= textStartX and globalX < textStartX + #overlayText
        local textChar = charInText and overlayText:sub(globalX - textStartX + 1, globalX - textStartX + 1) or "\127"

        if i <= usedWidth then
            -- Red (used) portion
            self.frameBuffer:setPixel(i + 2, y, textChar, colors.white, colors.red)
        else
            -- Green (free) portion
            self.frameBuffer:setPixel(i + 2, y, textChar, colors.black, colors.lime)
        end
    end
end

function MonitorService:drawLetterFilter()
    local y = self.height - 15

    local line
    if self.currentLetter then
        local filterText = "[X] " .. self.currentLetter:upper()
        local startX = math.max(1, math.floor((self.width - #filterText) / 2))
        line = string.rep(" ", startX) .. filterText .. string.rep(" ", self.width - startX - #filterText)
    else
        local filterText = "#abcdefghijklmnopqrstuvwxyz"
        local startX = math.max(1, math.floor((self.width - #filterText) / 2))
        line = string.rep(" ", startX) .. filterText .. string.rep(" ", self.width - startX - #filterText)
    end

    self.frameBuffer:writeText(1, y, line, colors.lightGray, colors.black)
end

function MonitorService:drawPagination()
    local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

    local startY = 3
    local endY = self.height - 19
    local maxRows = endY - startY + 1
    local itemsPerPage = maxRows * 2

    local totalPages = math.ceil(#items / itemsPerPage)
    if totalPages <= 1 then return end

    local paginationY = self.height - 13

    local paginationStr = string.format("Page %d/%d", self.currentPage, totalPages)

    if self.currentPage > 1 and self.currentPage < totalPages then
        paginationStr = "< " .. paginationStr .. " >"
    elseif self.currentPage > 1 then
        paginationStr = "< " .. paginationStr
    elseif self.currentPage < totalPages then
        paginationStr = paginationStr .. " >"
    end

    local startX = math.max(0, math.floor((self.width - #paginationStr) / 2))
    local line = string.rep(" ", startX) .. paginationStr .. string.rep(" ", self.width - startX - #paginationStr)

    self.frameBuffer:writeText(1, paginationY, line, colors.gray, colors.black)
end

function MonitorService:drawSeparator()
    local y = self.height - 11
    self.frameBuffer:writeText(1, y, string.rep("-", self.width), colors.gray, colors.black)
end

function MonitorService:drawVisualizer()
    local startY = self.height - 10

    -- Calculate positions
    local totalWidth = 0
    local poolOrder = {}
    for poolName, pool in pairs(self.visualizer.pools) do
        table.insert(poolOrder, {name = poolName, pool = pool})
        totalWidth = totalWidth + (#pool.workers * 2) + 2
    end
    totalWidth = totalWidth - 2

    local startX = math.floor((self.width - totalWidth) / 2)
    local x = startX

    -- Draw each pool
    for _, entry in ipairs(poolOrder) do
        local poolName = entry.name
        local pool = entry.pool

        if x + (#pool.workers * 2) > self.width then break end

        for w, worker in ipairs(pool.workers) do
            local stackX = x + (w - 1) * 2

            if stackX >= 1 and stackX <= self.width then
                -- Draw stacks
                for h = 1, math.min(#worker.stack, self.visualizer.maxHeight - 2) do
                    local rowIdx = self.visualizer.maxHeight - 2 - h + 1
                    local stackItem = worker.stack[h]
                    if stackItem and rowIdx >= 1 and rowIdx <= self.visualizer.maxHeight - 2 then
                        local y = startY + rowIdx - 1
                        self.frameBuffer:setPixel(stackX, y, "\138", stackItem.color, colors.black)
                    end
                end

                -- Worker number
                local workerRow = self.visualizer.maxHeight - 2 + 1
                if workerRow >= 1 and workerRow <= self.visualizer.maxHeight then
                    local y = startY + workerRow - 1
                    self.frameBuffer:setPixel(stackX, y, tostring(w), pool.color, colors.black)
                end
            end
        end

        -- Pool label
        local label = self.visualizer.labels[poolName] or poolName
        local labelX = x + math.floor((#pool.workers * 2 - #label) / 2)
        local labelRow = self.visualizer.maxHeight - 1 + 1
        if labelRow >= 1 and labelRow <= self.visualizer.maxHeight then
            local y = startY + labelRow - 1
            self.frameBuffer:writeText(labelX, y, label, pool.color, colors.black)
        end

        x = x + (#pool.workers * 2) + 2
    end
end

function MonitorService:drawIOIndicators()
    local y = self.height

    -- INPUT in green
    local inputText = "INPUT"
    local inputPos = self.inputSide == "left" and 1 or (self.width - 5)
    self.frameBuffer:writeText(inputPos, y, inputText, colors.lime, colors.black)

    -- OUTPUT in red
    local outputText = "OUTPUT"
    local outputPos = self.outputSide == "left" and 1 or (self.width - 6)
    self.frameBuffer:writeText(outputPos, y, outputText, colors.red, colors.black)
end

function MonitorService:drawStatsModal()
    -- Modal dimensions (same height as items list)
    local modalWidth = math.floor(self.width * 0.6)
    local modalHeight = self.height - 21
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = 3

    -- Get stats data
    local items = self:getAllItems()
    local uniqueCount = #items
    local totalCount = 0
    for _, item in ipairs(items) do
        totalCount = totalCount + (item.value.count or 0)
    end

    local inventoryCount = self.cachedStats.inventoryCount
    local bufferChest = self.cachedStats.bufferChest
    local totalSlots = self.cachedStats.totalSlots
    local usedSlots = self.cachedStats.usedSlots
    local freeSlots = self.cachedStats.freeSlots
    local freePercent = totalSlots > 0 and math.floor((freeSlots / totalSlots) * 100) or 0

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.lightGray)
    self.frameBuffer:writeText(startX + 2, startY, "STORAGE STATISTICS", colors.black, colors.lightGray)

    -- Close button
    self.frameBuffer:writeText(startX + modalWidth - 4, startY, "[X]", colors.red, colors.lightGray)

    -- Draw stats content
    local contentY = startY + 2
    local contentX = startX + 2

    self.frameBuffer:writeText(contentX, contentY, string.format("Total Items: %d", totalCount), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Unique Items: %d", uniqueCount), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Inventories Connected: %d", inventoryCount), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Buffer Chest: %s", bufferChest), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Free Slots: %d", freeSlots), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Storage: %d / %d", usedSlots, totalSlots), colors.white, colors.gray)
    contentY = contentY + 1

    self.frameBuffer:writeText(contentX, contentY, string.format("Free Space: %d%%", freePercent), colors.white, colors.gray)
    contentY = contentY + 2

    self.frameBuffer:writeText(contentX, contentY, "Click [X] to close", colors.lightGray, colors.gray)
end

function MonitorService:drawOrderModal()
    if not self.selectedItem then return end

    -- Modal dimensions (centered, 50% width + 3, auto height)
    local modalWidth = math.floor(self.width * 0.5) + 3
    local modalHeight = 15
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = math.floor((self.height - modalHeight) / 2)

    -- Get item info
    local itemName = self.selectedItem.key:match("([^:]+)$") or self.selectedItem.key
    local maxAmount = self.selectedItem.value.count or 0
    local stackSize = self.selectedItem.value.stackSize or 64

    -- Initialize item info tab state if not exists
    if not self.itemInfoTab then
        self.itemInfoTab = "ORDER"  -- ORDER or CRAFT
    end
    if not self.craftAmount then
        self.craftAmount = 1
    end
    if not self.autocraft then
        self.autocraft = false
    end

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header with item name
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.lightGray)
    local displayName = itemName
    if #displayName > modalWidth - 8 then
        displayName = displayName:sub(1, modalWidth - 11) .. "..."
    end
    self.frameBuffer:writeText(startX + 2, startY, displayName, colors.black, colors.lightGray)

    -- Close button
    self.frameBuffer:writeText(startX + modalWidth - 4, startY, "[X]", colors.red, colors.lightGray)

    -- Draw tabs (row 2)
    local tabY = startY + 1
    self.frameBuffer:fillRect(startX, tabY, modalWidth, 1, " ", colors.white, colors.gray)

    -- ORDER tab
    local orderTabBg = self.itemInfoTab == "ORDER" and colors.lightGray or colors.gray
    local orderTabFg = self.itemInfoTab == "ORDER" and colors.black or colors.lightGray
    self.frameBuffer:writeText(startX + 2, tabY, " ORDER ", orderTabFg, orderTabBg)

    -- CRAFT tab
    local craftTabBg = self.itemInfoTab == "CRAFT" and colors.lightGray or colors.gray
    local craftTabFg = self.itemInfoTab == "CRAFT" and colors.black or colors.lightGray
    self.frameBuffer:writeText(startX + 11, tabY, " CRAFT ", craftTabFg, craftTabBg)

    -- Draw content based on active tab
    local contentY = startY + 3
    local contentX = startX + 2

    -- Show available count for both tabs
    self.frameBuffer:writeText(contentX, contentY, string.format("Available: %d", maxAmount), colors.lightGray, colors.gray)
    contentY = contentY + 2

    if self.itemInfoTab == "ORDER" then
        self:drawOrderTab(contentX, contentY, modalWidth, startX, startY, modalHeight, maxAmount, stackSize)
    elseif self.itemInfoTab == "CRAFT" then
        self:drawCraftTab(contentX, contentY, modalWidth, startX, startY, modalHeight, maxAmount, itemName)
    end
end

function MonitorService:drawOrderTab(contentX, contentY, modalWidth, startX, startY, modalHeight, maxAmount, stackSize)

    -- Amount field
    self.frameBuffer:writeText(contentX, contentY, "Amount:", colors.white, colors.gray)
    contentY = contentY + 1

    -- Amount controls line
    local controlsY = contentY
    local controlsX = contentX + 2

    -- Triple left button (<<<)
    self.frameBuffer:writeText(controlsX, controlsY, "<<<", colors.cyan, colors.gray)
    controlsX = controlsX + 4

    -- Double left button (<<)
    self.frameBuffer:writeText(controlsX, controlsY, "<<", colors.cyan, colors.gray)
    controlsX = controlsX + 3

    -- Single left button (<)
    self.frameBuffer:writeText(controlsX, controlsY, "<", colors.cyan, colors.gray)
    controlsX = controlsX + 2

    -- Amount display
    local amountStr = tostring(self.orderAmount)
    self.frameBuffer:fillRect(controlsX, controlsY, 8, 1, " ", colors.white, colors.black)
    local amountX = controlsX + math.floor((8 - #amountStr) / 2)
    self.frameBuffer:writeText(amountX, controlsY, amountStr, colors.white, colors.black)
    controlsX = controlsX + 9

    -- Single right button (>)
    self.frameBuffer:writeText(controlsX, controlsY, ">", colors.cyan, colors.gray)
    controlsX = controlsX + 2

    -- Double right button (>>)
    self.frameBuffer:writeText(controlsX, controlsY, ">>", colors.cyan, colors.gray)
    controlsX = controlsX + 3

    -- Triple right button (>>>)
    self.frameBuffer:writeText(controlsX, controlsY, ">>>", colors.cyan, colors.gray)

    contentY = contentY + 2

    -- Location field
    self.frameBuffer:writeText(contentX, contentY, "Destination:", colors.white, colors.gray)
    contentY = contentY + 1

    -- Location selector
    local locationName = "Output Chest"
    for _, loc in ipairs(self.connectedLocations) do
        if loc.id == self.selectedLocation then
            locationName = loc.name
            break
        end
    end

    local locationBox = "[" .. locationName .. "]"
    if #locationBox > modalWidth - 4 then
        locationBox = "[" .. locationName:sub(1, modalWidth - 9) .. "...]"
    end
    self.frameBuffer:writeText(contentX + 2, contentY, locationBox, colors.yellow, colors.gray)
    contentY = contentY + 2

    -- Buttons
    local buttonY = startY + modalHeight - 2
    local cancelX = startX + 2
    local confirmX = startX + modalWidth - 12

    self.frameBuffer:writeText(cancelX, buttonY, "[Cancel]", colors.lightGray, colors.gray)
    self.frameBuffer:writeText(confirmX, buttonY, "[Confirm]", colors.lime, colors.gray)
end

function MonitorService:drawCraftTab(contentX, contentY, modalWidth, startX, startY, modalHeight, maxAmount, itemName)
    -- Check if recipe exists
    local recipes = self:loadRecipes()
    local fullItemName = nil
    for _, item in ipairs(self.itemCache) do
        local shortName = item.key:match("([^:]+)$")
        if shortName == itemName then
            fullItemName = item.key
            break
        end
    end

    local hasRecipe = fullItemName and recipes[fullItemName] ~= nil

    if not hasRecipe then
        -- NO RECIPE - Show "Add Recipe" button
        self.frameBuffer:writeText(contentX, contentY, "No recipe found for this item", colors.orange, colors.gray)
        contentY = contentY + 2

        self.frameBuffer:writeText(contentX, contentY, "To enable crafting, a recipe must", colors.lightGray, colors.gray)
        contentY = contentY + 1
        self.frameBuffer:writeText(contentX, contentY, "be added to the crafting turtle.", colors.lightGray, colors.gray)
        contentY = contentY + 2

        -- Add Recipe button (centered)
        local addRecipeBtn = "[Add Recipe]"
        local btnX = contentX + math.floor((modalWidth - 4 - #addRecipeBtn) / 2)
        local btnY = contentY
        self.frameBuffer:writeText(btnX, btnY, addRecipeBtn, colors.lime, colors.gray)
        contentY = contentY + 3

        -- Store button position for click detection
        self.addRecipeButton = {
            x = btnX,
            y = btnY,
            width = #addRecipeBtn,
            itemName = fullItemName or itemName
        }

        -- Cancel button at bottom
        local buttonY = startY + modalHeight - 2
        local cancelX = startX + 2
        self.frameBuffer:writeText(cancelX, buttonY, "[Cancel]", colors.lightGray, colors.gray)

        return
    end

    -- RECIPE EXISTS - Show normal craft controls
    self.addRecipeButton = nil  -- Clear the add recipe button

    -- Amount field
    self.frameBuffer:writeText(contentX, contentY, "Craft Amount:", colors.white, colors.gray)
    contentY = contentY + 1

    -- Amount controls line (triple arrow system)
    local controlsY = contentY
    local controlsX = contentX + 2

    -- Triple left button (<<<)
    self.frameBuffer:writeText(controlsX, controlsY, "<<<", colors.cyan, colors.gray)
    controlsX = controlsX + 4

    -- Double left button (<<)
    self.frameBuffer:writeText(controlsX, controlsY, "<<", colors.cyan, colors.gray)
    controlsX = controlsX + 3

    -- Single left button (<)
    self.frameBuffer:writeText(controlsX, controlsY, "<", colors.cyan, colors.gray)
    controlsX = controlsX + 2

    -- Amount display
    local amountStr = tostring(self.craftAmount)
    self.frameBuffer:fillRect(controlsX, controlsY, 8, 1, " ", colors.white, colors.black)
    local amountX = controlsX + math.floor((8 - #amountStr) / 2)
    self.frameBuffer:writeText(amountX, controlsY, amountStr, colors.white, colors.black)
    controlsX = controlsX + 9

    -- Single right button (>)
    self.frameBuffer:writeText(controlsX, controlsY, ">", colors.cyan, colors.gray)
    controlsX = controlsX + 2

    -- Double right button (>>)
    self.frameBuffer:writeText(controlsX, controlsY, ">>", colors.cyan, colors.gray)
    controlsX = controlsX + 3

    -- Triple right button (>>>)
    self.frameBuffer:writeText(controlsX, controlsY, ">>>", colors.cyan, colors.gray)

    contentY = contentY + 2

    -- Autocraft checkbox
    local checkboxChar = self.autocraft and "X" or " "
    self.frameBuffer:writeText(contentX, contentY, "[" .. checkboxChar .. "] Autocraft", colors.yellow, colors.gray)
    contentY = contentY + 2

    -- Calculate if we can craft the requested amount
    local craftable = self:calculateCraftable(itemName, self.craftAmount)

    -- Warning message if insufficient items
    if not craftable.canCraftAll then
        if self.autocraft then
            -- Show warning with partial craft info
            self.frameBuffer:writeText(contentX, contentY, "Warning:", colors.orange, colors.gray)
            contentY = contentY + 1
            self.frameBuffer:writeText(contentX, contentY, "Cannot craft requested amount", colors.lightGray, colors.gray)
            contentY = contentY + 1
            self.frameBuffer:writeText(contentX, contentY, string.format("Will craft %d now", craftable.canCraft), colors.lime, colors.gray)
            contentY = contentY + 1
            self.frameBuffer:writeText(contentX, contentY, "Will craft rest when available", colors.lightGray, colors.gray)
            contentY = contentY + 1
        else
            -- Show error - cannot craft
            self.frameBuffer:writeText(contentX, contentY, "Insufficient items!", colors.red, colors.gray)
            contentY = contentY + 1
            self.frameBuffer:writeText(contentX, contentY, string.format("Can only craft %d", craftable.canCraft), colors.lightGray, colors.gray)
            contentY = contentY + 1
        end
    end

    -- Buttons
    local buttonY = startY + modalHeight - 2
    local cancelX = startX + 2
    local craftX = startX + modalWidth - 10

    self.frameBuffer:writeText(cancelX, buttonY, "[Cancel]", colors.lightGray, colors.gray)

    -- Craft button - disabled if insufficient items AND autocraft is off
    local canCraft = craftable.canCraftAll or self.autocraft
    local craftColor = canCraft and colors.lime or colors.gray
    self.frameBuffer:writeText(craftX, buttonY, "[Craft]", craftColor, colors.gray)
end

function MonitorService:calculateCraftable(itemName, requestedAmount)
    -- Load recipes from disk (if available)
    local recipes = self:loadRecipes()

    -- Check if recipe exists for this item
    local fullItemName = nil
    for _, item in ipairs(self.itemCache) do
        local shortName = item.key:match("([^:]+)$")
        if shortName == itemName then
            fullItemName = item.key
            break
        end
    end

    if not fullItemName then
        return {
            canCraftAll = false,
            canCraft = 0,
            missing = {itemName}
        }
    end

    local recipe = recipes[fullItemName]

    if not recipe then
        -- No recipe found
        return {
            canCraftAll = false,
            canCraft = 0,
            missing = {fullItemName}
        }
    end

    -- Calculate how many we can craft with available ingredients
    local canCraftBatches = math.huge
    local missing = {}

    -- Count required ingredients from pattern
    local ingredientCounts = {}
    for _, row in ipairs(recipe.pattern) do
        for _, ingredient in ipairs(row) do
            if ingredient then
                ingredientCounts[ingredient] = (ingredientCounts[ingredient] or 0) + 1
            end
        end
    end

    -- Check each ingredient
    for ingredient, countPerBatch in pairs(ingredientCounts) do
        local available = 0

        -- Find ingredient in cache
        for _, item in ipairs(self.itemCache) do
            if item.key == ingredient then
                available = item.value.count or 0
                break
            end
        end

        local batchesFromThis = math.floor(available / countPerBatch)

        if batchesFromThis == 0 then
            table.insert(missing, ingredient)
        end

        canCraftBatches = math.min(canCraftBatches, batchesFromThis)
    end

    -- If no ingredients or all missing, can't craft any
    if canCraftBatches == math.huge then
        canCraftBatches = 0
    end

    -- Each batch produces recipe.result.count items
    local itemsPerBatch = recipe.result.count or 1
    local totalCanCraft = canCraftBatches * itemsPerBatch

    return {
        canCraftAll = totalCanCraft >= requestedAmount,
        canCraft = totalCanCraft,
        missing = missing
    }
end

function MonitorService:loadRecipes()
    -- Load recipes from disk drive (future implementation will sync with turtle)
    local recipePath = "/disk/recipes.json"

    if fs.exists(recipePath) then
        local file = fs.open(recipePath, "r")
        local content = file.readAll()
        file.close()

        local recipes = textutils.unserialiseJSON(content)
        if recipes and type(recipes) == "table" then
            return recipes
        end
    end

    -- Return empty recipes table if file doesn't exist
    return {}
end

function MonitorService:drawLocationsModal()
    -- Modal dimensions (centered, 40% width, 60% height)
    local modalWidth = math.floor(self.width * 0.4)
    local modalHeight = math.floor(self.height * 0.6)
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = math.floor((self.height - modalHeight) / 2)

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.lightGray)
    self.frameBuffer:writeText(startX + 2, startY, "SELECT LOCATION", colors.black, colors.lightGray)

    -- Close button
    self.frameBuffer:writeText(startX + modalWidth - 4, startY, "[X]", colors.red, colors.lightGray)

    -- Draw locations list
    local contentY = startY + 2
    local contentX = startX + 2

    local itemsPerPage = modalHeight - 6
    local totalPages = math.ceil(#self.connectedLocations / itemsPerPage)
    local startIdx = (self.locationsPage - 1) * itemsPerPage + 1
    local endIdx = math.min(startIdx + itemsPerPage - 1, #self.connectedLocations)

    if #self.connectedLocations == 0 then
        self.frameBuffer:writeText(contentX, contentY, "No locations found", colors.lightGray, colors.gray)
    else
        for i = startIdx, endIdx do
            local loc = self.connectedLocations[i]
            local displayName = loc.name
            if #displayName > modalWidth - 6 then
                displayName = displayName:sub(1, modalWidth - 9) .. "..."
            end

            local textColor = colors.white
            local prefix = " "
            if loc.id == self.selectedLocation then
                prefix = ">"
                textColor = colors.lime
            end

            self.frameBuffer:writeText(contentX, contentY, prefix .. " " .. displayName, textColor, colors.gray)
            contentY = contentY + 1
        end
    end

    -- Pagination
    if totalPages > 1 then
        local paginationY = startY + modalHeight - 2
        local paginationStr = string.format("Page %d/%d", self.locationsPage, totalPages)

        if self.locationsPage > 1 and self.locationsPage < totalPages then
            paginationStr = "< " .. paginationStr .. " >"
        elseif self.locationsPage > 1 then
            paginationStr = "< " .. paginationStr
        elseif self.locationsPage < totalPages then
            paginationStr = paginationStr .. " >"
        end

        local paginationX = startX + math.floor((modalWidth - #paginationStr) / 2)
        self.frameBuffer:writeText(paginationX, paginationY, paginationStr, colors.lightGray, colors.gray)
    end
end

function MonitorService:drawNetworkPage()
    -- Network page layout
    local contentY = 3
    local contentX = 2

    -- Title
    self.frameBuffer:writeText(contentX, contentY, "NETWORK MANAGEMENT", colors.white, colors.black)
    contentY = contentY + 2

    -- Add Connection section
    self.frameBuffer:writeText(contentX, contentY, "Add Connection:", colors.lightGray, colors.black)
    contentY = contentY + 1

    -- Connection name label
    self.frameBuffer:writeText(contentX + 2, contentY, "Name:", colors.white, colors.black)
    contentY = contentY + 1

    -- Connection name text box
    local textBoxWidth = 30
    self.frameBuffer:fillRect(contentX + 2, contentY, textBoxWidth, 1, " ", colors.white, colors.gray)
    if #self.connectionName > 0 then
        local displayName = self.connectionName
        if #displayName > textBoxWidth - 2 then
            displayName = displayName:sub(1, textBoxWidth - 2)
        end
        self.frameBuffer:writeText(contentX + 3, contentY, displayName, colors.black, colors.gray)
    else
        self.frameBuffer:writeText(contentX + 3, contentY, "Enter connection name...", colors.lightGray, colors.gray)
    end
    contentY = contentY + 2

    -- Add button
    self.frameBuffer:writeText(contentX + 2, contentY, "[Add Connection]", colors.lime, colors.black)
    contentY = contentY + 3

    -- Paired computers section
    self.frameBuffer:writeText(contentX, contentY, "Paired Computers:", colors.lightGray, colors.black)
    contentY = contentY + 1

    if #self.pairedComputers == 0 then
        self.frameBuffer:writeText(contentX + 2, contentY, "No paired computers", colors.gray, colors.black)
    else
        -- List paired computers
        local maxRows = self.height - 25
        for i = 1, math.min(#self.pairedComputers, maxRows) do
            local paired = self.pairedComputers[i]
            local displayText = string.format('"%s" (%s) - ID: %d',
                paired.customName,
                paired.computerName,
                paired.computerID)

            if #displayText > self.width - 6 then
                displayText = displayText:sub(1, self.width - 9) .. "..."
            end

            self.frameBuffer:writeText(contentX + 2, contentY, displayText, colors.white, colors.black)
            contentY = contentY + 1
        end
    end
end

function MonitorService:drawWarningModal()
    -- Modal dimensions (centered, 50% width, auto height)
    local modalWidth = math.floor(self.width * 0.5)
    local modalHeight = 8
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = math.floor((self.height - modalHeight) / 2)

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.red)
    self.frameBuffer:writeText(startX + 2, startY, "WARNING", colors.white, colors.red)

    -- Draw warning message
    local contentY = startY + 2
    local contentX = startX + 2

    -- Word wrap the message
    local words = {}
    for word in self.warningMessage:gmatch("%S+") do
        table.insert(words, word)
    end

    local line = ""
    local maxWidth = modalWidth - 4
    for _, word in ipairs(words) do
        if #line + #word + 1 <= maxWidth then
            line = line == "" and word or line .. " " .. word
        else
            self.frameBuffer:writeText(contentX, contentY, line, colors.white, colors.gray)
            contentY = contentY + 1
            line = word
        end
    end
    if #line > 0 then
        self.frameBuffer:writeText(contentX, contentY, line, colors.white, colors.gray)
    end

    -- OK button
    local buttonY = startY + modalHeight - 2
    local buttonX = startX + math.floor((modalWidth - 4) / 2)
    self.frameBuffer:writeText(buttonX, buttonY, "[OK]", colors.lime, colors.gray)
end

function MonitorService:drawPairingModal()
    -- Modal dimensions (centered, 60% width, auto height)
    local modalWidth = math.floor(self.width * 0.6)
    local modalHeight = 12
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = math.floor((self.height - modalHeight) / 2)

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.lightGray)
    self.frameBuffer:writeText(startX + 2, startY, "PAIRING CODE", colors.black, colors.lightGray)

    -- Draw content
    local contentY = startY + 2
    local contentX = startX + 2

    self.frameBuffer:writeText(contentX, contentY, "Enter this code on the other computer:", colors.white, colors.gray)
    contentY = contentY + 2

    -- Display pairing code (large and centered)
    local codeDisplay = self.currentPairingCode or "------"
    local codeX = startX + math.floor((modalWidth - #codeDisplay) / 2)
    self.frameBuffer:writeText(codeX, contentY, codeDisplay, colors.lime, colors.gray)
    contentY = contentY + 2

    -- Time remaining
    local timeRemaining = math.max(0, math.ceil(self.pairingCodeExpiry - (os.epoch("utc") / 1000)))
    local timerText = string.format("Code expires in %d seconds", timeRemaining)
    local timerX = startX + math.floor((modalWidth - #timerText) / 2)
    self.frameBuffer:writeText(timerX, contentY, timerText, colors.lightGray, colors.gray)
    contentY = contentY + 2

    self.frameBuffer:writeText(contentX, contentY, "Waiting for response...", colors.yellow, colors.gray)

    -- Cancel button
    local buttonY = startY + modalHeight - 2
    local buttonX = startX + math.floor((modalWidth - 8) / 2)
    self.frameBuffer:writeText(buttonX, buttonY, "[Cancel]", colors.red, colors.gray)
end

function MonitorService:drawAcceptDenyModal()
    -- Modal dimensions (centered, 60% width, auto height)
    local modalWidth = math.floor(self.width * 0.6)
    local modalHeight = 10
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = math.floor((self.height - modalHeight) / 2)

    -- Draw modal background
    self.frameBuffer:fillRect(startX, startY, modalWidth, modalHeight, " ", colors.white, colors.gray)

    -- Draw modal header
    self.frameBuffer:fillRect(startX, startY, modalWidth, 1, " ", colors.black, colors.lightGray)
    self.frameBuffer:writeText(startX + 2, startY, "PAIRING REQUEST", colors.black, colors.lightGray)

    -- Draw content
    local contentY = startY + 2
    local contentX = startX + 2

    local requestText = string.format(
        "Computer %d (%s) requests to pair",
        self.incomingPairRequest.computerID,
        self.incomingPairRequest.computerName
    )

    -- Word wrap if needed
    if #requestText > modalWidth - 4 then
        local words = {}
        for word in requestText:gmatch("%S+") do
            table.insert(words, word)
        end

        local line = ""
        local maxWidth = modalWidth - 4
        for _, word in ipairs(words) do
            if #line + #word + 1 <= maxWidth then
                line = line == "" and word or line .. " " .. word
            else
                self.frameBuffer:writeText(contentX, contentY, line, colors.white, colors.gray)
                contentY = contentY + 1
                line = word
            end
        end
        if #line > 0 then
            self.frameBuffer:writeText(contentX, contentY, line, colors.white, colors.gray)
            contentY = contentY + 1
        end
    else
        self.frameBuffer:writeText(contentX, contentY, requestText, colors.white, colors.gray)
        contentY = contentY + 1
    end

    contentY = contentY + 2
    self.frameBuffer:writeText(contentX, contentY, "Do you want to accept this pairing?", colors.lightGray, colors.gray)

    -- Buttons
    local buttonY = startY + modalHeight - 2
    local acceptX = startX + 4
    local denyX = startX + modalWidth - 10

    self.frameBuffer:writeText(acceptX, buttonY, "[Accept]", colors.lime, colors.gray)
    self.frameBuffer:writeText(denyX, buttonY, "[Deny]", colors.red, colors.gray)
end

-- ============================================================================
-- DATA MANAGEMENT
-- ============================================================================

function MonitorService:refreshCache()
    -- Update item cache from storage service
    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()
        local oldCount = #self.itemCache
        self.itemCache = items
        self.cacheLastUpdate = os.epoch("utc") / 1000

        self.logger:debug("MonitorService", string.format(
            "Cache refreshed: %d items (was %d)",
            #items, oldCount
        ))
    end
end

function MonitorService:updateCache(items, uniqueCount)
    -- Direct cache update from storage service (called by syncToMonitor)
    self.itemCache = items or {}
    self.cacheLastUpdate = os.epoch("utc") / 1000

    self.logger:debug("MonitorService", string.format(
        "Cache updated: %d items, %d unique",
        #items, uniqueCount or 0
    ))
end

function MonitorService:updateStats()
    -- Update expensive cached stats
    local freeSlots = 0
    local totalSlots = 0
    local usedSlots = 0
    local inventoryCount = 0
    local bufferChest = "None"

    if self.context.services and self.context.services.storage then
        local storageService = self.context.services.storage

        if storageService.storageMap then
            inventoryCount = #storageService.storageMap

            for _, storage in ipairs(storageService.storageMap) do
                if not storage.isME then
                    local inv = peripheral.wrap(storage.name)
                    if inv and inv.list and inv.size then
                        local items = inv.list()
                        local size = inv.size()
                        totalSlots = totalSlots + size
                        local used = 0
                        for _ in pairs(items) do
                            used = used + 1
                        end
                        usedSlots = usedSlots + used
                        freeSlots = freeSlots + (size - used)
                    end
                end
            end
        end

        if storageService.bufferChest then
            bufferChest = storageService.bufferChest
        end
    end

    self.cachedStats = {
        freeSlots = freeSlots,
        totalSlots = totalSlots,
        usedSlots = usedSlots,
        inventoryCount = inventoryCount,
        bufferChest = bufferChest,
        lastUpdate = os.epoch("utc") / 1000
    }
end

function MonitorService:getAllItems()
    -- Deduplicate items by key
    local itemMap = {}
    for _, item in ipairs(self.itemCache) do
        if not itemMap[item.key] then
            itemMap[item.key] = {
                key = item.key,
                value = {
                    count = item.value.count or 0,
                    stackSize = item.value.stackSize or 64
                }
            }
        end
    end

    -- Convert to array
    local items = {}
    for _, item in pairs(itemMap) do
        table.insert(items, item)
    end

    -- Sort
    table.sort(items, function(a, b)
        if self.sortBy == "count" then
            return (a.value.count or 0) > (b.value.count or 0)
        else
            return a.key < b.key
        end
    end)

    return items
end

function MonitorService:getFilteredItems()
    local items = self:getAllItems()
    local filtered = {}

    for _, item in ipairs(items) do
        local firstChar = item.key:sub(1, 1):lower()
        local match = false

        if self.currentLetter == "#" then
            match = not firstChar:match("[a-z]")
        elseif self.currentLetter then
            match = firstChar == self.currentLetter:lower()
        else
            match = true
        end

        if match then
            table.insert(filtered, item)
        end
    end

    return filtered
end

-- ============================================================================
-- INPUT HANDLING
-- ============================================================================

function MonitorService:handleClick(x, y)
    -- Handle locations modal clicks (highest priority)
    if self.showLocationsModal then
        local modalWidth = math.floor(self.width * 0.4)
        local modalHeight = math.floor(self.height * 0.6)
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = math.floor((self.height - modalHeight) / 2)

        -- Close button
        if y == startY and x >= startX + modalWidth - 4 and x <= startX + modalWidth - 1 then
            self.showLocationsModal = false
            return
        end

        -- Pagination
        local itemsPerPage = modalHeight - 6
        local totalPages = math.ceil(#self.connectedLocations / itemsPerPage)
        if totalPages > 1 then
            local paginationY = startY + modalHeight - 2
            local paginationStr = string.format("Page %d/%d", self.locationsPage, totalPages)
            local hasLeft = self.locationsPage > 1
            local hasRight = self.locationsPage < totalPages

            if hasLeft and hasRight then
                paginationStr = "< " .. paginationStr .. " >"
            elseif hasLeft then
                paginationStr = "< " .. paginationStr
            elseif hasRight then
                paginationStr = paginationStr .. " >"
            end

            local paginationX = startX + math.floor((modalWidth - #paginationStr) / 2)

            if y == paginationY then
                if hasLeft and x >= paginationX and x <= paginationX + 1 then
                    self.locationsPage = self.locationsPage - 1
                    return
                elseif hasRight and x >= paginationX + #paginationStr - 1 and x <= paginationX + #paginationStr then
                    self.locationsPage = self.locationsPage + 1
                    return
                end
            end
        end

        -- Location selection
        local contentY = startY + 2
        local contentX = startX + 2
        local startIdx = (self.locationsPage - 1) * itemsPerPage + 1
        local endIdx = math.min(startIdx + itemsPerPage - 1, #self.connectedLocations)

        for i = startIdx, endIdx do
            if y == contentY then
                local loc = self.connectedLocations[i]
                self.selectedLocation = loc.id
                self.showLocationsModal = false
                return
            end
            contentY = contentY + 1
        end

        -- Click outside closes modal
        if x < startX or x >= startX + modalWidth or y < startY or y >= startY + modalHeight then
            self.showLocationsModal = false
            return
        end

        return
    end

    -- Handle order modal clicks
    if self.showOrderModal then
        local modalWidth = math.floor(self.width * 0.5) + 3
        local modalHeight = 15
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = math.floor((self.height - modalHeight) / 2)

        -- Close button
        if y == startY and x >= startX + modalWidth - 4 and x <= startX + modalWidth - 1 then
            self.showOrderModal = false
            self.selectedItem = nil
            return
        end

        -- Tab clicks (row 2)
        local tabY = startY + 1
        if y == tabY then
            -- ORDER tab
            if x >= startX + 2 and x <= startX + 8 then
                self.itemInfoTab = "ORDER"
                return
            end
            -- CRAFT tab
            if x >= startX + 11 and x <= startX + 17 then
                self.itemInfoTab = "CRAFT"
                return
            end
        end

        -- Amount controls (ORDER tab)
        if self.itemInfoTab == "ORDER" then
            local controlsY = startY + 6
            local controlsX = startX + 4

            local maxAmount = self.selectedItem and (self.selectedItem.value.count or 0) or 0
            local stackSize = self.selectedItem and (self.selectedItem.value.stackSize or 64) or 64

            if y == controlsY then
                -- <<< button (decrease by stack size)
                if x >= controlsX and x <= controlsX + 2 then
                    self.orderAmount = math.max(1, self.orderAmount - stackSize)
                    return
                end
                controlsX = controlsX + 4

                -- << button (decrease by 10)
                if x >= controlsX and x <= controlsX + 1 then
                    self.orderAmount = math.max(1, self.orderAmount - 10)
                    return
                end
                controlsX = controlsX + 3

                -- < button (decrease by 1)
                if x >= controlsX and x <= controlsX then
                    self.orderAmount = math.max(1, self.orderAmount - 1)
                    return
                end
                controlsX = controlsX + 11  -- Skip amount display box

                -- > button (increase by 1)
                if x >= controlsX and x <= controlsX then
                    self.orderAmount = math.min(maxAmount, self.orderAmount + 1)
                    return
                end
                controlsX = controlsX + 2

                -- >> button (increase by 10)
                if x >= controlsX and x <= controlsX + 1 then
                    self.orderAmount = math.min(maxAmount, self.orderAmount + 10)
                    return
                end
                controlsX = controlsX + 3

                -- >>> button (increase by stack size)
                if x >= controlsX and x <= controlsX + 2 then
                    self.orderAmount = math.min(maxAmount, self.orderAmount + stackSize)
                    return
                end
            end

            -- Location field click
            local locationY = startY + 10
            if y == locationY and x >= startX + 4 and x <= startX + modalWidth - 4 then
                self.showLocationsModal = true
                self.locationsPage = 1
                return
            end

            -- Cancel button
            local buttonY = startY + modalHeight - 2
            local cancelX = startX + 2
            if y == buttonY and x >= cancelX and x <= cancelX + 7 then
                self.showOrderModal = false
                self.selectedItem = nil
                return
            end

            -- Confirm button
            local confirmX = startX + modalWidth - 12
            if y == buttonY and x >= confirmX and x <= confirmX + 8 then
                -- Submit order
                self:submitOrder()
                self.showOrderModal = false
                self.selectedItem = nil
                return
            end

        elseif self.itemInfoTab == "CRAFT" then
            -- Check for Add Recipe button click (shown when no recipe exists)
            if self.addRecipeButton then
                local btn = self.addRecipeButton
                if y == btn.y and x >= btn.x and x <= btn.x + btn.width - 1 then
                    -- Send request to turtle to enter recipe mode
                    self:requestRecipeMode(btn.itemName)
                    self.showOrderModal = false
                    self.selectedItem = nil
                    return
                end
            end

            -- CRAFT tab controls (only shown when recipe exists)
            local controlsY = startY + 6
            local controlsX = startX + 4

            -- Craft amount controls (triple arrow system)
            if y == controlsY then
                -- <<< button (decrease by 64)
                if x >= controlsX and x <= controlsX + 2 then
                    self.craftAmount = math.max(1, self.craftAmount - 64)
                    return
                end
                controlsX = controlsX + 4

                -- << button (decrease by 16)
                if x >= controlsX and x <= controlsX + 1 then
                    self.craftAmount = math.max(1, self.craftAmount - 16)
                    return
                end
                controlsX = controlsX + 3

                -- < button (decrease by 1)
                if x >= controlsX and x <= controlsX then
                    self.craftAmount = math.max(1, self.craftAmount - 1)
                    return
                end
                controlsX = controlsX + 11  -- Skip amount display box

                -- > button (increase by 1)
                if x >= controlsX and x <= controlsX then
                    self.craftAmount = self.craftAmount + 1
                    return
                end
                controlsX = controlsX + 2

                -- >> button (increase by 16)
                if x >= controlsX and x <= controlsX + 1 then
                    self.craftAmount = self.craftAmount + 16
                    return
                end
                controlsX = controlsX + 3

                -- >>> button (increase by 64)
                if x >= controlsX and x <= controlsX + 2 then
                    self.craftAmount = self.craftAmount + 64
                    return
                end
            end

            -- Autocraft checkbox click
            local checkboxY = startY + 8
            if y == checkboxY and x >= startX + 2 and x <= startX + 17 then
                self.autocraft = not self.autocraft
                return
            end

            -- Cancel button
            local buttonY = startY + modalHeight - 2
            local cancelX = startX + 2
            if y == buttonY and x >= cancelX and x <= cancelX + 7 then
                self.showOrderModal = false
                self.selectedItem = nil
                return
            end

            -- Craft button
            local craftX = startX + modalWidth - 10
            if y == buttonY and x >= craftX and x <= craftX + 6 then
                -- Check if we can craft
                local itemName = self.selectedItem.key:match("([^:]+)$") or self.selectedItem.key
                local craftable = self:calculateCraftable(itemName, self.craftAmount)
                local canCraft = craftable.canCraftAll or self.autocraft

                if canCraft then
                    -- Send craft request to turtle via rednet
                    self:sendCraftRequest(self.selectedItem.key, self.craftAmount, self.autocraft)
                    self.showOrderModal = false
                    self.selectedItem = nil
                end
                return
            end
        end

        -- Click outside closes modal
        if x < startX or x >= startX + modalWidth or y < startY or y >= startY + modalHeight then
            self.showOrderModal = false
            self.selectedItem = nil
            return
        end

        return
    end

    -- Handle stats modal clicks
    if self.showStatsModal then
        local modalWidth = math.floor(self.width * 0.6)
        local modalHeight = self.height - 21
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = 3

        -- Close button
        if y == startY and x >= startX + modalWidth - 4 and x <= startX + modalWidth - 1 then
            self.showStatsModal = false
            return
        end

        -- Click outside modal closes it
        if x < startX or x >= startX + modalWidth or y < startY or y >= startY + modalHeight then
            self.showStatsModal = false
            return
        end

        return
    end

    -- Handle accept/deny modal clicks (highest priority)
    if self.incomingPairRequest then
        local modalWidth = math.floor(self.width * 0.6)
        local modalHeight = 10
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = math.floor((self.height - modalHeight) / 2)
        local buttonY = startY + modalHeight - 2

        -- Accept button
        local acceptX = startX + 4
        if y == buttonY and x >= acceptX and x <= acceptX + 7 then
            self:acceptPairRequest()
            return
        end

        -- Deny button
        local denyX = startX + modalWidth - 10
        if y == buttonY and x >= denyX and x <= denyX + 5 then
            self:denyPairRequest()
            return
        end

        return
    end

    -- Handle pairing modal clicks
    if self.pairingState == "waiting_response" and not self.incomingPairRequest then
        local modalWidth = math.floor(self.width * 0.6)
        local modalHeight = 12
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = math.floor((self.height - modalHeight) / 2)
        local buttonY = startY + modalHeight - 2
        local buttonX = startX + math.floor((modalWidth - 8) / 2)

        -- Cancel button
        if y == buttonY and x >= buttonX and x <= buttonX + 7 then
            self:cancelPairing()
            return
        end

        return
    end

    -- Handle warning modal clicks
    if self.showWarningModal then
        local modalWidth = math.floor(self.width * 0.5)
        local modalHeight = 8
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = math.floor((self.height - modalHeight) / 2)
        local buttonY = startY + modalHeight - 2
        local buttonX = startX + math.floor((modalWidth - 4) / 2)

        -- OK button
        if y == buttonY and x >= buttonX and x <= buttonX + 3 then
            self.showWarningModal = false
            return
        end

        -- Click outside closes modal
        if x < startX or x >= startX + modalWidth or y < startY or y >= startY + modalHeight then
            self.showWarningModal = false
            return
        end

        return
    end

    -- Header clicks
    if y == 1 then
        -- View switching
        if self.currentView == "storage" then
            -- Stats link
            if x >= 12 and x <= 18 then
                self.showStatsModal = true
                return
            end

            -- Net link
            if x >= 22 and x <= 24 then
                self.currentView = "network"
                return
            end

            -- Sort buttons
            local sortX = self.width - 19
            if x >= sortX + 6 and x <= sortX + 11 then
                self.sortBy = "name"
            elseif x >= sortX + 12 and x <= sortX + 18 then
                self.sortBy = "count"
            end
        elseif self.currentView == "network" then
            -- Storage link
            if x >= 2 and x <= 8 then
                self.currentView = "storage"
                return
            end
        end
    end

    -- Letter filter
    local letterFilterY = self.height - 15
    if y == letterFilterY then
        if self.currentLetter then
            local filterText = "[X] " .. self.currentLetter:upper()
            local startX = math.max(1, math.floor((self.width - #filterText) / 2) + 1)
            if x >= startX and x <= startX + 2 then
                self.currentLetter = nil
                self.currentPage = 1
            end
        else
            local totalLength = 27
            local startX = math.max(1, math.floor((self.width - totalLength) / 2) + 1)
            local relativeX = x - startX + 1

            if relativeX == 1 then
                self.currentLetter = "#"
                self.currentPage = 1
            elseif relativeX >= 2 and relativeX <= 27 then
                self.currentLetter = string.char(96 + relativeX - 1)
                self.currentPage = 1
            end
        end
    end

    -- Pagination
    local paginationY = self.height - 13
    if y == paginationY then
        local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()
        local startY = 3
        local endY = self.height - 19
        local maxRows = endY - startY + 1
        local itemsPerPage = maxRows * 2
        local totalPages = math.ceil(#items / itemsPerPage)

        if totalPages > 1 then
            local paginationStr = string.format("Page %d/%d", self.currentPage, totalPages)
            local hasLeft = self.currentPage > 1
            local hasRight = self.currentPage < totalPages

            if hasLeft and hasRight then
                paginationStr = "< " .. paginationStr .. " >"
            elseif hasLeft then
                paginationStr = "< " .. paginationStr
            elseif hasRight then
                paginationStr = paginationStr .. " >"
            end

            local startX = math.max(0, math.floor((self.width - #paginationStr) / 2))

            if hasLeft and x >= startX and x <= startX + 1 then
                self.currentPage = self.currentPage - 1
            elseif hasRight and x >= startX + #paginationStr - 1 and x <= startX + #paginationStr then
                self.currentPage = self.currentPage + 1
            end
        end
    end

    -- Network page clicks
    if self.currentView == "network" then
        -- Add connection button
        if y == 9 and x >= 4 and x <= 19 then
            if #self.connectionName == 0 then
                self.showWarningModal = true
                self.warningMessage = "Please enter a connection name before adding."
            else
                -- Start pairing process
                self:startPairingProcess()
            end
            return
        end

        -- Text box click (for keyboard input in real implementation)
        -- Note: In ComputerCraft, text input would need os.pullEvent("char") handling
        -- For now, this is a placeholder
        return
    end

    -- Item clicks (open order modal)
    local startY = 3
    local endY = self.height - 19
    if y >= startY and y <= endY then
        local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()
        local maxRows = endY - startY + 1
        local itemsPerPage = maxRows * 2
        local startIdx = (self.currentPage - 1) * itemsPerPage + 1
        local endIdx = math.min(startIdx + itemsPerPage - 1, #items)

        -- Build row/column mapping
        local rowItems = {}
        for i = startIdx, endIdx do
            local item = items[i]
            local itemOffset = i - startIdx
            local leftColumnItems = math.ceil((endIdx - startIdx + 1) / 2)

            local row, column
            if itemOffset < leftColumnItems then
                column = "left"
                row = itemOffset + 1
            else
                column = "right"
                row = itemOffset - leftColumnItems + 1
            end

            if row >= 1 and row <= maxRows then
                if not rowItems[row] then
                    rowItems[row] = {}
                end
                rowItems[row][column] = item
            end
        end

        -- Check which item was clicked
        local clickedRow = y - startY + 1
        local columnWidth = math.floor(self.width / 2)

        if rowItems[clickedRow] then
            local clickedItem = nil

            if x <= columnWidth and rowItems[clickedRow].left then
                clickedItem = rowItems[clickedRow].left
            elseif x > columnWidth and rowItems[clickedRow].right then
                clickedItem = rowItems[clickedRow].right
            end

            if clickedItem then
                self.selectedItem = clickedItem
                self.orderAmount = 1
                self.selectedLocation = "local"
                self.showOrderModal = true
                return
            end
        end
    end
end

function MonitorService:submitOrder()
    if not self.selectedItem then return end

    -- Log the order
    self.logger:info("MonitorService", string.format(
        "Order: %s x%d to %s",
        self.selectedItem.key,
        self.orderAmount,
        self.selectedLocation
    ))

    -- Withdraw to output chest if location is local
    if self.selectedLocation == "local" then
        if self.context.services and self.context.services.storage then
            local withdrawn = self.context.services.storage:withdraw(
                self.selectedItem.key,
                self.orderAmount
            )

            if withdrawn > 0 then
                self.logger:info("MonitorService", string.format(
                    "Withdrew %d x %s to output chest",
                    withdrawn,
                    self.selectedItem.key
                ))
            else
                self.logger:warn("MonitorService", string.format(
                    "Failed to withdraw %s",
                    self.selectedItem.key
                ))
            end
        end
    else
        -- TODO: Implement remote withdrawal via rednet
        self.logger:warn("MonitorService", "Remote withdrawal not yet implemented")
    end
end

function MonitorService:sendCraftRequest(itemName, amount, autocraft)
    -- Find turtle computer ID (for now, broadcast to any turtle)
    -- TODO: In production, should track registered turtle IDs
    local message = {
        action = "craft_request",
        item_name = itemName,
        amount = amount,
        autocraft = autocraft
    }

    -- Broadcast craft request
    if rednet.isOpen() then
        rednet.broadcast(message)
        self.logger:info("MonitorService", string.format(
            "Sent craft request: %s x%d (autocraft: %s)",
            itemName,
            amount,
            tostring(autocraft)
        ))
    else
        self.logger:error("MonitorService", "Rednet not open, cannot send craft request")
    end
end

function MonitorService:requestRecipeMode(itemName)
    self.logger:info("MonitorService", "requestRecipeMode called for: " .. tostring(itemName))

    -- Send request to turtle to enter recipe save mode
    local message = {
        action = "enter_recipe_mode",
        item_name = itemName
    }

    -- Check if any rednet modem is open
    local openSides = {}
    for _, side in ipairs({"left", "right", "top", "bottom", "front", "back"}) do
        if rednet.isOpen(side) then
            table.insert(openSides, side)
        end
    end

    if #openSides > 0 then
        rednet.broadcast(message)
        self.logger:info("MonitorService", string.format(
            "Broadcasting recipe mode request for '%s' on sides: %s",
            itemName,
            table.concat(openSides, ", ")
        ))
    else
        self.logger:error("MonitorService", "No rednet modems open! Cannot send recipe mode request.")
        self.logger:error("MonitorService", "Make sure a wireless modem is attached and rednet is open.")
    end
end

-- ============================================================================
-- PAIRING SYSTEM
-- ============================================================================

function MonitorService:generatePairingCode()
    -- Get computer ID
    local computerID = os.getComputerID()

    -- Generate random 4-digit verification code
    local verificationCode = math.random(1000, 9999)

    -- Combine: computerID + verificationCode
    local combined = tostring(computerID) .. string.format("%04d", verificationCode)

    -- Simple encryption: XOR each digit with a rotating key based on current time
    local timeKey = math.floor(os.epoch("utc") / 30000) % 10  -- Changes every 30 seconds
    local encrypted = ""

    for i = 1, #combined do
        local digit = tonumber(combined:sub(i, i))
        local key = (timeKey + i - 1) % 10
        local encryptedDigit = (digit + key) % 10
        encrypted = encrypted .. tostring(encryptedDigit)
    end

    return encrypted, verificationCode
end

function MonitorService:decryptPairingCode(encryptedCode)
    -- Get time key (same as encryption)
    local timeKey = math.floor(os.epoch("utc") / 30000) % 10

    -- Decrypt: reverse XOR operation
    local decrypted = ""

    for i = 1, #encryptedCode do
        local encryptedDigit = tonumber(encryptedCode:sub(i, i))
        local key = (timeKey + i - 1) % 10
        local digit = (encryptedDigit - key) % 10
        if digit < 0 then digit = digit + 10 end
        decrypted = decrypted .. tostring(digit)
    end

    -- Split: last 4 digits are verification code, rest is computer ID
    if #decrypted < 5 then return nil, nil end

    local computerID = tonumber(decrypted:sub(1, #decrypted - 4))
    local verificationCode = tonumber(decrypted:sub(#decrypted - 3))

    return computerID, verificationCode
end

function MonitorService:startPairingProcess()
    -- Generate pairing code
    local code, verificationCode = self:generatePairingCode()

    self.pairingState = "waiting_response"
    self.currentPairingCode = code
    self.pairingVerificationCode = verificationCode
    self.pairingCodeExpiry = os.epoch("utc") / 1000 + 30

    self.logger:info("MonitorService", "Pairing process started with code: " .. code)
end

function MonitorService:cancelPairing()
    self.pairingState = "idle"
    self.currentPairingCode = nil
    self.pairingVerificationCode = nil
    self.pairingCodeExpiry = 0

    self.logger:info("MonitorService", "Pairing cancelled")
end

function MonitorService:rotatePairingCode()
    if self.pairingState == "waiting_response" then
        local code, verificationCode = self:generatePairingCode()
        self.currentPairingCode = code
        self.pairingVerificationCode = verificationCode
        self.pairingCodeExpiry = os.epoch("utc") / 1000 + 30

        self.logger:info("MonitorService", "Pairing code rotated: " .. code)
    end
end

function MonitorService:sendPairRequest(encryptedCode)
    -- Decrypt the code
    local targetComputerID, verificationCode = self:decryptPairingCode(encryptedCode)

    if not targetComputerID or not verificationCode then
        self.logger:warn("MonitorService", "Invalid pairing code")
        return false
    end

    -- Send pair request via rednet
    local message = {
        type = "pair_request",
        senderID = os.getComputerID(),
        senderName = os.getComputerLabel() or "Computer " .. os.getComputerID(),
        verificationCode = verificationCode
    }

    rednet.send(targetComputerID, message, "storage_pairing")

    self.logger:info("MonitorService", string.format(
        "Pair request sent to computer %d with code %d",
        targetComputerID, verificationCode
    ))

    return true
end

function MonitorService:acceptPairRequest()
    if not self.incomingPairRequest then return end

    -- Add to paired computers
    table.insert(self.pairedComputers, {
        computerID = self.incomingPairRequest.computerID,
        computerName = self.incomingPairRequest.computerName,
        customName = self.connectionName or "Unnamed"
    })

    -- Save to disk
    self:savePairedComputers()

    -- Send acceptance response
    local message = {
        type = "pair_accept",
        senderID = os.getComputerID(),
        senderName = os.getComputerLabel() or "Computer " .. os.getComputerID()
    }

    rednet.send(self.incomingPairRequest.computerID, message, "storage_pairing")

    self.logger:info("MonitorService", string.format(
        "Pair request accepted from computer %d",
        self.incomingPairRequest.computerID
    ))

    -- Clear state
    self.incomingPairRequest = nil
    self.pairingState = "idle"
    self.connectionName = ""
end

function MonitorService:denyPairRequest()
    if not self.incomingPairRequest then return end

    -- Send denial response
    local message = {
        type = "pair_deny",
        senderID = os.getComputerID()
    }

    rednet.send(self.incomingPairRequest.computerID, message, "storage_pairing")

    self.logger:info("MonitorService", string.format(
        "Pair request denied from computer %d",
        self.incomingPairRequest.computerID
    ))

    -- Clear state
    self.incomingPairRequest = nil
    self.pairingState = "idle"
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

function MonitorService:initializeVisualizer()
    local pools = self.context.scheduler:getPools()

    for poolName, pool in pairs(pools) do
        local upperName = poolName:upper()
        self.visualizer.pools[upperName] = {
            name = upperName,
            workers = {},
            color = self.visualizer.colors[upperName] or colors.white
        }

        local workerCount = math.min(pool.size, 4)
        for i = 1, workerCount do
            self.visualizer.pools[upperName].workers[i] = {
                id = i,
                stack = {},
                idle = true
            }
        end
    end
end

function MonitorService:onTaskStart(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if not pool or not pool.workers[data.worker] then
        return
    end

    local worker = pool.workers[data.worker]
    worker.idle = false

    local taskType = data.taskType or "generic"
    local barColor = self.visualizer.taskColors[taskType] or colors.white

    table.insert(worker.stack, 1, {
        color = barColor,
        type = "start",
        taskType = taskType,
        time = os.epoch("utc") / 1000
    })
end

function MonitorService:onTaskEnd(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]

        local taskType = data.taskType or "generic"
        local barColor = self.visualizer.taskColors[taskType] or colors.lime

        table.insert(worker.stack, 1, {
            color = barColor,
            type = "end",
            taskType = taskType,
            time = os.epoch("utc") / 1000
        })

        worker.idle = true
    end
end

function MonitorService:onItemAdded(data)
    local itemKey = data.key or data.item
    self.itemColors[itemKey] = "new"
    self.itemTimers[itemKey] = os.epoch("utc") / 1000
end

function MonitorService:onItemUpdated(data)
    local itemName = data.key or data.item
    if self.itemColors[itemName] ~= "new" then
        self.itemColors[itemName] = "updated"
        self.itemTimers[itemName] = os.epoch("utc") / 1000
    end
end

function MonitorService:onIndexRebuilt(data)
    -- Just log, cache will be refreshed by background thread
    self.logger:info("MonitorService", string.format(
        "Index rebuilt: %d unique items, %d stacks",
        data.uniqueItems or 0, data.totalStacks or 0
    ))
end

function MonitorService:stop()
    self.running = false
    self.logger:info("MonitorService", "Service stopped")
end

return MonitorService
