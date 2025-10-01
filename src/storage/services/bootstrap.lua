local fsx = require("core.fsx")

local Bootstrap = {}
Bootstrap.__index = Bootstrap

function Bootstrap:new(eventBus, logger)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.logger = logger
    o.configPath = "/cfg/storages.json"
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
        return name == "back" and not p.isWireless()
    end)

    if not modem then
        error("[ERROR] No wired modem found on back!")
    end

    local peripherals = modem.getNamesRemote()
    local storages = {}
    local largestStorage = nil
    local largestSize = 0

    -- Scan all inventories and ME interfaces
    self.logger:info("Bootstrap", string.format("Scanning %d peripherals...", #peripherals))
    for _, name in ipairs(peripherals) do
        local pType = peripheral.getType(name)

        -- Check if it's an ME interface
        if pType and self:isMEInterface(pType) then
            local p = peripheral.wrap(name)
            if p then
                local storage = {
                    id = #storages + 1,
                    name = name,
                    type = pType,
                    isME = true,
                    size = 0  -- ME systems have dynamic size
                }

                table.insert(storages, storage)

                self.logger:info("Bootstrap", string.format(
                        "Found ME Interface [%d]: %s (%s)",
                        storage.id, name, pType
                ))
            end
        -- Check if it's a regular inventory
        elseif pType and self:isInventory(pType) then
            local p = peripheral.wrap(name)
            if p and p.size then
                local size = p.size()
                local storage = {
                    id = #storages + 1,
                    name = name,
                    type = pType,
                    isME = false,
                    size = size
                }

                table.insert(storages, storage)

                -- Track largest for buffer
                if size > largestSize then
                    largestSize = size
                    largestStorage = storage
                end

                self.logger:info("Bootstrap", string.format(
                        "Found inventory [%d]: %s (%s) - %d slots",
                        storage.id, name, pType, size
                ))
            end
        else
            if pType then
                self.logger:debug("Bootstrap", string.format(
                    "Skipping: %s (%s)", name, pType
                ))
            end
        end
    end

    if #storages == 0 then
        error("[ERROR] No storage inventories found!")
    end

    -- Save configuration (NO BUFFER - all inventories are storage)
    local config = {
        storages = storages,
        inputSide = "right",
        outputSide = "left"
    }

    fsx.writeJson(self.configPath, config)

    self.logger:info("Bootstrap", string.format(
            "Configuration saved: %d storages (no buffer needed)",
            #storages
    ))

    return storages
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

function Bootstrap:isMEInterface(pType)
    -- Check for Applied Energistics 2 ME interfaces
    return pType:lower():find("me_interface") or
           pType:lower():find("meinterface") or
           pType == "ME Interface"
end

function Bootstrap:loadConfig(config)
    local storages = config.storages or {}

    -- Verify peripherals still exist
    for _, storage in ipairs(storages) do
        if not peripheral.isPresent(storage.name) then
            self.logger:warn("Bootstrap", string.format(
                    "Storage %s no longer present", storage.name
            ))
        end
    end

    return storages
end

function Bootstrap:rescan()
    -- Delete existing config
    fs.delete(self.configPath)

    -- Re-discover
    return self:discover()
end

return Bootstrap