-- modules/storage_manager.lua
-- Core storage management logic

local StorageManager = {}
StorageManager.__index = StorageManager

local TaskExecutor = require("modules.task_executor")
local InventoryScanner = require("modules.inventory_scanner")

function StorageManager:new(logger, eventBus)
    local self = setmetatable({}, StorageManager)
    self.logger = logger
    self.eventBus = eventBus
    self.running = true

    -- Initialize components
    self.scanner = InventoryScanner:new(logger)
    self.executor = TaskExecutor:new(logger, 16) -- 16 threads

    -- Storage data
    self.items = {}
    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0

    -- Chest references
    self.inputChest = nil
    self.outputChest = nil
    self.storageChests = {}

    -- Task queues
    self.sortQueue = {}
    self.depositQueue = {}
    self.reformatQueue = {}
    self.orderQueue = {}

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
    self.eventBus:on("storage:reload", function()
        self:reloadStorage()
    end)

    self.eventBus:on("storage:sort", function(consolidate)
        self:queueSort(consolidate)
    end)

    self.eventBus:on("storage:reformat", function()
        self:queueReformat()
    end)

    self.eventBus:on("storage:order", function(item, amount)
        self:queueOrder(item, amount)
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

function StorageManager:reloadStorage()
    self.logger:info("Reloading storage data...", "Storage")

    self.items = {}
    local itemMap = {}

    -- Scan all storage chests
    for _, chest in ipairs(self.storageChests) do
        local items = self.scanner:scanChest(chest.peripheral, chest.name)

        -- Merge items into main list
        for _, item in ipairs(items) do
            -- Create a unique key for the item
            local key = item.name .. "|" .. item.displayName .. "|" .. (item.nbt or "")

            if itemMap[key] then
                -- Add to existing item count
                itemMap[key].count = itemMap[key].count + item.count
            else
                -- Create new entry
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

    self.logger:success(string.format("Storage reload complete: %d items, %d empty slots", #self.items, self.emptySlots), "Storage")
end

function StorageManager:calculateSpace()
    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0
    local emptyChests = 0

    for _, chest in ipairs(self.storageChests) do
        local usage = self.scanner:getChestUsage(chest.peripheral)

        self.emptySlots = self.emptySlots + usage.free

        if usage.used == usage.size then
            self.fullChests = self.fullChests + 1
        elseif usage.used > 0 then
            self.partialChests = self.partialChests + 1
        else
            emptyChests = emptyChests + 1
        end
    end

    self.logger:debug(string.format("Space: %d empty slots, %d full, %d partial, %d empty chests",
            self.emptySlots, self.fullChests, self.partialChests, emptyChests), "Storage")
end

function StorageManager:queueSort(consolidate)
    if consolidate == nil then
        consolidate = self.sortConsolidate
    end

    for _, chest in ipairs(self.storageChests) do
        table.insert(self.sortQueue, {
            chest = chest,
            consolidate = consolidate
        })
    end

    self.logger:info(string.format("Queued %d chests for sorting", #self.storageChests), "Storage")

    -- Update task status
    self.eventBus:emit("task:status", "sort", {
        queue = #self.sortQueue,
        threads = {}
    })
end

function StorageManager:queueDeposit()
    if not self.inputChest then
        self.logger:error("No input chest configured", "Storage")
        return
    end

    -- Check if input chest has items
    local hasItems = false
    for slot = 1, self.inputChest.size() do
        if self.inputChest.getItemDetail(slot) then
            hasItems = true
            break
        end
    end

    if hasItems then
        -- Queue deposit for all storage chests
        for _, chest in ipairs(self.storageChests) do
            table.insert(self.depositQueue, chest)
        end

        self.logger:info("Deposit queued", "Storage")

        -- Update task status
        self.eventBus:emit("task:status", "deposit", {
            queue = #self.depositQueue,
            threads = {}
        })
    else
        self.logger:debug("Input chest empty, skipping deposit", "Storage")
    end
end

function StorageManager:queueReformat()
    for _, chest in ipairs(self.storageChests) do
        table.insert(self.reformatQueue, chest)
    end

    self.logger:info(string.format("Queued %d chests for reformatting", #self.storageChests), "Storage")

    -- Update task status
    self.eventBus:emit("task:status", "reformat", {
        queue = #self.reformatQueue,
        threads = {}
    })
end

function StorageManager:queueOrder(item, amount)
    table.insert(self.orderQueue, {
        item = item,
        amount = amount
    })

    self.logger:info(string.format("Order queued: %dx %s", amount, item.displayName), "Storage")

    -- Notify display
    self.eventBus:emit("storage:order_queued", item, amount)

    -- Update task status
    self.eventBus:emit("task:status", "order", {
        queue = #self.orderQueue,
        active = true
    })
end

function StorageManager:sortChest(chest, name, consolidate)
    local size = chest.size()
    local sorted = false
    local passes = 0
    local maxPasses = 10

    repeat
        sorted = true
        passes = passes + 1

        -- Find first empty slot
        local firstEmpty = nil
        for slot = 1, size do
            if not chest.getItemDetail(slot) then
                firstEmpty = slot
                break
            end
        end

        -- If we found an empty slot, move items forward
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

        -- Consolidate stacks if requested
        if consolidate and sorted then
            sorted = self:consolidateChest(chest, name)
        end

    until sorted or passes >= maxPasses

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
                if item2 and item1.name == item2.name and (item1.nbt == item2.nbt or not item1.nbt) then
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
            -- First try to stack with existing items
            for targetSlot = 1, targetChest.peripheral.size() do
                local targetItem = targetChest.peripheral.getItemDetail(targetSlot)
                if targetItem and targetItem.name == item.name and
                        (targetItem.nbt == item.nbt or not targetItem.nbt) and
                        targetItem.count < targetItem.maxCount then

                    local space = targetItem.maxCount - targetItem.count
                    local moved = self.inputChest.pushItems(targetChest.name, inputSlot, space, targetSlot)
                    if moved > 0 then
                        deposited = true
                        self.logger:debug(string.format("Stacked %d %s", moved, item.displayName), "Storage")
                    end
                end
            end

            -- Then try empty slots
            item = self.inputChest.getItemDetail(inputSlot) -- Re-check after stacking
            if item then
                for targetSlot = 1, targetChest.peripheral.size() do
                    if not targetChest.peripheral.getItemDetail(targetSlot) then
                        local moved = self.inputChest.pushItems(targetChest.name, inputSlot, item.count, targetSlot)
                        if moved > 0 then
                            deposited = true
                            self.logger:debug(string.format("Deposited %d %s", moved, item.displayName), "Storage")
                            break
                        end
                    end
                end
            end
        end
    end

    return deposited
end

function StorageManager:reformatChest(chest)
    self.logger:info("Reformatting " .. chest.name, "Storage")
    -- Sort and consolidate
    self:sortChest(chest.peripheral, chest.name, true)
end

function StorageManager:processOrder(order)
    if not self.outputChest then
        self.logger:error("No output chest configured", "Storage")
        return false
    end

    local remaining = order.amount

    for _, chest in ipairs(self.storageChests) do
        for slot = 1, chest.peripheral.size() do
            if remaining <= 0 then break end

            local item = chest.peripheral.getItemDetail(slot)
            if item and item.name == order.item.name and item.displayName == order.item.displayName then
                local toMove = math.min(remaining, item.count)
                local moved = chest.peripheral.pushItems(peripheral.getName(self.outputChest), slot, toMove)

                if moved > 0 then
                    remaining = remaining - moved
                    self.logger:debug(string.format("Moved %d %s to output", moved, item.displayName), "Storage")
                end
            end
        end

        if remaining <= 0 then break end
    end

    if remaining < order.amount then
        self.logger:success(string.format("Order complete: %dx %s", order.amount - remaining, order.item.displayName), "Storage")
        return true
    else
        self.logger:error(string.format("Order failed: %s not found", order.item.displayName), "Storage")
        return false
    end
end

function StorageManager:processQueues()
    -- Process sort queue
    if #self.sortQueue > 0 then
        local task = table.remove(self.sortQueue, 1)
        self.executor:submit("sort", function()
            self:sortChest(task.chest.peripheral, task.chest.name, task.consolidate)
            self.eventBus:emit("storage:sort_complete", task.chest.name)
            self:calculateSpace()
            self:reloadStorage()
        end)
    end

    -- Process deposit queue
    if #self.depositQueue > 0 and self.inputChest then
        local chest = table.remove(self.depositQueue, 1)
        self.executor:submit("deposit", function()
            local success = self:depositFromInput(chest)
            if success then
                self:calculateSpace()
                self:reloadStorage()
            end
        end)
    end

    -- Process reformat queue
    if #self.reformatQueue > 0 then
        local chest = table.remove(self.reformatQueue, 1)
        self.executor:submit("reformat", function()
            self:reformatChest(chest)
            self:calculateSpace()
            self:reloadStorage()
        end)
    end

    -- Process order queue
    if #self.orderQueue > 0 and self.outputChest then
        local order = table.remove(self.orderQueue, 1)
        self.executor:submit("order", function()
            local success = self:processOrder(order)
            if success then
                self:reloadStorage()
            end
        end)
    end
end

function StorageManager:run()
    -- Initial reload
    sleep(0.5) -- Give everything time to initialize
    self:reloadStorage()

    -- Main loop
    local tickTimer = os.startTimer(0.5)
    local reloadTimer = os.startTimer(10) -- Periodic reload
    local lastInputCheck = 0

    while self.running do
        local event, p1 = os.pullEvent()

        if event == "timer" then
            if p1 == tickTimer then
                -- Process queues
                self:processQueues()
                self.executor:tick()

                -- Check for auto-deposit every 2 seconds
                local now = os.epoch("utc")
                if now - lastInputCheck > 2000 and self.autoDeposit and self.inputChest and self.emptySlots > 0 then
                    lastInputCheck = now

                    -- Check if input chest has items
                    local hasItems = false
                    for slot = 1, self.inputChest.size() do
                        if self.inputChest.getItemDetail(slot) then
                            hasItems = true
                            break
                        end
                    end

                    if hasItems then
                        self:queueDeposit()
                    end
                end

                tickTimer = os.startTimer(0.5)

            elseif p1 == reloadTimer then
                -- Periodic full reload to stay in sync
                self:reloadStorage()
                reloadTimer = os.startTimer(10)
            end
        end
    end

    self.logger:info("Storage manager stopped", "Storage")
end

return StorageManager