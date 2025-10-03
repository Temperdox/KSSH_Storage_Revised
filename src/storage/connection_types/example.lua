--[[
    EXAMPLE CONNECTION TYPE

    This file serves as a template and documentation for creating custom connection types.
    To create a new connection type, copy this file and modify it according to your needs.

    IMPORTANT: Set loadConnectionType = false to prevent this example from loading.
]]

local ExampleConnection = {}

-- ============================================================================
-- REQUIRED CONFIGURATION
-- ============================================================================

-- Set to true to load this connection type, false to exclude from system
ExampleConnection.loadConnectionType = false

-- Unique identifier for this connection type
ExampleConnection.id = "example"

-- Display name shown in UI
ExampleConnection.name = "Example Connection"

-- Description of what this connection type does
ExampleConnection.description = "An example connection type template"

-- Connection type enum flag - determines default behaviors
-- Available types:
--   - "STORAGE" : Enables storage-related features (withdrawal locations, etc.)
--   - "MONITOR" : Enables monitor-related features (display management, etc.)
--   - "CUSTOM"  : No default behaviors, fully custom implementation
ExampleConnection.connectionType = "CUSTOM"

-- Color used in UI (ComputerCraft colors)
ExampleConnection.color = colors.blue

-- Icon or symbol shown in UI (single character or short string)
ExampleConnection.icon = "?"

-- ============================================================================
-- LIFECYCLE METHODS
-- ============================================================================

-- Called when connection type is loaded/registered
-- @param context - Application context with services, logger, etc.
function ExampleConnection:onLoad(context)
    self.context = context
    self.logger = context.logger

    self.logger:info("ExampleConnection", "Connection type loaded")
end

-- Called when a connection of this type is established
-- @param connection - The connection object
function ExampleConnection:onConnect(connection)
    self.logger:info("ExampleConnection", "Connected to #" .. connection.id)

    -- Initialize connection-specific data
    connection.customData = {
        initialized = os.epoch("utc"),
        status = "ready"
    }
end

-- Called when a connection of this type is disconnected
-- @param connection - The connection object
function ExampleConnection:onDisconnect(connection)
    self.logger:info("ExampleConnection", "Disconnected from #" .. connection.id)
end

-- Called periodically to update connection state (every 5 seconds with ping)
-- @param connection - The connection object
function ExampleConnection:onUpdate(connection)
    -- Update connection state, check health, etc.
end

-- ============================================================================
-- PROTOCOL METHODS
-- ============================================================================

-- Handle incoming messages for this connection type
-- @param connection - The connection object
-- @param message - The received message (table)
-- @return boolean - true if message was handled, false otherwise
function ExampleConnection:handleMessage(connection, message)
    if message.type == "example_request" then
        -- Handle custom message type
        self:sendResponse(connection, {
            type = "example_response",
            data = "Response data"
        })
        return true
    end

    return false -- Message not handled
end

-- Send a message to the connection
-- @param connection - The connection object
-- @param message - The message to send (table)
function ExampleConnection:sendMessage(connection, message)
    rednet.send(connection.id, message, "storage_pair")
end

-- Send a response to the connection
-- @param connection - The connection object
-- @param response - The response to send (table)
function ExampleConnection:sendResponse(connection, response)
    self:sendMessage(connection, response)
end

-- ============================================================================
-- UI METHODS (Optional)
-- ============================================================================

-- Draw custom UI section in connection details view
-- @param connection - The connection object
-- @param x - Starting X position
-- @param y - Starting Y position
-- @param width - Available width
-- @param height - Available height
-- @return number - Y position after drawing (for next section)
function ExampleConnection:drawDetails(connection, x, y, width, height)
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("== EXAMPLE DATA ==")
    y = y + 2

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Custom Field:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.white)
    term.write("Custom Value")
    y = y + 1

    return y
end

-- Get actions available for this connection (shown as buttons in UI)
-- @param connection - The connection object
-- @return table - Array of action definitions
function ExampleConnection:getActions(connection)
    return {
        {
            label = "TEST ACTION",
            color = colors.green,
            handler = function()
                self:performTestAction(connection)
            end
        },
        {
            label = "ANOTHER ACTION",
            color = colors.blue,
            handler = function()
                self:performAnotherAction(connection)
            end
        }
    }
end

-- ============================================================================
-- STORAGE-SPECIFIC METHODS (Only for connectionType = "STORAGE")
-- ============================================================================

-- Check if this connection can be used as a storage location
-- @param connection - The connection object
-- @return boolean - true if can be used for storage
function ExampleConnection:canUseAsStorage(connection)
    return self.connectionType == "STORAGE" and connection.presence.online
end

-- Get inventory information from this storage connection
-- @param connection - The connection object
-- @return table - Inventory data {slots, items, capacity, etc.}
function ExampleConnection:getInventory(connection)
    if self.connectionType ~= "STORAGE" then
        return nil
    end

    -- Request inventory from remote connection
    self:sendMessage(connection, {
        type = "get_inventory"
    })

    -- Wait for response (implement proper async handling in real code)
    -- This is just an example
    return {
        slots = 27,
        usedSlots = 10,
        items = {}
    }
end

-- Request item withdrawal from this storage connection
-- @param connection - The connection object
-- @param itemName - Name of item to withdraw
-- @param quantity - Amount to withdraw
-- @return boolean - true if request sent successfully
function ExampleConnection:requestWithdrawal(connection, itemName, quantity)
    if self.connectionType ~= "STORAGE" then
        return false
    end

    self:sendMessage(connection, {
        type = "withdraw_item",
        item = itemName,
        quantity = quantity
    })

    return true
end

-- ============================================================================
-- MONITOR-SPECIFIC METHODS (Only for connectionType = "MONITOR")
-- ============================================================================

-- Get monitor capabilities
-- @param connection - The connection object
-- @return table - Monitor info {width, height, isColor, scale, etc.}
function ExampleConnection:getMonitorInfo(connection)
    if self.connectionType ~= "MONITOR" then
        return nil
    end

    return {
        width = 50,
        height = 19,
        isColor = true,
        scale = 1
    }
end

-- Send display data to monitor
-- @param connection - The connection object
-- @param displayData - Data to display
function ExampleConnection:updateDisplay(connection, displayData)
    if self.connectionType ~= "MONITOR" then
        return
    end

    self:sendMessage(connection, {
        type = "update_display",
        data = displayData
    })
end

-- ============================================================================
-- CUSTOM METHODS (Your specific implementation)
-- ============================================================================

-- Add your custom methods here
function ExampleConnection:performTestAction(connection)
    self.logger:info("ExampleConnection", "Performing test action on #" .. connection.id)
end

function ExampleConnection:performAnotherAction(connection)
    self.logger:info("ExampleConnection", "Performing another action on #" .. connection.id)
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

-- Validate connection data before saving
-- @param connection - The connection object
-- @return boolean, string - success status and error message if failed
function ExampleConnection:validate(connection)
    if not connection.id then
        return false, "Missing connection ID"
    end

    if not connection.name then
        return false, "Missing connection name"
    end

    return true, nil
end

-- ============================================================================
-- EXPORT
-- ============================================================================

return ExampleConnection
