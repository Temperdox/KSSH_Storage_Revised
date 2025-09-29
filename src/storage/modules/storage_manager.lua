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

    -- Create reload task
    self.executor:submit("reload", function()
        self.items = {}

        -- Scan all storage chests
        for _, chest in ipairs(self.storageChests) do
            local items = self.scanner:scanChest(chest.peripheral, chest.name)

            -- Merge items into main list
            for _, item in ipairs(items) do
                local found = false
                for _, existingItem in ipairs(self.items) do
                    if existingItem.name == item.name and
                            existingItem.displayName == item.displayName and
                            existingItem.nbt == item.nbt then
                        existingItem.count = existingItem.count + item.count
                        found = true
                        break
                    end
                end

                if not found then
                    table.insert(self.items, item)
                end
            end
        end

        -- Calculate storage space
        self:calculateSpace()

        -- Notify display
        self.eventBus:emit("storage:data_updated", {
            items = self.items,
            emptySlots = self.emptySlots,
            fullChests = self.fullChests,
            partialChests = self.partialChests
        })

        self.logger:success("Storage reload complete", "Storage")
    end)
end

function StorageManager:calculateSpace()
    self.emptySlots = 0
    self.fullChests = 0
    self.partialChests = 0

    for _, chest in ipairs(self.storageChests) do
        local size = chest.peripheral.size()
        local used = 0

        for slot = 1, size do
            if chest.peripheral.getItemDetail(slot) then
                used = used + 1
            end
        end

        self.emptySlots = self.emptySlots + (size - used)

        if used == size then
            self.fullChests = self.fullChests + 1
        elseif used > 0 then
            self.partialChests = self.partialChests + 1
        end
    end
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
        -- First sort the input chest
        self.executor:submit("deposit-sort", function()
            self:sortChest(self.inputChest, "input", false)
        end)

        -- Then deposit items
        for _, chest in ipairs(self.storageChests) do
            table.insert(self.depositQueue, chest)
        end

        self.logger:info("Deposit queued", "Storage")
    end
end

function StorageManager:queueReformat()
    for _, chest in ipairs(self.storageChests) do
        table.insert(self.reformatQueue, chest)
    end

    self.logger:info(string.format("Queued %d chests for reformatting", #self.storageChests), "Storage")
end

function StorageManager:queueOrder(item, amount)
    table.insert(self.orderQueue, {
        item = item,
        amount = amount
    })

    self.logger:info(string.format("Order queued: %dx %s", amount, item.displayName), "Storage")

    -- Notify display
    self.eventBus:emit("storage:order_queued", item, amount)
end

function StorageManager:sortChest(chest, name, consolidate)
    -- Implementation of chest sorting algorithm
    -- This maintains your original sort logic
    local sorted = false
    local merged = false

    repeat
        sorted = true
        local emptySlot = -1
        local size = chest.size()

        -- Find first empty slot
        for i = 1, size do
            if not chest.getItemDetail(i) then
                emptySlot = i
                break
            end
        end

        -- Move items from end to empty slots
        if emptySlot > 0 then
            for i = size, emptySlot + 1, -1 do
                local item = chest.getItemDetail(i)
                if item then
                    chest.pushItems(peripheral.getName(chest), i, item.count, emptySlot)
                    sorted = false
                    break
                end
            end
        end

        -- Consolidate if requested
        if consolidate and sorted then
            merged = self:consolidateChest(chest, name)
        else
            merged = true
        end
    until sorted and merged
end

function StorageManager:consolidateChest(chest, name)
    -- Consolidation logic
    local size = chest.size()

    for i = 1, size do
        local item1 = chest.getItemDetail(i)
        if item1 and item1.count < item1.maxCount then
            for j = i + 1, size do
                local item2 = chest.getItemDetail(j)
                if item2 and item1.name == item2.name and item1.nbt == item2.nbt then
                    local moved = chest.pushItems(peripheral.getName(chest), j,
                            item1.maxCount - item1.count, i)
                    if moved > 0 then
                        return false -- Not fully merged, need another pass
                    end
                end
            end
        end
    end

    return true
end

function StorageManager:processQueues()
    -- Process sort queue
    if #self.sortQueue > 0 then
        local task = table.remove(self.sortQueue, 1)
        self.executor:submit("sort", function()
            self:sortChest(task.chest.peripheral, task.chest.name, task.consolidate)
            self.eventBus:emit("storage:sort_complete", task.chest.name)
        end)
    end

    -- Process deposit queue
    if #self.depositQueue > 0 and self.inputChest then
        local chest = table.remove(self.depositQueue, 1)
        self.executor:submit("deposit", function()
            self:depositFromInput(chest)
        end)
    end

    -- Process reformat queue
    if #self.reformatQueue > 0 then
        local chest = table.remove(self.reformatQueue, 1)
        self.executor:submit("reformat", function()
            self:reformatChest(chest)
        end)
    end

    -- Process order queue
    if #self.orderQueue > 0 and self.outputChest then
        local order = table.remove(self.orderQueue, 1)
        self.executor:submit("order", function()
            self:processOrder(order)
        end)
    end
end

function StorageManager:depositFromInput(targetChest)
    -- Deposit logic from input to storage
    for slot = 1, self.inputChest.size() do
        local item = self.inputChest.getItemDetail(slot)
        if item then
            -- Try to stack with existing items first
            local deposited = false
            for targetSlot = 1, targetChest.peripheral.size() do
                local targetItem = targetChest.peripheral.getItemDetail(targetSlot)
                if targetItem and targetItem.name == item.name and
                        targetItem.nbt == item.nbt and
                        targetItem.count < targetItem.maxCount then
                    local moved = self.inputChest.pushItems(targetChest.name, slot,
                            targetItem.maxCount - targetItem.count,
                            targetSlot)
                    if moved > 0 then
                        deposited = true
                        break
                    end
                end
            end

            -- If not stacked, find empty slot
            if not deposited then
                for targetSlot = 1, targetChest.peripheral.size() do
                    if not targetChest.peripheral.getItemDetail(targetSlot) then
                        self.inputChest.pushItems(targetChest.name, slot, item.count, targetSlot)
                        break
                    end
                end
            end
        end
    end
end

function StorageManager:reformatChest(chest)
    -- Reformat chest logic - optimize item placement
    self.logger:info("Reformatting " .. chest.name, "Storage")
    -- Implementation would go here
end

function StorageManager:processOrder(order)
    -- Process item order to output chest
    self.logger:info(string.format("Processing order: %dx %s",
            order.amount, order.item.displayName), "Storage")
    -- Implementation would go here
end

function StorageManager:run()
    -- Initial reload
    self:reloadStorage()

    -- Main loop
    local tickTimer = os.startTimer(0.5)

    while self.running do
        local event, p1 = os.pullEvent()

        if event == "timer" and p1 == tickTimer then
            -- Process queues
            self:processQueues()

            -- Check for deposit
            if self.inputChest and self.emptySlots > 0 then
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
        end
    end

    self.logger:info("Storage manager stopped", "Storage")
end

return StorageManager