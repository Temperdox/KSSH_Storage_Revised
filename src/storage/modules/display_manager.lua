-- modules/display_manager.lua
-- Monitor display management - MATCHING ORIGINAL VISUALIZATION

local DisplayManager = {}
DisplayManager.__index = DisplayManager

local SoundManager = require("modules.sound_manager")

function DisplayManager:new(logger, eventBus)
    local self = setmetatable({}, DisplayManager)
    self.logger = logger
    self.eventBus = eventBus
    self.sound = SoundManager:new(logger)
    self.running = true

    -- Display data
    self.displayItems = {}
    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0

    -- UI state
    self.selectedItem = nil
    self.desiredAmount = 0
    self.selectedSort = nil

    -- Display settings
    self.columnWidth = 24
    self.column = 0

    -- Sort configuration
    self.displaySort = {
        {sort = "maxCount", ascending = true},
        {sort = "displayName", ascending = true},
        {sort = "name", ascending = true},
        {sort = "count", ascending = true}
    }

    self.displaySortVisual = {
        maxCount = {large = "[Stack]", small = "[Sk]"},
        displayName = {large = "[Name]", small = "[Nm]"},
        name = {large = "[ID]", small = "[ID]"},
        count = {large = "[Amount]", small = "[Am]"}
    }

    -- Task tracking - MATCHING ORIGINAL STRUCTURE
    self.tasks = {
        sort = {queue = {}, threads = {}},
        deposit = {queue = {}, threads = {}},
        reformat = {queue = {}, threads = {}}
    }

    -- Initialize threads
    for taskType, task in pairs(self.tasks) do
        for i = 1, 16 do
            table.insert(task.threads, {active = false, log = {}})
        end
        -- Extra thread for deposit
        if taskType == "deposit" then
            table.insert(task.threads, {active = false, log = {}})
        end
    end

    -- Order and reload tracking
    self.orderQueue = {}
    self.orderLogs = {active = false, log = {}}
    self.reloadLogs = {active = false, log = {}}

    -- First draw flag
    self.firstDraw = true

    -- Find monitor
    self:findMonitor()

    -- Register events
    self:registerEvents()

    return self
end

function DisplayManager:findMonitor()
    self.monitor = nil

    local badPos = {"top", "bottom", "front", "back", "left", "right"}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local skip = false
            for _, pos in ipairs(badPos) do
                if name == pos then
                    skip = true
                    break
                end
            end

            if not skip then
                self.monitor = peripheral.wrap(name)
                self.logger:success("Monitor found: " .. name, "Display")
                self.firstDraw = true
                break
            end
        end
    end

    if not self.monitor then
        self.logger:warning("No monitor found", "Display")
    end
end

function DisplayManager:registerEvents()
    -- Storage data updates
    self.eventBus:on("storage:data_updated", function(data)
        self:updateStorageData(data)
    end)

    -- Order events
    self.eventBus:on("storage:order_queued", function(item, amount)
        self:markItemQueued(item, amount)
    end)

    -- Task status updates
    self.eventBus:on("task:status", function(type, status)
        self:updateTaskStatus(type, status)
    end)

    -- Reload events
    self.eventBus:on("storage:reload_started", function()
        self.reloadLogs.active = true
        self:addLog(self.reloadLogs.log, "Reloading", colors.cyan)
    end)

    self.eventBus:on("storage:reload_complete", function()
        self.reloadLogs.active = false
    end)

    self.eventBus:on("storage:calculation_started", function()
        self:addLog(self.reloadLogs.log, "Calculating", colors.lightBlue)
    end)

    -- Stop event
    self.eventBus:on("process:stop:display", function()
        self.running = false
    end)
end

function DisplayManager:addLog(logTable, message, color)
    table.insert(logTable, {
        message = message,
        color = color,
        time = os.epoch("utc") + 2000
    })

    -- Keep only last 10
    while #logTable > 10 do
        table.remove(logTable, 1)
    end
end

function DisplayManager:updateStorageData(data)
    -- Convert storage items to display format
    self.displayItems = {}

    for _, item in ipairs(data.items) do
        table.insert(self.displayItems, {
            item = item,
            searching = false,
            queued = false,
            merged = false,
            added = false,
            overflow = false,
            failed = 0
        })
    end

    self.emptySlots = data.emptySlots
    self.fullChests = data.fullChests
    self.partialChests = data.partialChests

    -- Sort items
    self:sortDisplayItems()
end

function DisplayManager:sortDisplayItems()
    table.sort(self.displayItems, function(a, b)
        -- Priority for active items
        local aPriority = 0
        local bPriority = 0

        if a.searching then
            aPriority = 1
        elseif a.queued or a.overflow then
            aPriority = 2
        end

        if b.searching then
            bPriority = 1
        elseif b.queued or b.overflow then
            bPriority = 2
        end

        if aPriority ~= bPriority then
            return aPriority > bPriority
        end

        -- Sort by configured order
        for i = 1, #self.displaySort do
            local field = self.displaySort[i].sort
            if a.item[field] ~= b.item[field] then
                if self.displaySort[i].ascending then
                    return a.item[field] < b.item[field]
                else
                    return a.item[field] > b.item[field]
                end
            end
        end

        return false
    end)
end

function DisplayManager:markItemQueued(item, amount)
    for _, displayItem in ipairs(self.displayItems) do
        if displayItem.item.name == item.name and
                displayItem.item.displayName == item.displayName then
            displayItem.queued = true
            displayItem.queuedAmount = amount
            self.sound:play("minecraft:block.enchantment_table.use", 1)
            break
        end
    end
end

function DisplayManager:updateTaskStatus(type, status)
    if type == "sort" then
        -- Update queue
        while #self.tasks.sort.queue < (status.queue or 0) do
            table.insert(self.tasks.sort.queue, {})
        end
        while #self.tasks.sort.queue > (status.queue or 0) do
            table.remove(self.tasks.sort.queue)
        end

        -- Update threads
        if status.threads then
            for i, thread in ipairs(status.threads) do
                if i <= 16 and self.tasks.sort.threads[i] then
                    local wasActive = self.tasks.sort.threads[i].active
                    self.tasks.sort.threads[i].active = thread.active and thread.currentTask and thread.currentTask.type == "sort"

                    if not wasActive and self.tasks.sort.threads[i].active then
                        self:addLog(self.tasks.sort.threads[i].log, "sorting", colors.green)
                    end
                end
            end
        end
    elseif type == "deposit" then
        -- Update queue
        while #self.tasks.deposit.queue < (status.queue or 0) do
            table.insert(self.tasks.deposit.queue, {})
        end
        while #self.tasks.deposit.queue > (status.queue or 0) do
            table.remove(self.tasks.deposit.queue)
        end

        -- Update threads
        if status.threads then
            for i, thread in ipairs(status.threads) do
                if i <= 17 and self.tasks.deposit.threads[i] then
                    local wasActive = self.tasks.deposit.threads[i].active
                    self.tasks.deposit.threads[i].active = thread.active and thread.currentTask and thread.currentTask.type == "deposit"

                    if not wasActive and self.tasks.deposit.threads[i].active then
                        self:addLog(self.tasks.deposit.threads[i].log, "depositing", colors.orange)
                    end
                end
            end
        end
    elseif type == "reformat" then
        -- Update queue
        while #self.tasks.reformat.queue < (status.queue or 0) do
            table.insert(self.tasks.reformat.queue, {})
        end
        while #self.tasks.reformat.queue > (status.queue or 0) do
            table.remove(self.tasks.reformat.queue)
        end

        -- Update threads
        if status.threads then
            for i, thread in ipairs(status.threads) do
                if i <= 16 and self.tasks.reformat.threads[i] then
                    local wasActive = self.tasks.reformat.threads[i].active
                    self.tasks.reformat.threads[i].active = thread.active and thread.currentTask and thread.currentTask.type == "reformat"

                    if not wasActive and self.tasks.reformat.threads[i].active then
                        self:addLog(self.tasks.reformat.threads[i].log, "reformatting", colors.purple)
                    end
                end
            end
        end
    elseif type == "order" then
        -- Update queue
        while #self.orderQueue < (status.queue or 0) do
            table.insert(self.orderQueue, {})
        end
        while #self.orderQueue > (status.queue or 0) do
            table.remove(self.orderQueue)
        end

        self.orderLogs.active = status.active or false
        if status.active then
            self:addLog(self.orderLogs.log, "ordering", colors.blue)
        end
    end

    -- Clean expired logs
    self:cleanLogs()
end

function DisplayManager:cleanLogs()
    local now = os.epoch("utc")

    -- Clean all logs
    for _, task in pairs(self.tasks) do
        for _, thread in ipairs(task.threads) do
            while #thread.log > 0 and now > thread.log[1].time do
                table.remove(thread.log, 1)
            end
        end
    end

    while #self.orderLogs.log > 0 and now > self.orderLogs.log[1].time do
        table.remove(self.orderLogs.log, 1)
    end

    while #self.reloadLogs.log > 0 and now > self.reloadLogs.log[1].time do
        table.remove(self.reloadLogs.log, 1)
    end
end

function DisplayManager:draw()
    if not self.monitor then return end

    local w, h = self.monitor.getSize()
    self.column = math.ceil(w / self.columnWidth)

    -- Only clear on first draw
    if self.firstDraw then
        self.monitor.setCursorPos(1, 1)
        self.monitor.clear()
        self.monitor.setTextScale(0.5)
        self.firstDraw = false
    end

    -- Check if enough space
    if h <= math.floor((#self.displayItems - self.column + 1) / self.column) + 15 then
        self.monitor.setTextColor(colors.red)
        self.monitor.setTextScale(0.75)
        self.monitor.setCursorPos(1, 1)
        self.monitor.write("NOT ENOUGH SPACE")
        return
    end

    -- Button text sizes
    local reloadText = "[RELOAD]"
    local sortText = "[SORT]"
    local reformatText = "[REFORMAT]"
    local depositText = "DEPOSIT"

    if w <= 18 then
        reloadText = "RL"
        sortText = "ST"
        reformatText = "RF"
        depositText = "DP"
    elseif w <= 36 then
        reloadText = "RLD"
        sortText = "SRT"
        reformatText = "RFM"
        depositText = "DPS"
    end

    -- DRAW THREAD VISUALIZATION FIRST (like original)
    -- This ensures bars are drawn before anything else overwrites them

    -- Thread lists configuration (matching original)
    local lists = {
        reloadLog = {
            type = "singlelog",
            list = self.reloadLogs.log,
            condition = self.reloadLogs.active,
            color = colors.cyan,
            x = 1,
            y = h,
            gap = 1
        },
        sortQueue = {
            type = "queue",
            list = self.tasks.sort.queue,
            condition = #self.tasks.sort.queue > 0,
            color = colors.green,
            x = 2 + string.len(reloadText),
            y = h,
            gap = 1
        },
        sortThreads = {
            type = "threads",
            list = self.tasks.sort.threads,
            condition = nil,
            color = colors.green,
            x = 3 + string.len(reloadText),
            y = h,
            gap = 1,
            max = string.len(sortText) - 2
        },
        reformatQueue = {
            type = "queue",
            list = self.tasks.reformat.queue,
            condition = #self.tasks.reformat.queue > 0,
            color = colors.purple,
            x = 3 + string.len(reloadText) + string.len(sortText),
            y = h,
            gap = 1
        },
        reformatThreads = {
            type = "threads",
            list = self.tasks.reformat.threads,
            condition = nil,
            color = colors.purple,
            x = 4 + string.len(reloadText) + string.len(sortText),
            y = h,
            gap = 1,
            max = string.len(reformatText) - 2
        },
        depositQueue = {
            type = "queue",
            list = self.tasks.deposit.queue,
            condition = #self.tasks.deposit.queue > 0,
            color = colors.orange,
            x = 4 + string.len(reloadText) + string.len(sortText) + string.len(reformatText),
            y = h,
            gap = 1
        },
        depositThreads = {
            type = "threads",
            list = self.tasks.deposit.threads,
            condition = nil,
            color = colors.orange,
            x = 5 + string.len(reloadText) + string.len(sortText) + string.len(reformatText),
            y = h,
            gap = 1,
            max = string.len(depositText) - 2
        },
        orderQueue = {
            type = "queue",
            list = self.orderQueue,
            condition = #self.orderQueue > 0,
            color = colors.blue,
            x = w - 1,
            y = h,
            gap = 0
        },
        orderLog = {
            type = "singlelog",
            list = self.orderLogs.log,
            condition = self.orderLogs.active,
            color = colors.blue,
            x = w,
            y = h,
            gap = 0
        }
    }

    -- Draw thread visualization (bars and indicators)
    for k, v in pairs(lists) do
        if v.list ~= nil then
            if v.type ~= "threads" then
                -- Draw queue/status indicators
                self.monitor.setCursorPos(v.x, v.y)
                if v.condition then
                    self.monitor.setTextColor(v.color)
                else
                    self.monitor.setTextColor(colors.gray)
                end
                if v.type == "queue" then
                    self.monitor.write("Q")
                else
                    self.monitor.write("S")
                end
            end

            local amount = 0
            for i = 1, #v.list do
                if v.type == "threads" then
                    -- Draw thread indicators and bars
                    if (v.list[i].active or #v.list[i].log > 0 or 16 <= (v.max or 0)) and amount <= (v.max or 999) then
                        local threadNumber = string.format("%X", i - 1)
                        if i > 16 then
                            threadNumber = "+"
                        end

                        -- Draw bars FIRST
                        for i2 = 1, #v.list[i].log do
                            if i2 <= 10 then  -- Max 10 bars
                                self.monitor.setCursorPos(v.x + amount, v.y - v.gap - i2)
                                self.monitor.setTextColor(v.list[i].log[i2].color)
                                self.monitor.write("\138")
                            end
                        end

                        -- Then draw thread number
                        self.monitor.setCursorPos(v.x + amount, v.y)
                        if v.list[i].active then
                            self.monitor.setTextColor(v.color)
                        else
                            self.monitor.setTextColor(colors.gray)
                        end
                        self.monitor.write(threadNumber)

                        amount = amount + string.len(threadNumber)
                    end
                elseif v.type == "singlelog" then
                    -- Draw single log bars
                    if v.list[i] ~= nil then
                        self.monitor.setCursorPos(v.x, v.y - v.gap - i)
                        self.monitor.setTextColor(v.list[i].color)
                        self.monitor.write("\138")
                    end
                elseif v.type == "queue" then
                    -- Draw queue bars
                    if i < 10 then
                        self.monitor.setCursorPos(v.x, v.y - v.gap - i)
                        self.monitor.setTextColor(v.color)
                        self.monitor.write("\138")
                    end
                end
            end
        end
    end

    -- NOW DRAW EVERYTHING ELSE ON TOP

    -- Draw header (sort buttons)
    local add = 0
    for i = 1, #self.displaySort do
        if i == 1 then add = 1 end

        local color = colors.white
        if self.displaySort[i].ascending then
            color = colors.lime
        else
            color = colors.red
        end

        if self.selectedSort == i then
            color = colors.cyan
        end

        self.monitor.setCursorPos(1 + add, 1)
        self.monitor.setTextColor(color)
        self.monitor.write(self.displaySortVisual[self.displaySort[i].sort].large)

        add = add + string.len(self.displaySortVisual[self.displaySort[i].sort].large) + 1
    end

    if self.selectedSort then
        self.monitor.setCursorPos(1 + add, 1)
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("[\18]")
    end

    -- Draw separator
    self.monitor.setTextColor(colors.gray)
    for i = 2, w - 1 do
        self.monitor.setCursorPos(i, 2)
        self.monitor.write("\140")
    end

    -- Draw items
    for i = 1, #self.displayItems do
        local item = self.displayItems[i]

        if item == self.selectedItem then
            self.monitor.setTextColor(colors.cyan)
        elseif item.searching then
            self.monitor.setTextColor(colors.lime)
        elseif item.queued then
            self.monitor.setTextColor(colors.green)
        elseif item.merged then
            self.monitor.setTextColor(colors.yellow)
        elseif item.added then
            self.monitor.setTextColor(colors.orange)
        elseif item.overflow then
            self.monitor.setTextColor(colors.purple)
        elseif math.fmod(math.ceil(i / self.column), 2) == 0 then
            self.monitor.setTextColor(colors.lightGray)
        else
            self.monitor.setTextColor(colors.white)
        end

        local itemX = 0
        for i2 = 0, self.column do
            if math.fmod(i, i2) == 0 then
                local widthDiff = math.floor(w / self.column)
                itemX = (i - 1) * widthDiff - math.floor((i - 1) / self.column) * widthDiff * self.column
            end
        end

        self.monitor.setCursorPos(2 + itemX, 2 + math.ceil(i / self.column))
        local itemCount = tostring(item.item.count)
        self.monitor.write(string.sub(item.item.displayName, 1, math.floor(w / self.column) - 3 - string.len(itemCount)))

        -- Count color
        if item.item.count > item.item.maxCount * 16 then
            self.monitor.setTextColor(colors.pink)
        elseif item.item.count > item.item.maxCount * 8 then
            self.monitor.setTextColor(colors.magenta)
        elseif item.item.count > item.item.maxCount * 4 then
            self.monitor.setTextColor(colors.purple)
        elseif item.item.count > item.item.maxCount * 2 then
            self.monitor.setTextColor(colors.blue)
        elseif item.item.count > item.item.maxCount then
            self.monitor.setTextColor(colors.lightBlue)
        elseif math.fmod(i, 2) == 0 then
            self.monitor.setTextColor(colors.lightGray)
        else
            self.monitor.setTextColor(colors.white)
        end

        self.monitor.setCursorPos(itemX + (w / self.column) - string.len(itemCount), 2 + math.ceil(i / self.column))
        self.monitor.write(itemCount)
    end

    -- Draw column separators
    self.monitor.setTextColor(colors.gray)
    for i = 1, self.column - 1 do
        for i2 = 3, math.ceil(#self.displayItems / self.column) + 2 do
            self.monitor.setCursorPos(math.floor(w / self.column) * i, i2)
            self.monitor.write("\127\149")
        end
    end

    -- Draw status line
    local statusY = 3 + math.ceil(#self.displayItems / self.column)

    if self.emptySlots > 108 then
        self.monitor.setTextColor(colors.cyan)
    elseif self.emptySlots > 81 then
        self.monitor.setTextColor(colors.green)
    elseif self.emptySlots > 54 then
        self.monitor.setTextColor(colors.yellow)
    elseif self.emptySlots > 27 then
        self.monitor.setTextColor(colors.orange)
    elseif self.emptySlots > 0 then
        self.monitor.setTextColor(colors.red)
    else
        self.monitor.setTextColor(colors.purple)
    end

    local slotText = self.emptySlots .. " slots free"
    if w < 36 then
        slotText = tostring(self.emptySlots)
    elseif self.emptySlots == 0 then
        slotText = "FULL"
    end

    self.monitor.setCursorPos(2, statusY)
    self.monitor.write(slotText)

    -- Chest status
    if self.partialChests + self.fullChests > 0 and self.fullChests > 0 then
        self.monitor.setTextColor(colors.purple)
    elseif self.partialChests > 3 then
        self.monitor.setTextColor(colors.red)
    elseif self.partialChests > 2 then
        self.monitor.setTextColor(colors.orange)
    elseif self.partialChests > 1 then
        self.monitor.setTextColor(colors.yellow)
    else
        self.monitor.setTextColor(colors.green)
    end

    local chestText = self.fullChests .. " + " .. self.partialChests .. " storage filled"
    if w < 36 then
        chestText = self.fullChests .. "+" .. self.partialChests
    elseif self.fullChests == 0 and self.partialChests == 0 then
        chestText = "EMPTY"
    end

    self.monitor.setCursorPos(w - string.len(chestText), statusY)
    self.monitor.write(chestText)

    -- Separator between status and empty space
    self.monitor.setTextColor(colors.gray)
    for i = 3 + string.len(slotText), w - 2 - string.len(chestText) do
        self.monitor.setCursorPos(i, statusY)
        self.monitor.write("\140")
    end

    -- Draw separator before thread visualization
    if statusY < h - 12 then
        for i = 1, w do
            self.monitor.setCursorPos(i, h - 12)
            self.monitor.write("_")
        end
    end

    -- Draw bottom buttons
    self.monitor.setCursorPos(1, h - 1)
    self.monitor.setTextColor(colors.cyan)
    self.monitor.write(reloadText)

    self.monitor.setCursorPos(2 + string.len(reloadText), h - 1)
    self.monitor.setTextColor(colors.green)
    self.monitor.write(sortText)

    self.monitor.setCursorPos(3 + string.len(reloadText) + string.len(sortText), h - 1)
    self.monitor.setTextColor(colors.purple)
    self.monitor.write(reformatText)

    self.monitor.setCursorPos(4 + string.len(reloadText) + string.len(sortText) + string.len(reformatText), h - 1)
    self.monitor.setTextColor(colors.orange)
    self.monitor.write(depositText)

    -- Draw selected item controls
    if self.selectedItem ~= nil then
        self.monitor.setTextColor(colors.purple)
        if w > 18 then
            self.monitor.setCursorPos(w - 2 - string.len(string.sub(self.selectedItem.item.displayName, 1, w)), h - 4)
        elseif 9 - string.len(self.selectedItem.item.displayName) / 2 < 1 then
            self.monitor.setCursorPos(1, h - 4)
        else
            self.monitor.setCursorPos(9 - string.len(self.selectedItem.item.displayName) / 2, h - 4)
        end
        self.monitor.write(self.selectedItem.item.displayName)

        -- Amount controls
        self.monitor.setCursorPos(w - 12, h - 3)
        self.monitor.setTextColor(colors.red)
        self.monitor.write("<")

        self.monitor.setCursorPos(w - 11, h - 3)
        self.monitor.setTextColor(colors.orange)
        self.monitor.write("<")

        self.monitor.setCursorPos(w - 10, h - 3)
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("<")

        self.monitor.setTextColor(colors.white)
        self.monitor.setCursorPos(w - 6 - string.len(tostring(self.desiredAmount)) / 2, h - 3)
        self.monitor.write(tostring(self.desiredAmount))

        self.monitor.setCursorPos(w - 4, h - 3)
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write(">")

        self.monitor.setCursorPos(w - 3, h - 3)
        self.monitor.setTextColor(colors.lime)
        self.monitor.write(">")

        self.monitor.setCursorPos(w - 2, h - 3)
        self.monitor.setTextColor(colors.green)
        self.monitor.write(">")

        -- Order button
        self.monitor.setCursorPos(w - 10, h - 2)
        self.monitor.setTextColor(colors.blue)
        self.monitor.write("[ORDER]")
    end
end

function DisplayManager:handleTouch(x, y)
    if not self.monitor then return end

    local w, h = self.monitor.getSize()

    -- Button text sizes
    local reloadText = "[RELOAD]"
    local sortText = "[SORT]"
    local reformatText = "[REFORMAT]"

    if w <= 18 then
        reloadText = "RL"
        sortText = "ST"
        reformatText = "RF"
    elseif w <= 36 then
        reloadText = "RLD"
        sortText = "SRT"
        reformatText = "RFM"
    end

    -- Check item selection
    if y < h - 10 then
        for i = 1, #self.displayItems do
            local itemX = 0
            for i2 = 0, self.column do
                if math.fmod(i, i2) == 0 then
                    local widthDiff = math.floor(w / self.column)
                    itemX = (i - 1) * widthDiff - math.floor((i - 1) / self.column) * widthDiff * self.column
                end
            end

            if x > 2 + itemX and x < itemX + (w / self.column) and y == 2 + math.ceil(i / self.column) then
                if not self.displayItems[i].queued then
                    self.selectedItem = self.displayItems[i]
                    if self.selectedItem.item.count < self.selectedItem.item.maxCount then
                        self.desiredAmount = self.selectedItem.item.count
                    else
                        self.desiredAmount = self.selectedItem.item.maxCount
                    end
                    self.sound:play("minecraft:block.amethyst_block.resonate", 1)
                end
                return
            end
        end

        -- Deselect if clicked elsewhere
        if y < h - 3 then
            self.selectedItem = nil
        end
    end

    -- Bottom control buttons
    if y == h - 1 then
        if x >= 1 and x <= string.len(reloadText) then
            self.eventBus:emit("storage:reload")
            self.eventBus:emit("storage:reload_started")
            self.selectedItem = nil
            self.sound:play("minecraft:item.book.page_turn", 1)
        elseif x >= 2 + string.len(reloadText) and x < 2 + string.len(reloadText) + string.len(sortText) then
            self.eventBus:emit("storage:sort", true)
            self.sound:play("minecraft:block.barrel.open", 1)
        elseif x >= 3 + string.len(reloadText) + string.len(sortText) and
                x < 3 + string.len(reloadText) + string.len(sortText) + string.len(reformatText) then
            self.eventBus:emit("storage:reformat")
            self.sound:play("minecraft:block.ender_chest.open", 1)
        end
    end

    -- Sort header buttons
    if y == 1 then
        local add = 1
        for i = 1, #self.displaySort do
            local buttonLen = string.len(self.displaySortVisual[self.displaySort[i].sort].large)

            if x >= add and x < add + buttonLen then
                if self.selectedSort then
                    if self.selectedSort ~= i then
                        local tempSort = self.displaySort[self.selectedSort]
                        table.remove(self.displaySort, self.selectedSort)
                        table.insert(self.displaySort, i, tempSort)
                        self.sound:play("minecraft:block.ender_chest.close", 1)
                    else
                        self.sound:play("minecraft:block.sculk_sensor.clicking_stop", 1)
                    end
                    self.selectedSort = nil
                else
                    self.selectedSort = i
                    self.sound:play("minecraft:block.ender_chest.open", 1)
                end
                self:sortDisplayItems()
                return
            end

            add = add + buttonLen + 1
        end

        -- Direction toggle
        if self.selectedSort and x >= add and x < add + 3 then
            self.displaySort[self.selectedSort].ascending = not self.displaySort[self.selectedSort].ascending
            self.sound:play("minecraft:block.sculk_sensor.clicking", 1)
            self.selectedSort = nil
            self:sortDisplayItems()
        end
    end

    -- Order controls
    if self.selectedItem and y == h - 3 then
        if x == w - 12 then
            self.desiredAmount = math.max(1, self.desiredAmount - self.selectedItem.item.maxCount)
            self.sound:play("minecraft:block.amethyst_block.break", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        elseif x == w - 11 then
            self.desiredAmount = math.max(1, self.desiredAmount - 10)
            self.sound:play("minecraft:block.amethyst_block.hit", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        elseif x == w - 10 then
            self.desiredAmount = math.max(1, self.desiredAmount - 1)
            self.sound:play("minecraft:block.amethyst_block.step", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        elseif x == w - 4 then
            self.desiredAmount = math.min(math.min(999, self.selectedItem.item.count), self.desiredAmount + 1)
            self.sound:play("minecraft:block.amethyst_block.step", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        elseif x == w - 3 then
            self.desiredAmount = math.min(math.min(999, self.selectedItem.item.count), self.desiredAmount + 10)
            self.sound:play("minecraft:block.amethyst_block.hit", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        elseif x == w - 2 then
            self.desiredAmount = math.min(math.min(999, self.selectedItem.item.count),
                    self.desiredAmount + self.selectedItem.item.maxCount)
            self.sound:play("minecraft:block.amethyst_block.break", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
        end
    end

    -- Order button
    if self.selectedItem and y == h - 2 and x >= w - 10 and x <= w - 3 then
        self.eventBus:emit("storage:order", self.selectedItem.item, self.desiredAmount)
        self.selectedItem.queued = true
        self.selectedItem.queuedAmount = self.desiredAmount
        self.sound:play("minecraft:block.enchantment_table.use", 1)
        self.selectedItem = nil
    end
end

function DisplayManager:run()
    if not self.monitor then
        self.logger:warning("No monitor found, display manager idle", "Display")
        while self.running do
            self:findMonitor()
            if self.monitor then
                self.logger:success("Monitor detected, starting display", "Display")
                break
            end
            sleep(5)
        end
    end

    if not self.monitor then
        return
    end

    -- Initial draw
    self:draw()

    -- Main loop
    local drawTimer = os.startTimer(0.1)

    while self.running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == drawTimer then
            if self.monitor then
                self:draw()
            else
                self:findMonitor()
            end
            drawTimer = os.startTimer(0.1)
        elseif event == "monitor_touch" then
            if self.monitor and peripheral.getName(self.monitor) == p1 then
                self:handleTouch(p2, p3)
            end
        elseif event == "process:stop:display" then
            self.running = false
        end
    end

    self.logger:info("Display manager stopped", "Display")
end

return DisplayManager