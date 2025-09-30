local GenericAdapter = {}
GenericAdapter.__index = GenericAdapter

function GenericAdapter:new(peripheralName)
    local o = setmetatable({}, self)
    o.name = peripheralName
    o.peripheral = peripheral.wrap(peripheralName)

    if not o.peripheral then
        error("Failed to wrap peripheral: " .. peripheralName)
    end

    -- Cache capabilities
    o.capabilities = {
        size = o.peripheral.size ~= nil,
        list = o.peripheral.list ~= nil,
        getItemDetail = o.peripheral.getItemDetail ~= nil,
        getItemLimit = o.peripheral.getItemLimit ~= nil,
        pushItems = o.peripheral.pushItems ~= nil,
        pullItems = o.peripheral.pullItems ~= nil
    }

    return o
end

function GenericAdapter:getSize()
    if self.capabilities.size then
        return self.peripheral.size()
    end
    return 0
end

function GenericAdapter:list()
    if self.capabilities.list then
        return self.peripheral.list()
    end
    return {}
end

function GenericAdapter:getItemDetail(slot)
    if self.capabilities.getItemDetail then
        return self.peripheral.getItemDetail(slot)
    end

    -- Fallback to list
    local items = self:list()
    return items[slot]
end

function GenericAdapter:getItemLimit(slot)
    if self.capabilities.getItemLimit then
        return self.peripheral.getItemLimit(slot)
    end
    return 64  -- Default stack size
end

function GenericAdapter:pushItems(toName, fromSlot, limit, toSlot)
    if self.capabilities.pushItems then
        return self.peripheral.pushItems(toName, fromSlot, limit, toSlot)
    end
    return 0
end

function GenericAdapter:pullItems(fromName, fromSlot, limit, toSlot)
    if self.capabilities.pullItems then
        return self.peripheral.pullItems(fromName, fromSlot, limit, toSlot)
    end
    return 0
end

function GenericAdapter:getEmptySlots()
    local empty = {}
    local size = self:getSize()
    local items = self:list()

    for slot = 1, size do
        if not items[slot] then
            table.insert(empty, slot)
        end
    end

    return empty
end

function GenericAdapter:getUsedSlots()
    local used = {}
    local items = self:list()

    for slot, item in pairs(items) do
        table.insert(used, {
            slot = slot,
            item = item
        })
    end

    return used
end

function GenericAdapter:findItem(itemName)
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

function GenericAdapter:getCapacity()
    local size = self:getSize()
    local items = self:list()
    local usedSlots = 0
    local totalItems = 0

    for slot, item in pairs(items) do
        usedSlots = usedSlots + 1
        totalItems = totalItems + item.count
    end

    return {
        totalSlots = size,
        usedSlots = usedSlots,
        freeSlots = size - usedSlots,
        totalItems = totalItems,
        utilization = usedSlots / size
    }
end

function GenericAdapter:optimize()
    -- Consolidate stacks of the same item
    local items = self:list()
    local consolidated = {}

    -- Group items by name
    for slot, item in pairs(items) do
        if not consolidated[item.name] then
            consolidated[item.name] = {}
        end
        table.insert(consolidated[item.name], {
            slot = slot,
            count = item.count,
            maxCount = item.maxCount or 64
        })
    end

    -- Merge stacks
    local moves = 0
    for itemName, slots in pairs(consolidated) do
        if #slots > 1 then
            -- Sort by count ascending
            table.sort(slots, function(a, b) return a.count < b.count end)

            for i = 1, #slots - 1 do
                local from = slots[i]
                for j = i + 1, #slots do
                    local to = slots[j]

                    if to.count < to.maxCount then
                        local space = to.maxCount - to.count
                        local toMove = math.min(space, from.count)

                        if toMove > 0 then
                            self:pushItems(self.name, from.slot, toMove, to.slot)
                            moves = moves + 1

                            from.count = from.count - toMove
                            to.count = to.count + toMove

                            if from.count == 0 then
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    return moves
end

return GenericAdapter