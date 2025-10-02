-- ============================================================================
-- DISCOVERY MODULE - Maps physical sides (left/right) to network IDs
-- ============================================================================
-- The computer can access chests two ways:
--   1. Physical: "left" or "right" (no inventory name)
--   2. Network: "sophisticatedstorage:chest_7" (has inventory name)
-- Discovery pumps items through network inventories to determine which
-- network ID corresponds to which physical side.
-- ============================================================================

local Discovery = {}

-- Main discovery function
function Discovery.discover(modem, logger, storageMap, itemIndex)
    logger:info("Discovery", "========================================")
    logger:info("Discovery", "UNIFIED DISCOVERY STARTING")
    logger:info("Discovery", "========================================")

    -- Get test item (from storage or wait for manual input)
    local testItemName, sourceStorage = Discovery.getTestItem(modem, logger, storageMap)

    if not testItemName then
        logger:error("Discovery", "No test item available!")
        return nil
    end

    logger:info("Discovery", "Test item: " .. testItemName)
    logger:info("Discovery", "Source: " .. (sourceStorage or "manual input"))

    -- Map physical sides to network IDs
    local leftNetworkId = nil
    local rightNetworkId = nil

    -- Get list of all networked inventories (including source - we need to map it too!)
    local testInventories = {}
    for _, name in ipairs(modem.getNamesRemote()) do
        local pType = peripheral.getType(name)
        if pType and (pType:find("chest") or pType:find("barrel") or pType:find("shulker")) then
            table.insert(testInventories, name)
        end
    end

    logger:info("Discovery", "Testing " .. #testInventories .. " network inventories...")

    -- Get source inventory
    local sourceInv = sourceStorage and peripheral.wrap(sourceStorage) or peripheral.wrap("right")
    if not sourceInv then
        logger:error("Discovery", "Failed to wrap source inventory")
        return nil
    end

    -- Find test item slot
    local testSlot = nil
    local items = sourceInv.list()
    for slot, item in pairs(items) do
        if item.name == testItemName then
            testSlot = slot
            break
        end
    end

    if not testSlot then
        logger:error("Discovery", "Test item not found")
        return nil
    end

    -- First, check if the source storage itself is on a physical side
    if sourceStorage then
        -- Check if source is on LEFT
        if peripheral.isPresent("left") then
            local leftInv = peripheral.wrap("left")
            if leftInv and leftInv.list then
                local leftItems = leftInv.list()
                for _, item in pairs(leftItems) do
                    if item.name == testItemName then
                        logger:info("Discovery", "Source chest is on LEFT side")
                        leftNetworkId = sourceStorage
                        break
                    end
                end
            end
        end

        -- Check if source is on RIGHT
        if peripheral.isPresent("right") then
            local rightInv = peripheral.wrap("right")
            if rightInv and rightInv.list then
                local rightItems = rightInv.list()
                for _, item in pairs(rightItems) do
                    if item.name == testItemName then
                        logger:info("Discovery", "Source chest is on RIGHT side")
                        rightNetworkId = sourceStorage
                        break
                    end
                end
            end
        end
    end

    -- Test each networked inventory (excluding source if already mapped)
    for _, networkId in ipairs(testInventories) do
        -- Skip if this is the source and we already mapped it
        if networkId == sourceStorage and (leftNetworkId == sourceStorage or rightNetworkId == sourceStorage) then
            goto continue_test
        end

        logger:info("Discovery", "Testing: " .. networkId)

        -- Push item to this inventory
        local moved = sourceInv.pushItems(networkId, testSlot, 1)

        if moved > 0 then
            os.sleep(0.2)

            -- Check if item appeared on LEFT physical side
            if peripheral.isPresent("left") then
                local leftInv = peripheral.wrap("left")
                if leftInv and leftInv.list then
                    local leftItems = leftInv.list()
                    for _, item in pairs(leftItems) do
                        if item.name == testItemName then
                            logger:info("Discovery", "LEFT side = " .. networkId)
                            leftNetworkId = networkId
                            break
                        end
                    end
                end
            end

            -- Check if item appeared on RIGHT physical side
            if peripheral.isPresent("right") then
                local rightInv = peripheral.wrap("right")
                if rightInv and rightInv.list then
                    local rightItems = rightInv.list()
                    for _, item in pairs(rightItems) do
                        if item.name == testItemName then
                            logger:info("Discovery", "RIGHT side = " .. networkId)
                            rightNetworkId = networkId
                            break
                        end
                    end
                end
            end

            -- If we found a match, move item back to storage
            if leftNetworkId == networkId or rightNetworkId == networkId then
                local targetInv = peripheral.wrap(networkId)
                if targetInv then
                    local targetItems = targetInv.list()
                    for slot, item in pairs(targetItems) do
                        if item.name == testItemName then
                            if sourceStorage then
                                targetInv.pushItems(sourceStorage, slot, 1)
                            end
                            break
                        end
                    end
                end
                os.sleep(0.1)
            end

            -- Stop if we found both sides
            if leftNetworkId and rightNetworkId then
                break
            end

            -- If not a match, try to move item back and continue
            if not (leftNetworkId == networkId or rightNetworkId == networkId) then
                local targetInv = peripheral.wrap(networkId)
                if targetInv then
                    local targetItems = targetInv.list()
                    for slot, item in pairs(targetItems) do
                        if item.name == testItemName then
                            if sourceStorage then
                                targetInv.pushItems(sourceStorage, slot, 1)
                            else
                                -- Move back to right side for next test
                                targetInv.pushItems("right", slot, 1)
                            end
                            break
                        end
                    end
                end
                os.sleep(0.1)
            end
        end

        ::continue_test::
    end

    if not leftNetworkId or not rightNetworkId then
        logger:error("Discovery", "Could not map both physical sides!")
        logger:error("Discovery", "Left: " .. (leftNetworkId or "NOT FOUND"))
        logger:error("Discovery", "Right: " .. (rightNetworkId or "NOT FOUND"))
        return nil
    end

    -- Determine INPUT and OUTPUT based on assumption: INPUT=right, OUTPUT=left
    local inputConfig = {
        side = "right",
        networkId = rightNetworkId
    }

    local outputConfig = {
        side = "left",
        networkId = leftNetworkId
    }

    logger:info("Discovery", "========================================")
    logger:info("Discovery", "DISCOVERY COMPLETE")
    logger:info("Discovery", "Input (right): " .. rightNetworkId)
    logger:info("Discovery", "Output (left): " .. leftNetworkId)
    logger:info("Discovery", "========================================")

    return {
        input = inputConfig,
        output = outputConfig
    }
end

-- Get test item from storage or wait for manual input
function Discovery.getTestItem(modem, logger, storageMap)
    -- Try to find any item in storage
    for _, storage in ipairs(storageMap) do
        if not storage.isME then
            local inv = peripheral.wrap(storage.name)
            if inv and inv.list then
                local items = inv.list()
                for slot, item in pairs(items) do
                    logger:info("Discovery", "Found test item in storage: " .. item.name)
                    return item.name, storage.name
                end
            end
        end
    end

    -- No items in storage - wait for manual input
    logger:info("Discovery", "No items in storage")
    logger:info("Discovery", "Place ONE item in the INPUT chest (right side)...")

    local lastCheck = {}

    while true do
        os.sleep(0.5)

        -- Check for new items in networked inventories
        for _, name in ipairs(modem.getNamesRemote()) do
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

                    -- New items detected
                    if currentCount > 0 and lastCount == 0 then
                        local _, firstItem = next(items)
                        if firstItem then
                            logger:info("Discovery", "Item detected in: " .. name)
                            -- Return the item name AND the inventory it's in!
                            return firstItem.name, name
                        end
                    end

                    lastCheck[name] = currentCount
                end
            end
        end
    end
end

return Discovery
