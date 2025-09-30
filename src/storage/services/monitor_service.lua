local MonitorService = {}
MonitorService.__index = MonitorService

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

    o.width, o.height = o.monitor.getSize()
    o.running = false

    -- UI state
    o.currentLetter = nil  -- nil means show all, "#" for special chars, "a"-"z" for letters
    o.currentPage = 1
    o.itemsPerPage = o.height - 17  -- Header (1) + Letter filter (1) + Column header (1) + Visualizer (11) + I/O (1) + spacing (2)
    o.sortBy = "name"
    o.scrollOffset = 0

    -- Item display state
    o.itemColors = {}  -- Track color states for items
    o.itemTimers = {}   -- Track when to reset colors

    -- Visualizer state with proper labels
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
        }
    }

    -- Load I/O configuration
    o.inputSide = "right"
    o.outputSide = "left"
    self:loadIOConfig()

    -- Item cache to persist data between renders
    o.itemCache = {}
    o.cacheLastUpdate = 0

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

    self.logger:info("MonitorService", "Service started")
end

function MonitorService:stackDecayLoop()
    while self.running do
        -- Remove old stack items
        local now = os.epoch("utc") / 1000
        local changed = false

        for poolName, pool in pairs(self.visualizer.pools) do
            for _, worker in ipairs(pool.workers) do
                local newStack = {}
                for _, item in ipairs(worker.stack) do
                    if now - item.time < 5 then  -- Keep items less than 5 seconds old (increased from 1)
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
            if now - colorTime > 2 then  -- Increased from 1 to 2 seconds
                self.itemColors[itemName] = nil
                self.itemTimers[itemName] = nil
                changed = true
            end
        end

        if changed then
            -- Don't need to render here since render loop handles it
            -- self:render()
        end

        os.sleep(0.1)
    end
end

function MonitorService:run()
    local processes = {}

    -- Render loop
    table.insert(processes, function()
        while self.running do
            self:render()
            os.sleep(0.1)
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

function MonitorService:render()
    -- Refresh cache every render to ensure we have latest data
    self:refreshCache()

    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clear()

    -- Modern minimalist header
    self:drawHeader()

    -- Table column headers
    self:drawTableHeaders()

    -- Letter filter navigation
    self:drawLetterFilter()

    -- Items table
    self:drawItemsTable()

    -- Pagination (always show if multiple pages)
    self:drawPagination()

    -- Visualizer at bottom
    self:drawVisualizer()

    -- I/O indicators at very bottom
    self:drawIOIndicators()
end

function MonitorService:drawHeader()
    self.monitor.setCursorPos(1, 1)
    self.monitor.setBackgroundColor(colors.gray)
    self.monitor.clearLine()
    self.monitor.setTextColor(colors.white)

    -- Get total item count
    local items = self:getAllItems()
    local uniqueCount = #items

    -- Left side: Title
    self.monitor.setCursorPos(2, 1)
    self.monitor.write(string.format("STORAGE | %d Items", uniqueCount))

    -- Right side: Sort buttons
    local sortX = self.width - 18
    self.monitor.setCursorPos(sortX, 1)
    self.monitor.setTextColor(colors.lightGray)
    self.monitor.write("Sort:")

    -- Name sort button
    self.monitor.setCursorPos(sortX + 6, 1)
    if self.sortBy == "name" then
        self.monitor.setTextColor(colors.lime)
        self.monitor.write("[Name]")
    else
        self.monitor.setTextColor(colors.white)
        self.monitor.write(" Name ")
    end

    -- Count sort button
    self.monitor.setCursorPos(sortX + 12, 1)
    if self.sortBy == "count" then
        self.monitor.setTextColor(colors.lime)
        self.monitor.write("[Count]")
    else
        self.monitor.setTextColor(colors.white)
        self.monitor.write(" Count ")
    end

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawLetterFilter()
    self.monitor.setCursorPos(1, 2)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clearLine()

    if self.currentLetter then
        -- Show back button when filtered
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("[X]")
        self.monitor.setTextColor(colors.white)
        self.monitor.write(" " .. self.currentLetter:upper())
    else
        -- Show letter navigation
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("#")

        for i = 1, 26 do
            local letter = string.char(96 + i)  -- a-z
            self.monitor.setTextColor(colors.lightGray)
            self.monitor.write(letter)
        end
    end

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawTableHeaders()
    self.monitor.setCursorPos(1, 3)
    self.monitor.setBackgroundColor(colors.gray)
    self.monitor.clearLine()
    self.monitor.setTextColor(colors.white)

    -- Two-column layout
    local columnWidth = math.floor(self.width / 2)
    local nameWidth = columnWidth - 13  -- Space for name in each column
    local countWidth = 6
    local stacksWidth = 6

    -- Left column header
    self.monitor.setCursorPos(2, 3)
    self.monitor.write("ITEM")
    self.monitor.setCursorPos(nameWidth + 2, 3)
    self.monitor.write("COUNT")
    self.monitor.setCursorPos(nameWidth + countWidth + 3, 3)
    self.monitor.write("STACKS")

    -- Right column header
    self.monitor.setCursorPos(columnWidth + 2, 3)
    self.monitor.write("ITEM")
    self.monitor.setCursorPos(columnWidth + nameWidth + 2, 3)
    self.monitor.write("COUNT")
    self.monitor.setCursorPos(columnWidth + nameWidth + countWidth + 3, 3)
    self.monitor.write("STACKS")

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawItemsTable()
    -- Use filtered items if a letter is selected
    local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

    if #items == 0 then
        self.monitor.setCursorPos(math.floor(self.width / 2) - 5, math.floor(self.height / 2))
        self.monitor.setBackgroundColor(colors.black)
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("NO ITEMS")
        return
    end

    -- Two-column layout
    local columnWidth = math.floor(self.width / 2)
    local nameWidth = columnWidth - 13
    local countWidth = 6
    local stacksWidth = 6

    -- Calculate available rows (from line 4 to line before pagination)
    local startY = 4
    local paginationY = self.height - 12
    local maxRows = paginationY - startY

    -- Calculate items per page (rows per column * 2 columns)
    local itemsPerPage = maxRows * 2
    local startIdx = (self.currentPage - 1) * itemsPerPage + 1
    local endIdx = math.min(startIdx + itemsPerPage - 1, #items)

    -- Clear all item rows first
    for y = startY, paginationY - 1 do
        self.monitor.setCursorPos(1, y)
        self.monitor.setBackgroundColor(colors.black)
        self.monitor.clearLine()
    end

    -- Draw items, favoring left column (fill left completely before moving to right)
    for i = startIdx, endIdx do
        local item = items[i]
        local itemOffset = i - startIdx

        -- Split evenly: left column gets ceiling, right gets floor
        local leftColumnItems = math.ceil((endIdx - startIdx + 1) / 2)

        local row, column
        if itemOffset < leftColumnItems then
            -- Left column
            column = 0
            row = itemOffset
        else
            -- Right column
            column = 1
            row = itemOffset - leftColumnItems
        end

        -- Only draw if we have space
        if row < maxRows then
            local y = startY + row
            local xOffset = column * columnWidth

            -- Alternating background colors for rows
            local bgColor = (row % 2 == 0) and colors.lightGray or colors.white

            -- Clear the section for this item
            self.monitor.setCursorPos(xOffset + 1, y)
            self.monitor.setBackgroundColor(bgColor)
            self.monitor.write(string.rep(" ", columnWidth))

            -- Item name
            self.monitor.setCursorPos(xOffset + 2, y)
            self.monitor.setTextColor(colors.black)
            local name = item.key:match("([^:]+)$") or item.key
            if #name > nameWidth - 1 then
                name = name:sub(1, nameWidth - 3) .. "..."
            end
            self.monitor.write(name)

            -- Count (in lime color)
            local count = item.value and item.value.count or 0
            local countStr = tostring(count)
            if #countStr > countWidth then
                countStr = countStr:sub(1, countWidth)
            end
            self.monitor.setCursorPos(xOffset + nameWidth + 2, y)
            self.monitor.setTextColor(colors.lime)
            self.monitor.write(countStr)

            -- Stacks (in orange color)
            local stackSize = item.value and item.value.stackSize or 64
            local stacks = math.ceil(count / stackSize)
            local stackStr = tostring(stacks)
            if #stackStr > stacksWidth then
                stackStr = stackStr:sub(1, stacksWidth)
            end
            self.monitor.setCursorPos(xOffset + nameWidth + countWidth + 3, y)
            self.monitor.setTextColor(colors.orange)
            self.monitor.write(stackStr)
        end
    end

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawPagination()
    -- Use filtered items if a letter is selected
    local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

    -- Calculate items per page dynamically based on available rows
    local startY = 4
    local paginationY = self.height - 12
    local maxRows = paginationY - startY
    local itemsPerPage = maxRows * 2  -- Two columns

    local totalPages = math.ceil(#items / itemsPerPage)

    if totalPages <= 1 then return end

    -- Draw pagination at paginationY (just above the separator line)

    -- Clear the line first
    self.monitor.setCursorPos(1, paginationY)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clearLine()

    self.monitor.setTextColor(colors.gray)

    -- Build simple, clean pagination string
    local paginationStr = string.format("Page %d/%d", self.currentPage, totalPages)

    -- Add navigation hints
    if self.currentPage > 1 and self.currentPage < totalPages then
        paginationStr = "< " .. paginationStr .. " >"
    elseif self.currentPage > 1 then
        paginationStr = "< " .. paginationStr
    elseif self.currentPage < totalPages then
        paginationStr = paginationStr .. " >"
    end

    -- Center the pagination
    local x = math.max(1, math.floor((self.width - #paginationStr) / 2) + 1)
    self.monitor.setCursorPos(x, paginationY)
    self.monitor.write(paginationStr)
end

function MonitorService:drawAllItems()
    local items = self:getAllItems()
    local startY = 4

    self.logger:debug("MonitorService", string.format("drawAllItems: rendering %d items", #items))

    if #items == 0 then
        self.monitor.setCursorPos(math.floor(self.width / 2) - 5, math.floor(self.height / 2))
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("NO ITEMS")
        self.logger:debug("MonitorService", "Drawing 'NO ITEMS' message")
        return
    end

    self:drawItemList(items, startY)
end

function MonitorService:drawFilteredItems()
    local items = self:getFilteredItems()
    local startY = 4

    if #items == 0 then
        self.monitor.setCursorPos(math.floor(self.width / 2) - 5, math.floor(self.height / 2))
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("NO ITEMS")
        return
    end

    -- Calculate page items
    local startIdx = (self.currentPage - 1) * self.itemsPerPage + 1
    local endIdx = math.min(startIdx + self.itemsPerPage - 1, #items)

    local pageItems = {}
    for i = startIdx, endIdx do
        table.insert(pageItems, items[i])
    end

    self:drawItemList(pageItems, startY)
end

function MonitorService:drawItemList(items, startY)
    local colorToggle = false

    for i, item in ipairs(items) do
        local y = startY + i - 1
        if y > self.height - 12 then break end

        self.monitor.setCursorPos(1, y)

        -- Determine color
        local itemColor = colors.white
        if self.itemColors[item.key] == "new" then
            itemColor = colors.orange
        elseif self.itemColors[item.key] == "updated" then
            itemColor = colors.blue
        else
            itemColor = colorToggle and colors.white or colors.lightGray
            colorToggle = not colorToggle
        end

        self.monitor.setTextColor(itemColor)

        -- Item name
        local name = item.key:match("([^:]+)$") or item.key
        if #name > 30 then
            name = name:sub(1, 27) .. "..."
        end
        self.monitor.write(name)

        -- Item count
        local count = item.value and item.value.count or 0
        local countStr = tostring(count)
        self.monitor.setCursorPos(self.width - #countStr - 10, y)
        self.monitor.setTextColor(colors.green)
        self.monitor.write(countStr)

        -- Stack indicator
        local stackSize = item.value and item.value.stackSize or 64
        local stacks = math.ceil(count / stackSize)
        local stackStr = "[" .. stacks .. "]"
        self.monitor.setCursorPos(self.width - #stackStr, y)
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write(stackStr)
    end
end

function MonitorService:drawVisualizer()
    local startY = self.height - 11

    -- Draw separator
    self.monitor.setCursorPos(1, startY)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.setTextColor(colors.gray)
    self.monitor.write(string.rep("-", self.width))

    startY = startY + 1

    -- Calculate total width needed for all pools
    local totalWidth = 0
    local poolOrder = {}
    for poolName, pool in pairs(self.visualizer.pools) do
        table.insert(poolOrder, {name = poolName, pool = pool})
        totalWidth = totalWidth + (#pool.workers * 2) + 2
    end
    totalWidth = totalWidth - 2  -- Remove extra spacing after last pool

    -- Center the visualizer and shift left by 1 (was +5, now -1)
    local startX = math.floor((self.width - totalWidth) / 2) - 1
    local x = startX

    -- Draw each pool with labels
    for _, entry in ipairs(poolOrder) do
        local poolName = entry.name
        local pool = entry.pool

        if x + (#pool.workers * 2) > self.width then break end

        -- Draw stacks
        for w, worker in ipairs(pool.workers) do
            local stackX = x + (w - 1) * 2

            -- Draw stack from bottom up
            for h = 1, math.min(#worker.stack, self.visualizer.maxHeight - 2) do
                local stackY = startY + self.visualizer.maxHeight - 2 - h
                local stackItem = worker.stack[h]

                if stackItem then
                    self.monitor.setCursorPos(stackX, stackY)
                    self.monitor.setTextColor(stackItem.color)
                    self.monitor.write("\138")
                end
            end

            -- Draw worker number
            self.monitor.setCursorPos(stackX, startY + self.visualizer.maxHeight - 2)
            self.monitor.setTextColor(pool.color)
            self.monitor.write(tostring(w))
        end

        -- Draw pool label
        local label = self.visualizer.labels[poolName] or poolName
        local labelX = x + math.floor((#pool.workers * 2 - #label) / 2)
        self.monitor.setCursorPos(labelX, startY + self.visualizer.maxHeight - 1)
        self.monitor.setTextColor(pool.color)
        self.monitor.write(label)

        x = x + (#pool.workers * 2) + 2
    end
end

function MonitorService:drawIOIndicators()
    local y = self.height

    -- Input indicator
    if self.inputSide == "left" then
        self.monitor.setCursorPos(1, y)
    else
        self.monitor.setCursorPos(self.width - 5, y)
    end
    self.monitor.setTextColor(colors.lime)
    self.monitor.write("INPUT")

    -- Output indicator
    if self.outputSide == "left" then
        self.monitor.setCursorPos(1, y)
    else
        self.monitor.setCursorPos(self.width - 6, y)
    end
    self.monitor.setTextColor(colors.red)
    self.monitor.write("OUTPUT")
end

function MonitorService:initializeVisualizer()
    local pools = self.context.scheduler:getPools()

    for poolName, pool in pairs(pools) do
        local upperName = poolName:upper()
        self.visualizer.pools[upperName] = {
            name = upperName,
            workers = {},
            color = self.visualizer.colors[upperName] or colors.white
        }

        for i = 1, math.min(pool.size, 4) do
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

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]
        worker.idle = false

        table.insert(worker.stack, 1, {
            color = colors.white,
            type = "start",
            time = os.epoch("utc") / 1000
        })
    end
end

function MonitorService:onTaskEnd(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]

        table.insert(worker.stack, 1, {
            color = colors.lime,
            type = "end",
            time = os.epoch("utc") / 1000
        })

        worker.idle = true
    end
end

function MonitorService:onItemAdded(data)
    local itemKey = data.key or data.item
    self.itemColors[itemKey] = "new"
    self.itemTimers[itemKey] = os.epoch("utc") / 1000

    -- Update cache
    self:refreshCache()
end

function MonitorService:onItemUpdated(data)
    local itemName = data.key or data.item
    if self.itemColors[itemName] ~= "new" then
        self.itemColors[itemName] = "updated"
        self.itemTimers[itemName] = os.epoch("utc") / 1000
    end

    -- Update cache
    self:refreshCache()
end

function MonitorService:onIndexRebuilt(data)
    self.logger:info("MonitorService", "=== RECEIVED storage.indexRebuilt EVENT ===")
    self.logger:info("MonitorService", string.format(
        "Index rebuilt: %d unique items, %d stacks",
        data.uniqueItems or 0, data.totalStacks or 0
    ))

    -- Force cache refresh
    self:refreshCache()

    -- Verify we can actually get items
    local items = self:getAllItems()
    self.logger:info("MonitorService", string.format("getAllItems() returned %d items (from cache: %d)",
        #items, #self.itemCache))

    if #items > 0 then
        self.logger:info("MonitorService", "Sample items:")
        for i = 1, math.min(3, #items) do
            self.logger:info("MonitorService", string.format("  %d. %s (count: %d)",
                i, items[i].key, items[i].value and items[i].value.count or 0))
        end
    else
        self.logger:warn("MonitorService", "NO ITEMS returned from getAllItems()!")
    end

    -- Force a render to show the updated items
    if self.running then
        self.logger:info("MonitorService", "Triggering render...")
        self:render()
    else
        self.logger:warn("MonitorService", "Not rendering - monitor not running yet")
    end
end

function MonitorService:refreshCache()
    -- Refresh cache from storage service
    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()
        self.itemCache = items
        self.cacheLastUpdate = os.epoch("utc") / 1000
        self.logger:debug("MonitorService", string.format("Cache refreshed: %d items", #self.itemCache))
    end
end

function MonitorService:updateCache(items, uniqueCount)
    -- Direct cache update from storage service (bypasses event bus)
    self.logger:info("MonitorService", string.format(
        "RECEIVING SYNC: %d items, %d unique (cache had %d)",
        #items, uniqueCount or 0, #self.itemCache
    ))

    self.itemCache = items
    self.cacheLastUpdate = os.epoch("utc") / 1000

    self.logger:info("MonitorService", string.format(
        "Cache updated via direct sync: %d items stored", #self.itemCache
    ))

    -- Log sample items if any
    if #self.itemCache > 0 then
        for i = 1, math.min(3, #self.itemCache) do
            local item = self.itemCache[i]
            self.logger:info("MonitorService", string.format(
                "  Sample %d: %s (count: %d)",
                i, item.key or "unknown", item.value and item.value.count or 0
            ))
        end
    else
        self.logger:error("MonitorService", "Cache is EMPTY after sync!")
    end
end

function MonitorService:getAllItems()
    self.logger:info("MonitorService", string.format(
        "getAllItems called: cache has %d items", #self.itemCache
    ))

    -- Use cached items if available
    if #self.itemCache > 0 then
        local items = self.itemCache
        self.logger:info("MonitorService", string.format("Using cached items: %d", #items))

        -- Sort items
        table.sort(items, function(a, b)
            if self.sortBy == "count" then
                return (a.value.count or 0) > (b.value.count or 0)
            else
                return a.key < b.key
            end
        end)

        return items
    end

    -- Fallback: try to get from storage service
    self.logger:warn("MonitorService", "Cache is empty, trying storage service...")

    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()

        self.logger:info("MonitorService", string.format(
            "Storage service returned %d items (cache was empty)", #items
        ))

        -- Update cache
        if #items > 0 then
            self.itemCache = items
            self.cacheLastUpdate = os.epoch("utc") / 1000
        end

        -- Sort items
        table.sort(items, function(a, b)
            if self.sortBy == "count" then
                return (a.value.count or 0) > (b.value.count or 0)
            else
                return a.key < b.key
            end
        end)

        return items
    else
        self.logger:error("MonitorService", "Storage service not available and cache is empty!")
        return {}
    end
end

function MonitorService:getFilteredItems()
    local items = self:getAllItems()
    local filtered = {}

    for _, item in ipairs(items) do
        local firstChar = item.key:sub(1, 1):lower()
        local match = false

        if self.currentLetter == "#" then
            -- Special characters
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

function MonitorService:handleClick(x, y)
    -- Header: Sort buttons
    if y == 1 then
        local sortX = self.width - 18
        -- Name sort button (positions sortX+6 to sortX+11)
        if x >= sortX + 6 and x <= sortX + 11 then
            self.sortBy = "name"
        -- Count sort button (positions sortX+12 to sortX+18)
        elseif x >= sortX + 12 and x <= sortX + 18 then
            self.sortBy = "count"
        end
    end

    -- Letter navigation (line 2)
    if y == 2 then
        if self.currentLetter then
            -- Click [X] to go back (positions 1-3)
            if x >= 1 and x <= 3 then
                self.currentLetter = nil
                self.currentPage = 1
            end
        else
            -- Click on letters to filter
            if x == 1 then
                self.currentLetter = "#"
                self.currentPage = 1
            elseif x >= 2 and x <= 27 then
                self.currentLetter = string.char(96 + x - 1)
                self.currentPage = 1
            end
        end
    end

    -- Pagination clicks
    local paginationY = self.height - 12
    if y == paginationY then
        local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

        -- Calculate items per page dynamically
        local startY = 4
        local maxRows = paginationY - startY
        local itemsPerPage = maxRows * 2  -- Two columns
        local totalPages = math.ceil(#items / itemsPerPage)

        -- Check if pagination is being displayed
        if totalPages > 1 then
            -- Previous page (left side, clicking "<")
            if x <= 5 and self.currentPage > 1 then
                self.currentPage = self.currentPage - 1
            -- Next page (right side, clicking ">")
            elseif x >= self.width - 5 and self.currentPage < totalPages then
                self.currentPage = self.currentPage + 1
            end
        end
    end
end

function MonitorService:stop()
    self.running = false
    self.logger:info("MonitorService", "Service stopped")
end

return MonitorService