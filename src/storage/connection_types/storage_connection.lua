local StorageConnection = {}

-- Configuration
StorageConnection.loadConnectionType = true
StorageConnection.id = "storage"
StorageConnection.name = "Storage Connection"
StorageConnection.description = "Remote storage system connection for inventory management"
StorageConnection.connectionType = "STORAGE"
StorageConnection.color = colors.orange
StorageConnection.icon = "S"

-- Lifecycle methods
function StorageConnection:onLoad(context)
    self.context = context
    self.logger = context.logger
    self.logger:info("StorageConnection", "Storage connection type loaded")
end

function StorageConnection:onConnect(connection)
    self.logger:info("StorageConnection", "Storage connected: #" .. connection.id)

    -- Initialize storage-specific data
    connection.storageData = {
        inventory = nil,
        lastSync = nil,
        totalSlots = 0,
        usedSlots = 0,
        availableItems = {}
    }

    -- Request initial inventory
    self:syncInventory(connection)
end

function StorageConnection:onDisconnect(connection)
    self.logger:info("StorageConnection", "Storage disconnected: #" .. connection.id)
end

function StorageConnection:onUpdate(connection)
    -- Sync inventory every 30 seconds
    local now = os.epoch("utc")
    if not connection.storageData.lastSync or (now - connection.storageData.lastSync) > 30000 then
        self:syncInventory(connection)
    end
end

-- Protocol methods
function StorageConnection:handleMessage(connection, message)
    if message.type == "inventory_sync" then
        connection.storageData.inventory = message.data
        connection.storageData.lastSync = os.epoch("utc")
        connection.storageData.totalSlots = message.data.totalSlots or 0
        connection.storageData.usedSlots = message.data.usedSlots or 0
        connection.storageData.availableItems = message.data.items or {}

        self.logger:info("StorageConnection", "Inventory synced from #" .. connection.id)
        return true

    elseif message.type == "withdrawal_complete" then
        self.logger:info("StorageConnection", "Withdrawal completed from #" .. connection.id)
        -- Trigger re-sync
        self:syncInventory(connection)
        return true

    elseif message.type == "withdrawal_failed" then
        self.logger:warn("StorageConnection", "Withdrawal failed from #" .. connection.id .. ": " .. (message.reason or "unknown"))
        return true
    end

    return false
end

function StorageConnection:sendMessage(connection, message)
    rednet.send(connection.id, message, "storage_pair")
end

-- Storage-specific methods
function StorageConnection:canUseAsStorage(connection)
    return connection.presence and connection.presence.online
end

function StorageConnection:syncInventory(connection)
    if not self:canUseAsStorage(connection) then
        return
    end

    self:sendMessage(connection, {
        type = "request_inventory_sync"
    })

    self.logger:info("StorageConnection", "Requested inventory sync from #" .. connection.id)
end

function StorageConnection:getInventory(connection)
    return connection.storageData and connection.storageData.inventory
end

function StorageConnection:requestWithdrawal(connection, itemName, quantity)
    if not self:canUseAsStorage(connection) then
        self.logger:warn("StorageConnection", "Cannot withdraw from offline storage #" .. connection.id)
        return false
    end

    self:sendMessage(connection, {
        type = "withdraw_item",
        item = itemName,
        quantity = quantity
    })

    self.logger:info("StorageConnection", "Withdrawal request sent to #" .. connection.id .. ": " .. itemName .. " x" .. quantity)
    return true
end

function StorageConnection:getAvailableItems(connection)
    if not connection.storageData then
        return {}
    end

    return connection.storageData.availableItems or {}
end

-- UI methods
function StorageConnection:drawDetails(connection, x, y, width, height)
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("== STORAGE INFO ==")
    y = y + 2

    local storageData = connection.storageData or {}

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Total Slots:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.white)
    term.write(tostring(storageData.totalSlots or 0))
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Used Slots:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.orange)
    term.write(tostring(storageData.usedSlots or 0))
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Unique Items:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.yellow)
    local itemCount = 0
    if storageData.availableItems then
        for _ in pairs(storageData.availableItems) do
            itemCount = itemCount + 1
        end
    end
    term.write(tostring(itemCount))
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Last Sync:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.cyan)
    if storageData.lastSync then
        local elapsed = (os.epoch("utc") - storageData.lastSync) / 1000
        term.write(string.format("%ds ago", math.floor(elapsed)))
    else
        term.write("Never")
    end
    y = y + 1

    return y
end

function StorageConnection:getActions(connection)
    return {
        {
            label = "SYNC NOW",
            color = colors.green,
            handler = function()
                self:syncInventory(connection)
            end
        }
    }
end

function StorageConnection:validate(connection)
    if not connection.id then
        return false, "Missing connection ID"
    end

    if not connection.name then
        return false, "Missing connection name"
    end

    return true, nil
end

return StorageConnection
