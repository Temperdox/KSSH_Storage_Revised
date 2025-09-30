local HashOA_RRSC = require("core.hash_oa_rrsc")

local StorageService = {}
StorageService.__index = StorageService

function StorageService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.scheduler = context.scheduler
    o.logger = context.logger
    o.storageMap = context.storageMap  -- All discovered storages
    o.bufferInventory = nil  -- DON'T ASSIGN YET!

    -- Auto-discovery state
    o.discoveryMode = false
    o.inputConfig = nil   -- {side: "left/right", networkId: "peripheral_name"}
    o.outputConfig = nil  -- {side: "left/right", networkId: "peripheral_name"}

    -- Initialize item index
    o.itemIndex = HashOA_RRSC:new(context.eventBus)
    o.itemIndex:load("/storage/data/item_index.dat")

    -- Get wired modem
    o.modem = peripheral.find("modem", function(name, p)
        return name == "back" and not p.isWireless()
    end)

    if not o.modem then
        o.logger:error("StorageService", "No wired modem found on back!")
        error("No wired modem on back")
    end

    -- Check for existing configuration
    local configPath = "/storage/cfg/io_config.json"
    if fs.exists(configPath) then
        local file = fs.open(configPath, "r")
        local config = textutils.unserialiseJSON(file.readAll())
        file.close()

        o.inputConfig = config.input
        o.outputConfig = config.output
        o.bufferInventory = config.buffer
        o.logger:info("StorageService", "Loaded I/O configuration")
        o.logger:info("StorageService", "Input: " .. o.inputConfig.networkId .. " (side: " .. o.inputConfig.side .. ")")
        o.logger:info("StorageService", "Output: " .. o.outputConfig.networkId .. " (side: " .. o.outputConfig.side .. ")")
    else
        o.logger:info("StorageService", "No configuration found, starting discovery...")
        o.discoveryMode = true
    end

    o.running = false
    return o
end

function StorageService:start()
    self.running = true

    if self.discoveryMode then
        self.logger:info("StorageService", "Starting auto-discovery...")
        self.scheduler:submit("io", function()
            self:runDiscovery()
        end)
    else
        -- Normal operation
        self:initializePeripherals()
        self:rebuildIndex()

        self.scheduler:submit("io", function()
            self:monitorInput()
        end)

        self.scheduler:submit("io", function()
            self:processBuffer()
        end)
    end

    -- Subscribe to events
    self.eventBus:subscribe("storage.withdraw", function(event, data)
        if not self.discoveryMode then
            self:withdraw(data.itemName, data.count)
        end
    end)

    self.logger:info("StorageService", "Service started")
end

function StorageService:runDiscovery()
    self.logger:info("Discovery", "=== AUTO-DISCOVERY MODE ===")
    self.logger:info("Discovery", "Please insert items into any chest...")

    -- Step 1: Wait for items to appear anywhere
    local lastState = self:captureAllInventoryState()
    local inputFound = false

    while not inputFound and self.running do
        os.sleep(0.5)
        local currentState = self:captureAllInventoryState()

        -- Find what changed
        for networkId, currentItems in pairs(currentState) do
            local lastItems = lastState[networkId] or {}

            -- Check if items were added
            if self:hasNewItems(lastItems, currentItems) then
                self.logger:info("Discovery", "Items detected in: " .. networkId)

                -- Step 2: Check if computer can see these items on left or right
                local detectedSide = nil

                -- Check left side
                if peripheral.isPresent("left") then
                    local leftInv = peripheral.wrap("left")
                    if leftInv and leftInv.list then
                        local leftItems = leftInv.list()
                        if self:inventoriesMatch(leftItems, currentItems) then
                            detectedSide = "left"
                        end
                    end
                end

                -- Check right side
                if not detectedSide and peripheral.isPresent("right") then
                    local rightInv = peripheral.wrap("right")
                    if rightInv and rightInv.list then
                        local rightItems = rightInv.list()
                        if self:inventoriesMatch(rightItems, currentItems) then
                            detectedSide = "right"
                        end
                    end
                end

                if detectedSide then
                    self.logger:info("Discovery", "INPUT FOUND!")
                    self.logger:info("Discovery", "Network ID: " .. networkId)
                    self.logger:info("Discovery", "Computer Side: " .. detectedSide)

                    self.inputConfig = {
                        side = detectedSide,
                        networkId = networkId
                    }

                    inputFound = true

                    -- Now discover output
                    self:discoverOutput(networkId, currentItems)
                    break
                end
            end
        end

        lastState = currentState
    end
end

function StorageService:discoverOutput(inputNetworkId, inputItems)
    self.logger:info("Discovery", "Searching for output chest...")

    -- Get the first item to test with
    local testSlot, testItem = next(inputItems)
    if not testSlot or not testItem then
        self.logger:error("Discovery", "No items to test with!")
        return
    end

    self.logger:info("Discovery", "Testing with: " .. testItem.name)

    -- Get input inventory using network ID
    local inputInv = peripheral.wrap(inputNetworkId)
    if not inputInv then
        self.logger:error("Discovery", "Failed to wrap input inventory!")
        return
    end

    -- Get opposite side for output
    local expectedOutputSide = (self.inputConfig.side == "left") and "right" or "left"

    -- Get all network inventories except input
    local testInventories = {}
    for _, name in ipairs(self.modem.getNamesRemote()) do
        if name ~= inputNetworkId then
            local pType = peripheral.getType(name)
            if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
                table.insert(testInventories, name)
            end
        end
    end

    self.logger:info("Discovery", "Found " .. #testInventories .. " inventories to test")

    -- Test each inventory
    for _, targetNetworkId in ipairs(testInventories) do
        self.logger:info("Discovery", "Testing: " .. targetNetworkId)

        -- Move ONE item using network IDs
        local moved = inputInv.pushItems(targetNetworkId, testSlot, 1)

        if moved and moved > 0 then
            -- Check if the opposite side now has the item
            os.sleep(0.2)  -- Small delay to ensure transfer completes

            if peripheral.isPresent(expectedOutputSide) then
                local sideInv = peripheral.wrap(expectedOutputSide)
                if sideInv and sideInv.list then
                    local sideItems = sideInv.list()

                    -- Check if the item appeared on this side
                    for slot, item in pairs(sideItems) do
                        if item.name == testItem.name then
                            self.logger:info("Discovery", "OUTPUT FOUND!")
                            self.logger:info("Discovery", "Network ID: " .. targetNetworkId)
                            self.logger:info("Discovery", "Computer Side: " .. expectedOutputSide)

                            self.outputConfig = {
                                side = expectedOutputSide,
                                networkId = targetNetworkId
                            }

                            -- Move item back to input
                            local targetInv = peripheral.wrap(targetNetworkId)
                            targetInv.pushItems(inputNetworkId, slot, 1)

                            -- Now assign buffer and save config
                            self:assignBufferAndSave()
                            return
                        end
                    end
                end
            end

            -- Not the output, move item back
            local targetInv = peripheral.wrap(targetNetworkId)
            if targetInv then
                -- Find where the item went
                local targetItems = targetInv.list()
                for slot, item in pairs(targetItems) do
                    if item.name == testItem.name then
                        targetInv.pushItems(inputNetworkId, slot, 1)
                        break
                    end
                end
            end
        end

        os.sleep(0.1)  -- Small delay between tests
    end

    self.logger:error("Discovery", "Could not find output chest!")
end

function StorageService:assignBufferAndSave()
    self.logger:info("Discovery", "Assigning buffer from remaining storages...")

    -- Find the largest remaining storage for buffer
    local largestSize = 0
    local largestId = nil

    for _, name in ipairs(self.modem.getNamesRemote()) do
        -- Skip input and output
        if name ~= self.inputConfig.networkId and name ~= self.outputConfig.networkId then
            local pType = peripheral.getType(name)
            if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
                local inv = peripheral.wrap(name)
                if inv and inv.size then
                    local size = inv.size()
                    if size > largestSize then
                        largestSize = size
                        largestId = name
                    end
                end
            end
        end
    end

    if largestId then
        self.bufferInventory = {
            name = largestId,
            size = largestSize
        }
        self.logger:info("Discovery", "Buffer assigned: " .. largestId .. " (" .. largestSize .. " slots)")
    else
        self.logger:error("Discovery", "No suitable buffer found!")
        return
    end

    -- Save configuration
    local config = {
        input = self.inputConfig,
        output = self.outputConfig,
        buffer = self.bufferInventory,
        timestamp = os.epoch("utc")
    }

    local file = fs.open("/storage/cfg/io_config.json", "w")
    file.write(textutils.serialiseJSON(config))
    file.close()

    self.logger:info("Discovery", "Configuration saved!")
    self.logger:info("Discovery", "Discovery complete! Starting normal operation...")

    -- Exit discovery mode and start normal operation
    self.discoveryMode = false
    self:initializePeripherals()
    self:rebuildIndex()

    -- Start monitoring
    self.scheduler:submit("io", function()
        self:monitorInput()
    end)

    self.scheduler:submit("io", function()
        self:processBuffer()
    end)
end

function StorageService:captureAllInventoryState()
    local state = {}

    -- Capture all network inventories
    for _, name in ipairs(self.modem.getNamesRemote()) do
        local pType = peripheral.getType(name)
        if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
            local inv = peripheral.wrap(name)
            if inv and inv.list then
                state[name] = inv.list()
            end
        end
    end

    return state
end

function StorageService:hasNewItems(oldItems, newItems)
    -- Count total items
    local oldCount = 0
    for _, item in pairs(oldItems) do
        oldCount = oldCount + item.count
    end

    local newCount = 0
    for _, item in pairs(newItems) do
        newCount = newCount + item.count
    end

    return newCount > oldCount
end

function StorageService:inventoriesMatch(inv1, inv2)
    -- Check if two inventories have the same items
    local items1 = {}
    for _, item in pairs(inv1) do
        items1[item.name] = (items1[item.name] or 0) + item.count
    end

    local items2 = {}
    for _, item in pairs(inv2) do
        items2[item.name] = (items2[item.name] or 0) + item.count
    end

    -- Compare
    for name, count in pairs(items1) do
        if items2[name] ~= count then
            return false
        end
    end

    for name, count in pairs(items2) do
        if items1[name] ~= count then
            return false
        end
    end

    return true
end

function StorageService:initializePeripherals()
    -- Use network IDs for everything!
    self.inputChest = peripheral.wrap(self.inputConfig.networkId)
    self.outputChest = peripheral.wrap(self.outputConfig.networkId)
    self.buffer = peripheral.wrap(self.bufferInventory.name)

    self.logger:info("StorageService", "Peripherals initialized using network IDs")
end

function StorageService:monitorInput()
    while self.running do
        if self.inputChest and self.buffer then
            local ok, items = pcall(function() return self.inputChest.list() end)
            if ok and items and next(items) then
                for slot, item in pairs(items) do
                    -- Transfer using network IDs only!
                    local moved = self.inputChest.pushItems(self.bufferInventory.name, slot)

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
                        -- Use network ID for transfer
                        local moved = self.buffer.pushItems(targetStorage.name, slot)

                        if moved and moved > 0 then
                            self.eventBus:publish("storage.movedToStorage", {
                                item = item.name,
                                count = moved,
                                storage = targetStorage.name
                            })
                        end
                    end
                end
            end
        end

        os.sleep(1)
    end
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
            reason = "No output chest"
        })
        return 0
    end

    local withdrawn = 0
    local remaining = math.min(requestedCount, itemData.count)

    for _, storage in ipairs(self.storageMap) do
        if remaining <= 0 then break end

        local inv = peripheral.wrap(storage.name)
        if inv then
            local ok, slots = pcall(function() return inv.list() end)
            if ok and slots then
                for slot, slotItem in pairs(slots) do
                    if slotItem.name == itemName and remaining > 0 then
                        local toMove = math.min(remaining, slotItem.count)

                        -- Use network ID for output!
                        local moved = inv.pushItems(self.outputConfig.networkId, slot, toMove)

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

-- Standard methods
function StorageService:findBestStorage(item)
    for _, storage in ipairs(self.storageMap) do
        -- Skip input, output, and buffer
        if storage.name ~= self.inputConfig.networkId and
                storage.name ~= self.outputConfig.networkId and
                storage.name ~= self.bufferInventory.name then

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

function StorageService:rebuildIndex()
    self.logger:info("StorageService", "Rebuilding item index...")

    self.itemIndex:clear()
    local totalItems = 0

    for _, storage in ipairs(self.storageMap) do
        -- Skip input, output, buffer
        if storage.name ~= self.inputConfig.networkId and
                storage.name ~= self.outputConfig.networkId and
                storage.name ~= self.bufferInventory.name then

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
    end

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

    return results
end

function StorageService:stop()
    self.running = false
    self.itemIndex:save("/storage/data/item_index.dat")
    self.logger:info("StorageService", "Service stopped")
end

return StorageService