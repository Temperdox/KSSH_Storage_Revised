local HashOA_RRSC = require("core.hash_oa_rrsc")
local Discovery = require("core.discovery")

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

    -- Storage location cache - maps item names to their best storage location
    -- This avoids repeated lookups and makes transfers FAST
    o.storageCache = {}

    -- Transfer queue for parallel processing
    o.transferQueue = {}
    o.queueLock = false  -- Simple lock for queue access

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

    -- Check for existing configuration from disk
    local configContent = context.diskManager:readFile("config", "io_config.json")
    if configContent then
        local ok, config = pcall(textutils.unserialiseJSON, configContent)
        if ok and config then
            o.inputConfig = config.input
            o.outputConfig = config.output
            o.logger:info("StorageService", "Loaded I/O configuration")
            o.logger:info("StorageService", "Input: " .. o.inputConfig.networkId .. " (side: " .. o.inputConfig.side .. ")")
            o.logger:info("StorageService", "Output: " .. o.outputConfig.networkId .. " (side: " .. o.outputConfig.side .. ")")
        else
            o.logger:warn("StorageService", "Failed to parse config, starting discovery...")
            o.discoveryMode = true
        end
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
        self.logger:info("StorageService", "Starting unified discovery...")

        -- Run discovery using the unified module
        self.scheduler:submit("io", function()
            self:runUnifiedDiscovery()
        end)
    else
        self.logger:warn("StorageService", "!!!! IN NORMAL MODE - STARTING ALL MONITORING THREADS !!!!")
        -- Normal operation
        self:initializePeripherals()

        self.logger:info("StorageService", "Submitting IO tasks to scheduler...")

        self.scheduler:submit("io", function()
            self:monitorInput()
        end, "input_monitor")

        -- Start 3 transfer workers for parallel processing
        for i = 1, 3 do
            self.scheduler:submit("io", function()
                self:transferWorker(i)
            end, "transfer_worker_" .. i)
        end

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

-- Unified discovery using new discovery module
function StorageService:runUnifiedDiscovery()
    local result = Discovery.discover(self.modem, self.logger, self.storageMap, self.itemIndex)

    if result then
        self.inputConfig = result.input
        self.outputConfig = result.output
        self:saveConfigAndStart()
    else
        self.logger:error("Discovery", "Discovery failed!")
    end
end


function StorageService:saveConfigAndStart()
    -- Save configuration using disk manager
    local config = {
        input = self.inputConfig,
        output = self.outputConfig,
        timestamp = os.epoch("utc")
    }

    local ok, json = pcall(textutils.serialiseJSON, config)

    if not ok then
        self.logger:error("Discovery", "Failed to serialize config: " .. tostring(json))
        return
    end

    -- Get disk status for logging
    local diskStatus = self.context.diskManager:getStatus()
    local diskPath = diskStatus.currentDisk and diskStatus.currentDisk.mountPath or "UNKNOWN"

    self.logger:warn("Discovery", "========================================")
    self.logger:warn("Discovery", "SAVING DISCOVERY CONFIG TO DISK")
    self.logger:warn("Discovery", "Disk: " .. diskPath)
    self.logger:warn("Discovery", "File: config/io_config.json")
    self.logger:warn("Discovery", "========================================")

    -- Use disk manager to save config
    local success = self.context.diskManager:writeFile("config", "io_config.json", json)

    if not success then
        self.logger:error("Discovery", "Failed to save config to disk!")
        return
    end

    self.logger:info("Discovery", "Configuration saved to disk successfully!")
    self.logger:info("Discovery", "Discovery complete! Starting normal operation...")

    -- Exit discovery mode and start normal operation
    self.discoveryMode = false
    self:initializePeripherals()
    self:rebuildIndex()

    -- Start input monitoring (detects items and adds to queue)
    self.scheduler:submit("io", function()
        self:monitorInput()
    end, "input_monitor")

    -- Start 3 transfer workers for parallel processing
    for i = 1, 3 do
        self.scheduler:submit("io", function()
            self:transferWorker(i)
        end, "transfer_worker_" .. i)
    end

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

-- Queue helper functions (thread-safe)
function StorageService:addToQueue(transferJob)
    -- Simple spinlock
    while self.queueLock do os.sleep(0) end
    self.queueLock = true

    table.insert(self.transferQueue, transferJob)

    self.queueLock = false
end

function StorageService:getFromQueue()
    -- Simple spinlock
    while self.queueLock do os.sleep(0) end
    self.queueLock = true

    local job = table.remove(self.transferQueue, 1)

    self.queueLock = false
    return job
end

function StorageService:monitorInput()
    self.logger:warn("StorageService", ">>>>>>>>>> INPUT MONITOR THREAD STARTED <<<<<<<<<<")
    self.logger:warn("StorageService", string.format("Input chest: %s", self.inputChest and self.inputConfig.networkId or "NIL"))

    while self.running do
        if self.inputChest then
            local ok, items = pcall(function() return self.inputChest.list() end)
            if ok and items and next(items) then
                local totalSlots = 0
                for _ in pairs(items) do totalSlots = totalSlots + 1 end
                self.logger:info("StorageService", string.format("[INPUT] Found %d slots with items", totalSlots))

                for slot, item in pairs(items) do
                    local count = item.count

                    -- Chunk items > 128 for parallel processing
                    if count > 128 then
                        local chunks = math.floor(count / 128)
                        local remainder = count % 128

                        -- Add full chunks
                        for i = 1, chunks do
                            self:addToQueue({
                                slot = slot,
                                itemName = item.name,
                                count = 128,
                                chunk = i,
                                totalChunks = chunks + (remainder > 0 and 1 or 0)
                            })
                        end

                        -- Add remainder
                        if remainder > 0 then
                            self:addToQueue({
                                slot = slot,
                                itemName = item.name,
                                count = remainder,
                                chunk = chunks + 1,
                                totalChunks = chunks + 1
                            })
                        end

                        self.logger:info("StorageService", string.format(
                            "[INPUT] Queued %s x%d in %d chunks",
                            item.name, count, chunks + (remainder > 0 and 1 or 0)
                        ))
                    else
                        -- Add single job
                        self:addToQueue({
                            slot = slot,
                            itemName = item.name,
                            count = count,
                            chunk = 1,
                            totalChunks = 1
                        })
                    end
                end
            end
        else
            self.logger:error("StorageService", "[INPUT] Thread cannot run - inputChest is nil")
            return
        end

        os.sleep(0.5)
    end
end

-- Transfer worker - processes jobs from the queue
function StorageService:transferWorker(workerId)
    self.logger:warn("StorageService", string.format(">>>>>>>>>> TRANSFER WORKER #%d STARTED <<<<<<<<<<", workerId))

    while self.running do
        local job = self:getFromQueue()

        if job then
            self.logger:info("StorageService", string.format(
                "[WORKER-%d] Processing: %s x%d (chunk %d/%d) from slot %d",
                workerId, job.itemName, job.count, job.chunk, job.totalChunks, job.slot
            ))

            -- Verify the item is still in the slot before attempting transfer
            local ok, item = pcall(function()
                local items = self.inputChest.list()
                return items[job.slot]
            end)

            if not ok or not item or item.name ~= job.itemName then
                self.logger:warn("StorageService", string.format(
                    "[WORKER-%d] Item no longer in slot %d, skipping",
                    workerId, job.slot
                ))
            else
                -- Transfer the items
                local moved = 0
                local cachedStorage = self.storageCache[job.itemName]

                -- FAST PATH: Try cached location first
                if cachedStorage then
                    self.logger:debug("StorageService", string.format(
                        "[WORKER-%d] Trying cached storage: %s",
                        workerId, cachedStorage
                    ))

                    for _, s in ipairs(self.storageMap) do
                        if s.name == cachedStorage then
                            if s.isME then
                                local meInterface = peripheral.wrap(s.name)
                                if meInterface and meInterface.importItem then
                                    local transferOk, result = pcall(function()
                                        return meInterface.importItem(
                                            {name = job.itemName, count = job.count},
                                            self.inputConfig.side
                                        )
                                    end)
                                    if transferOk and result and result > 0 then
                                        moved = result
                                        self.logger:info("StorageService", string.format(
                                            "[WORKER-%d] FAST: Moved %d to ME via cache",
                                            workerId, moved
                                        ))
                                    end
                                end
                            else
                                moved = self.inputChest.pushItems(s.name, job.slot, job.count) or 0
                                if moved > 0 then
                                    self.logger:info("StorageService", string.format(
                                        "[WORKER-%d] FAST: Moved %d to %s via cache",
                                        workerId, moved, s.name
                                    ))
                                end
                            end
                            break
                        end
                    end

                    -- Clear cache if failed
                    if moved == 0 then
                        self.logger:warn("StorageService", string.format(
                            "[WORKER-%d] Cache failed, clearing",
                            workerId
                        ))
                        self.storageCache[job.itemName] = nil
                    end
                end

                -- SLOW PATH: Find best storage
                if moved == 0 then
                    self.logger:info("StorageService", string.format(
                        "[WORKER-%d] Finding best storage...",
                        workerId
                    ))

                    local triedStorages = {}
                    local attempts = 0

                    while moved == 0 and attempts < 20 do
                        local targetStorage = self:findBestStorage({name = job.itemName}, triedStorages)

                        if not targetStorage then
                            self.logger:error("StorageService", string.format(
                                "[WORKER-%d] No storage found after %d attempts",
                                workerId, attempts
                            ))
                            break
                        end

                        attempts = attempts + 1
                        triedStorages[targetStorage.name] = true

                        if targetStorage.isME then
                            local meInterface = peripheral.wrap(targetStorage.name)
                            if meInterface and meInterface.importItem then
                                local transferOk, result = pcall(function()
                                    return meInterface.importItem(
                                        {name = job.itemName, count = job.count},
                                        self.inputConfig.side
                                    )
                                end)
                                if transferOk and result and result > 0 then
                                    moved = result
                                    self.storageCache[job.itemName] = targetStorage.name
                                    self.logger:info("StorageService", string.format(
                                        "[WORKER-%d] SUCCESS: Moved %d to ME, cached",
                                        workerId, moved
                                    ))
                                end
                            end
                        else
                            moved = self.inputChest.pushItems(targetStorage.name, job.slot, job.count) or 0
                            if moved > 0 then
                                self.storageCache[job.itemName] = targetStorage.name
                                self.logger:info("StorageService", string.format(
                                    "[WORKER-%d] SUCCESS: Moved %d to %s, cached",
                                    workerId, moved, targetStorage.name
                                ))
                            end
                        end
                    end
                end

                -- Publish event if successful
                if moved > 0 then
                    self.eventBus:publish("storage.inputReceived", {
                        item = job.itemName,
                        count = moved,
                        from = "input",
                        workerId = workerId
                    })
                else
                    self.logger:error("StorageService", string.format(
                        "[WORKER-%d] FAILED to move %s",
                        workerId, job.itemName
                    ))
                end
            end
        else
            -- Queue is empty, sleep briefly
            os.sleep(0.05)
        end
    end

    self.logger:warn("StorageService", string.format(">>>>>>>>>> TRANSFER WORKER #%d STOPPED <<<<<<<<<<", workerId))
end

function StorageService:transferInputToStorage(slot, item)
    self.logger:info("StorageService", string.format("[TRANSFER] Moving %s x%d from slot %d", item.name, item.count, slot))

    local moved = 0
    local cachedStorage = self.storageCache[item.name]

    -- FAST PATH: Try cached location first
    if cachedStorage then
        self.logger:debug("StorageService", "[TRANSFER] Trying cached storage: " .. cachedStorage)
        for _, s in ipairs(self.storageMap) do
            if s.name == cachedStorage then
                if s.isME then
                    local meInterface = peripheral.wrap(s.name)
                    if meInterface and meInterface.importItem then
                        local ok, result = pcall(function()
                            return meInterface.importItem({name = item.name, count = item.count}, self.inputConfig.side)
                        end)
                        if ok and result and result > 0 then
                            moved = result
                            self.logger:info("StorageService", "[TRANSFER] FAST: Moved to ME via cache")
                        end
                    end
                else
                    moved = self.inputChest.pushItems(s.name, slot) or 0
                    if moved > 0 then
                        self.logger:info("StorageService", "[TRANSFER] FAST: Moved to " .. s.name .. " via cache")
                    end
                end
                break
            end
        end

        -- Clear cache if failed
        if moved == 0 then
            self.logger:warn("StorageService", "[TRANSFER] Cache failed, clearing")
            self.storageCache[item.name] = nil
        end
    end

    -- SLOW PATH: Find best storage
    if moved == 0 then
        self.logger:info("StorageService", "[TRANSFER] Finding best storage...")
        local triedStorages = {}
        local attempts = 0

        while moved == 0 and attempts < 20 do
            local targetStorage = self:findBestStorage(item, triedStorages)

            if not targetStorage then
                self.logger:error("StorageService", string.format("[TRANSFER] No storage found after %d attempts", attempts))
                break
            end

            attempts = attempts + 1
            triedStorages[targetStorage.name] = true
            self.logger:debug("StorageService", "[TRANSFER] Attempt " .. attempts .. ": " .. targetStorage.name)

            if targetStorage.isME then
                local meInterface = peripheral.wrap(targetStorage.name)
                if meInterface and meInterface.importItem then
                    local ok, result = pcall(function()
                        return meInterface.importItem({name = item.name, count = item.count}, self.inputConfig.side)
                    end)
                    if ok and result and result > 0 then
                        moved = result
                        self.storageCache[item.name] = targetStorage.name
                        self.logger:info("StorageService", "[TRANSFER] SUCCESS: Moved to ME, cached")
                    end
                end
            else
                moved = self.inputChest.pushItems(targetStorage.name, slot) or 0
                if moved > 0 then
                    self.storageCache[item.name] = targetStorage.name
                    self.logger:info("StorageService", "[TRANSFER] SUCCESS: Moved to " .. targetStorage.name .. ", cached")
                end
            end
        end
    end

    if moved > 0 then
        self.eventBus:publish("storage.inputReceived", {
            item = item.name,
            count = moved,
            from = "input"
        })
    else
        self.logger:error("StorageService", string.format("[TRANSFER] FAILED to move %s", item.name))
    end
end

function StorageService:withdraw(itemName, requestedCount)
    -- If in discovery mode, cannot withdraw - discovery must complete first
    if self.discoveryMode then
        self.logger:warn("StorageService", "Cannot withdraw in discovery mode")
        self.eventBus:publish("storage.withdrawFailed", {
            item = itemName,
            reason = "System in discovery mode"
        })
        return 0
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