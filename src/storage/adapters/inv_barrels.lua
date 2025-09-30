local BarrelsAdapter = {}
BarrelsAdapter.__index = BarrelsAdapter

function BarrelsAdapter:new(peripheralName)
    local o = setmetatable({}, self)
    o.name = peripheralName
    o.peripheral = peripheral.wrap(peripheralName)

    if not o.peripheral then
        error("Failed to wrap barrel: " .. peripheralName)
    end

    -- Detect barrel tier
    local pType = peripheral.getType(peripheralName)
    o.tier = self:detectTier(pType)

    return o
end

function BarrelsAdapter:detectTier(peripheralType)
    -- Detect barrel tier from type name
    local tiers = {
        copper = {size = 45, stackMultiplier = 1},
        iron = {size = 54, stackMultiplier = 1},
        silver = {size = 72, stackMultiplier = 1},
        gold = {size = 81, stackMultiplier = 2},
        diamond = {size = 108, stackMultiplier = 2},
        obsidian = {size = 108, stackMultiplier = 4},
        crystal = {size = 108, stackMultiplier = 8}
    }

    for tierName, config in pairs(tiers) do
        if peripheralType:lower():find(tierName) then
            return config
        end
    end

    -- Default tier
    return {size = 27, stackMultiplier = 1}
end

function BarrelsAdapter:getSize()
    if self.peripheral.size then
        return self.peripheral.size()
    end

    return self.tier.size
end

function BarrelsAdapter:getItemLimit(slot)
    if self.peripheral.getItemLimit then
        local baseLimit = self.peripheral.getItemLimit(slot)
        return baseLimit * self.tier.stackMultiplier
    end

    -- Calculate based on tier
    local item = self:getItemDetail(slot)
    if item then
        local baseStackSize = item.maxCount or 64
        return baseStackSize * self.tier.stackMultiplier
    end

    return 64 * self.tier.stackMultiplier
end

function BarrelsAdapter:getCapacity()
    local size = self:getSize()
    local items = self:list()
    local usedSlots = 0
    local totalItems = 0
    local maxCapacity = 0

    for slot = 1, size do
        local item = items[slot]
        if item then
            usedSlots = usedSlots + 1
            totalItems = totalItems + item.count
        end
        maxCapacity = maxCapacity + self:getItemLimit(slot)
    end

    return {
        totalSlots = size,
        usedSlots = usedSlots,
        freeSlots = size - usedSlots,
        totalItems = totalItems,
        maxCapacity = maxCapacity,
        utilization = totalItems / maxCapacity,
        tier = self.tier
    }
end

-- Inherit other methods from generic adapter
setmetatable(BarrelsAdapter, {__index = require("adapters.inv_generic")})

return BarrelsAdapter