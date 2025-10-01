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

    -- Auto-discovery state
    o.discoveryMode = false
    o.inputConfig = nil   -- {side: "left/right", networkId: "peripheral_name"}
    o.outputConfig = nil  -- {side: "left/right", networkId: "peripheral_name"}

    -- Initialize item index
    o.itemIndex = HashOA_RRSC:new(context.eventBus)
    o.itemIndex:load("/data/item_index.dat")

    -- Get wired modem
    o.modem = peripheral.find("modem", function(name, p)
        return name == "back" and not p.isWireless()
    end)

    if not o.modem then
        o.logger:error("StorageService", "No wired modem found on back!")
        error("No wired modem on back")
    end

    -- Check for existing configuration
    local configPath = "/cfg/io_config.json"
    if fs.exists(configPath) then
        local file = fs.open(configPath, "r")
        local config = textutils.unserialiseJSON(file.readAll())
        file.close()

        o.inputConfig = config.input
        o.outputConfig = config.output
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

    self.logger:warn("StorageService", "============================================================")
    self.logger:warn("StorageService", "STORAGE SERVICE START() CALLED")
    self.logger:warn("StorageService", string.format("Discovery mode: %s", tostring(self.discoveryMode)))
    self.logger:warn("StorageService", "============================================================")

    -- ALWAYS rebuild index immediately on startup, regardless of discovery mode
    self.logger:info("StorageService", "Building initial index from all inventories...")
    self:rebuildIndexAllInventories()

    if self.discoveryMode then
        self.logger:warn("StorageService", "!!!! IN DISCOVERY MODE !!!!")
        self.logger:info("StorageService", "Discovery will trigger when:")
        self.logger:info("StorageService", "  1. You click to withdraw an item on the monitor")
        self.logger:info("StorageService", "  2. You place items in a chest next to the computer")

        -- Start simple periodic check for manual item insertion
        self.scheduler:submit("io", function()
            self:checkForManualInsertion()
        end)
    else
        self.logger:warn("StorageService", "!!!! IN NORMAL MODE - STARTING ALL MONITORING THREADS !!!!")
        -- Normal operation
        self:initializePeripherals()

        self.logger:info("StorageService", "Submitting IO tasks to scheduler...")

        self.scheduler:submit("io", function()
            self:monitorInput()
        end, "input_monitor")

        -- Start periodic sync to monitor service
        self.logger:info("StorageService", "Submitting syncToMonitor task...")
        self.scheduler:submit("io", function()
            self.logger:info("StorageService", "syncToMonitor task STARTED in scheduler")
            self:syncToMonitor()
        end, "monitor_sync")

        -- Start active storage monitoring to detect manual changes
        self.logger:warn("StorageService", "========================================")
        self.logger:warn("StorageService", "SUBMITTING STORAGE MONITOR TASK TO IO POOL")
        self.logger:warn("StorageService", "========================================")
        self.scheduler:submit("io", function()
            self.logger:warn("StorageService", ">>>>>>>>>> STORAGE MONITOR THREAD STARTED <<<<<<<<<<")
            self:monitorStorageChanges()
        end, "storage_monitor")

        self.logger:info("StorageService", "All IO tasks submitted")
    end

    -- Subscribe to events (allow withdrawals in discovery mode for auto-discovery)
    self.eventBus:subscribe("storage.withdraw", function(event, data)
        self:withdraw(data.itemName, data.count)
    end)

    self.logger:info("StorageService", "Service started")
end

-- Simple periodic check for manual item insertion
function StorageService:checkForManualInsertion()
    self.logger:info("Discovery", "========================================")
    self.logger:info("Discovery", "AUTOMATIC DISCOVERY")
    self.logger:info("Discovery", "========================================")
    self.logger:info("Discovery", "Place ONE item in a chest on LEFT or RIGHT side")
    self.logger:info("Discovery", "The chest with the item = INPUT")
    self.logger:info("Discovery", "System will auto-detect OUTPUT on opposite side")

    local lastCheck = {}

    while self.running and self.discoveryMode do
        os.sleep(0.5)

        -- Check all networked inventories for new items
        for _, name in ipairs(self.modem.getNamesRemote()) do
            local pType = peripheral.getType(name)
            if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
                local inv = peripheral.wrap(name)
                if inv and inv.list then
                    local items = inv.list()
                    local currentCount = 0
                    for _ in pairs(items) do
                        currentCount = currentCount + 1
                    end

                    local lastCount = lastCheck[name] or 0

                    -- New items detected in previously empty chest
                    if currentCount > 0 and lastCount == 0 then
                        self.logger:info("Discovery", "========================================")
                        self.logger:info("Discovery", "Items detected in: " .. name)

                        -- Get first item
                        local _, firstItem = next(items)
                        if firstItem then
                            self.logger:info("Discovery", "Test item: " .. firstItem.name)
                            self:discoverFromItemNetworked(firstItem.name, name)
                            return
                        end
                    end

                    lastCheck[name] = currentCount
                end
            end
        end
    end
end

-- Discovery by moving item to networked chests and checking which appears on opposite side
function StorageService:discoverFromItemNetworked(itemName, inputNetworkId)
    self.logger:info("Discovery", "=== STARTING DISCOVERY ===")
    self.logger:info("Discovery", "Input chest: " .. inputNetworkId)
    self.logger:info("Discovery", "Test item: " .. itemName)

    -- Determine which side this input chest is on
    local inputSide = nil
    if peripheral.isPresent("left") then
        local leftInv = peripheral.wrap("left")
        if leftInv and leftInv.list then
            local leftItems = leftInv.list()
            for _, item in pairs(leftItems) do
                if item.name == itemName then
                    inputSide = "left"
                    break
                end
            end
        end
    end

    if not inputSide and peripheral.isPresent("right") then
        local rightInv = peripheral.wrap("right")
        if rightInv and rightInv.list then
            local rightItems = rightInv.list()
            for _, item in pairs(rightItems) do
                if item.name == itemName then
                    inputSide = "right"
                    break
                end
            end
        end
    end

    if not inputSide then
        self.logger:error("Discovery", "Could not determine which side input chest is on!")
        return
    end

    self.logger:info("Discovery", "Input is on " .. inputSide .. " side")

    local oppositeSide = (inputSide == "left") and "right" or "left"
    self.logger:info("Discovery", "Looking for output on " .. oppositeSide .. " side")

    -- Get the input inventory
    local inputInv = peripheral.wrap(inputNetworkId)
    if not inputInv then
        self.logger:error("Discovery", "Failed to wrap input inventory")
        return
    end

    -- Find the test item slot
    local testSlot = nil
    local items = inputInv.list()
    for slot, item in pairs(items) do
        if item.name == itemName then
            testSlot = slot
            break
        end
    end

    if not testSlot then
        self.logger:error("Discovery", "Test item not found in input chest")
        return
    end

    -- Get all OTHER networked inventories to test
    local testInventories = {}
    for _, name in ipairs(self.modem.getNamesRemote()) do
        if name ~= inputNetworkId then
            local pType = peripheral.getType(name)
            if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
                table.insert(testInventories, name)
            end
        end
    end

    self.logger:info("Discovery", "Testing " .. #testInventories .. " chests for output")

    local outputNetworkId = nil

    -- Test each chest - check if item appears on OPPOSITE side
    for _, targetNetworkId in ipairs(testInventories) do
        self.logger:info("Discovery", "Testing: " .. targetNetworkId)

        -- Push item to test inventory
        local moved = inputInv.pushItems(targetNetworkId, testSlot, 1)

        if moved > 0 then
            self.logger:info("Discovery", "Moved item to " .. targetNetworkId)
            os.sleep(0.3)

            -- Check if item appeared on opposite side
            if peripheral.isPresent(oppositeSide) then
                local oppInv = peripheral.wrap(oppositeSide)
                if oppInv and oppInv.list then
                    local oppItems = oppInv.list()
                    for _, item in pairs(oppItems) do
                        if item.name == itemName then
                            -- FOUND IT!
                            self.logger:info("Discovery", "OUTPUT FOUND: " .. targetNetworkId)
                            self.logger:info("Discovery", "Item appeared on " .. oppositeSide .. " side!")
                            outputNetworkId = targetNetworkId
                            break
                        end
                    end
                end
            end

            if outputNetworkId then
                break
            else
                -- Not the output, move item back
                self.logger:info("Discovery", "Not output, moving item back...")
                local targetInv = peripheral.wrap(targetNetworkId)
                if targetInv then
                    local targetItems = targetInv.list()
                    for slot, item in pairs(targetItems) do
                        if item.name == itemName then
                            targetInv.pushItems(inputNetworkId, slot, 1)
                            os.sleep(0.2)
                            break
                        end
                    end
                end
            end
        end

        os.sleep(0.1)
    end

    if not outputNetworkId then
        self.logger:error("Discovery", "Could not find output chest on " .. oppositeSide .. " side!")
        return
    end

    -- Save configuration
    self.inputConfig = {
        side = inputSide,
        networkId = inputNetworkId
    }

    self.outputConfig = {
        side = oppositeSide,
        networkId = outputNetworkId
    }

    self.logger:info("Discovery", "========================================")
    self.logger:info("Discovery", "CONFIGURATION COMPLETE")
    self.logger:info("Discovery", "Input (" .. inputSide .. "): " .. inputNetworkId)
    self.logger:info("Discovery", "Output (" .. oppositeSide .. "): " .. outputNetworkId)
    self.logger:info("Discovery", "========================================")

    self:saveConfigAndStart()
end

function StorageService:saveConfigAndStart()
    -- Save configuration (NO BUFFER NEEDED)
    local config = {
        input = self.inputConfig,
        output = self.outputConfig,
        timestamp = os.epoch("utc")
    }

    local file = fs.open("/cfg/io_config.json", "w")
    local ok, json = pcall(textutils.serialiseJSON, config)

    if not ok then
        file.close()
        error(string.format("[StorageService:saveConfig] Failed to serialize config: %s", tostring(json)))
        return
    end

    file.write(json)
    file.close()

    self.logger:info("Discovery", "Configuration saved!")
    self.logger:info("Discovery", "Discovery complete! Starting normal operation...")

    -- Exit discovery mode and start normal operation
    self.discoveryMode = false
    self:initializePeripherals()
    self:rebuildIndex()

    -- Start input monitoring (moves directly to storage, no buffer)
    self.scheduler:submit("io", function()
        self:monitorInput()
    end, "input_monitor")

    -- Start periodic sync to monitor service
    self.scheduler:submit("io", function()
        self:syncToMonitor()
    end, "monitor_sync")

    -- Start active storage monitoring
    self.logger:warn("StorageService", "========================================")
    self.logger:warn("StorageService", "SUBMITTING STORAGE MONITOR TASK TO IO POOL (DISCOVERY COMPLETE)")
    self.logger:warn("StorageService", "========================================")
    self.scheduler:submit("io", function()
        self.logger:warn("StorageService", ">>>>>>>>>> STORAGE MONITOR THREAD STARTED (DISCOVERY) <<<<<<<<<<")
        self:monitorStorageChanges()
    end, "storage_monitor")
end

function StorageService:initializePeripherals()
    -- Use network IDs for input/output only (no buffer!)
    self.inputChest = peripheral.wrap(self.inputConfig.networkId)
    self.outputChest = peripheral.wrap(self.outputConfig.networkId)

    self.logger:info("StorageService", "Peripherals initialized using network IDs")
end

function StorageService:monitorInput()
    self.logger:warn("StorageService", ">>>>>>>>>> INPUT MONITOR THREAD STARTED <<<<<<<<<<")
    self.logger:warn("StorageService", string.format("Input chest: %s", self.inputChest and self.inputConfig.networkId or "NIL"))

    while self.running do
        if self.inputChest then
            local ok, items = pcall(function() return self.inputChest.list() end)
            if ok and items and next(items) then
                self.logger:warn("StorageService", string.format("[INPUT] Found %d items in input chest", self:countItems(items)))
                for slot, item in pairs(items) do
                    -- Submit individual task to move directly to storage (NO BUFFER)
                    self.scheduler:submit("io", function()
                        self:transferInputToStorage(slot, item)
                    end, "input_transfer")
                end
            end
        else
            self.logger:error("StorageService", "[INPUT] Thread cannot run - inputChest is nil")
            return -- Exit thread if peripheral isn't set
        end

        os.sleep(0.5)
    end
end

function StorageService:transferInputToStorage(slot, item)
    self.logger:warn("StorageService", string.format(
        "[INPUT→STORAGE] Starting transfer: slot=%d, item=%s x%d",
        slot, item.name, item.count
    ))

    local moved = 0
    local triedStorages = {}

    -- Keep trying different storage locations until we succeed or run out of options
    while moved == 0 do
        -- Find best storage location (excluding ones we've already tried)
        local targetStorage = self:findBestStorage(item, triedStorages)

        if not targetStorage then
            self.logger:warn("StorageService", string.format(
                "[INPUT→STORAGE] No storage found for %s (tried %d storages)",
                item.name, #triedStorages
            ))
            return
        end

        -- Mark this storage as tried
        triedStorages[targetStorage.name] = true

        -- Handle ME interfaces with importItem
        if targetStorage.isME then
            local meInterface = peripheral.wrap(targetStorage.name)
            if meInterface and meInterface.importItem then
                local importFilter = {
                    name = item.name,
                    count = item.count
                }

                local ok, result = pcall(function()
                    return meInterface.importItem(importFilter, self.inputConfig.side)
                end)

                if ok and result and result > 0 then
                    moved = result
                    self.logger:warn("StorageService", string.format(
                        "[INPUT→STORAGE] Imported %d x %s to ME system",
                        moved, item.name
                    ))
                end
            end
        else
            -- Regular inventory - use pushItems
            moved = self.inputChest.pushItems(targetStorage.name, slot) or 0
            if moved > 0 then
                self.logger:warn("StorageService", string.format(
                    "[INPUT→STORAGE] Pushed %d x %s to %s",
                    moved, item.name, targetStorage.name
                ))
            else
                self.logger:warn("StorageService", string.format(
                    "[INPUT→STORAGE] Failed to push to %s (full?), trying next storage...",
                    targetStorage.name
                ))
            end
        end

        -- Break if we've tried too many (safety limit)
        if #triedStorages >= 20 then
            self.logger:error("StorageService", "[INPUT→STORAGE] Tried 20 storages, giving up")
            break
        end
    end

    -- Publish event (NO index update - storage monitor will handle that)
    if moved and moved > 0 then
        self.eventBus:publish("storage.inputReceived", {
            item = item.name,
            count = moved,
            from = "input",
            to = triedStorages, -- This will be a table, but we don't really need it
            isME = false
        })

        self.logger:warn("StorageService", string.format(
            "[INPUT→STORAGE] SUCCESS - moved %d x %s (storage monitor will update index)",
            moved, item.name
        ))
    else
        self.logger:warn("StorageService", string.format(
            "[INPUT→STORAGE] Failed to move %s from input",
            item.name
        ))
    end
end

function StorageService:withdraw(itemName, requestedCount)
    -- If in discovery mode, trigger withdrawal-based discovery
    if self.discoveryMode then
        self.logger:info("StorageService", "========================================")
        self.logger:info("StorageService", "WITHDRAWAL-TRIGGERED DISCOVERY")
        self.logger:info("StorageService", "========================================")
        self.logger:info("StorageService", "Step 1: Find OUTPUT (left side)")
        self.logger:info("StorageService", "Step 2: Find INPUT (right side)")

        -- Find item in storage
        local itemData = self.itemIndex:get(itemName)
        if not itemData or itemData.count == 0 then
            self.eventBus:publish("storage.withdrawFailed", {
                item = itemName,
                reason = "Item not found"
            })
            return 0
        end

        -- Get list of test inventories
        local testInventories = {}
        for _, name in ipairs(self.modem.getNamesRemote()) do
            local pType = peripheral.getType(name)
            if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
                table.insert(testInventories, name)
            end
        end

        self.logger:info("StorageService", "Testing " .. #testInventories .. " inventories")

        -- STEP 1: Find OUTPUT (must appear on LEFT side)
        local outputNetworkId = nil

        for _, targetName in ipairs(testInventories) do
            -- Try to move item from storage to this inventory
            local moved = false
            for _, storage in ipairs(self.storageMap) do
                local inv = peripheral.wrap(storage.name)
                if inv and inv.list then
                    local slots = inv.list()
                    for slot, item in pairs(slots) do
                        if item.name == itemName then
                            local result = inv.pushItems(targetName, slot, 1)
                            if result and result > 0 then
                                moved = true
                                self.logger:info("StorageService", "Moved item to: " .. targetName)
                                os.sleep(0.3)
                                break
                            end
                        end
                    end
                    if moved then break end
                end
            end

            if moved then
                -- Check if item appeared on LEFT side
                if peripheral.isPresent("left") then
                    local leftInv = peripheral.wrap("left")
                    if leftInv and leftInv.list then
                        local leftItems = leftInv.list()
                        for _, item in pairs(leftItems) do
                            if item.name == itemName then
                                outputNetworkId = targetName
                                self.logger:info("StorageService", "OUTPUT FOUND: " .. targetName .. " (left side)")
                                break
                            end
                        end
                    end
                end

                if outputNetworkId then
                    break
                else
                    -- Not output, move item back to storage
                    local targetInv = peripheral.wrap(targetName)
                    if targetInv and targetInv.list then
                        local targetSlots = targetInv.list()
                        for slot, item in pairs(targetSlots) do
                            if item.name == itemName then
                                -- Move back to first available storage
                                for _, storage in ipairs(self.storageMap) do
                                    local moved = targetInv.pushItems(storage.name, slot, 1)
                                    if moved and moved > 0 then
                                        break
                                    end
                                end
                                break
                            end
                        end
                    end
                    os.sleep(0.2)
                end
            end
        end

        if not outputNetworkId then
            self.logger:error("StorageService", "Failed to find OUTPUT on left side!")
            return 0
        end

        -- STEP 2: Find INPUT (must appear on RIGHT side)
        local inputNetworkId = nil

        for _, targetName in ipairs(testInventories) do
            if targetName == outputNetworkId then
                -- Skip output
                goto continue
            end

            -- Try to move item from storage to this inventory
            local moved = false
            for _, storage in ipairs(self.storageMap) do
                local inv = peripheral.wrap(storage.name)
                if inv and inv.list then
                    local slots = inv.list()
                    for slot, item in pairs(slots) do
                        if item.name == itemName then
                            local result = inv.pushItems(targetName, slot, 1)
                            if result and result > 0 then
                                moved = true
                                self.logger:info("StorageService", "Moved item to: " .. targetName)
                                os.sleep(0.3)
                                break
                            end
                        end
                    end
                    if moved then break end
                end
            end

            if moved then
                -- Check if item appeared on RIGHT side
                if peripheral.isPresent("right") then
                    local rightInv = peripheral.wrap("right")
                    if rightInv and rightInv.list then
                        local rightItems = rightInv.list()
                        for _, item in pairs(rightItems) do
                            if item.name == itemName then
                                inputNetworkId = targetName
                                self.logger:info("StorageService", "INPUT FOUND: " .. targetName .. " (right side)")
                                break
                            end
                        end
                    end
                end

                if inputNetworkId then
                    break
                else
                    -- Not input, move item back to storage
                    local targetInv = peripheral.wrap(targetName)
                    if targetInv and targetInv.list then
                        local targetSlots = targetInv.list()
                        for slot, item in pairs(targetSlots) do
                            if item.name == itemName then
                                -- Move back to first available storage
                                for _, storage in ipairs(self.storageMap) do
                                    local moved = targetInv.pushItems(storage.name, slot, 1)
                                    if moved and moved > 0 then
                                        break
                                    end
                                end
                                break
                            end
                        end
                    end
                    os.sleep(0.2)
                end
            end

            ::continue::
        end

        if not inputNetworkId then
            self.logger:error("StorageService", "Failed to find INPUT on right side!")
            return 0
        end

        -- Move item from INPUT to OUTPUT
        self.logger:info("StorageService", "Moving item from INPUT to OUTPUT...")
        local inputInv = peripheral.wrap(inputNetworkId)
        if inputInv and inputInv.list then
            local inputSlots = inputInv.list()
            for slot, item in pairs(inputSlots) do
                if item.name == itemName then
                    inputInv.pushItems(outputNetworkId, slot, 1)
                    os.sleep(0.2)
                    break
                end
            end
        end

        -- Save configuration
        self.inputConfig = {
            side = "right",
            networkId = inputNetworkId
        }

        self.outputConfig = {
            side = "left",
            networkId = outputNetworkId
        }

        self.logger:info("StorageService", "========================================")
        self.logger:info("StorageService", "DISCOVERY COMPLETE")
        self.logger:info("StorageService", "Input (right): " .. inputNetworkId)
        self.logger:info("StorageService", "Output (left): " .. outputNetworkId)
        self.logger:info("StorageService", "========================================")

        self:saveConfigAndStart()

        -- Item is now in output, count as 1 withdrawn
        if requestedCount <= 1 then
            return 1
        else
            -- Withdraw remaining items
            os.sleep(0.5)
            local additional = self:withdraw(itemName, requestedCount - 1)
            return 1 + additional
        end
    end

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

        -- Handle ME interfaces
        if storage.isME then
            local meInterface = peripheral.wrap(storage.name)
            if meInterface and meInterface.exportItem then
                -- Export from ME to output chest
                local exportFilter = {
                    name = itemName,
                    count = remaining
                }

                local ok, moved = pcall(function()
                    return meInterface.exportItem(exportFilter, self.outputConfig.side or "up")
                end)

                if ok and moved and moved > 0 then
                    withdrawn = withdrawn + moved
                    remaining = remaining - moved

                    self.eventBus:publish("storage.itemWithdrawn", {
                        item = itemName,
                        count = moved,
                        from = storage.name,
                        isME = true
                    })

                    self.logger:debug("StorageService", string.format(
                        "Exported %d x %s from ME system",
                        moved, itemName
                    ))
                end
            end
        else
            -- Regular inventory
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
    end

    -- Don't update index here - storage monitor will detect the removal and update it
    -- This prevents double-counting (withdraw + monitor both updating)

    self.eventBus:publish("storage.withdrawComplete", {
        item = itemName,
        requested = requestedCount,
        withdrawn = withdrawn
    })

    return withdrawn
end

-- Standard methods
function StorageService:findBestStorage(item, triedStorages)
    triedStorages = triedStorages or {}

    -- First pass: prefer ME interfaces (unlimited storage)
    for _, storage in ipairs(self.storageMap) do
        -- Skip input, output, and already-tried storages
        if storage.name ~= self.inputConfig.networkId and
                storage.name ~= self.outputConfig.networkId and
                not triedStorages[storage.name] then

            if storage.isME then
                -- ME interfaces always have space
                return storage
            end
        end
    end

    -- Second pass: check regular inventories
    for _, storage in ipairs(self.storageMap) do
        -- Skip input, output, and already-tried storages
        if storage.name ~= self.inputConfig.networkId and
                storage.name ~= self.outputConfig.networkId and
                not triedStorages[storage.name] then

            if not storage.isME then
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

    -- FIX: Use consistent field names
    self.eventBus:publish("index.updated", {
        key = itemName,  -- Use 'key' to match monitor expectations
        item = itemName, -- Also include 'item' for compatibility
        count = current.count,
        operation = operation
    })
end

function StorageService:rebuildIndexAllInventories()
    self.logger:info("StorageService", "=== SCANNING ALL INVENTORIES (NO CONFIG) ===")

    self.itemIndex:clear()
    local totalItems = 0
    local totalSlots = 0

    -- Scan ALL network inventories and ME interfaces, no skip list
    local scannedCount = 0
    for _, name in ipairs(self.modem.getNamesRemote()) do
        local pType = peripheral.getType(name)

        -- Check if it's an ME interface
        if pType and (pType:lower():find("me_interface") or pType:lower():find("meinterface")) then
            scannedCount = scannedCount + 1
            self.logger:info("StorageService", string.format(">>> Scanning ME Interface %s (%s)", name, pType))

            local meInterface = peripheral.wrap(name)
            if meInterface and meInterface.listItems then
                local ok, items = pcall(function() return meInterface.listItems() end)
                if ok and items then
                    local itemCount = #items
                    self.logger:info("StorageService", string.format("    Found %d items in ME system %s", itemCount, name))

                    for _, item in ipairs(items) do
                        local current = self.itemIndex:get(item.name) or {
                            count = 0,
                            stackSize = item.maxCount or 64,
                            nbtHash = item.nbt,
                            locations = {},
                            isME = true
                        }

                        local amount = item.amount or item.count or 0
                        current.count = current.count + amount
                        table.insert(current.locations, {
                            name = name,
                            isME = true,
                            count = amount
                        })

                        self.itemIndex:put(item.name, current)
                        totalItems = totalItems + 1
                    end
                else
                    self.logger:error("StorageService", "FAILED to list ME items: " .. name)
                end
            else
                self.logger:error("StorageService", "FAILED to wrap ME interface: " .. name)
            end
        -- Check if it's a regular inventory type
        elseif pType and (pType:find("chest") or pType:find("barrel") or pType:find("drawer") or
                      pType:find("storage") or pType:find("shulker")) then
            scannedCount = scannedCount + 1
            self.logger:info("StorageService", string.format(">>> Scanning %s (%s)", name, pType))

            local inv = peripheral.wrap(name)
            if inv and inv.list then
                local ok, slots = pcall(function() return inv.list() end)
                if ok and slots then
                    local slotCount = 0
                    for _ in pairs(slots) do slotCount = slotCount + 1 end
                    totalSlots = totalSlots + slotCount

                    self.logger:info("StorageService", string.format("    Found %d items in %s", slotCount, name))

                    for slot, item in pairs(slots) do
                        local current = self.itemIndex:get(item.name) or {
                            count = 0,
                            stackSize = item.maxCount or 64,
                            nbtHash = item.nbt,
                            locations = {}
                        }

                        current.count = current.count + item.count
                        table.insert(current.locations, {
                            name = name,
                            slot = slot,
                            count = item.count
                        })

                        self.itemIndex:put(item.name, current)
                        totalItems = totalItems + 1
                    end
                else
                    self.logger:error("StorageService", "FAILED to scan: " .. name)
                end
            else
                self.logger:error("StorageService", "FAILED to wrap: " .. name)
            end
        end
    end

    self.itemIndex:save("/data/item_index.dat")

    local uniqueCount = self.itemIndex:getSize()

    self.logger:info("StorageService", "=== INITIAL INDEX COMPLETE ===")
    self.logger:info("StorageService", string.format("Scanned: %d inventories", scannedCount))
    self.logger:info("StorageService", string.format("Unique items: %d", uniqueCount))
    self.logger:info("StorageService", string.format("Total slots: %d", totalSlots))
    self.logger:info("StorageService", string.format("Total stacks: %d", totalItems))

    self.eventBus:publish("storage.indexRebuilt", {
        uniqueCount = uniqueCount,
        totalStacks = totalItems,
        timestamp = os.epoch("utc")
    })

    self.logger:info("StorageService", "Published storage.indexRebuilt event")
end

function StorageService:rebuildIndex()
    self.logger:info("StorageService", "=== STARTING INDEX REBUILD ===")
    self.logger:info("StorageService", string.format("StorageMap has %d inventories", #self.storageMap))

    self.itemIndex:clear()
    local totalItems = 0
    local totalSlots = 0

    -- Build skip list for special inventories (input and output only, no buffer)
    local skipList = {}
    if self.inputConfig and self.inputConfig.networkId then
        skipList[self.inputConfig.networkId] = true
        self.logger:info("StorageService", "Skip input: " .. self.inputConfig.networkId)
    end
    if self.outputConfig and self.outputConfig.networkId then
        skipList[self.outputConfig.networkId] = true
        self.logger:info("StorageService", "Skip output: " .. self.outputConfig.networkId)
    end

    self.logger:info("StorageService", string.format("StorageMap contains %d entries:", #self.storageMap))
    for i, storage in ipairs(self.storageMap) do
        self.logger:info("StorageService", string.format("  [%d] name=%s, id=%d, type=%s, size=%d",
            i, storage.name or "nil", storage.id or 0, storage.type or "nil", storage.size or 0))
    end

    for _, storage in ipairs(self.storageMap) do
        -- Skip input, output, buffer
        local shouldSkip = skipList[storage.name]
        self.logger:info("StorageService", string.format("Checking storage: %s (skipList[%s] = %s)",
            storage.name, storage.name, tostring(shouldSkip)))

        if not shouldSkip then
            self.logger:info("StorageService", string.format(">>> Scanning storage: %s (ME=%s)", storage.name, tostring(storage.isME)))

            -- Handle ME interfaces differently
            if storage.isME then
                local meInterface = peripheral.wrap(storage.name)
                if meInterface and meInterface.listItems then
                    local ok, items = pcall(function() return meInterface.listItems() end)
                    if ok and items then
                        local itemCount = #items
                        self.logger:info("StorageService", string.format("    Found %d items in ME system %s", itemCount, storage.name))

                        for _, item in ipairs(items) do
                            local current = self.itemIndex:get(item.name) or {
                                count = 0,
                                stackSize = item.maxCount or 64,
                                nbtHash = item.nbt,
                                locations = {},
                                isME = true
                            }

                            local amount = item.amount or item.count or 0
                            current.count = current.count + amount
                            table.insert(current.locations, {
                                id = storage.id,
                                name = storage.name,
                                isME = true,
                                count = amount
                            })

                            self.itemIndex:put(item.name, current)
                            totalItems = totalItems + 1

                            -- Publish event for each item indexed
                            self.logger:debug("StorageService", string.format("    Indexed ME: %s x%d", item.name, amount))
                            self.eventBus:publish("storage.itemIndexed", {
                                key = item.name,
                                item = item.name,
                                count = current.count,
                                storage = storage.name,
                                isME = true
                            })
                        end
                    else
                        self.logger:error("StorageService", "FAILED to list ME items: " .. storage.name)
                    end
                else
                    self.logger:error("StorageService", "FAILED to wrap ME interface: " .. storage.name)
                end
            else
                -- Regular inventory
                local inv = peripheral.wrap(storage.name)
                if inv then
                    local ok, slots = pcall(function() return inv.list() end)
                    if ok and slots then
                        local slotCount = 0
                        for _ in pairs(slots) do slotCount = slotCount + 1 end
                        totalSlots = totalSlots + slotCount

                        self.logger:info("StorageService", string.format("    Found %d items in %s", slotCount, storage.name))

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

                            -- Publish event for each item indexed
                            self.logger:debug("StorageService", string.format("    Indexed: %s x%d", item.name, item.count))
                            self.eventBus:publish("storage.itemIndexed", {
                                key = item.name,
                                item = item.name,
                                count = current.count,
                                storage = storage.name
                            })
                        end
                    else
                        self.logger:error("StorageService", "FAILED to scan: " .. storage.name)
                    end
                else
                    self.logger:error("StorageService", "FAILED to wrap: " .. storage.name)
                end
            end
        else
            self.logger:info("StorageService", "Skipping special inventory: " .. storage.name)
        end
    end

    self.itemIndex:save("/data/item_index.dat")

    local uniqueCount = self.itemIndex:getSize()

    self.logger:info("StorageService", "=== INDEX REBUILD COMPLETE ===")
    self.logger:info("StorageService", string.format("Unique items: %d", uniqueCount))
    self.logger:info("StorageService", string.format("Total slots: %d", totalSlots))
    self.logger:info("StorageService", string.format("Total stacks: %d", totalItems))

    self.eventBus:publish("storage.indexRebuilt", {
        uniqueItems = uniqueCount,
        totalStacks = totalItems
    })

    self.logger:info("StorageService", "Published storage.indexRebuilt event")
end

function StorageService:getItems()
    local items = self.itemIndex:getAllItems()
    local size = self.itemIndex:getSize()

    self.logger:debug("StorageService", string.format(
        "getItems called: returning %d items, index size: %d",
        #items, size
    ))

    return items
end

function StorageService:monitorStorageChanges()
    self.logger:info("StorageService", "Starting active storage monitoring...")

    -- Build skip list for special inventories (input and output only, no buffer)
    local skipList = {}
    if self.inputConfig and self.inputConfig.networkId then
        skipList[self.inputConfig.networkId] = true
        self.logger:info("StorageService", "Monitoring: Skipping input chest: " .. self.inputConfig.networkId)
    end
    if self.outputConfig and self.outputConfig.networkId then
        skipList[self.outputConfig.networkId] = true
        self.logger:info("StorageService", "Monitoring: Skipping output chest: " .. self.outputConfig.networkId)
    end

    self.logger:info("StorageService", string.format("Monitoring %d storage inventories", #self.storageMap))

    -- Capture initial state
    local previousState = self:captureStorageState(skipList)
    local monitorCount = 0

    while self.running do
        -- Wait 1 second between checks
        os.sleep(1)
        monitorCount = monitorCount + 1

        -- Capture current state
        local currentState = self:captureStorageState(skipList)

        self.logger:info("StorageService", string.format(
            "Storage monitor check #%d: %d inventories scanned",
            monitorCount, self:countInventories(currentState)
        ))

        -- Compare states and emit events for changes
        self:detectAndEmitChanges(previousState, currentState)

        previousState = currentState
    end

    self.logger:info("StorageService", "Stopped active storage monitoring")
end

function StorageService:countInventories(state)
    local count = 0
    for _ in pairs(state) do
        count = count + 1
    end
    return count
end

function StorageService:countItems(items)
    local count = 0
    for _ in pairs(items) do
        count = count + 1
    end
    return count
end

function StorageService:captureStorageState(skipList)
    -- Capture detailed state of all storage inventories
    local state = {}
    local totalItems = 0

    for _, storage in ipairs(self.storageMap) do
        if not skipList[storage.name] then
            local items = {}

            if storage.isME then
                -- Capture ME system state
                local meInterface = peripheral.wrap(storage.name)
                if meInterface and meInterface.listItems then
                    local ok, meItems = pcall(function() return meInterface.listItems() end)
                    if ok and meItems then
                        for _, item in ipairs(meItems) do
                            local amount = item.amount or item.count or 0
                            items[item.name] = (items[item.name] or 0) + amount
                            totalItems = totalItems + 1
                        end
                    end
                end
            else
                -- Capture regular inventory state
                local inv = peripheral.wrap(storage.name)
                if inv and inv.list then
                    local ok, slots = pcall(function() return inv.list() end)
                    if ok and slots then
                        for slot, item in pairs(slots) do
                            items[item.name] = (items[item.name] or 0) + item.count
                            totalItems = totalItems + 1
                        end
                    else
                        self.logger:warn("StorageService", string.format(
                            "Failed to list inventory: %s",
                            storage.name
                        ))
                    end
                end
            end

            state[storage.name] = items
        end
    end

    self.logger:info("StorageService", string.format(
        "Captured state: %d storages, %d total item stacks",
        self:countInventories(state), totalItems
    ))

    return state
end

function StorageService:detectAndEmitChanges(previousState, currentState)
    -- Track all item names across both states
    local allItems = {}

    -- Collect all item names from previous state
    for storageName, items in pairs(previousState) do
        for itemName, _ in pairs(items) do
            allItems[itemName] = true
        end
    end

    -- Collect all item names from current state
    for storageName, items in pairs(currentState) do
        for itemName, _ in pairs(items) do
            allItems[itemName] = true
        end
    end

    local itemCount = 0
    for _ in pairs(allItems) do itemCount = itemCount + 1 end

    self.logger:info("StorageService", string.format(
        "Checking %d unique items for changes...",
        itemCount
    ))

    local changesDetected = 0

    -- Check each item for changes
    for itemName, _ in pairs(allItems) do
        local previousCount = 0
        local currentCount = 0

        -- Sum previous count across all storages
        for storageName, items in pairs(previousState) do
            previousCount = previousCount + (items[itemName] or 0)
        end

        -- Sum current count across all storages
        for storageName, items in pairs(currentState) do
            currentCount = currentCount + (items[itemName] or 0)
        end

        -- Detect changes
        if currentCount ~= previousCount then
            changesDetected = changesDetected + 1
            local difference = currentCount - previousCount

            if difference > 0 then
                -- Items added
                self.logger:info("StorageService", string.format(
                    ">>> DETECTED ADDITION: %s x%d (was %d, now %d)",
                    itemName, difference, previousCount, currentCount
                ))

                self:updateIndex(itemName, difference, "add")

                self.eventBus:publish("storage.itemAdded", {
                    key = itemName,
                    item = itemName,
                    count = difference,
                    totalCount = currentCount
                })
            else
                -- Items removed
                local removed = math.abs(difference)
                self.logger:info("StorageService", string.format(
                    ">>> DETECTED REMOVAL: %s x%d (was %d, now %d)",
                    itemName, removed, previousCount, currentCount
                ))

                self:updateIndex(itemName, removed, "remove")

                self.eventBus:publish("storage.itemRemoved", {
                    key = itemName,
                    item = itemName,
                    count = removed,
                    totalCount = currentCount
                })
            end
        end
    end

    if changesDetected > 0 then
        self.logger:info("StorageService", string.format(
            "Total changes detected: %d",
            changesDetected
        ))
    end
end

function StorageService:syncToMonitor()
    self.logger:info("StorageService", "Starting periodic sync to monitor service...")

    local syncCount = 0

    while self.running do
        -- Wait 1 second
        os.sleep(1)
        syncCount = syncCount + 1

        -- Get current items from index
        local items = self.itemIndex:getAllItems()
        local uniqueCount = self.itemIndex:getSize()

        -- Log every sync (every second) to both console and log file
        self.logger:info("StorageService", string.format(
            "SYNC CHECK #%d: Index has %d unique items, %d total entries",
            syncCount, uniqueCount, #items
        ))

        -- Sync to monitor service if available
        if self.context.services and self.context.services.monitor then
            -- Directly update monitor's cache
            if self.context.services.monitor.updateCache then
                self.context.services.monitor:updateCache(items, uniqueCount)
                self.logger:info("StorageService", string.format(
                    "Synced %d items (%d unique) to monitor service [sync #%d]",
                    #items, uniqueCount, syncCount
                ))
            else
                self.logger:warn("StorageService", "Monitor service has no updateCache method!")
            end
        else
            self.logger:warn("StorageService", "Monitor service not available for sync!")
        end
    end

    self.logger:info("StorageService", "Stopped periodic sync to monitor service")
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
    self.itemIndex:save("/data/item_index.dat")
    self.logger:info("StorageService", "Service stopped")
end

return StorageService