local RefinedAdapter = {}
RefinedAdapter.__index = RefinedAdapter

function RefinedAdapter:new(peripheralName)
    local o = setmetatable({}, self)
    o.name = peripheralName
    o.peripheral = peripheral.wrap(peripheralName)

    if not o.peripheral then
        error("Failed to wrap RS interface: " .. peripheralName)
    end

    -- Check if it's an interface or external storage
    o.isInterface = peripheral.getType(peripheralName):find("interface") ~= nil
    o.isExternalStorage = peripheral.getType(peripheralName):find("external") ~= nil

    return o
end

function RefinedAdapter:getSize()
    if self.isInterface then
        -- RS Interface typically has 9 slots
        return 9
    end

    if self.peripheral.size then
        return self.peripheral.size()
    end

    -- For network storage, return large number
    if self.peripheral.getMaxStoredItems then
        return 1000  -- Virtual size
    end

    return 27  -- Default chest size
end

function RefinedAdapter:list()
    if self.peripheral.list then
        return self.peripheral.list()
    end

    -- RS-specific: list all items in network
    if self.peripheral.listItems then
        local networkItems = self.peripheral.listItems()
        local items = {}

        -- Convert to slot-based format
        for i, item in ipairs(networkItems) do
            items[i] = {
                name = item.name,
                count = item.count,
                nbt = item.nbt,
                displayName = item.displayName
            }
        end

        return items
    end

    return {}
end

function RefinedAdapter:getItemDetail(slot)
    if self.peripheral.getItemDetail then
        return self.peripheral.getItemDetail(slot)
    end

    -- For network items
    if self.peripheral.getItem then
        return self.peripheral.getItem(slot)
    end

    return nil
end

function RefinedAdapter:exportItem(itemName, count, toName)
    -- RS-specific export functionality
    if self.peripheral.exportItem then
        return self.peripheral.exportItem(
                {name = itemName},
                toName,
                count
        )
    end

    -- Fallback to standard push
    local slots = self:findItem(itemName)
    local exported = 0

    for _, slotInfo in ipairs(slots) do
        if exported >= count then break end

        local toExport = math.min(count - exported, slotInfo.count)
        local moved = self:pushItems(toName, slotInfo.slot, toExport)
        exported = exported + moved
    end

    return exported
end

function RefinedAdapter:importItem(itemName, count, fromName)
    -- RS-specific import functionality
    if self.peripheral.importItem then
        return self.peripheral.importItem(
                {name = itemName},
                fromName,
                count
        )
    end

    -- Fallback to standard pull
    return self:pullItems(fromName, nil, count)
end

function RefinedAdapter:getCraftableItems()
    -- Get list of craftable items
    if self.peripheral.getCraftableItems then
        return self.peripheral.getCraftableItems()
    end

    return {}
end

function RefinedAdapter:requestCrafting(itemName, count)
    -- Request crafting of items
    if self.peripheral.craftItem then
        return self.peripheral.craftItem(
                {name = itemName},
                count
        )
    end

    return false
end

function RefinedAdapter:getNetworkInfo()
    local info = {
        energy = 0,
        energyCapacity = 0,
        items = 0,
        itemCapacity = 0,
        fluids = 0,
        fluidCapacity = 0
    }

    if self.peripheral.getEnergyStored then
        info.energy = self.peripheral.getEnergyStored()
    end

    if self.peripheral.getMaxEnergyStored then
        info.energyCapacity = self.peripheral.getMaxEnergyStored()
    end

    if self.peripheral.getTotalItemStorage then
        info.items = self.peripheral.getTotalItemStorage()
    end

    if self.peripheral.getMaxItemStorage then
        info.itemCapacity = self.peripheral.getMaxItemStorage()
    end

    return info
end

function RefinedAdapter:findItem(itemName)
    -- Override to use RS search
    if self.peripheral.findItems then
        return self.peripheral.findItems({name = itemName})
    end

    -- Fallback to standard search
    local slots = {}
    local items = self:list()

    for slot, item in pairs(items) do
        if item.name == itemName then
            table.insert(slots, {
                slot = slot,
                count = item.count,
                item = item
            })
        end
    end

    return slots
end

return RefinedAdapter