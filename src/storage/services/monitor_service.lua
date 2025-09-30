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
    o.itemsPerPage = o.height - 17  -- Account for header, sort, letters, visualizer, etc.
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
                    if now - item.time < 1 then  -- Keep items less than 1 second old
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
            if now - colorTime > 1 then
                self.itemColors[itemName] = nil
                self.itemTimers[itemName] = nil
                changed = true
            end
        end

        if changed then
            self:render()
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
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clear()

    -- Header
    self:drawHeader()

    -- Sort options (line 2)
    self:drawSortOptions()

    -- Letter navigation (line 3)
    self:drawLetterNav()

    -- Items (starting line 4)
    if self.currentLetter then
        self:drawFilteredItems()
    else
        self:drawAllItems()
    end

    -- Pagination just above visualizer separator (if filtered)
    if self.currentLetter then
        self:drawPagination()
    end

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

    local title = " STORAGE SYSTEM "
    local x = math.floor((self.width - #title) / 2)
    self.monitor.setCursorPos(x, 1)
    self.monitor.write(title)

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawSortOptions()
    self.monitor.setCursorPos(1, 2)
    self.monitor.setTextColor(colors.lightGray)
    self.monitor.write("Sort: ")

    local options = {"[Name]", "Count", "ID", "NBT"}
    local x = 7

    for i, option in ipairs(options) do
        if option:lower():find(self.sortBy) then
            self.monitor.setTextColor(colors.yellow)
        else
            self.monitor.setTextColor(colors.gray)
        end
        self.monitor.write(option .. " ")
    end
end

function MonitorService:drawLetterNav()
    self.monitor.setCursorPos(1, 3)
    self.monitor.clearLine()

    if not self.currentLetter then
        -- Show all letters - this is the "all items" view
        self.monitor.setTextColor(colors.cyan)
        self.monitor.write("#")

        for i = 1, 26 do
            local letter = string.char(96 + i)
            self.monitor.setTextColor(colors.lightGray)
            self.monitor.write(letter)
        end
    else
        -- Show current letter with back option
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("[")
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("X")
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("] ")

        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("Showing: ")
        self.monitor.setTextColor(colors.white)
        self.monitor.write(self.currentLetter:upper())

        -- Show item count
        local items = self:getFilteredItems()
        local countStr = " (" .. #items .. " items)"
        self.monitor.setTextColor(colors.gray)
        self.monitor.write(countStr)
    end
end

function MonitorService:drawPagination()
    if not self.currentLetter then return end

    local items = self:getFilteredItems()
    local totalPages = math.ceil(#items / self.itemsPerPage)

    if totalPages <= 1 then return end

    -- Position pagination ONE line above the dashed separator
    local paginationY = self.height - 12

    -- Clear the line first
    self.monitor.setCursorPos(1, paginationY)
    self.monitor.clearLine()

    self.monitor.setTextColor(colors.lightGray)

    local paginationStr = ""

    -- Previous controls
    if self.currentPage > 1 then
        paginationStr = "<< < "
    else
        paginationStr = "     "
    end

    -- Page numbers
    if totalPages <= 7 then
        for i = 1, totalPages do
            if i == self.currentPage then
                paginationStr = paginationStr .. "[" .. i .. "] "
            else
                paginationStr = paginationStr .. i .. " "
            end
        end
    else
        -- Complex pagination with ellipsis
        if self.currentPage <= 3 then
            for i = 1, 5 do
                if i == self.currentPage then
                    paginationStr = paginationStr .. "[" .. i .. "] "
                else
                    paginationStr = paginationStr .. i .. " "
                end
            end
            paginationStr = paginationStr .. "... " .. totalPages
        elseif self.currentPage >= totalPages - 2 then
            paginationStr = paginationStr .. "1 ... "
            for i = totalPages - 4, totalPages do
                if i == self.currentPage then
                    paginationStr = paginationStr .. "[" .. i .. "] "
                else
                    paginationStr = paginationStr .. i .. " "
                end
            end
        else
            paginationStr = paginationStr .. "1 ... "
            for i = self.currentPage - 1, self.currentPage + 1 do
                if i == self.currentPage then
                    paginationStr = paginationStr .. "[" .. i .. "] "
                else
                    paginationStr = paginationStr .. i .. " "
                end
            end
            paginationStr = paginationStr .. "... " .. totalPages
        end
    end

    -- Next controls
    if self.currentPage < totalPages then
        paginationStr = paginationStr .. " > >>"
    else
        paginationStr = paginationStr .. "     "
    end

    -- Center the pagination properly
    local x = math.max(1, math.floor((self.width - #paginationStr) / 2) + 1)
    self.monitor.setCursorPos(x, paginationY)
    self.monitor.write(paginationStr)
end

function MonitorService:drawAllItems()
    local items = self:getAllItems()
    local startY = 4

    if #items == 0 then
        self.monitor.setCursorPos(math.floor(self.width / 2) - 5, math.floor(self.height / 2))
        self.monitor.setTextColor(colors.gray)
        self.monitor.write("NO ITEMS")
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
    self.monitor.setTextColor(colors.gray)
    self.monitor.write(string.rep("-", self.width))

    local x = 2
    startY = startY + 1

    -- Draw each pool with labels
    for poolName, pool in pairs(self.visualizer.pools) do
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
    self.itemColors[data.key or data.item] = "new"
    self.itemTimers[data.key or data.item] = os.epoch("utc") / 1000
end

function MonitorService:onItemUpdated(data)
    local itemName = data.key or data.item
    if self.itemColors[itemName] ~= "new" then
        self.itemColors[itemName] = "updated"
        self.itemTimers[itemName] = os.epoch("utc") / 1000
    end
end

function MonitorService:onIndexRebuilt(data)
    self.logger:info("MonitorService", string.format(
        "Index rebuilt: %d unique items, %d stacks",
        data.uniqueItems or 0, data.totalStacks or 0
    ))
    -- Force a render to show the updated items
    if self.running then
        self:render()
    end
end

function MonitorService:getAllItems()
    if self.context.services and self.context.services.storage then
        local items = self.context.services.storage:getItems()

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
    return {}
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
    -- Letter navigation
    if y == 3 then
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

    -- Sort options
    if y == 2 then
        if x >= 7 and x <= 12 then
            self.sortBy = "name"
        elseif x >= 14 and x <= 18 then
            self.sortBy = "count"
        end
    end

    -- Pagination clicks
    if y == self.height - 12 and self.currentLetter then
        local items = self:getFilteredItems()
        local totalPages = math.ceil(#items / self.itemsPerPage)

        -- Previous page (left side)
        if x <= 5 and self.currentPage > 1 then
            self.currentPage = self.currentPage - 1
            -- Next page (right side)
        elseif x >= self.width - 5 and self.currentPage < totalPages then
            self.currentPage = self.currentPage + 1
            -- First page (clicking "<<")
        elseif x <= 3 and self.currentPage > 1 then
            self.currentPage = 1
            -- Last page (clicking ">>")
        elseif x >= self.width - 3 and self.currentPage < totalPages then
            self.currentPage = totalPages
        end
    end
end

function MonitorService:stop()
    self.running = false
    self.logger:info("MonitorService", "Service stopped")
end

return MonitorService