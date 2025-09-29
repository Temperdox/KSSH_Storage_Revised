-- modules/display_manager.lua
-- Monitor display management - preserves original UI

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

    -- Task status tracking
    self.sortThreads = {}
    self.depositThreads = {}
    self.reformatThreads = {}
    self.sortQueue = 0
    self.depositQueue = 0
    self.reformatQueue = 0
    self.orderQueue = 0
    self.orderActive = false

    -- Logs for display
    self.reloadActive = false
    self.reloadLog = {}
    self.orderLog = {}

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

    -- Stop event
    self.eventBus:on("process:stop:display", function()
        self.running = false
    end)
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

        if a.searching then aPriority = 1
        elseif a.queued or a.overflow then aPriority = 2 end

        if b.searching then bPriority = 1
        elseif b.queued or b.overflow then bPriority = 2 end

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
        self.sortQueue = status.queue or 0
        self.sortThreads = status.threads or {}
    elseif type == "deposit" then
        self.depositQueue = status.queue or 0
        self.depositThreads = status.threads or {}
    elseif type == "reformat" then
        self.reformatQueue = status.queue or 0
        self.reformatThreads = status.threads or {}
    elseif type == "order" then
        self.orderQueue = status.queue or 0
        self.orderActive = status.active or false
    end
end

function DisplayManager:drawHeader()
    if not self.monitor then return end

    local w, h = self.monitor.getSize()

    -- Sort buttons
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

    -- Direction button if sort selected
    if self.selectedSort then
        self.monitor.setCursorPos(1 + add, 1)
        self.monitor.setTextColor(colors.yellow)
        self.monitor.write("[\18]")
    end
end

function DisplayManager:drawItems()
    if not self.monitor then return end

    local w, h = self.monitor.getSize()
    self.column = math.ceil(w / self.columnWidth)

    -- Draw separator
    self.monitor.setTextColor(colors.gray)
    for i = 2, w - 1 do
        self.monitor.setCursorPos(i, 2)
        self.monitor.write("\140")
    end

    -- Draw items
    for i = 1, #self.displayItems do
        local item = self.displayItems[i]

        -- Determine color
        local color = colors.white
        if item == self.selectedItem then
            color = colors.cyan
        elseif item.searching then
            color = colors.lime
        elseif item.queued then
            color = colors.green
        elseif item.merged then
            color = colors.yellow
        elseif item.added then
            color = colors.orange
        elseif item.overflow then
            color = colors.purple
        elseif math.fmod(math.ceil(i / self.column), 2) == 0 then
            color = colors.lightGray
        end

        self.monitor.setTextColor(color)

        -- Calculate position
        local itemX = 0
        for i2 = 0, self.column do
            if math.fmod(i, i2) == 0 then
                local widthDiff = math.floor(w / self.column)
                itemX = (i - 1) * widthDiff - math.floor((i - 1) / self.column) * widthDiff * self.column
            end
        end

        -- Draw item name
        self.monitor.setCursorPos(2 + itemX, 2 + math.ceil(i / self.column))
        local nameLen = math.floor(w / self.column) - 3 - string.len(tostring(item.item.count))
        self.monitor.write(string.sub(item.item.displayName, 1, nameLen))

        -- Draw item count with color coding
        local countColor = colors.white
        if item.item.count > item.item.maxCount * 16 then
            countColor = colors.pink
        elseif item.item.count > item.item.maxCount * 8 then
            countColor = colors.magenta
        elseif item.item.count > item.item.maxCount * 4 then
            countColor = colors.purple
        elseif item.item.count > item.item.maxCount * 2 then
            countColor = colors.blue
        elseif item.item.count > item.item.maxCount then
            countColor = colors.lightBlue
        end

        self.monitor.setTextColor(countColor)
        self.monitor.setCursorPos(itemX + (w / self.column) - string.len(tostring(item.item.count)),
                2 + math.ceil(i / self.column))
        self.monitor.write(tostring(item.item.count))
    end

    -- Draw column separators
    self.monitor.setTextColor(colors.gray)
    for i = 1, self.column - 1 do
        for i2 = 3, math.ceil(#self.displayItems / self.column) + 2 do
            self.monitor.setCursorPos(math.floor(w / self.column) * i, i2)
            self.monitor.write("\127\149")
        end
    end
end

function DisplayManager:drawStatus()
    if not self.monitor then return end

    local w, h = self.monitor.getSize()
    local statusY = 3 + math.ceil(#self.displayItems / self.column)

    -- Empty slots
    local slotColor = colors.cyan
    if self.emptySlots <= 0 then
        slotColor = colors.purple
    elseif self.emptySlots <= 27 then
        slotColor = colors.red
    elseif self.emptySlots <= 54 then
        slotColor = colors.orange
    elseif self.emptySlots <= 81 then
        slotColor = colors.yellow
    elseif self.emptySlots <= 108 then
        slotColor = colors.green
    end

    local slotText = self.emptySlots .. " slots free"
    if w < 36 then
        slotText = tostring(self.emptySlots)
    elseif self.emptySlots == 0 then
        slotText = "FULL"
    end

    self.monitor.setCursorPos(2, statusY)
    self.monitor.setTextColor(slotColor)
    self.monitor.write(slotText)

    -- Chest status
    local chestColor = colors.green
    if self.partialChests + self.fullChests > 0 and self.fullChests > 0 then
        chestColor = colors.purple
    elseif self.partialChests > 3 then
        chestColor = colors.red
    elseif self.partialChests > 2 then
        chestColor = colors.orange
    elseif self.partialChests > 1 then
        chestColor = colors.yellow
    end

    local chestText = self.fullChests .. " + " .. self.partialChests .. " storage filled"
    if w < 36 then
        chestText = self.fullChests .. "+" .. self.partialChests
    elseif self.fullChests == 0 and self.partialChests == 0 then
        chestText = "EMPTY"
    end

    self.monitor.setCursorPos(w - string.len(chestText), statusY)
    self.monitor.setTextColor(chestColor)
    self.monitor.write(chestText)
end

function DisplayManager:drawButtons()
    if not self.monitor then return end

    local w, h = self.monitor.getSize()

    -- Bottom buttons
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

    self.monitor.setCursorPos(1, h - 1)
    self.monitor.setTextColor(colors.cyan)
    self.monitor.write(reloadText)

    self.monitor.setCursorPos(2 + string.len(reloadText), h - 1)
    self.monitor.setTextColor(colors.green)
    self.monitor.write(sortText)

    self.monitor.setCursorPos(3 + string.len(reloadText) + string.len(sortText), h - 1)
    self.monitor.setTextColor(colors.purple)
    self.monitor.write(reformatText)

    -- Order controls if item selected
    if self.selectedItem then
        -- Item name
        self.monitor.setCursorPos(w - 2 - string.len(self.selectedItem.item.displayName), h - 4)
        self.monitor.setTextColor(colors.purple)
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

        self.monitor.setCursorPos(w - 6 - string.len(tostring(self.desiredAmount)) / 2, h - 3)
        self.monitor.setTextColor(colors.white)
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

function DisplayManager:draw()
    if not self.monitor then return end

    self.monitor.clear()
    self.monitor.setTextScale(0.5)

    local w, h = self.monitor.getSize()

    -- Calculate required height more accurately
    local itemRows = math.max(1, math.ceil(#self.displayItems / self.column))
    local requiredHeight = itemRows + 8  -- Header + items + status + buttons + margins

    if h >= requiredHeight then
        self:drawHeader()
        self:drawItems()
        self:drawStatus()
        self:drawButtons()
    else
        -- Try smaller text scale
        self.monitor.setTextScale(0.25)
        w, h = self.monitor.getSize()

        itemRows = math.max(1, math.ceil(#self.displayItems / math.ceil(w / 12)))
        requiredHeight = itemRows + 6

        if h >= requiredHeight then
            self:drawHeader()
            self:drawItems()
            self:drawStatus()
            self:drawButtons()
        else
            -- Show error message
            self.monitor.setTextColor(colors.red)
            self.monitor.setTextScale(0.5)
            self.monitor.setCursorPos(1, 1)
            self.monitor.write("MONITOR TOO SMALL")
            self.monitor.setCursorPos(1, 2)
            self.monitor.write("Need: " .. requiredHeight)
            self.monitor.setCursorPos(1, 3)
            self.monitor.write("Have: " .. h)
        end
    end
end

function DisplayManager:handleTouch(x, y)
    if not self.monitor then return end

    local w, h = self.monitor.getSize()

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

    -- Check button clicks
    self:handleButtonClick(x, y)
end

function DisplayManager:handleButtonClick(x, y)
    if not self.monitor then return end

    local w, h = self.monitor.getSize()

    -- Bottom control buttons
    if y == h - 1 then
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

        -- Reload button
        if x >= 1 and x <= string.len(reloadText) then
            self.eventBus:emit("storage:reload")
            self.selectedItem = nil
            self.sound:play("minecraft:item.book.page_turn", 1)
            -- Sort button
        elseif x >= 2 + string.len(reloadText) and
                x < 2 + string.len(reloadText) + string.len(sortText) then
            self.eventBus:emit("storage:sort", true)
            self.sound:play("minecraft:block.barrel.open", 1)
            -- Reformat button
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
                        -- Reorder sort priorities
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

        -- Direction toggle button
        if self.selectedSort and x >= add and x < add + 3 then
            self.displaySort[self.selectedSort].ascending = not self.displaySort[self.selectedSort].ascending
            self.sound:play("minecraft:block.sculk_sensor.clicking", 1)
            self.selectedSort = nil
            self:sortDisplayItems()
        end
    end

    -- Order controls
    if self.selectedItem and y == h - 3 then
        -- Stack down
        if x == w - 12 then
            self.desiredAmount = math.max(1, self.desiredAmount - self.selectedItem.item.maxCount)
            self.sound:play("minecraft:block.amethyst_block.break", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
            -- Ten down
        elseif x == w - 11 then
            self.desiredAmount = math.max(1, self.desiredAmount - 10)
            self.sound:play("minecraft:block.amethyst_block.hit", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
            -- One down
        elseif x == w - 10 then
            self.desiredAmount = math.max(1, self.desiredAmount - 1)
            self.sound:play("minecraft:block.amethyst_block.step", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
            -- One up
        elseif x == w - 4 then
            self.desiredAmount = math.min(math.min(999, self.selectedItem.item.count), self.desiredAmount + 1)
            self.sound:play("minecraft:block.amethyst_block.step", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
            -- Ten up
        elseif x == w - 3 then
            self.desiredAmount = math.min(math.min(999, self.selectedItem.item.count), self.desiredAmount + 10)
            self.sound:play("minecraft:block.amethyst_block.hit", 0.5 + (self.desiredAmount / self.selectedItem.item.count))
            -- Stack up
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
            sleep(1)
        end
        return
    end

    -- Initial draw
    self:draw()

    -- Main loop
    local drawTimer = os.startTimer(0.1)

    while self.running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == drawTimer then
            self:draw()
            drawTimer = os.startTimer(0.1)
        elseif event == "monitor_touch" then
            self:handleTouch(p2, p3)
        end
    end

    self.logger:info("Display manager stopped", "Display")
end

return DisplayManager