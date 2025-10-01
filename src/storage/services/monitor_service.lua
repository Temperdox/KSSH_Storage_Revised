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
    o.currentLetter = nil
    o.currentPage = 1
    o.sortBy = "name"
    o.showStatsModal = false

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

    return o
end

function MonitorService:loadIOConfig()
    local configPath = "/storage/cfg/io_config.json"
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
    end)

    self.eventBus:subscribe("index.updated", function(event, data)
        self:onItemUpdated(data)
    end)

    self.eventBus:subscribe("storage.indexRebuilt", function(event, data)
        self:onIndexRebuilt(data)
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

    if self.showStatsModal then
        -- When modal is open, draw everything then overlay modal
        self:drawBaseUI()
        self:drawStatsModal()
    else
        -- Normal rendering
        self:drawBaseUI()
    end

    -- Flush complete frame to screen (single operation, no flicker)
    self.frameBuffer:flush(self.monitor)
end

function MonitorService:drawBaseUI()
    -- Draw all base UI elements to frame buffer
    self:drawHeader()
    self:drawTableHeaders()
    self:drawItemsTable()
    self:drawProgressBar()
    self:drawLetterFilter()
    self:drawPagination()
    self:drawSeparator()
    self:drawVisualizer()
    self:drawIOIndicators()
end

-- ============================================================================
-- UI COMPONENTS
-- ============================================================================

function MonitorService:drawHeader()
    -- Build header line
    local title = " STORAGE | [Stats]"

    -- Sort buttons
    local sortX = self.width - 19
    local sortText = "Sort: "
    if self.sortBy == "name" then
        sortText = sortText .. "[Name]  Count "
    else
        sortText = sortText .. " Name  [Count]"
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
            self.frameBuffer:writeText(xOffset + nameWidth + 3, y, countStr, colors.lime, bgColor)

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
            self.frameBuffer:writeText(xOffset + nameWidth + 3, y, countStr, colors.lime, bgColor)

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

-- ============================================================================
-- DATA MANAGEMENT
-- ============================================================================

function MonitorService:refreshCache()
    -- Update item cache from storage service
    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()
        self.itemCache = items
        self.cacheLastUpdate = os.epoch("utc") / 1000
    end
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

    -- Header clicks
    if y == 1 then
        -- Stats link
        if x >= 12 and x <= 18 then
            self.showStatsModal = true
            return
        end

        -- Sort buttons
        local sortX = self.width - 19
        if x >= sortX + 6 and x <= sortX + 11 then
            self.sortBy = "name"
        elseif x >= sortX + 12 and x <= sortX + 18 then
            self.sortBy = "count"
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
