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

    -- Set text scale for better visibility
    if o.monitor.setTextScale then
        o.monitor.setTextScale(0.5)
    end

    o.width, o.height = o.monitor.getSize()
    o.running = false

    -- UI state
    o.currentPage = "items"
    o.selectedItems = {}
    o.scrollOffset = 0
    o.sortBy = "name"

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
        }
    }

    return o
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

    self.eventBus:subscribe("task.error", function(event, data)
        self:onTaskError(data)
    end)

    self.logger:info("MonitorService", "Service started")
end

function MonitorService:stop()
    self.running = false
    self.logger:info("MonitorService", "Service stopped")
end

function MonitorService:run()
    local processes = {}

    -- Render loop process
    table.insert(processes, function()
        while self.running do
            self:render()
            os.sleep(0.1)  -- 10 FPS
        end
    end)

    -- Input handler process
    table.insert(processes, function()
        while self.running do
            local event, side, x, y = os.pullEvent("monitor_touch")

            if side == peripheral.getName(self.monitor) then
                self.eventBus:publish("ui.monitor.interacted", {
                    x = x,
                    y = y,
                    page = self.currentPage
                })

                -- Handle click based on position
                self:handleClick(x, y)
            end
        end
    end)

    -- Run both in parallel
    parallel.waitForAny(table.unpack(processes))
end

function MonitorService:render()
    -- Ensure text scale is set
    if self.monitor.setTextScale then
        self.monitor.setTextScale(0.5)
    end

    self.monitor.clear()

    if self.currentPage == "items" then
        self:renderItemsPage()
    elseif self.currentPage == "console" then
        self:renderConsolePage()
    end

    -- Always render visualizer at bottom
    self:renderVisualizer()

    self.eventBus:publish("ui.monitor.update", {
        page = self.currentPage
    })
end

function MonitorService:initializeVisualizer()
    local pools = self.context.scheduler:getPools()

    for poolName, pool in pairs(pools) do
        self.visualizer.pools[poolName:upper()] = {
            name = poolName:upper(),
            workers = {},
            color = self.visualizer.colors[poolName:upper()] or colors.white
        }

        -- Initialize worker slots
        for i = 1, math.min(pool.size, 6) do
            self.visualizer.pools[poolName:upper()].workers[i] = {
                id = i,
                label = string.sub("0123456789ABCDEF", i, i),
                stack = {},
                idle = true
            }
        end

        -- Add overflow indicator if needed
        if pool.size > 6 then
            self.visualizer.pools[poolName:upper()].workers[6] = {
                id = 6,
                label = "+",
                stack = {},
                idle = false,
                overflow = true,
                count = pool.size - 5
            }
        end
    end
end

function MonitorService:renderItemsPage()
    local y = 1

    -- Header
    self:drawHeader(y)
    y = y + 2

    -- Sort options
    self:drawSortOptions(y)
    y = y + 2

    -- Item list
    local items = self.context.services.storage:getItems()
    self:drawItemList(items, y)
end

function MonitorService:renderConsolePage()
    -- Console page implementation (if needed)
    local y = 1
    self:drawHeader(y)
    self.monitor.setTextSize(0.5)

    self.monitor.setCursorPos(1, 3)
    self.monitor.setTextColor(colors.white)
    self.monitor.write("Console Page - Not Implemented")
end

function MonitorService:drawHeader(y)
    self.monitor.setCursorPos(1, y)
    self.monitor.setBackgroundColor(colors.gray)
    self.monitor.clearLine()
    self.monitor.setTextColor(colors.white)

    local title = " STORAGE SYSTEM "
    local x = math.floor((self.width - #title) / 2)
    self.monitor.setCursorPos(x, y)
    self.monitor.write(title)

    self.monitor.setBackgroundColor(colors.black)
end

function MonitorService:drawSortOptions(y)
    self.monitor.setCursorPos(1, y)
    self.monitor.setTextColor(colors.lightGray)
    self.monitor.write("Sort: ")

    local options = {"Name", "Count", "ID", "NBT"}
    local x = 7

    for _, option in ipairs(options) do
        if option:lower() == self.sortBy then
            self.monitor.setTextColor(colors.yellow)
            self.monitor.write("[" .. option .. "]")
        else
            self.monitor.setTextColor(colors.gray)
            self.monitor.write(" " .. option .. " ")
        end
        x = x + #option + 3
    end
end

function MonitorService:drawItemList(items, startY)
    local itemsPerPage = self.height - startY - 12  -- Leave room for visualizer

    -- Sort items
    table.sort(items, function(a, b)
        if self.sortBy == "name" then
            return a.key < b.key
        elseif self.sortBy == "count" then
            return (a.value.count or 0) > (b.value.count or 0)
        end
        return a.key < b.key
    end)

    -- Draw items
    for i = 1, itemsPerPage do
        local itemIndex = i + self.scrollOffset
        if items[itemIndex] then
            local item = items[itemIndex]
            local y = startY + i - 1

            self.monitor.setCursorPos(1, y)

            -- Selection indicator
            if self.selectedItems[item.key] then
                self.monitor.setBackgroundColor(colors.blue)
            else
                self.monitor.setBackgroundColor(colors.black)
            end

            -- Item name
            self.monitor.setTextColor(colors.white)
            local name = item.key:match("([^:]+)$") or item.key
            if #name > 25 then
                name = name:sub(1, 22) .. "..."
            end
            self.monitor.write(name)

            -- Item count
            local countStr = string.format(" x%d", item.value.count or 0)
            self.monitor.setCursorPos(28, y)
            self.monitor.setTextColor(colors.green)
            self.monitor.write(countStr)

            -- Stack count
            local stackSize = item.value.stackSize or 64
            local stacks = math.ceil((item.value.count or 0) / stackSize)
            local stackStr = string.format(" [%d]", stacks)
            self.monitor.setCursorPos(40, y)
            self.monitor.setTextColor(colors.lightGray)
            self.monitor.write(stackStr)

            self.monitor.setBackgroundColor(colors.black)
        end
    end
end

function MonitorService:renderVisualizer()
    local startY = self.height - 11

    -- Draw separator
    self.monitor.setCursorPos(1, startY)
    self.monitor.setTextColor(colors.gray)
    self.monitor.write(string.rep("-", self.width))

    local x = 2
    startY = startY + 1

    -- Draw each pool
    for poolName, pool in pairs(self.visualizer.pools) do
        if x + (#pool.workers * 2) > self.width then
            break  -- No more room
        end

        -- Draw stacks
        for w, worker in ipairs(pool.workers) do
            local stackX = x + (w - 1) * 2

            -- Draw stack from bottom up
            for h = 1, self.visualizer.maxHeight do
                local stackY = startY + self.visualizer.maxHeight - h
                local stackItem = worker.stack[h]

                if stackItem then
                    self.monitor.setCursorPos(stackX, stackY)
                    self.monitor.setTextColor(stackItem.color)
                    self.monitor.write("\138")
                end
            end

            -- Draw worker label
            self.monitor.setCursorPos(stackX, startY + self.visualizer.maxHeight)
            self.monitor.setTextColor(pool.color)
            self.monitor.write(worker.label)

            -- Draw idle/active indicator
            self.monitor.setCursorPos(stackX, startY + self.visualizer.maxHeight + 1)
            if worker.idle then
                self.monitor.setTextColor(colors.gray)
                self.monitor.write("T")
            else
                self.monitor.setTextColor(pool.color)
                self.monitor.write("T")
            end
        end

        -- Draw pool name
        local nameX = x + math.floor((#pool.workers * 2 - #poolName) / 2)
        self.monitor.setCursorPos(nameX, startY + self.visualizer.maxHeight + 2)
        self.monitor.setTextColor(pool.color)
        self.monitor.write(poolName)

        x = x + (#pool.workers * 2) + 2
    end
end

function MonitorService:onTaskStart(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]
        worker.idle = false

        -- Add white marker to stack
        table.insert(worker.stack, 1, {
            color = colors.white,
            type = "start"
        })

        -- Limit stack height
        if #worker.stack > self.visualizer.maxHeight then
            table.remove(worker.stack)
        end
    end
end

function MonitorService:onTaskEnd(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]

        -- Add white marker
        table.insert(worker.stack, 1, {
            color = colors.white,
            type = "end"
        })

        if #worker.stack > self.visualizer.maxHeight then
            table.remove(worker.stack)
        end

        -- Set idle after delay
        self.context.timeWheel:schedule(2, function()
            worker.idle = true
        end)
    end
end

function MonitorService:onTaskError(data)
    local poolName = data.pool:upper()
    local pool = self.visualizer.pools[poolName]

    if pool and pool.workers[data.worker] then
        local worker = pool.workers[data.worker]

        -- Add red error marker
        table.insert(worker.stack, 1, {
            color = colors.red,
            type = "error"
        })

        if #worker.stack > self.visualizer.maxHeight then
            table.remove(worker.stack)
        end
    end
end

function MonitorService:handleClick(x, y)
    -- Check sort options
    if y == 3 then
        if x >= 7 and x <= 12 then
            self.sortBy = "name"
        elseif x >= 14 and x <= 20 then
            self.sortBy = "count"
        elseif x >= 22 and x <= 26 then
            self.sortBy = "id"
        elseif x >= 28 and x <= 32 then
            self.sortBy = "nbt"
        end
    end

    -- Check item list
    local itemY = y - 4
    if itemY > 0 and itemY <= self.height - 16 then
        -- Toggle selection
        local items = self.context.services.storage:getItems()
        local itemIndex = itemY + self.scrollOffset

        if items[itemIndex] then
            local item = items[itemIndex]
            if self.selectedItems[item.key] then
                self.selectedItems[item.key] = nil
            else
                self.selectedItems[item.key] = true
            end
        end
    end
end

return MonitorService