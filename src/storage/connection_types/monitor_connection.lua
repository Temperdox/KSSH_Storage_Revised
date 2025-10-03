local MonitorConnection = {}

-- Configuration
MonitorConnection.loadConnectionType = true
MonitorConnection.id = "monitor"
MonitorConnection.name = "Monitor Connection"
MonitorConnection.description = "Remote monitor connection for display management"
MonitorConnection.connectionType = "MONITOR"
MonitorConnection.color = colors.lightBlue
MonitorConnection.icon = "M"

-- Lifecycle methods
function MonitorConnection:onLoad(context)
    self.context = context
    self.logger = context.logger
    self.logger:info("MonitorConnection", "Monitor connection type loaded")
end

function MonitorConnection:onConnect(connection)
    self.logger:info("MonitorConnection", "Monitor connected: #" .. connection.id)

    -- Initialize monitor-specific data
    connection.monitorData = {
        width = 0,
        height = 0,
        isColor = false,
        scale = 1,
        lastUpdate = nil,
        displayMode = "idle"
    }

    -- Request monitor info
    self:requestMonitorInfo(connection)
end

function MonitorConnection:onDisconnect(connection)
    self.logger:info("MonitorConnection", "Monitor disconnected: #" .. connection.id)
end

function MonitorConnection:onUpdate(connection)
    -- Update monitor display if needed
    if connection.monitorData.displayMode ~= "idle" then
        self:updateDisplay(connection)
    end
end

-- Protocol methods
function MonitorConnection:handleMessage(connection, message)
    if message.type == "monitor_info" then
        connection.monitorData.width = message.width or 0
        connection.monitorData.height = message.height or 0
        connection.monitorData.isColor = message.isColor or false
        connection.monitorData.scale = message.scale or 1

        self.logger:info("MonitorConnection", "Monitor info received from #" .. connection.id)
        return true

    elseif message.type == "display_updated" then
        connection.monitorData.lastUpdate = os.epoch("utc")
        self.logger:info("MonitorConnection", "Display updated on #" .. connection.id)
        return true

    elseif message.type == "display_error" then
        self.logger:warn("MonitorConnection", "Display error on #" .. connection.id .. ": " .. (message.error or "unknown"))
        return true
    end

    return false
end

function MonitorConnection:sendMessage(connection, message)
    rednet.send(connection.id, message, "storage_pair")
end

-- Monitor-specific methods
function MonitorConnection:requestMonitorInfo(connection)
    if not (connection.presence and connection.presence.online) then
        return
    end

    self:sendMessage(connection, {
        type = "request_monitor_info"
    })

    self.logger:info("MonitorConnection", "Requested monitor info from #" .. connection.id)
end

function MonitorConnection:getMonitorInfo(connection)
    return connection.monitorData
end

function MonitorConnection:updateDisplay(connection, displayData)
    if not (connection.presence and connection.presence.online) then
        return
    end

    self:sendMessage(connection, {
        type = "update_display",
        data = displayData or {
            mode = connection.monitorData.displayMode,
            content = {}
        }
    })

    self.logger:info("MonitorConnection", "Display update sent to #" .. connection.id)
end

function MonitorConnection:setDisplayMode(connection, mode)
    connection.monitorData.displayMode = mode
    self:updateDisplay(connection)
end

function MonitorConnection:clearDisplay(connection)
    self:sendMessage(connection, {
        type = "clear_display"
    })

    self.logger:info("MonitorConnection", "Clear display sent to #" .. connection.id)
end

-- UI methods
function MonitorConnection:drawDetails(connection, x, y, width, height)
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("== MONITOR INFO ==")
    y = y + 2

    local monitorData = connection.monitorData or {}

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Resolution:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.white)
    term.write(string.format("%dx%d", monitorData.width or 0, monitorData.height or 0))
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Color Support:")
    term.setCursorPos(x + 20, y)
    if monitorData.isColor then
        term.setTextColor(colors.lime)
        term.write("Yes")
    else
        term.setTextColor(colors.red)
        term.write("No")
    end
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Scale:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.cyan)
    term.write(tostring(monitorData.scale or 1))
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Display Mode:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.yellow)
    term.write(monitorData.displayMode or "idle")
    y = y + 1

    term.setCursorPos(x, y)
    term.setTextColor(colors.lightGray)
    term.write("Last Update:")
    term.setCursorPos(x + 20, y)
    term.setTextColor(colors.orange)
    if monitorData.lastUpdate then
        local elapsed = (os.epoch("utc") - monitorData.lastUpdate) / 1000
        term.write(string.format("%ds ago", math.floor(elapsed)))
    else
        term.write("Never")
    end
    y = y + 1

    return y
end

function MonitorConnection:getActions(connection)
    return {
        {
            label = "REFRESH",
            color = colors.green,
            handler = function()
                self:requestMonitorInfo(connection)
            end
        },
        {
            label = "CLEAR",
            color = colors.red,
            handler = function()
                self:clearDisplay(connection)
            end
        }
    }
end

function MonitorConnection:validate(connection)
    if not connection.id then
        return false, "Missing connection ID"
    end

    if not connection.name then
        return false, "Missing connection name"
    end

    return true, nil
end

return MonitorConnection
