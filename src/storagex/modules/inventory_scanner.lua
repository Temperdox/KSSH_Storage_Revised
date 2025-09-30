-- modules/inventory_scanner.lua
-- Inventory scanning utilities

local InventoryScanner = {}
InventoryScanner.__index = InventoryScanner

function InventoryScanner:new(logger)
    local self = setmetatable({}, InventoryScanner)
    self.logger = logger
    return self
end

function InventoryScanner:scanChest(chest, name)
    local items = {}
    local size = chest.size()

    for slot = 1, size do
        local item = chest.getItemDetail(slot)
        if item then
            -- Create standardized item entry
            table.insert(items, {
                name = item.name,
                displayName = item.displayName,
                count = item.count,
                maxCount = item.maxCount,
                nbt = item.nbt,
                slot = slot,
                chest = chest,
                chestName = name
            })
        end
    end

    return items
end

function InventoryScanner:findItem(chests, itemName, amount, avoidChest)
    local results = {}
    local foundAmount = 0

    for _, chest in ipairs(chests) do
        if not avoidChest or chest.name ~= peripheral.getName(avoidChest) then
            local items = self:scanChest(chest.peripheral, chest.name)

            for _, item in ipairs(items) do
                if item.name == itemName then
                    table.insert(results, item)
                    foundAmount = foundAmount + item.count

                    if amount and foundAmount >= amount then
                        return results
                    end
                end
            end
        end
    end

    return results
end

function InventoryScanner:findEmptySlot(chests, avoidChest)
    for _, chest in ipairs(chests) do
        if not avoidChest or chest.name ~= peripheral.getName(avoidChest) then
            local size = chest.peripheral.size()

            for slot = 1, size do
                if not chest.peripheral.getItemDetail(slot) then
                    return {
                        chest = chest.peripheral,
                        chestName = chest.name,
                        slot = slot
                    }
                end
            end
        end
    end

    return nil
end

function InventoryScanner:findPartialStack(chests, itemName, itemNbt)
    for _, chest in ipairs(chests) do
        local items = self:scanChest(chest.peripheral, chest.name)

        for _, item in ipairs(items) do
            if item.name == itemName and item.nbt == itemNbt and item.count < item.maxCount then
                return item
            end
        end
    end

    return nil
end

function InventoryScanner:getChestUsage(chest)
    local size = chest.size()
    local used = 0

    for slot = 1, size do
        if chest.getItemDetail(slot) then
            used = used + 1
        end
    end

    return {
        size = size,
        used = used,
        free = size - used,
        percentage = (used / size) * 100
    }
end

return InventoryScanner