-- modules/storage_manager.lua
-- Core storage management logic - COMPLETE FIX

local StorageManager = {}
StorageManager.__index = StorageManager

local TaskExecutor = require("modules.task_executor")
local InventoryScanner = require("modules.inventory_scanner")
local SoundManager = require("modules.sound_manager")

function StorageManager:new(logger, eventBus)
    local self = setmetatable({}, StorageManager)
    self.logger = logger
    self.eventBus = eventBus
    self.running = true

    -- Initialize components
    self.scanner = InventoryScanner:new(logger)
    self.executor = TaskExecutor:new(logger, 16)
    self.sound = SoundManager:new(logger)

    -- Storage data
    self.items = {}
    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0

    -- Chest references
    self.inputChest = nil
    self.outputChest = nil
    self.storageChests = {}

    -- Task queues (matching old code structure)
    self.sortQueue = {}
    self.depositQueue = {}
    self.reformatQueue = {}
    self.orderQueue = {}

    -- Queue processing flags
    self.reload = false
    self.sort = false
    self.reformat = false
    self.calculate = false

    -- Settings
    self.sortConsolidate = true
    self.autoDeposit = true

    -- Register event handlers
    self:registerEvents()

    -- Scan for peripherals
    self:scanPeripherals()

    return self
end

function StorageManager:registerEvents()
    -- Direct queue manipulation like old code
    self.eventBus:on("storage:reload", function()
        self.reload = true
        self.selectedItem = nil
    end)

    self.eventBus:on("storage:sort", function(consolidate)
        self.sort = true
        self.sortConsolidate = consolidate ~= false
    end)

    self.eventBus:on("storage:reformat", function()
        self.reformat = true
    end)

    self.eventBus:on("storage:order", function(item, amount)
        table.insert(self.orderQueue, {
            item = item,
            amount = amount
        })
        self.logger:info(string.format("Order queued: %dx %s", amount, item.displayName), "Storage")
        self.eventBus:emit("storage:order_queued", item, amount)
        self:updateTaskStatus()
    end)

    self.eventBus:on("storage:deposit", function()
        self:queueDeposit()
    end)

    self.eventBus:on("api:items_response", function()
        self.eventBus:emit("api:items_response", self.items)
    end)

    self.eventBus:on("process:stop:storage", function()
        self.running = false
    end)
end

function StorageManager:scanPeripherals()
    self.logger:info("Scanning for peripherals...", "Storage")

    -- Reset chest lists
    self.inputChest = nil
    self.outputChest = nil
    self.storageChests = {}

    -- Find all inventories
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        local p = peripheral.wrap(name)

        -- Skip terminal-side peripherals
        local badPositions = {"top", "bottom", "front", "back", "left", "right"}
        local skip = false
        for _, pos in ipairs(badPositions) do
            if name == pos then
                skip = true
                break
            end
        end

        if not skip and p and p.size then
            if pType == "minecraft:chest" then
                -- Regular chest is input
                if not self.inputChest then
                    self.inputChest = p
                    self.logger:success("Input chest found: " .. name, "Storage")
                end
            elseif pType == "minecraft:trapped_chest" then
                -- Trapped chest is output
                if not self.outputChest then
                    self.outputChest = p
                    self.logger:success("Output chest found: " .. name, "Storage")
                end
            elseif p.size() > 0 then
                -- Any other inventory is storage
                table.insert(self.storageChests, {
                    peripheral = p,
                    name = name
                })
                self.logger:info("Storage found: " .. name, "Storage")
            end
        end
    end

    self.logger:info(string.format("Found %d storage containers", #self.storageChests), "Storage")

    -- Notify display manager
    self.eventBus:emit("storage:peripherals_updated", {
        input = self.inputChest ~= nil,
        output = self.outputChest ~= nil,
        storage = #self.storageChests
    })
end

function StorageManager:updateTaskStatus()
    -- Send task status to display for visualization
    self.eventBus:emit("task:status", "sort", {
        queue = #self.sortQueue,
        threads = self.executor:getStatus().threads or {}
    })

    self.eventBus:emit("task:status", "deposit", {
        queue = #self.depositQueue,
        threads = self.executor:getStatus().threads or {}
    })

    self.eventBus:emit("task:status", "reformat", {
        queue = #self.reformatQueue,
        threads = self.executor:getStatus().threads or {}
    })

    self.eventBus:emit("task:status", "order", {
        queue = #self.orderQueue,
        active = #self.orderQueue > 0
    })
end

function StorageManager:reloadStorage()
    self.logger:info("Reloading storage data...", "Storage")
    self.sound:play("minecraft:item.book.page_turn", 1)

    self.items = {}
    local itemMap = {}

    -- Scan all storage chests
    for _, chest in ipairs(self.storageChests) do
        self.logger:debug("Scanning " .. chest.name, "Storage")
        self.sound:play("minecraft:item.spyglass.use", 1)

        local items = self.scanner:scanChest(chest.peripheral, chest.name)

        -- Merge items into main list
        for _, item in ipairs(items) do
            local key = item.name .. "|" .. item.displayName .. "|" .. (item.nbt or "")

            if itemMap[key] then
                itemMap[key].count = itemMap[key].count + item.count
            else
                itemMap[key] = {
                    name = item.name,
                    displayName = item.displayName,
                    count = item.count,
                    maxCount = item.maxCount,
                    nbt = item.nbt
                }
            end
        end
    end

    -- Convert map to list
    for _, item in pairs(itemMap) do
        table.insert(self.items, item)
    end

    -- Calculate storage space
    self:calculateSpace()

    -- Notify display with updated data
    self.eventBus:emit("storage:data_updated", {
        items = self.items,
        emptySlots = self.emptySlots,
        fullChests = self.fullChests,
        partialChests = self.partialChests
    })

    self.logger:success(string.format("Storage reload complete: %d items, %d empty slots",
            #self.items, self.emptySlots), "Storage")
    self.sound:play("minecraft:item.book.put", 1)
    self.sound:play("minecraft:block.beacon.activate", 1)
end

function StorageManager:calculateSpace()
    self.logger:info("Calculating space", "Storage")

    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0

    for _, chest in ipairs(self.storageChests) do
        self.logger:debug("Calculating space in " .. chest.name, "Storage")
        self.sound:play("minecraft:item.spyglass.use", 1)

        local usage = self.scanner:getChestUsage(chest.peripheral)

        self.emptySlots = self.emptySlots + usage.free

        if usage.used == usage.size then
            self.fullChests = self.fullChests + 1
        elseif usage.used > 0 then
            self.partialChests = self.partialChests + 1
        end
    end

    self.sound:play("minecraft:block.end_portal_frame.fill", 1)
    self.logger:success("Calculation concluded", "Storage")
end

function StorageManager:queueSort(consolidate)
    if consolidate == nil then
        consolidate = self.sortConsolidate
    end

    for _, chest in ipairs(self.storageChests) do
        local chestFull = 0
        for k,v in pairs(chest.peripheral.list()) do
            chestFull = chestFull + 1
        end

        if chestFull > 0 then
            table.insert(self.sortQueue, {
                chest = chest,
                consolidate = consolidate
            })
            self.logger:info("Queued sort for " .. chest.name, "Storage")
        end
    end

    self:updateTaskStatus()
end

function StorageManager:queueDeposit()
    if not self.inputChest then
        self.logger:error("No input chest configured", "Storage")
        return
    end

    for _, chest in ipairs(self.storageChests) do
        table.insert(self.depositQueue, chest)
        self.logger:info("Queued deposit for " .. chest.name, "Storage")
    end

    self:updateTaskStatus()
end

function StorageManager:queueReformat()
    for _, chest in ipairs(self.storageChests) do
        local chestFull = 0
        for k,v in pairs(chest.peripheral.list()) do
            chestFull = chestFull + 1
        end

        if chestFull > 0 then
            table.insert(self.reformatQueue, chest)
            self.logger:info("Queued reformat for " .. chest.name, "Storage")
        end
    end

    self:updateTaskStatus()
end

function StorageManager:sortChest(chest, name, consolidate)
    local size = chest.size()
    local sorted = false
    local passes = 0

    repeat
        sorted = true
        passes = passes + 1

        local firstEmpty = nil
        for slot = 1, size do
            if not chest.getItemDetail(slot) then
                firstEmpty = slot
                break
            end
        end

        if firstEmpty and firstEmpty < size then
            for slot = firstEmpty + 1, size do
                local item = chest.getItemDetail(slot)
                if item then
                    chest.pushItems(peripheral.getName(chest), slot, item.count, firstEmpty)
                    sorted = false
                    break
                end
            end
        end

        if consolidate and sorted then
            sorted = self:consolidateChest(chest, name)
        end

    until sorted or passes >= 10

    return sorted
end

function StorageManager:consolidateChest(chest, name)
    local size = chest.size()
    local consolidated = true

    for slot1 = 1, size - 1 do
        local item1 = chest.getItemDetail(slot1)
        if item1 and item1.count < item1.maxCount then
            for slot2 = slot1 + 1, size do
                local item2 = chest.getItemDetail(slot2)
                if item2 and item1.name == item2.name and
                        (item1.nbt == item2.nbt or not item1.nbt or not item2.nbt) then
                    local space = item1.maxCount - item1.count
                    local moved = chest.pushItems(peripheral.getName(chest), slot2, space, slot1)
                    if moved > 0 then
                        consolidated = false
                        item1.count = item1.count + moved
                    end
                end
            end
        end
    end

    return consolidated
end

function StorageManager:depositFromInput(targetChest)
    if not self.inputChest then
        return false
    end

    local deposited = false

    for inputSlot = 1, self.inputChest.size() do
        local item = self.inputChest.getItemDetail(inputSlot)
        if item then
            -- Try to stack first
            if item.maxCount > 1 then
                for targetSlot = 1, targetChest.peripheral.size() do
                    local targetItem = targetChest.peripheral.getItemDetail(targetSlot)
                    if targetItem and targetItem.name == item.name and
                            targetItem.count < targetItem.maxCount and
                            (targetItem.nbt == item.nbt or not targetItem.nbt or not item.nbt) then

                        local space = targetItem.maxCount - targetItem.count
                        local moved = self.inputChest.pushItems(targetChest.name, inputSlot, space, targetSlot)
                        if moved > 0 then
                            deposited = true
                            self.logger:debug(string.format("Deposited %dx %s", moved, item.displayName), "Storage")
                            self.sound:play("minecraft:item.armor.equip_diamond", 1)
                        end
                    end
                end
            end

            -- Then try empty slots
            item = self.inputChest.getItemDetail(inputSlot)
            if item then
                for targetSlot = 1, targetChest.peripheral.size() do
                    if not targetChest.peripheral.getItemDetail(targetSlot) then
                        local moved = self.inputChest.pushItems(targetChest.name, inputSlot, item.count, targetSlot)
                        if moved > 0 then
                            deposited = true
                            self.logger:debug(string.format("Deposited %dx %s", moved, item.displayName), "Storage")
                            self.sound:play("minecraft:item.armor.equip_turtle", 1)
                            break
                        end
                    end
                end
            end
        end
    end

    return deposited
end

function StorageManager:processQueues()
    -- Process sort queue
    if #self.sortQueue > 0 then
        local task = table.remove(self.sortQueue, 1)
        self.executor:submit("sort", function()
            self.logger:info("Dispatched sort for " .. task.chest.name, "Storage")
            self:sortChest(task.chest.peripheral, task.chest.name, task.consolidate)
            self.eventBus:emit("storage:sort_complete", task.chest.name)
        end)
        self:updateTaskStatus()
    end

    -- Process deposit queue
    if #self.depositQueue > 0 and self.inputChest then
        local chest = table.remove(self.depositQueue, 1)
        self.executor:submit("deposit", function()
            self.logger:info("Dispatched deposit for " .. chest.name, "Storage")
            self:depositFromInput(chest)
            self.calculate = true
        end)
        self:updateTaskStatus()
    end

    -- Process reformat queue
    if #self.reformatQueue > 0 then
        local chest = table.remove(self.reformatQueue, 1)
        self.executor:submit("reformat", function()
            self.logger:info("Dispatched reformat for " .. chest.name, "Storage")
            self:sortChest(chest.peripheral, chest.name, true)
            self.calculate = true
        end)
        self:updateTaskStatus()
    end

    -- Process order queue
    if #self.orderQueue > 0 and self.outputChest then
        local order = table.remove(self.orderQueue, 1)
        self.executor:submit("order", function()
            self.logger:info(string.format("Processing order: %dx %s", order.amount, order.item.displayName), "Storage")
            -- Order processing logic here
        end)
        self:updateTaskStatus()
    end
end

-- Main loops running in parallel
function StorageManager:sortLoop()
    while self.running do
        if self.sort then
            self:queueSort(self.sortConsolidate)
            self.sort = false
        end
        sleep(1)
    end
end

function StorageManager:depositLoop()
    while self.running do
        if self.inputChest then
            local inputFull = 0
            for k,v in pairs(self.inputChest.list()) do
                inputFull = inputFull + 1
            end

            -- Check if deposit threads are active
            local active = false
            local status = self.executor:getStatus()
            for _, thread in ipairs(status.threads) do
                if thread.active and thread.currentTask and
                        thread.currentTask.type == "deposit" then
                    active = true
                    break
                end
            end

            if inputFull > 0 and self.emptySlots > 0 and not active then
                -- Sort input chest first
                self:sortChest(self.inputChest, "input", false)
                -- Queue deposit
                self:queueDeposit()
            end
        end
        sleep(1)
    end
end

function StorageManager:reformatLoop()
    while self.running do
        if self.reformat then
            self:queueReformat()
            self.reformat = false
        end
        sleep(1)
    end
end

function StorageManager:reloadLoop()
    while self.running do
        if self.reload then
            self:reloadStorage()
            self:calculateSpace()
            self.reload = false
        end
        sleep(1)
    end
end

function StorageManager:calculateLoop()
    while self.running do
        if self.calculate then
            self:calculateSpace()
            self.calculate = false
        end
        sleep(1)
    end
end

function StorageManager:processLoop()
    while self.running do
        self:processQueues()
        self.executor:tick()
        sleep(0.1)
    end
end

function StorageManager:run()
    -- Initial reload
    sleep(1)
    self.reload = true

    -- Run all loops in parallel (like old code)
    parallel.waitForAny(
            function() self:processLoop() end,
            function() self:sortLoop() end,
            function() self:depositLoop() end,
            function() self:reformatLoop() end,
            function() self:reloadLoop() end,
            function() self:calculateLoop() end
    )

    self.logger:info("Storage manager stopped", "Storage")
end

return StorageManager