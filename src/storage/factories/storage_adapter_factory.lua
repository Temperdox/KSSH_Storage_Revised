local StorageAdapterFactory = {}
StorageAdapterFactory.__index = StorageAdapterFactory

function StorageAdapterFactory:new()
    local o = setmetatable({}, self)
    o.adapters = {}

    -- Register default adapters
    self:registerDefaults()

    return o
end

function StorageAdapterFactory:registerDefaults()
    -- Load adapter modules
    local adapters = {
        ["minecraft:chest"] = "adapters.inv_generic",
        ["minecraft:barrel"] = "adapters.inv_generic",
        ["minecraft:hopper"] = "adapters.inv_generic",
        ["minecraft:dropper"] = "adapters.inv_generic",
        ["minecraft:dispenser"] = "adapters.inv_generic",
        ["minecraft:shulker_box"] = "adapters.inv_generic",
        ["storagedrawers:"] = "adapters.inv_drawers",
        ["refinedstorage:"] = "adapters.inv_refined",
        ["metalbarrels:"] = "adapters.inv_barrels"
    }

    for pattern, modulePath in pairs(adapters) do
        self:register(pattern, modulePath)
    end
end

function StorageAdapterFactory:register(pattern, adapterModule)
    self.adapters[pattern] = adapterModule
end

function StorageAdapterFactory:create(peripheralType, peripheralName)
    -- Find matching adapter
    local adapterModule = nil

    for pattern, module in pairs(self.adapters) do
        if peripheralType:find(pattern) then
            adapterModule = module
            break
        end
    end

    -- Default to generic adapter
    if not adapterModule then
        adapterModule = "adapters.inv_generic"
    end

    -- Load and instantiate adapter
    local ok, Adapter = pcall(require, adapterModule)
    if not ok then
        -- Fallback to generic
        Adapter = require("adapters.inv_generic")
    end

    return Adapter:new(peripheralName)
end

function StorageAdapterFactory:getAdapterFor(peripheralName)
    local pType = peripheral.getType(peripheralName)
    if not pType then
        return nil
    end

    return self:create(pType, peripheralName)
end

return StorageAdapterFactory
