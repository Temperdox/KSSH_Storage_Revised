local HashOA_RRSC = require("core.hash_oa_rrsc")

local StorageService = {}
StorageService.__index = StorageService

function StorageService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.scheduler = context.scheduler
    o.logger = context.logger
    o.storageMap = context.storageMap
    o.bufferInventory = context.bufferInventory
    o.inputSide = context.settings.inputSide or "right"
    o.outputSide = context.settings.outputSide or "left"

    -- Initialize item index
    o.itemIndex = HashOA_RRSC:new(context.eventBus)
    o.itemIndex:load("/storage/data/item_index.dat")

    -- Get the wired modem for network operations
    o.modem = peripheral.find("modem", function(name, p)
        return name == "back" and not p.isWireless()
    end)

    if not o.modem then
        o.logger:error("StorageService", "No wired modem found on back!")
    end

    -- Peripheral handles
    -- Buffer is on the wired network
    o.buffer = peripheral.wrap(o.bufferInventory.name)
    if not o.buffer then
        o.logger:error("StorageService", "Failed to wrap buffer: " .. o.bufferInventory.name)
    else
        o.logger:info("StorageService", "Buffer found: " .. o.bufferInventory.name)
    end

    -- Input/Output chests are directly connected to the computer sides
    if peripheral.isPresent(o.inputSide) then
        o.inputChest = peripheral.wrap(o.inputSide)
        o.logger:info("StorageService", "Input chest found on " .. o.inputSide)
    else
        o.logger:warn("StorageService", "No input chest found on side: " .. o.inputSide)
        o.inputChest = nil
    end

    if peripheral.isPresent(o.outputSide) then
        o.outputChest = peripheral.wrap(o.outputSide)
        o.logger:info("StorageService", "Output chest found on " .. o.outputSide)
    else
        o.logger:warn("StorageService", "No output chest found on side: " .. o.outputSide)
        o.outputChest = nil
    end

    o.running = false

    return o
end

function StorageService:start()
    self.running = true

    -- Initial index rebuild
    self:rebuildIndex()

    -- Start monitoring tasks
    self.scheduler:submit("io", function()
        self:monitorInput()
    end)

    self.scheduler:submit("io", function()
        self:processBuffer()
    end)

    -- Subscribe to events
    self.eventBus:subscribe("storage.withdraw", function(event, data)
        self:withdraw(data.itemName, data.count)
    end)

    self.eventBus:subscribe("storage.deposit", function(event, data)
        self:deposit(data.items)
    end)

    self.eventBus:subscribe("storage.rescan", function()
        self:rebuildIndex()
    end)

    self.logger:info("StorageService", "Service started")
end

function StorageService:stop()
    self.running = false

    -- Save index
    self.itemIndex:save("/storage/data/item_index.dat")

    self.logger:info("StorageService", "Service stopped")
end

function StorageService:monitorInput()
    while self.running do
        if self.inputChest and self.buffer then
            local ok, items = pcall(function() return self.inputChest.list() end)
            if ok and items and next(items) then
                -- Since input chest is on a side and buffer is on network,
                -- we need to use the buffer to pull from the input chest
                -- OR use the modem as an intermediary

                for slot, item in pairs(items) do
                    -- Try to have the buffer pull from the input chest
                    local moved = 0

                    -- First attempt: buffer pulls from input side
                    if self.buffer.pullItems then
                        moved = self.buffer.pullItems(self.inputSide, slot)
                    end

                    -- If that didn't work, try pushing through the modem
                    if moved == 0 and self.modem then
                        -- Use the modem to facilitate the transfer
                        -- The modem can see both the side peripheral and network peripherals
                        local ok2, result = pcall(function()
                            -- Try to get the modem to help transfer
                            return self.inputChest.pushItems(self.bufferInventory.name, slot)
                        end)

                        if ok2 and result then
                            moved = result
                        else
                            self.logger:debug("StorageService", "Failed to push through modem: " .. tostring(result))
                        end
                    end

                    if moved and moved > 0 then
                        self.eventBus:publish("storage.inputReceived", {
                            item = item.name,
                            count = moved,
                            from = "input",
                            to = "buffer"
                        })

                        self.logger:debug("StorageService", string.format(
                                "Moved %d x %s to buffer",
                                moved, item.name
                        ))
                    end
                end

                self.eventBus:publish("storage.movedToBuffer", {
                    itemCount = #items
                })
            end
        end

        os.sleep(0.5)
    end
end

function StorageService:processBuffer()
    while self.running do
        if self.buffer then
            local ok, items = pcall(function() return self.buffer.list() end)
            if ok and items and next(items) then
                for slot, item in pairs(items) do
                    -- Update index
                    self:updateIndex(item.name, item.count, "add")

                    -- Find best storage location
                    local targetStorage = self:findBestStorage(item)

                    if targetStorage then
                        -- Both buffer and storage are on the network, so this should work
                        local moved = self.buffer.pushItems(
                                targetStorage.name,
                                slot
                        )

                        if moved and moved > 0 then
                            self.eventBus:publish("storage.movedToStorage", {
                                item = item.name,
                                count = moved,
                                storage = targetStorage.name
                            })

                            self.logger:debug("StorageService", string.format(
                                    "Stored %d x %s in %s",
                                    moved, item.name, targetStorage.name
                            ))
                        end
                    end
                end
            end
        end

        os.sleep(1)
    end
end

function StorageService:findBestStorage(item)
    -- Simple strategy: find first available storage with space
    for _, storage in ipairs(self.storageMap) do
        local inv = peripheral.wrap(storage.name)
        if inv then
            local ok, slots = pcall(function() return inv.list() end)
            if ok and slots then
                -- Check for existing stack
                for slot, slotItem in pairs(slots) do
                    if slotItem.name == item.name and slotItem.count < (slotItem.maxCount or 64) then
                        return storage
                    end
                end

                -- Check for empty slot
                if inv.size then
                    local invSize = inv.size()
                    for i = 1, invSize do
                        if not slots[i] then
                            return storage
                        end
                    end
                end
            end
        end
    end

    return nil
end

function StorageService:updateIndex(itemName, count, operation)
    local current = self.itemIndex:get(itemName) or {
        count = 0,
        stackSize = 64,
        nbtHash = nil,
        locations = {}
    }

    if operation == "add" then
        current.count = current.count + count
    elseif operation == "remove" then
        current.count = math.max(0, current.count - count)
    end

    self.itemIndex:put(itemName, current)

    self.eventBus:publish("index.updated", {
        item = itemName,
        count = current.count,
        operation = operation
    })
end

function StorageService:withdraw(itemName, requestedCount)
    local itemData = self.itemIndex:get(itemName)

    if not itemData or itemData.count == 0 then
        self.eventBus:publish("storage.withdrawFailed", {
            item = itemName,
            reason = "Item not found"
        })
        return 0
    end

    if not self.outputChest then
        self.eventBus:publish("storage.withdrawFailed", {
            item = itemName,
            reason = "No output chest available"
        })
        return 0
    end

    local withdrawn = 0
    local remaining = math.min(requestedCount, itemData.count)

    -- Search all storages for the item
    for _, storage in ipairs(self.storageMap) do
        if remaining <= 0 then break end

        local inv = peripheral.wrap(storage.name)
        if inv then
            local ok, slots = pcall(function() return inv.list() end)
            if ok and slots then
                for slot, slotItem in pairs(slots) do
                    if slotItem.name == itemName and remaining > 0 then
                        local toMove = math.min(remaining, slotItem.count)

                        -- Storage is on network, output is on side
                        -- Try having output chest pull from storage
                        local moved = 0

                        if self.outputChest.pullItems then
                            moved = self.outputChest.pullItems(storage.name, slot, toMove)
                        end

                        -- If that didn't work, try pushing
                        if moved == 0 then
                            moved = inv.pushItems(self.outputSide, slot, toMove)
                        end

                        if moved and moved > 0 then
                            withdrawn = withdrawn + moved
                            remaining = remaining - moved

                            self.eventBus:publish("storage.itemWithdrawn", {
                                item = itemName,
                                count = moved,
                                from = storage.name
                            })
                        end
                    end
                end
            end
        end
    end

    -- Update index
    if withdrawn > 0 then
        self:updateIndex(itemName, withdrawn, "remove")
    end

    self.eventBus:publish("storage.withdrawComplete", {
        item = itemName,
        requested = requestedCount,
        withdrawn = withdrawn
    })

    return withdrawn
end

function StorageService:deposit(items)
    -- Move items from output chest back to input
    if self.outputChest and self.inputChest then
        local ok, outputItems = pcall(function() return self.outputChest.list() end)
        if ok and outputItems then
            for slot, item in pairs(outputItems) do
                -- Both are on sides, so this should work
                self.outputChest.pushItems(self.inputSide, slot)
            end
        end
    end

    self.eventBus:publish("storage.depositComplete", {
        items = items
    })
end

function StorageService:rebuildIndex()
    self.logger:info("StorageService", "Rebuilding item index...")

    self.itemIndex:clear()
    local totalItems = 0

    -- Scan all storages (these are on the network)
    for _, storage in ipairs(self.storageMap) do
        local inv = peripheral.wrap(storage.name)
        if inv then
            local ok, slots = pcall(function() return inv.list() end)
            if ok and slots then
                for slot, item in pairs(slots) do
                    local current = self.itemIndex:get(item.name) or {
                        count = 0,
                        stackSize = item.maxCount or 64,
                        nbtHash = item.nbt,
                        locations = {}
                    }

                    current.count = current.count + item.count
                    table.insert(current.locations, {
                        id = storage.id,
                        slot = slot,
                        count = item.count
                    })

                    self.itemIndex:put(item.name, current)
                    totalItems = totalItems + 1
                end
            end
        end
    end

    -- Save index
    self.itemIndex:save("/storage/data/item_index.dat")

    self.eventBus:publish("storage.indexRebuilt", {
        uniqueItems = self.itemIndex:getSize(),
        totalStacks = totalItems
    })

    self.logger:info("StorageService", string.format(
            "Index rebuilt: %d unique items, %d stacks",
            self.itemIndex:getSize(), totalItems
    ))
end

function StorageService:getItems()
    return self.itemIndex:getAllItems()
end

function StorageService:searchItems(query)
    local results = {}
    local items = self.itemIndex:getAllItems()

    for _, item in ipairs(items) do
        if item.key:lower():find(query:lower()) then
            table.insert(results, item)
        end
    end

    self.eventBus:publish("storage.searched", {
        query = query,
        results = #results
    })

    return results
end

return StorageService