-- modules/api.lua
-- Rednet API for remote control

local API = {}
API.__index = API

function API:new(logger, eventBus, port)
    local self = setmetatable({}, API)
    self.logger = logger
    self.eventBus = eventBus
    self.port = port or 9001
    self.running = true
    self.modem = nil
    self.handlers = {}

    -- Find and open modem
    self:initModem()

    -- Register API handlers
    self:registerHandlers()

    return self
end

function API:initModem()
    -- Find wireless modem
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        if pType == "modem" then
            local modem = peripheral.wrap(name)
            if modem.isWireless and modem.isWireless() then
                self.modem = modem
                self.modem.open(self.port)
                rednet.open(name)
                rednet.host("storage", "main")
                self.logger:success("Rednet API opened on port " .. self.port, "API")
                break
            end
        end
    end

    if not self.modem then
        self.logger:warning("No wireless modem found, API disabled", "API")
    end
end

function API:registerHandlers()
    -- System info
    self.handlers["info"] = function(sender, data)
        return {
            version = "2.0.0",
            uptime = os.clock(),
            processes = _G.processManager:getAllStatus()
        }
    end

    -- Storage data
    self.handlers["items"] = function(sender, data)
        local items = {}
        -- Get items from storage manager via event
        local received, result = self.eventBus:waitFor("api:items_response", 2)
        if received then
            items = result[1]
        end
        return {items = items}
    end

    -- Order item
    self.handlers["order"] = function(sender, data)
        if not data.item or not data.amount then
            return {error = "Missing item or amount"}
        end

        self.eventBus:emit("storage:order", data.item, data.amount)
        return {success = true, message = "Order queued"}
    end

    -- Control commands
    self.handlers["reload"] = function(sender, data)
        self.eventBus:emit("storage:reload")
        return {success = true, message = "Reload initiated"}
    end

    self.handlers["sort"] = function(sender, data)
        local consolidate = data.consolidate
        if consolidate == nil then consolidate = true end
        self.eventBus:emit("storage:sort", consolidate)
        return {success = true, message = "Sort initiated"}
    end

    self.handlers["reformat"] = function(sender, data)
        self.eventBus:emit("storage:reformat")
        return {success = true, message = "Reformat initiated"}
    end

    -- Process control
    self.handlers["restart"] = function(sender, data)
        if not data.process then
            return {error = "Missing process name"}
        end

        local ok, err = _G.processManager:restart(data.process)
        if ok then
            return {success = true, message = "Process restarted"}
        else
            return {error = err}
        end
    end

    -- Configuration
    self.handlers["config_get"] = function(sender, data)
        if not data.path then
            return {error = "Missing config path"}
        end

        local value = _G.config:get(data.path)
        return {value = value}
    end

    self.handlers["config_set"] = function(sender, data)
        if not data.path or data.value == nil then
            return {error = "Missing path or value"}
        end

        _G.config:set(data.path, data.value)
        return {success = true, message = "Config updated"}
    end

    -- Custom command execution
    self.handlers["command"] = function(sender, data)
        if not data.cmd then
            return {error = "Missing command"}
        end

        -- Emit command event for terminal to handle
        self.eventBus:emit("api:command", data.cmd, data.args or {})
        return {success = true, message = "Command executed"}
    end
end

function API:handleRequest(sender, message)
    -- Parse message
    local request = nil
    if type(message) == "string" then
        local ok, parsed = pcall(textutils.unserialise, message)
        if ok then
            request = parsed
        else
            -- Try JSON
            ok, parsed = pcall(textutils.unserializeJSON, message)
            if ok then
                request = parsed
            end
        end
    elseif type(message) == "table" then
        request = message
    end

    if not request or not request.action then
        return {error = "Invalid request format"}
    end

    -- Find handler
    local handler = self.handlers[request.action]
    if not handler then
        return {error = "Unknown action: " .. request.action}
    end

    -- Execute handler
    local ok, result = pcall(handler, sender, request.data or {})
    if ok then
        return result
    else
        return {error = "Handler error: " .. tostring(result)}
    end
end

function API:broadcast(event, data)
    if not self.modem then return end

    local message = {
        event = event,
        data = data,
        timestamp = os.epoch("utc")
    }

    rednet.broadcast(textutils.serialise(message), "storage_event")
end

function API:run()
    if not self.modem then
        self.logger:warning("API cannot run without modem", "API")
        while self.running do
            sleep(1)
        end
        return
    end

    self.logger:info("API server listening on port " .. self.port, "API")

    -- Subscribe to storage events for broadcasting
    self.eventBus:on("storage:data_updated", function(data)
        self:broadcast("data_updated", data)
    end)

    while self.running do
        local sender, message, protocol = rednet.receive(1)

        if sender and message then
            self.logger:debug(string.format("API request from %d: %s", sender, tostring(message)), "API")

            -- Handle request
            local response = self:handleRequest(sender, message)

            -- Send response
            rednet.send(sender, textutils.serialise(response), "storage_response")

            self.logger:debug(string.format("API response to %d sent", sender), "API")
        end

        -- Check for stop event
        local event = os.pullEvent(0)
        if event == "process:stop:api" then
            self.running = false
        end
    end

    self.logger:info("API server stopped", "API")
end

function API:stop()
    self.running = false
    if self.modem then
        rednet.unhost("storage")
        self.modem.close(self.port)
    end
end

return API