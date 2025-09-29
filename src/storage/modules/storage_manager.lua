-- modules/storage_manager.lua
-- Core storage management logic (FIXED VERSION)

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

    -- Deposit state
    self.depositActive = false
    self.lastDepositCheck = 0

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
    self.sound:play("minecraft:item.book.page_turn", 1)

    -- Emit reload started event for UI
    self.eventBus:emit("storage:reload_started")

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

    self.logger:success(string.format("Storage reload complete: %d items, %d empty slots",
            #self.items, self.emptySlots), "Storage")
    self.sound:play("minecraft:item.book.put", 1)

    -- Emit reload complete
    self.eventBus:emit("storage:reload_complete")
end

function StorageManager:calculateSpace()
    self.logger:info("Calculating space...", "Storage")
    self.sound:play("minecraft:item.spyglass.use", 1)

    -- Emit calculation started
    self.eventBus:emit("storage:calculation_started")

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

    self.logger:success(string.format("Space: %d empty slots, %d full, %d partial, %d empty chests",
            self.emptySlots, self.fullChests, self.partialChests, emptyChests), "Storage")
    self.sound:play("minecraft:block.end_portal_frame.fill", 1)

    -- Emit calculation complete
    self.eventBus:emit("storage:calculation_complete")
end

function StorageManager:sortChest(chest, name, consolidate)
    -- Implementation matches your old code's sort logic
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
    local inputSize = self.inputChest.size()

    for inputSlot = 1, inputSize do
        local item = self.inputChest.getItemDetail(inputSlot)
        if item then
            local moved = false

            -- First try to stack with existing items (only if stackable)
            if item.maxCount > 1 then
                for targetSlot = 1, targetChest.peripheral.size() do
                    local targetItem = targetChest.peripheral.getItemDetail(targetSlot)
                    if targetItem and targetItem.name == item.name and
                            targetItem.count < targetItem.maxCount then
                        -- Check NBT match
                        if targetItem.nbt == item.nbt or not targetItem.nbt or not item.nbt then
                            local space = targetItem.maxCount - targetItem.count
                            local toMove = math.min(space, item.count)
                            local actuallyMoved = self.inputChest.pushItems(targetChest.name, inputSlot, toMove, targetSlot)
                            if actuallyMoved > 0 then
                                moved = true
                                deposited = true
                                self.logger:debug(string.format("Stacked %d %s", actuallyMoved, item.displayName), "Storage")
                                self.sound:play("minecraft:item.armor.equip_diamond", 1)
                                item.count = item.count - actuallyMoved
                                if item.count <= 0 then
                                    break
                                end
                            end
                        end
                    end
                end
            end

            -- If item still exists, try empty slots
            if not moved or (item.count and item.count > 0) then
                local remainingItem = self.inputChest.getItemDetail(inputSlot)
                if remainingItem then
                    for targetSlot = 1, targetChest.peripheral.size() do
                        if not targetChest.peripheral.getItemDetail(targetSlot) then
                            local actuallyMoved = self.inputChest.pushItems(targetChest.name, inputSlot, remainingItem.count, targetSlot)
                            if actuallyMoved > 0 then
                                deposited = true
                                self.logger:debug(string.format("Deposited %d %s", actuallyMoved, remainingItem.displayName), "Storage")
                                self.sound:play("minecraft:item.armor.equip_turtle", 1)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    return deposited
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
    self.eventBus:emit("task:status", "sort", {queue = #self.sortQueue, threads = {}})
end

function StorageManager:queueDeposit()
    if not self.inputChest then
        self.logger:error("No input chest configured", "Storage")
        return
    end

    -- Queue deposit for all storage chests
    for _, chest in ipairs(self.storageChests) do
        table.insert(self.depositQueue, chest)
    end

    self.logger:info("Deposit queued", "Storage")
    self.eventBus:emit("task:status", "deposit", {queue = #self.depositQueue, threads = {}})
end

function StorageManager:queueReformat()
    for _, chest in ipairs(self.storageChests) do
        table.insert(self.reformatQueue, chest)
    end

    self.logger:info(string.format("Queued %d chests for reformatting", #self.storageChests), "Storage")
    self.eventBus:emit("task:status", "reformat", {queue = #self.reformatQueue, threads = {}})
end

function StorageManager:queueOrder(item, amount)
    table.insert(self.orderQueue, {item = item, amount = amount})
    self.logger:info(string.format("Order queued: %dx %s", amount, item.displayName), "Storage")
    self.eventBus:emit("storage:order_queued", item, amount)
    self.eventBus:emit("task:status", "order", {queue = #self.orderQueue, active = true})
end

function StorageManager:processQueues()
    -- Process sort queue
    if #self.sortQueue > 0 then
        local task = table.remove(self.sortQueue, 1)
        self.executor:submit("sort", function()
            self:sortChest(task.chest.peripheral, task.chest.name, task.consolidate)
            self.eventBus:emit("storage:sort_complete", task.chest.name)
            self:calculateSpace()
        end)
    end

    -- Process deposit queue
    if #self.depositQueue > 0 and self.inputChest then
        local chest = table.remove(self.depositQueue, 1)
        self.executor:submit("deposit", function()
            local success = self:depositFromInput(chest)
            if success then
                self:calculateSpace()
                -- Schedule reload after deposit
                os.queueEvent("storage:deposit_complete")
            end
        end)
    end

    -- Process reformat queue
    if #self.reformatQueue > 0 then
        local chest = table.remove(self.reformatQueue, 1)
        self.executor:submit("reformat", function()
            self:sortChest(chest.peripheral, chest.name, true)
            self:calculateSpace()
        end)
    end

    -- Process order queue
    if #self.orderQueue > 0 and self.outputChest then
        local order = table.remove(self.orderQueue, 1)
        self.executor:submit("order", function()
            -- Order processing logic here
            self:reloadStorage()
        end)
    end
end

function StorageManager:checkInputChest()
    if not self.inputChest or not self.autoDeposit or self.emptySlots <= 0 then
        return false
    end

    -- Check if input chest has items
    local hasItems = false
    for slot = 1, self.inputChest.size() do
        if self.inputChest.getItemDetail(slot) then
            hasItems = true
            break
        end
    end

    if hasItems and not self.depositActive then
        self.depositActive = true
        self.logger:debug("Items detected in input chest", "Storage")

        -- Sort input chest first (like old code)
        self:sortChest(self.inputChest, "input", false)

        -- Then queue deposit
        self:queueDeposit()

        -- Mark deposit as active
        self.eventBus:emit("task:status", "deposit", {active = true})

        return true
    elseif not hasItems then
        self.depositActive = false
    end

    return false
end

function StorageManager:run()
    -- Initial setup
    sleep(1)
    self:reloadStorage()

    -- Main loop timers
    local tickTimer = os.startTimer(0.5)
    local depositCheckTimer = os.startTimer(1)  -- Check every second like old code
    local reloadTimer = os.startTimer(10)

    while self.running do
        local event, p1 = os.pullEvent()

        if event == "timer" then
            if p1 == tickTimer then
                -- Process queues
                self:processQueues()
                self.executor:tick()
                tickTimer = os.startTimer(0.5)

            elseif p1 == depositCheckTimer then
                -- Check input chest for items (like old depositloop)
                self:checkInputChest()
                depositCheckTimer = os.startTimer(1)

            elseif p1 == reloadTimer then
                -- Periodic full reload
                self:reloadStorage()
                reloadTimer = os.startTimer(10)
            end

        elseif event == "storage:deposit_complete" then
            -- Reload after successful deposit
            self:reloadStorage()
            self.depositActive = false
        end
    end

    self.logger:info("Storage manager stopped", "Storage")
end

return StorageManager