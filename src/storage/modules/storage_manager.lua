-- modules/storage_manager.lua
-- Core storage management logic - COMPLETE FIXED VERSION

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

    -- Task queues
    self.sortQueue = {}
    self.depositQueue = {}
    self.reformatQueue = {}
    self.orderQueue = {}

    -- Queue processing flags
    self.reload = false
    self.sort = false
    self.reformat = false
    self.calculate = false

    -- Deposit control with stuck detection
    self.forceDeposit = false
    self.checkDeposit = false
    self.depositBusy = false
    self.lastDepositCount = 0
    self.depositStuckCounter = 0

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
    -- Reload request
    self.eventBus:on("storage:reload", function()
        self.reload = true
        self.selectedItem = nil
    end)

    -- Sort request
    self.eventBus:on("storage:sort", function(consolidate)
        self.sort = true
        self.sortConsolidate = consolidate ~= false
    end)

    -- Reformat request
    self.eventBus:on("storage:reformat", function()
        self.reformat = true
    end)

    -- Input monitor triggers
    self.eventBus:on("storage:trigger_deposit", function()
        self.logger:info("Deposit triggered by input monitor", "Storage")
        self.forceDeposit = true
    end)

    self.eventBus:on("storage:check_deposit", function()
        -- Only set check flag if not busy and no deposit is forced
        if not self.depositBusy and not self.forceDeposit then
            self.checkDeposit = true
        end
    end)

    -- Order request
    self.eventBus:on("storage:order", function(item, amount)
        table.insert(self.orderQueue, {
            item = item,
            amount = amount
        })
        self.logger:info(string.format("Order queued: %dx %s", amount, item.displayName), "Storage")
        self.eventBus:emit("storage:order_queued", item, amount)
        self:updateTaskStatus()
    end)

    -- Direct deposit request
    self.eventBus:on("storage:deposit", function()
        self:queueDeposit()
    end)

    -- API data request
    self.eventBus:on("api:items_response", function()
        self.eventBus:emit("api:items_response", self.items)
    end)

    -- Shutdown
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
    -- Send detailed task status to display
    self.eventBus:emit("task:status", "sort", {
        queue = #self.sortQueue,
        threads = self.executor:getStatus().threads
    })

    self.eventBus:emit("task:status", "deposit", {
        queue = #self.depositQueue,
        threads = self.executor:getStatus().threads
    })

    self.eventBus:emit("task:status", "reformat", {
        queue = #self.reformatQueue,
        threads = self.executor:getStatus().threads
    })

    self.eventBus:emit("task:status", "order", {
        queue = #self.orderQueue,
        active = #self.orderQueue > 0
    })
end

function StorageManager:reloadStorage()
    self.logger:info("Reloading storage data...", "Storage")

    -- Notify display that reload is starting
    self.eventBus:emit("storage:reload_started")
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
                -- Item already exists, merge counts
                itemMap[key].count = itemMap[key].count + item.count
                self.sound:play("minecraft:item.armor.equip_generic", 1.5) -- Merge sound
            else
                -- New item found
                itemMap[key] = {
                    name = item.name,
                    displayName = item.displayName,
                    count = item.count,
                    maxCount = item.maxCount,
                    nbt = item.nbt
                }
                self.sound:play("minecraft:entity.item.pickup", 0.8) -- New item sound
            end
        end
    end

    -- Convert map to list
    for _, item in pairs(itemMap) do
        table.insert(self.items, item)
    end

    -- Calculate storage space
    self.eventBus:emit("storage:calculation_started")
    self:calculateSpace()

    -- Notify display with updated data
    self.eventBus:emit("storage:data_updated", {
        items = self.items,
        emptySlots = self.emptySlots,
        fullChests = self.fullChests,
        partialChests = self.partialChests
    })

    -- Notify reload complete
    self.eventBus:emit("storage:reload_complete")

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

function StorageManager:getInputItemCount()
    if not self.inputChest then
        return 0
    end

    local count = 0
    for slot = 1, self.inputChest.size() do
        local item = self.inputChest.getItemDetail(slot)
        if item then
            count = count + item.count
        end
    end
    return count
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

    -- Sort input chest first
    self.logger:info("Pre-sorting input chest", "Storage")
    self:sortChest(self.inputChest, "input", false)

    -- Queue deposit for all storage chests
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

        -- Find first empty slot
        local firstEmpty = nil
        for slot = 1, size do
            if not chest.getItemDetail(slot) then
                firstEmpty = slot
                break
            end
        end

        -- Move items to fill gaps
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

        -- Consolidate if requested and chest is sorted
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
    self.logger:debug(string.format("depositFromInput called for %s", targetChest.name), "Storage")

    if not self.inputChest then
        self.logger:error("No input chest available", "Storage")
        return false
    end

    if not targetChest or not targetChest.peripheral then
        self.logger:error(string.format("Invalid target chest: %s", tostring(targetChest.name)), "Storage")
        return false
    end

    local deposited = false
    local totalMoved = 0

    -- Get the proper peripheral name for the target chest
    local targetName = targetChest.name  -- This should already be the peripheral name like "minecraft:barrel_18"

    self.logger:debug(string.format("Starting deposit scan from input to %s", targetName), "Storage")

    for inputSlot = 1, self.inputChest.size() do
        local item = self.inputChest.getItemDetail(inputSlot)
        if item then
            self.logger:debug(string.format("Found %dx %s in slot %d", item.count, item.displayName or item.name, inputSlot), "Storage")

            -- Try to stack with existing items first
            if item.maxCount > 1 then
                for targetSlot = 1, targetChest.peripheral.size() do
                    local targetItem = targetChest.peripheral.getItemDetail(targetSlot)
                    if targetItem and targetItem.name == item.name and
                            targetItem.count < targetItem.maxCount and
                            (targetItem.nbt == item.nbt or not targetItem.nbt or not item.nbt) then

                        local space = targetItem.maxCount - targetItem.count
                        local toMove = math.min(space, item.count)

                        self.logger:debug(string.format("Attempting to stack %d items to slot %d", toMove, targetSlot), "Storage")

                        -- pushItems: source peripheral pushes to target name
                        local moved = self.inputChest.pushItems(targetName, inputSlot, toMove, targetSlot)

                        if moved and moved > 0 then
                            deposited = true
                            totalMoved = totalMoved + moved
                            self.logger:info(string.format("Stacked %dx %s to slot %d", moved, item.displayName or item.name, targetSlot), "Storage")
                            self.sound:play("minecraft:item.armor.equip_diamond", 1)

                            -- Update item count
                            item.count = item.count - moved
                            if item.count <= 0 then
                                break
                            end
                        else
                            self.logger:debug("Failed to stack items", "Storage")
                        end
                    end
                end
            end

            -- Then try empty slots if items remain
            item = self.inputChest.getItemDetail(inputSlot)
            if item then
                for targetSlot = 1, targetChest.peripheral.size() do
                    if not targetChest.peripheral.getItemDetail(targetSlot) then
                        self.logger:debug(string.format("Attempting to move %d items to empty slot %d", item.count, targetSlot), "Storage")

                        -- pushItems: source peripheral pushes to target name
                        local moved = self.inputChest.pushItems(targetName, inputSlot, item.count, targetSlot)

                        if moved and moved > 0 then
                            deposited = true
                            totalMoved = totalMoved + moved
                            self.logger:info(string.format("Deposited %dx %s to empty slot %d", moved, item.displayName or item.name, targetSlot), "Storage")
                            self.sound:play("minecraft:item.armor.equip_turtle", 1)
                            break
                        else
                            self.logger:debug("Failed to move to empty slot", "Storage")
                        end
                    end
                end
            end
        end
    end

    if totalMoved > 0 then
        self.logger:success(string.format("Successfully deposited %d items to %s", totalMoved, targetChest.name), "Storage")
    else
        self.logger:warning(string.format("No items deposited to %s", targetChest.name), "Storage")
    end

    return deposited
end

function StorageManager:processQueues()
    -- Process sort queue
    if #self.sortQueue > 0 then
        local task = table.remove(self.sortQueue, 1)
        self.executor:submit("sort", function()
            self.logger:info("Executing sort for " .. task.chest.name, "Storage")
            self:sortChest(task.chest.peripheral, task.chest.name, task.consolidate)
            self.logger:success("Sort complete for " .. task.chest.name, "Storage")
            self.eventBus:emit("storage:sort_complete", task.chest.name)
        end)
        self:updateTaskStatus()
    end

    -- Process deposit queue - FIXED with proper execution
    if #self.depositQueue > 0 and self.inputChest then
        local chest = table.remove(self.depositQueue, 1)
        self.executor:submit("deposit", function()
            self.logger:info("Executing deposit for " .. chest.name, "Storage")

            -- Validate chest is still valid
            if not chest.peripheral then
                self.logger:error("Invalid chest peripheral for " .. chest.name, "Storage")
                return
            end

            -- Actually perform the deposit!
            local success = false
            local ok, err = pcall(function()
                success = self:depositFromInput(chest)
            end)

            if not ok then
                self.logger:error(string.format("Deposit error for %s: %s", chest.name, tostring(err)), "Storage")
            elseif success then
                self.logger:success("Deposit complete for " .. chest.name, "Storage")
                -- Schedule recalculation
                self.calculate = true
            else
                self.logger:debug("No items deposited to " .. chest.name, "Storage")
            end
        end)
        self:updateTaskStatus()
    end

    -- Process reformat queue
    if #self.reformatQueue > 0 then
        local chest = table.remove(self.reformatQueue, 1)
        self.executor:submit("reformat", function()
            self.logger:info("Executing reformat for " .. chest.name, "Storage")
            self:sortChest(chest.peripheral, chest.name, true)
            self.logger:success("Reformat complete for " .. chest.name, "Storage")
            self.calculate = true
        end)
        self:updateTaskStatus()
    end

    -- Process order queue
    if #self.orderQueue > 0 and self.outputChest then
        local order = table.remove(self.orderQueue, 1)
        self.executor:submit("order", function()
            self.logger:info(string.format("Processing order: %dx %s", order.amount, order.item.displayName), "Storage")

            local remaining = order.amount
            local moved = 0

            -- Find items in storage
            for _, chest in ipairs(self.storageChests) do
                if remaining <= 0 then break end

                for slot = 1, chest.peripheral.size() do
                    local item = chest.peripheral.getItemDetail(slot)
                    if item and item.name == order.item.name then
                        local toMove = math.min(remaining, item.count)
                        local actualMoved = chest.peripheral.pushItems(
                                peripheral.getName(self.outputChest),
                                slot, toMove
                        )
                        if actualMoved > 0 then
                            moved = moved + actualMoved
                            remaining = remaining - actualMoved
                            self.logger:debug(string.format("Moved %d items from %s", actualMoved, chest.name), "Storage")
                        end
                    end
                end
            end

            if moved > 0 then
                self.logger:success(string.format("Order complete: %d/%d %s delivered", moved, order.amount, order.item.displayName), "Storage")
                self.sound:play("minecraft:block.note_block.chime", 1)
                self.calculate = true
            else
                self.logger:error(string.format("Order failed: %s not found", order.item.displayName), "Storage")
                self.sound:play("minecraft:block.note_block.bass", 0.5)
            end
        end)
        self:updateTaskStatus()
    end
end

-- Main control loops
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
        local shouldDeposit = false

        -- Check if forced by input monitor
        if self.forceDeposit then
            shouldDeposit = true
            self.forceDeposit = false
            self.depositStuckCounter = 0 -- Reset stuck counter
            self.logger:info("Processing forced deposit from input monitor", "Storage")
        end

        -- Check periodic flag
        if self.checkDeposit then
            shouldDeposit = true
            self.checkDeposit = false
            self.logger:debug("Processing periodic deposit check", "Storage")
        end

        -- Manual check for items in input
        if self.inputChest and not shouldDeposit then
            local currentCount = self:getInputItemCount()

            if currentCount > 0 and self.emptySlots > 0 then
                -- Check if we're stuck with same item count
                if currentCount == self.lastDepositCount then
                    self.depositStuckCounter = self.depositStuckCounter + 1
                    if self.depositStuckCounter >= 3 then
                        self.logger:warning(string.format("Deposit appears stuck with %d items, forcing retry", currentCount), "Storage")
                        shouldDeposit = true
                        self.depositStuckCounter = 0
                    end
                else
                    self.depositStuckCounter = 0
                end

                self.lastDepositCount = currentCount
            else
                self.lastDepositCount = 0
                self.depositStuckCounter = 0
            end
        end

        -- Process deposit if needed
        if shouldDeposit and self.inputChest and self.emptySlots > 0 then
            -- Check if deposit is already active
            local depositActive = false
            local status = self.executor:getStatus()

            for _, thread in ipairs(status.threads) do
                if thread.active and thread.currentTask and thread.currentTask.type == "deposit" then
                    depositActive = true
                    break
                end
            end

            -- Only queue if not active and queue is empty
            if not depositActive and #self.depositQueue == 0 then
                self.depositBusy = true

                -- Get current item count before deposit
                local beforeCount = self:getInputItemCount()
                self.logger:info(string.format("Starting deposit of %d items", beforeCount), "Storage")

                self:queueDeposit()
                self.sound:play("minecraft:block.barrel.open", 1)

                -- Schedule cleanup after deposits complete
                self.executor:submit("deposit-cleanup", function()
                    sleep(3)
                    local afterCount = self:getInputItemCount()
                    local movedCount = beforeCount - afterCount
                    if movedCount > 0 then
                        self.logger:success(string.format("Deposit complete: moved %d items", movedCount), "Storage")
                    else
                        self.logger:warning("No items were deposited", "Storage")
                    end
                    self.depositBusy = false
                    self.calculate = true
                end, 1)
            elseif depositActive then
                self.logger:debug("Deposit already in progress", "Storage")
            elseif #self.depositQueue > 0 then
                self.logger:debug("Deposit queue not empty", "Storage")
            end
        end

        sleep(0.5)
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
            self.reload = false
        end
        sleep(1)
    end
end

function StorageManager:calculateLoop()
    while self.running do
        if self.calculate then
            self:calculateSpace()

            -- Update display with new space info
            self.eventBus:emit("storage:data_updated", {
                items = self.items,
                emptySlots = self.emptySlots,
                fullChests = self.fullChests,
                partialChests = self.partialChests
            })

            self.calculate = false
        end
        sleep(1)
    end
end

function StorageManager:processLoop()
    local lastStatusUpdate = 0
    while self.running do
        self:processQueues()
        self.executor:tick()

        -- Only update task status every 0.5 seconds to reduce spam
        local now = os.epoch("utc")
        if now - lastStatusUpdate > 500 then
            self:updateTaskStatus()
            lastStatusUpdate = now
        end

        sleep(0.1)
    end
end

function StorageManager:run()
    -- Initial reload after short delay
    sleep(1)
    self.reload = true

    -- Run all loops in parallel
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