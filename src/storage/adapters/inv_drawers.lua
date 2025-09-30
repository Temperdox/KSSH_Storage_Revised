local DrawersAdapter = {}
DrawersAdapter.__index = DrawersAdapter

function DrawersAdapter:new(peripheralName)
    local o = setmetatable({}, self)
    o.name = peripheralName
    o.peripheral = peripheral.wrap(peripheralName)

    if not o.peripheral then
        error("Failed to wrap drawer: " .. peripheralName)
    end

    -- Drawer-specific capabilities
    o.isDrawerController = peripheral.getType(peripheralName):find("controller") ~= nil

    return o
end

function DrawersAdapter:getSize()
    if self.peripheral.size then
        return self.peripheral.size()
    end

    -- Drawers typically have 1-4 slots
    if self.peripheral.getDrawerCount then
        return self.peripheral.getDrawerCount()
    end

    return 1  -- Default single drawer
end

function DrawersAdapter:list()
    if self.peripheral.list then
        return self.peripheral.list()
    end

    -- Alternative for drawer-specific API
    local items = {}
    local size = self:getSize()

    for slot = 1, size do
        local item = self:getItemDetail(slot)
        if item and item.count > 0 then
            items[slot] = item
        end
    end

    return items
end

function DrawersAdapter:getItemDetail(slot)
    if self.peripheral.getItemDetail then
        return self.peripheral.getItemDetail(slot)
    end

    -- Drawer-specific methods
    if self.peripheral.getItemInSlot then
        return self.peripheral.getItemInSlot(slot)
    end

    return nil
end

function DrawersAdapter:getItemLimit(slot)
    if self.peripheral.getItemLimit then
        return self.peripheral.getItemLimit(slot)
    end

    -- Drawers can have upgraded capacity
    if self.peripheral.getMaxItems then
        return self.peripheral.getMaxItems(slot)
    end

    -- Check for upgrades
    if self.peripheral.getUpgrades then
        local upgrades = self.peripheral.getUpgrades(slot)
        local baseLimit = 64

        if upgrades then
            -- Calculate based on upgrade level
            -- Common upgrade multipliers: 2x, 4x, 8x, 16x, 32x
            local multiplier = 1
            for _, upgrade in ipairs(upgrades) do
                if upgrade:find("storage") then
                    multiplier = multiplier * 2
                end
            end
            return baseLimit * multiplier
        end
    end

    return 64 * 32  -- Default upgraded drawer capacity
end

function DrawersAdapter:pushItems(toName, fromSlot, limit, toSlot)
    if self.peripheral.pushItems then
        return self.peripheral.pushItems(toName, fromSlot, limit, toSlot)
    end

    -- Alternative drawer method
    if self.peripheral.pushItemsToSlot then
        return self.peripheral.pushItemsToSlot(toName, fromSlot, limit, toSlot)
    end

    return 0
end

function DrawersAdapter:pullItems(fromName, fromSlot, limit, toSlot)
    if self.peripheral.pullItems then
        return self.peripheral.pullItems(fromName, fromSlot, limit, toSlot)
    end

    -- Alternative drawer method
    if self.peripheral.pullItemsFromSlot then
        return self.peripheral.pullItemsFromSlot(fromName, fromSlot, limit, toSlot)
    end

    return 0
end

function DrawersAdapter:isVoid()
    -- Check if drawer has void upgrade
    if self.peripheral.hasVoidUpgrade then
        return self.peripheral.hasVoidUpgrade()
    end

    if self.peripheral.getUpgrades then
        local upgrades = self.peripheral.getUpgrades()
        for _, upgrade in ipairs(upgrades or {}) do
            if upgrade:find("void") then
                return true
            end
        end
    end

    return false
end

function DrawersAdapter:getLocked()
    -- Check which slots are locked
    local locked = {}
    local size = self:getSize()

    for slot = 1, size do
        if self.peripheral.isLocked then
            locked[slot] = self.peripheral.isLocked(slot)
        else
            locked[slot] = false
        end
    end

    return locked
end

function DrawersAdapter:getPriority()
    -- Drawers often have priority for specific items
    if self.peripheral.getPriority then
        return self.peripheral.getPriority()
    end

    -- Controller has higher priority
    if self.isDrawerController then
        return 10
    end

    return 5
end

return DrawersAdapter
