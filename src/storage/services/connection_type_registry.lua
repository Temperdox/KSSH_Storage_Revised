local ConnectionTypeRegistry = {}
ConnectionTypeRegistry.__index = ConnectionTypeRegistry

-- Connection type enum
ConnectionTypeRegistry.ConnectionType = {
    STORAGE = "STORAGE",
    MONITOR = "MONITOR",
    CUSTOM = "CUSTOM"
}

function ConnectionTypeRegistry:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.logger = context.logger
    o.connectionTypes = {}
    o.connectionTypesByEnum = {
        STORAGE = {},
        MONITOR = {},
        CUSTOM = {}
    }

    return o
end

function ConnectionTypeRegistry:start()
    self.logger:info("ConnectionTypeRegistry", "Starting connection type registry")
    self:loadConnectionTypes()
end

function ConnectionTypeRegistry:loadConnectionTypes()
    local typesPath = "/storage/connection_types"

    if not fs.exists(typesPath) then
        self.logger:warn("ConnectionTypeRegistry", "Connection types directory not found: " .. typesPath)
        return
    end

    local files = fs.list(typesPath)

    for _, fileName in ipairs(files) do
        if fileName:match("%.lua$") then
            local filePath = fs.combine(typesPath, fileName)
            self:loadConnectionType(filePath, fileName)
        end
    end

    self.logger:info("ConnectionTypeRegistry", "Loaded " .. #self:getConnectionTypes() .. " connection types")
end

function ConnectionTypeRegistry:loadConnectionType(filePath, fileName)
    local ok, connectionType = pcall(dofile, filePath)

    if not ok then
        self.logger:error("ConnectionTypeRegistry", "Failed to load " .. fileName .. ": " .. tostring(connectionType))
        return
    end

    -- Check if should load
    if connectionType.loadConnectionType == false then
        self.logger:info("ConnectionTypeRegistry", "Skipping " .. fileName .. " (loadConnectionType = false)")
        return
    end

    -- Validate required fields
    if not connectionType.id then
        self.logger:warn("ConnectionTypeRegistry", "Connection type in " .. fileName .. " missing 'id' field")
        return
    end

    if not connectionType.name then
        self.logger:warn("ConnectionTypeRegistry", "Connection type in " .. fileName .. " missing 'name' field")
        return
    end

    if not connectionType.connectionType then
        self.logger:warn("ConnectionTypeRegistry", "Connection type in " .. fileName .. " missing 'connectionType' field")
        return
    end

    -- Call onLoad lifecycle method
    if connectionType.onLoad then
        connectionType:onLoad(self.context)
    end

    -- Register connection type
    self.connectionTypes[connectionType.id] = connectionType

    -- Register by enum type
    local enumType = connectionType.connectionType
    if self.connectionTypesByEnum[enumType] then
        table.insert(self.connectionTypesByEnum[enumType], connectionType)
    end

    self.logger:info("ConnectionTypeRegistry", "Registered connection type: " .. connectionType.name .. " (" .. connectionType.id .. ")")
end

function ConnectionTypeRegistry:getConnectionType(id)
    return self.connectionTypes[id]
end

function ConnectionTypeRegistry:getConnectionTypes()
    local types = {}
    for _, connType in pairs(self.connectionTypes) do
        table.insert(types, connType)
    end

    -- Sort by name
    table.sort(types, function(a, b)
        return a.name < b.name
    end)

    return types
end

function ConnectionTypeRegistry:getConnectionTypesByEnum(enumType)
    return self.connectionTypesByEnum[enumType] or {}
end

function ConnectionTypeRegistry:getStorageConnectionTypes()
    return self:getConnectionTypesByEnum(ConnectionTypeRegistry.ConnectionType.STORAGE)
end

function ConnectionTypeRegistry:getMonitorConnectionTypes()
    return self:getConnectionTypesByEnum(ConnectionTypeRegistry.ConnectionType.MONITOR)
end

-- Connection lifecycle handlers
function ConnectionTypeRegistry:onConnect(connection)
    local connectionType = self:getConnectionType(connection.connectionTypeId or "storage")

    if connectionType and connectionType.onConnect then
        connectionType:onConnect(connection)
    end
end

function ConnectionTypeRegistry:onDisconnect(connection)
    local connectionType = self:getConnectionType(connection.connectionTypeId or "storage")

    if connectionType and connectionType.onDisconnect then
        connectionType:onDisconnect(connection)
    end
end

function ConnectionTypeRegistry:onUpdate(connection)
    local connectionType = self:getConnectionType(connection.connectionTypeId or "storage")

    if connectionType and connectionType.onUpdate then
        connectionType:onUpdate(connection)
    end
end

function ConnectionTypeRegistry:handleMessage(connection, message)
    local connectionType = self:getConnectionType(connection.connectionTypeId or "storage")

    if connectionType and connectionType.handleMessage then
        return connectionType:handleMessage(connection, message)
    end

    return false
end

function ConnectionTypeRegistry:stop()
    self.logger:info("ConnectionTypeRegistry", "Stopped connection type registry")
end

return ConnectionTypeRegistry
