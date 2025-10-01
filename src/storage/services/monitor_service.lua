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
    -- itemsPerPage calculated dynamically: (height - 19 rows for UI) * 2 columns
    -- Layout for 0.5 scale: Header(1) + TableHeaders(1) + Items(height-19) + Space(1) + ProgressBar(1) + Filter(1) + Pagination(1) + Separator(1) + Visualizer(10) + I/O(1)
    o.sortBy = "name"
    o.scrollOffset = 0
    o.showStatsModal = false  -- Stats modal visibility

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
        },
        taskColors = {
            -- IO tasks
            input_monitor = colors.cyan,
            input_transfer = colors.cyan,
            buffer_process = colors.lightBlue,
            monitor_sync = colors.blue,
            item_move = colors.lime,
            -- Storage tasks
            index_rebuild = colors.yellow,
            item_scan = colors.orange,
            index_update = colors.yellow,
            -- API tasks
            api_request = colors.orange,
            api_response = colors.red,
            -- Test tasks
            test_run = colors.pink,
            test_check = colors.magenta,
            -- Stats tasks
            uptime_check = colors.green,
            stats_save = colors.lime,
            -- Sound tasks
            play_sound = colors.purple,
            -- Generic
            generic = colors.white,
            error = colors.red
        },
        taskSounds = {
            -- IO tasks - higher pitched for input/output
            input_monitor = {instrument = "harp", volume = 0.5, pitch = 1.5},
            input_transfer = {instrument = "harp", volume = 0.4, pitch = 1.6},
            buffer_process = {instrument = "bass", volume = 0.5, pitch = 1.0},
            monitor_sync = {instrument = "bell", volume = 0.3, pitch = 0.8},
            item_move = {instrument = "guitar", volume = 0.4, pitch = 1.3},
            -- Storage tasks - mid tones
            index_rebuild = {instrument = "pling", volume = 0.6, pitch = 1.0},
            item_scan = {instrument = "banjo", volume = 0.4, pitch = 1.2},
            index_update = {instrument = "pling", volume = 0.3, pitch = 1.4},
            -- API tasks - distinctive
            api_request = {instrument = "bit", volume = 0.5, pitch = 1.3},
            api_response = {instrument = "bit", volume = 0.5, pitch = 0.7},
            -- Test tasks - playful
            test_run = {instrument = "flute", volume = 0.4, pitch = 1.4},
            test_check = {instrument = "chime", volume = 0.4, pitch = 1.1},
            -- Stats tasks - subtle
            uptime_check = {instrument = "cow_bell", volume = 0.3, pitch = 0.9},
            stats_save = {instrument = "cow_bell", volume = 0.3, pitch = 1.1},
            -- Sound tasks - ironic
            play_sound = {instrument = "didgeridoo", volume = 0.5, pitch = 1.0},
            -- Generic/error
            generic = {instrument = "hat", volume = 0.3, pitch = 1.0},
            error = {instrument = "bass drum", volume = 0.7, pitch = 0.5}
        }
    }

    -- Load I/O configuration
    o.inputSide = "right"
    o.outputSide = "left"
    self:loadIOConfig()

    -- Item cache to persist data between renders (updated by background thread)
    o.itemCache = {}
    o.cacheLastUpdate = 0

    -- Free slots cache (updated by background thread every 2 seconds)
    o.freeSlots = 0
    o.lastFreeSlots = 0

    -- Dirty flags - only redraw when needed
    o.dirty = {
        lists = true,      -- Item lists need redraw
        freeSlots = true,  -- Free slots display needs redraw
        header = true,     -- Header needs redraw
        pagination = true  -- Pagination needs redraw
    }

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

    -- Do initial cache population and screen clear
    self:refreshCache()
    self:updateFreeSlots()
    self.monitor.setTextScale(0.5)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clear()

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

    -- UI RENDER THREAD - Fast, no blocking logic
    table.insert(processes, function()
        while self.running do
            self:renderUI()
            os.sleep(0.05)  -- 20fps UI updates
        end
    end)

    -- CACHE UPDATE THREAD - Updates item cache periodically
    table.insert(processes, function()
        while self.running do
            self:refreshCache()
            os.sleep(0.5)  -- Update cache twice per second
        end
    end)

    -- FREE SLOTS UPDATE THREAD - Expensive peripheral calls
    table.insert(processes, function()
        while self.running do
            self:updateFreeSlots()
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

function MonitorService:renderUI()
    -- PURE UI RENDERING - No expensive logic, just draw from cached state
    -- This runs at 20fps and should never block
    -- Only redraws sections that have changed (dirty flags)

    self.monitor.setBackgroundColor(colors.black)

    -- Header (only when dirty)
    if self.dirty.header then
        self:drawHeader()
        self.dirty.header = false
    end

    -- Table column headers (static, only draw once)
    if self.dirty.lists then
        self:drawTableHeaders()
    end

    -- Items table (only when dirty)
    if self.dirty.lists then
        self:drawItemsTable()
        self.dirty.lists = false
    end

    -- Free slots info (only when dirty)
    if self.dirty.freeSlots then
        self:drawFreeSlots()
        self.dirty.freeSlots = false
    end

    -- Letter filter navigation (only when dirty)
    if self.dirty.lists then
        self:drawLetterFilter()
    end

    -- Pagination (only when dirty)
    if self.dirty.pagination then
        self:drawPagination()
        self.dirty.pagination = false
    end

    -- Visualizer at bottom (always update for animation)
    self:drawVisualizer()

    -- I/O indicators at very bottom (static, draw once on start)
    self:drawIOIndicators()

    -- Stats modal overlay (drawn last, on top of everything)
    if self.showStatsModal then
        self:drawStatsModal()
    end
end

function MonitorService:drawHeader()
    -- Draw entire line at once to avoid flicker
    self.monitor.setCursorPos(1, 1)
    self.monitor.setBackgroundColor(colors.gray)

    -- Build the entire line content
    local line = string.rep(" ", self.width)

    -- Build header content
    local title = " STORAGE | [Stats]"

    -- Right side: Sort buttons
    local sortX = self.width - 19
    local sortText = "Sort: "
    if self.sortBy == "name" then
        sortText = sortText .. "[Name]  Count "
    else
        sortText = sortText .. " Name  [Count]"
    end

    -- Combine into single line
    line = title .. string.rep(" ", sortX - #title - 1) .. sortText

    -- Write entire line in one operation
    self.monitor.setTextColor(colors.white)
    self.monitor.write(line)

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawLetterFilter()
    local y = self.height - 15
    self.monitor.setCursorPos(1, y)
    self.monitor.setBackgroundColor(colors.black)

    -- Build entire line
    local line = string.rep(" ", self.width)

    if self.currentLetter then
        -- Show back button when filtered (centered)
        local filterText = "[X] " .. self.currentLetter:upper()
        local startX = math.max(1, math.floor((self.width - #filterText) / 2))
        line = string.rep(" ", startX) .. filterText .. string.rep(" ", self.width - startX - #filterText)
    else
        -- Show letter navigation (centered)
        local filterText = "#abcdefghijklmnopqrstuvwxyz"
        local startX = math.max(1, math.floor((self.width - #filterText) / 2))
        line = string.rep(" ", startX) .. filterText .. string.rep(" ", self.width - startX - #filterText)
    end

    -- Write entire line
    self.monitor.setTextColor(colors.lightGray)
    self.monitor.write(line)
end

function MonitorService:drawTableHeaders()
    -- Build entire header line
    local columnWidth = math.floor(self.width / 2)
    local nameWidth = columnWidth - 13
    local countWidth = 6

    local line = string.rep(" ", self.width)
    local chars = {}
    for i = 1, self.width do chars[i] = " " end

    -- Left column headers
    local leftHeaders = " ITEM" .. string.rep(" ", nameWidth - 5) .. "COUNT" .. string.rep(" ", countWidth - 4) .. "STACK"
    for i = 1, #leftHeaders do
        chars[i] = leftHeaders:sub(i, i)
    end

    -- Right column headers (offset by +1 for divider)
    local offset = columnWidth + 2
    local rightHeaders = "ITEM" .. string.rep(" ", nameWidth - 5) .. "COUNT" .. string.rep(" ", countWidth - 4) .. "STACK"
    for i = 1, math.min(#rightHeaders, self.width - offset) do
        chars[offset + i] = rightHeaders:sub(i, i)
    end

    line = table.concat(chars)

    -- Write entire line
    self.monitor.setCursorPos(1, 2)
    self.monitor.setBackgroundColor(colors.gray)
    self.monitor.setTextColor(colors.white)
    self.monitor.write(line)
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
    local stacksWidth = 5

    -- Calculate available rows (from line 3 to line before free slots)
    local startY = 3
    local endY = self.height - 19
    local maxRows = endY - startY + 1

    -- Calculate items per page (rows per column * 2 columns)
    local itemsPerPage = maxRows * 2
    local startIdx = (self.currentPage - 1) * itemsPerPage + 1
    local endIdx = math.min(startIdx + itemsPerPage - 1, #items)

    -- Build map of which items go in which row/column
    local rowItems = {}  -- rowItems[row] = {left = item, right = item}
    for i = startIdx, endIdx do
        local item = items[i]
        local itemOffset = i - startIdx

        -- Split evenly: left column gets ceiling, right gets floor
        local leftColumnItems = math.ceil((endIdx - startIdx + 1) / 2)

        local row, column
        if itemOffset < leftColumnItems then
            -- Left column
            column = "left"
            row = itemOffset + 1  -- 1-indexed
        else
            -- Right column
            column = "right"
            row = itemOffset - leftColumnItems + 1  -- 1-indexed
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

        -- Clear entire row with black background first
        self.monitor.setCursorPos(1, y)
        self.monitor.setBackgroundColor(colors.black)
        self.monitor.write(string.rep(" ", self.width))

        -- Alternating background color
        local bgColor = (row % 2 == 0) and colors.lightGray or colors.white

        -- Draw left column item if exists
        if rowItems[row] and rowItems[row].left then
            local item = rowItems[row].left
            local xOffset = 0

            -- Draw background
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
            self.monitor.setCursorPos(xOffset + nameWidth + 3, y)
            self.monitor.setTextColor(colors.lime)
            self.monitor.write(countStr)

            -- Stacks (in orange color)
            local stackSize = item.value and item.value.stackSize or 64
            local stacks = math.ceil(count / stackSize)
            local stackStr = tostring(stacks)
            if #stackStr > stacksWidth then
                stackStr = stackStr:sub(1, stacksWidth)
            end
            self.monitor.setCursorPos(xOffset + nameWidth + countWidth + 4, y)
            self.monitor.setTextColor(colors.orange)
            self.monitor.write(stackStr)
        end

        -- Draw right column item if exists (offset by +1 for divider)
        if rowItems[row] and rowItems[row].right then
            local item = rowItems[row].right
            local xOffset = columnWidth + 1

            -- Draw background (1 char narrower for divider)
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
            self.monitor.setCursorPos(xOffset + nameWidth + 3, y)
            self.monitor.setTextColor(colors.lime)
            self.monitor.write(countStr)

            -- Stacks (in orange color)
            local stackSize = item.value and item.value.stackSize or 64
            local stacks = math.ceil(count / stackSize)
            local stackStr = tostring(stacks)
            if #stackStr > stacksWidth then
                stackStr = stackStr:sub(1, stacksWidth)
            end
            self.monitor.setCursorPos(xOffset + nameWidth + countWidth + 4, y)
            self.monitor.setTextColor(colors.orange)
            self.monitor.write(stackStr)
        end
    end

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:updateFreeSlots()
    -- Calculate total free slots from storage service
    -- Called by background thread every 2 seconds
    local freeSlots = 0
    if self.context.services and self.context.services.storage then
        local storageService = self.context.services.storage
        if storageService.storageMap then
            for _, storage in ipairs(storageService.storageMap) do
                if not storage.isME then
                    -- For regular inventories, count free slots
                    local inv = peripheral.wrap(storage.name)
                    if inv and inv.list and inv.size then
                        local items = inv.list()
                        local totalSlots = inv.size()
                        local usedSlots = 0
                        for _ in pairs(items) do
                            usedSlots = usedSlots + 1
                        end
                        freeSlots = freeSlots + (totalSlots - usedSlots)
                    end
                end
                -- ME systems have unlimited slots, don't count
            end
        end
    end

    -- Only mark dirty if changed
    if freeSlots ~= self.freeSlots then
        self.freeSlots = freeSlots
        self.dirty.freeSlots = true
    end
end

function MonitorService:drawFreeSlots()
    local y = self.height - 17

    -- Calculate total slots and usage percentage
    local totalSlots = 0
    local usedSlots = 0

    if self.context.services and self.context.services.storage then
        local storageService = self.context.services.storage
        if storageService.storageMap then
            for _, storage in ipairs(storageService.storageMap) do
                if not storage.isME then
                    local inv = peripheral.wrap(storage.name)
                    if inv and inv.size then
                        totalSlots = totalSlots + inv.size()
                    end
                end
            end
        end
    end

    usedSlots = totalSlots - self.freeSlots
    local freePercent = totalSlots > 0 and math.floor((self.freeSlots / totalSlots) * 100) or 0
    local usedPercent = 100 - freePercent

    -- Build progress bar
    local barWidth = self.width - 4  -- Leave 2 chars padding on each side
    local usedWidth = math.floor((usedPercent / 100) * barWidth)
    local freeWidth = barWidth - usedWidth

    -- Build the text to overlay
    local overlayText = string.format("Free space remaining: %d%%", freePercent)
    local textStartX = math.floor((self.width - #overlayText) / 2) + 1

    -- Draw the progress bar with text overlay
    self.monitor.setCursorPos(3, y)

    for i = 1, barWidth do
        local globalX = i + 2  -- Account for 2-char left padding
        local charInText = globalX >= textStartX and globalX < textStartX + #overlayText
        local textChar = charInText and overlayText:sub(globalX - textStartX + 1, globalX - textStartX + 1) or nil

        if i <= usedWidth then
            -- Red (used) portion
            self.monitor.setBackgroundColor(colors.red)
            self.monitor.setTextColor(colors.white)
            self.monitor.write(textChar or "\127")  -- Full block character
        else
            -- Green (free) portion
            self.monitor.setBackgroundColor(colors.lime)
            self.monitor.setTextColor(colors.black)
            self.monitor.write(textChar or "\127")  -- Full block character
        end
    end

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawPagination()
    -- Use filtered items if a letter is selected
    local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

    -- Calculate items per page dynamically based on available rows
    local startY = 3
    local endY = self.height - 19
    local maxRows = endY - startY + 1
    local itemsPerPage = maxRows * 2  -- Two columns

    local totalPages = math.ceil(#items / itemsPerPage)

    if totalPages <= 1 then return end

    -- Draw pagination at height - 13
    local paginationY = self.height - 13

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

    -- Build entire line with centered pagination
    local startX = math.max(0, math.floor((self.width - #paginationStr) / 2))
    local line = string.rep(" ", startX) .. paginationStr .. string.rep(" ", self.width - startX - #paginationStr)

    -- Write entire line at once
    self.monitor.setCursorPos(1, paginationY)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.setTextColor(colors.gray)
    self.monitor.write(line)
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
        if y > self.height - 19 then break end

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

    -- Draw separator line
    self.monitor.setCursorPos(1, startY)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.setTextColor(colors.gray)
    self.monitor.write(string.rep("-", self.width))

    startY = startY + 1

    -- Build visualizer in memory first (10 rows)
    local rows = {}
    for i = 1, 10 do
        rows[i] = {}
        for j = 1, self.width do
            rows[i][j] = {char = " ", color = colors.black, bg = colors.black}
        end
    end

    -- Calculate total width needed for all pools
    local totalWidth = 0
    local poolOrder = {}
    for poolName, pool in pairs(self.visualizer.pools) do
        table.insert(poolOrder, {name = poolName, pool = pool})
        totalWidth = totalWidth + (#pool.workers * 2) + 2
    end
    totalWidth = totalWidth - 2

    local startX = math.floor((self.width - totalWidth) / 2)
    local x = startX

    -- Build each pool in memory
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
                    if stackItem and rowIdx >= 1 and rowIdx <= 10 then
                        rows[rowIdx][stackX] = {char = "\138", color = stackItem.color, bg = colors.black}
                    end
                end

                -- Worker number
                local workerRow = self.visualizer.maxHeight - 2 + 1
                if workerRow >= 1 and workerRow <= 10 then
                    rows[workerRow][stackX] = {char = tostring(w), color = pool.color, bg = colors.black}
                end
            end
        end

        -- Pool label
        local label = self.visualizer.labels[poolName] or poolName
        local labelX = x + math.floor((#pool.workers * 2 - #label) / 2)
        local labelRow = self.visualizer.maxHeight - 1 + 1
        if labelRow >= 1 and labelRow <= 10 then
            for i = 1, #label do
                local col = labelX + i - 1
                if col >= 1 and col <= self.width then
                    rows[labelRow][col] = {char = label:sub(i, i), color = pool.color, bg = colors.black}
                end
            end
        end

        x = x + (#pool.workers * 2) + 2
    end

    -- Draw all rows with colors
    for i = 1, 10 do
        local y = startY + i - 1
        self.monitor.setCursorPos(1, y)
        self.monitor.setBackgroundColor(colors.black)

        -- Draw each character with its color
        for j = 1, self.width do
            local cell = rows[i][j]
            self.monitor.setTextColor(cell.color)
            self.monitor.write(cell.char)
        end
    end
end

function MonitorService:drawIOIndicators()
    local y = self.height

    -- Clear the line
    self.monitor.setCursorPos(1, y)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.write(string.rep(" ", self.width))

    -- Write INPUT in green
    local inputText = "INPUT"
    local inputPos = self.inputSide == "left" and 1 or (self.width - 5)
    self.monitor.setCursorPos(inputPos, y)
    self.monitor.setTextColor(colors.lime)
    self.monitor.write(inputText)

    -- Write OUTPUT in red
    local outputText = "OUTPUT"
    local outputPos = self.outputSide == "left" and 1 or (self.width - 6)
    self.monitor.setCursorPos(outputPos, y)
    self.monitor.setTextColor(colors.red)
    self.monitor.write(outputText)
end

function MonitorService:drawStatsModal()
    -- Calculate modal dimensions (centered, 60% width, same height as items list)
    local modalWidth = math.floor(self.width * 0.6)
    -- Items go from line 3 to height-19, so height is (height-19) - 3 + 1 = height-21
    local modalHeight = self.height - 21
    local startX = math.floor((self.width - modalWidth) / 2)
    local startY = 3  -- Align with items list start

    -- Get stats data
    local items = self:getAllItems()
    local uniqueCount = #items
    local totalCount = 0
    for _, item in ipairs(items) do
        totalCount = totalCount + (item.value.count or 0)
    end

    local inventoryCount = 0
    local bufferChest = "None"
    if self.context.services and self.context.services.storage then
        local storageService = self.context.services.storage
        if storageService.storageMap then
            inventoryCount = #storageService.storageMap
        end
        if storageService.bufferChest then
            bufferChest = storageService.bufferChest
        end
    end

    local totalSlots = self.freeSlots + 0  -- Calculate total from current state
    -- Need to get used slots
    local usedSlots = 0
    if self.context.services and self.context.services.storage then
        local storageService = self.context.services.storage
        if storageService.storageMap then
            for _, storage in ipairs(storageService.storageMap) do
                if not storage.isME then
                    local inv = peripheral.wrap(storage.name)
                    if inv and inv.list and inv.size then
                        local items = inv.list()
                        totalSlots = totalSlots + inv.size()
                        for _ in pairs(items) do
                            usedSlots = usedSlots + 1
                        end
                    end
                end
            end
        end
    end

    local freePercent = totalSlots > 0 and math.floor((self.freeSlots / totalSlots) * 100) or 0

    -- Draw modal background
    for y = startY, startY + modalHeight - 1 do
        self.monitor.setCursorPos(startX, y)
        self.monitor.setBackgroundColor(colors.gray)
        self.monitor.write(string.rep(" ", modalWidth))
    end

    -- Draw modal border
    self.monitor.setCursorPos(startX, startY)
    self.monitor.setBackgroundColor(colors.lightGray)
    self.monitor.setTextColor(colors.black)
    self.monitor.write(string.rep(" ", modalWidth))
    self.monitor.setCursorPos(startX + 2, startY)
    self.monitor.write("STORAGE STATISTICS")

    -- Close button
    local closeText = "[X]"
    self.monitor.setCursorPos(startX + modalWidth - 4, startY)
    self.monitor.setTextColor(colors.red)
    self.monitor.write(closeText)

    -- Draw stats content
    local contentY = startY + 2
    local contentX = startX + 2

    self.monitor.setBackgroundColor(colors.gray)
    self.monitor.setTextColor(colors.white)

    -- Total items
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Total Items: %d", totalCount))
    contentY = contentY + 1

    -- Unique items
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Unique Items: %d", uniqueCount))
    contentY = contentY + 1

    -- Inventories connected
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Inventories Connected: %d", inventoryCount))
    contentY = contentY + 1

    -- Buffer chest
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Buffer Chest: %s", bufferChest))
    contentY = contentY + 1

    -- Free slots
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Free Slots: %d", self.freeSlots))
    contentY = contentY + 1

    -- Storage capacity
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Storage: %d / %d", usedSlots, totalSlots))
    contentY = contentY + 1

    -- Free space percentage
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.write(string.format("Free Space: %d%%", freePercent))
    contentY = contentY + 2

    -- Close instruction
    self.monitor.setCursorPos(contentX, contentY)
    self.monitor.setTextColor(colors.lightGray)
    self.monitor.write("Click [X] to close")
end

function MonitorService:initializeVisualizer()
    local pools = self.context.scheduler:getPools()

    self.logger:info("MonitorService", "Initializing visualizer pools...")

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

        self.logger:info("MonitorService", string.format(
            "Pool '%s': %d workers (pool has %d total)",
            upperName, workerCount, pool.size
        ))
    end
end

function MonitorService:onTaskStart(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    self.logger:warn("MonitorService", string.format(
        "[VISUAL] onTaskStart: pool=%s, worker=%d, taskType=%s",
        poolName, data.worker or -1, data.taskType or "nil"
    ))

    if not pool then
        self.logger:warn("MonitorService", string.format(
            "[VISUAL] Pool '%s' not found in visualizer", poolName
        ))
        return
    end

    if not pool.workers[data.worker] then
        self.logger:warn("MonitorService", string.format(
            "[VISUAL] Worker %d not found in pool '%s' (has %d workers)",
            data.worker, poolName, #pool.workers
        ))
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

    self.logger:warn("MonitorService", string.format(
        "[VISUAL] Added bar: pool=%s, worker=%d, taskType=%s, color=%d",
        poolName, data.worker, taskType, barColor
    ))

    -- Play sound for this task type
    self:playTaskSound(taskType)
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

        -- Play completion sound (slightly different pitch)
        self:playTaskSound(taskType, true)
    end
end

function MonitorService:playTaskSound(taskType, isCompletion)
    local soundConfig = self.visualizer.taskSounds[taskType]

    if not soundConfig then
        soundConfig = self.visualizer.taskSounds.generic
        self.logger:warn("MonitorService", string.format(
            "[SOUND] No sound config for taskType '%s', using generic", taskType
        ))
    end

    -- Get sound settings or default
    local settings = self.context.settings or {}
    local soundEnabled = settings.soundEnabled
    if soundEnabled == nil then
        soundEnabled = true  -- Default to enabled
    end

    if not soundEnabled then
        self.logger:warn("MonitorService", "[SOUND] Sound disabled in settings")
        return  -- Sound disabled
    end

    -- Adjust pitch slightly for completion events
    local pitch = soundConfig.pitch
    if isCompletion then
        pitch = pitch * 1.2  -- Higher pitch for completion
    end

    -- Play the sound using noteblock peripheral if available
    local noteblock = peripheral.find("minecraft:note_block")
    if noteblock then
        self.logger:warn("MonitorService", string.format(
            "[SOUND] Playing: taskType=%s, instrument=%s, pitch=%.1f",
            taskType, soundConfig.instrument, pitch
        ))
        noteblock.playNote(soundConfig.instrument, soundConfig.volume, pitch)
    else
        self.logger:warn("MonitorService", "[SOUND] No noteblock peripheral found")
    end
end

function MonitorService:onItemAdded(data)
    local itemKey = data.key or data.item
    self.itemColors[itemKey] = "new"
    self.itemTimers[itemKey] = os.epoch("utc") / 1000

    -- Mark UI as dirty
    self.dirty.lists = true
    self.dirty.header = true
    self.dirty.pagination = true

    -- Update cache
    self:refreshCache()
end

function MonitorService:onItemUpdated(data)
    local itemName = data.key or data.item
    if self.itemColors[itemName] ~= "new" then
        self.itemColors[itemName] = "updated"
        self.itemTimers[itemName] = os.epoch("utc") / 1000
    end

    -- Mark lists as dirty
    self.dirty.lists = true

    -- Update cache
    self:refreshCache()
end

function MonitorService:onIndexRebuilt(data)
    self.logger:info("MonitorService", "=== RECEIVED storage.indexRebuilt EVENT ===")
    self.logger:info("MonitorService", string.format(
        "Index rebuilt: %d unique items, %d stacks",
        data.uniqueItems or 0, data.totalStacks or 0
    ))

    -- Mark all UI as dirty
    self.dirty.lists = true
    self.dirty.header = true
    self.dirty.pagination = true
    self.dirty.freeSlots = true

    -- Note: Cache will be refreshed by background thread
    -- UI will update automatically on next render cycle
end

function MonitorService:refreshCache()
    -- Refresh cache from storage service
    if self.context.services and self.context.services.storage then
        local oldCount = #self.itemCache
        local items = self.context.services.storage:getItems()
        self.itemCache = items
        self.cacheLastUpdate = os.epoch("utc") / 1000

        -- Mark dirty if item count changed
        if #items ~= oldCount then
            self.dirty.lists = true
            self.dirty.header = true
            self.dirty.pagination = true
        end

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

    -- Mark all UI as dirty
    self.dirty.lists = true
    self.dirty.header = true
    self.dirty.pagination = true

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
    -- PURE FUNCTION - Only reads from cache, no expensive operations
    -- Cache is updated by background thread

    -- Deduplicate items by key (keep first occurrence only)
    local itemMap = {}
    for _, item in ipairs(self.itemCache) do
        if not itemMap[item.key] then
            -- First occurrence, store a copy
            itemMap[item.key] = {
                key = item.key,
                value = {
                    count = item.value.count or 0,
                    stackSize = item.value.stackSize or 64
                }
            }
        end
        -- If duplicate, skip it (don't aggregate counts)
    end

    -- Convert map back to array
    local items = {}
    for _, item in pairs(itemMap) do
        table.insert(items, item)
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
    local changed = false

    -- If stats modal is open, handle modal clicks
    if self.showStatsModal then
        local modalWidth = math.floor(self.width * 0.6)
        local modalHeight = self.height - 21
        local startX = math.floor((self.width - modalWidth) / 2)
        local startY = 3

        -- Close button click (top right of modal)
        if y == startY and x >= startX + modalWidth - 4 and x <= startX + modalWidth - 1 then
            self.showStatsModal = false
            -- Clear screen and mark everything dirty to refresh display
            self.monitor.setBackgroundColor(colors.black)
            self.dirty.header = true
            self.dirty.lists = true
            self.dirty.freeSlots = true
            self.dirty.pagination = true
            return
        end

        -- Click outside modal closes it
        if x < startX or x >= startX + modalWidth or y < startY or y >= startY + modalHeight then
            self.showStatsModal = false
            -- Clear screen and mark everything dirty to refresh display
            self.monitor.setBackgroundColor(colors.black)
            self.dirty.header = true
            self.dirty.lists = true
            self.dirty.freeSlots = true
            self.dirty.pagination = true
            return
        end

        -- Ignore clicks inside modal (except close button)
        return
    end

    -- Header: Stats link and Sort buttons
    if y == 1 then
        -- Stats link (around position 12-18 for "[Stats]")
        if x >= 12 and x <= 18 then
            self.showStatsModal = true
            return
        end

        local sortX = self.width - 19
        -- Name sort button (positions sortX+6 to sortX+11)
        if x >= sortX + 6 and x <= sortX + 11 then
            if self.sortBy ~= "name" then
                self.sortBy = "name"
                changed = true
            end
        -- Count sort button (positions sortX+12 to sortX+18)
        elseif x >= sortX + 12 and x <= sortX + 18 then
            if self.sortBy ~= "count" then
                self.sortBy = "count"
                changed = true
            end
        end
    end

    -- Letter navigation (now at height - 15, centered)
    local letterFilterY = self.height - 15
    if y == letterFilterY then
        if self.currentLetter then
            -- Click [X] to go back (centered position)
            local filterText = "[X] " .. self.currentLetter:upper()
            local startX = math.max(1, math.floor((self.width - #filterText) / 2) + 1)
            if x >= startX and x <= startX + 2 then
                self.currentLetter = nil
                self.currentPage = 1
                changed = true
            end
        else
            -- Click on letters to filter (centered, 27 chars total)
            local totalLength = 27
            local startX = math.max(1, math.floor((self.width - totalLength) / 2) + 1)
            local relativeX = x - startX + 1

            if relativeX == 1 then
                -- Clicked on #
                self.currentLetter = "#"
                self.currentPage = 1
                changed = true
            elseif relativeX >= 2 and relativeX <= 27 then
                -- Clicked on a-z
                self.currentLetter = string.char(96 + relativeX - 1)
                self.currentPage = 1
                changed = true
            end
        end
    end

    -- Pagination clicks
    local paginationY = self.height - 13
    if y == paginationY then
        local items = self.currentLetter and self:getFilteredItems() or self:getAllItems()

        -- Calculate items per page dynamically
        local startY = 3
        local endY = self.height - 19
        local maxRows = endY - startY + 1
        local itemsPerPage = maxRows * 2  -- Two columns
        local totalPages = math.ceil(#items / itemsPerPage)

        -- Check if pagination is being displayed
        if totalPages > 1 then
            -- Build pagination string to calculate positions
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

            -- Previous page (clicking on "<")
            if hasLeft and x >= startX and x <= startX + 1 then
                self.currentPage = self.currentPage - 1
                changed = true
            -- Next page (clicking on ">")
            elseif hasRight and x >= startX + #paginationStr - 1 and x <= startX + #paginationStr then
                self.currentPage = self.currentPage + 1
                changed = true
            end
        end
    end

    -- Mark UI dirty if anything changed
    if changed then
        self.dirty.lists = true
        self.dirty.header = true
        self.dirty.pagination = true
    end
end

function MonitorService:stop()
    self.running = false
    self.logger:info("MonitorService", "Service stopped")
end

return MonitorService