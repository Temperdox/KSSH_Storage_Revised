local fsx = require("core.fsx")

local Bootstrap = {}
Bootstrap.__index = Bootstrap

function Bootstrap:new(eventBus, logger)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.logger = logger
    o.configPath = "/storage/cfg/storages.json"
    return o
end

function Bootstrap:discover()
    -- Check for existing config
    local config = fsx.readJson(self.configPath)
    if config then
        self.logger:info("Bootstrap", "Loading existing storage configuration")
        return self:loadConfig(config)
    end

    -- Find wired modem on back
    local modem = peripheral.find("modem", function(name, p)
        return name == "back" and p.isWireless and not p.isWireless()
    end)

    if not modem then
        error("[ERROR] No wired modem found on back!")
    end

    local peripherals = modem.getNamesRemote()
    local storages = {}
    local largestStorage = nil
    local largestSize = 0

    -- Scan all inventories
    for _, name in ipairs(peripherals) do
        local pType = peripheral.getType(name)

        -- Check if it's an inventory
        if pType and self:isInventory(pType) then
            local p = peripheral.wrap(name)
            if p and p.size then
                local size = p.size()
                local storage = {
                    id = #storages + 1,
                    name = name,
                    type = pType,
                    size = size
                }

                table.insert(storages, storage)

                -- Track largest for buffer
                if size > largestSize then
                    largestSize = size
                    largestStorage = storage
                end

                self.logger:debug("Bootstrap", string.format(
                        "Found %s: %d slots", name, size
                ))
            end
        end
    end

    if #storages == 0 then
        error("[ERROR] No storage inventories found!")
    end

    if not largestStorage then
        error("[ERROR] Could not determine buffer inventory!")
    end

    -- Remove buffer from storage list
    local finalStorages = {}
    for _, storage in ipairs(storages) do
        if storage.id ~= largestStorage.id then
            table.insert(finalStorages, storage)
        end
    end

    -- Save configuration
    local config = {
        storages = finalStorages,
        buffer = largestStorage,
        inputSide = "right",
        outputSide = "left"
    }

    fsx.writeJson(self.configPath, config)

    self.logger:info("Bootstrap", string.format(
            "Configuration saved: %d storages + buffer (%s)",
            #finalStorages, largestStorage.name
    ))

    return finalStorages, largestStorage
end

function Bootstrap:isInventory(pType)
    local inventoryTypes = {
        "chest", "barrel", "drawer", "storage",
        "inventory", "shulker", "hopper", "dropper",
        "dispenser", "furnace"
    }

    for _, invType in ipairs(inventoryTypes) do
        if pType:lower():find(invType) then
            return true
        end
    end

    return false
end

function Bootstrap:loadConfig(config)
    local storages = config.storages or {}
    local buffer = config.buffer

    if not buffer then
        error("[ERROR] No buffer configuration found!")
    end

    -- Verify peripherals still exist
    for _, storage in ipairs(storages) do
        if not peripheral.isPresent(storage.name) then
            self.logger:warn("Bootstrap", string.format(
                    "Storage %s no longer present", storage.name
            ))
        end
    end

    if not peripheral.isPresent(buffer.name) then
        error("[ERROR] Buffer inventory no longer present!")
    end

    return storages, buffer
end

function Bootstrap:rescan()
    -- Delete existing config
    fs.delete(self.configPath)

    -- Re-discover
    return self:discover()
end

return Bootstrap