-- Rednet communication bridge for turtle
-- Routes messages between computer and turtle services
local print = require("util.log_print")

local Bridge = {}

function Bridge.new()
    local self = {
        handlers = {},  -- action -> function mapping
        executor = nil,
        running = false,
        stats = {
            received = 0,
            sent = 0,
            errors = 0
        }
    }

    setmetatable(self, {__index = Bridge})
    return self
end

function Bridge:init(executor)
    self.executor = executor

    -- Open modems
    local opened = self:openModems()
    print.info("[bridge] Initialized with", opened, "modems")

    -- Set computer ID if known (optional)
    self.computerId = nil  -- Will be set on first message

    return self
end

function Bridge:openModems()
    local count = 0
    for _, side in ipairs({"left","right","top","bottom","front","back"}) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                pcall(rednet.open, side)
                count = count + 1
                print.debug("[bridge] Opened modem on", side)
            end
        end
    end
    return count
end

-- Register a handler for a specific action
function Bridge:register(action, handler)
    self.handlers[action] = handler
    print.debug("[bridge] Registered handler for action:", action)
end

-- Send a message (with optional specific recipient)
function Bridge:send(message, recipient)
    recipient = recipient or self.computerId

    if recipient then
        rednet.send(recipient, message)
        print.debug("[bridge] Sent message to", recipient, "- action:", message.action or "unknown")
    else
        rednet.broadcast(message)
        print.debug("[bridge] Broadcast message - action:", message.action or "unknown")
    end

    self.stats.sent = self.stats.sent + 1
end

-- Main message processing loop
function Bridge:listen()
    print.info("[bridge] Starting rednet listener...")
    self.running = true

    while self.running do
        local sender, message = rednet.receive(1)  -- 1 second timeout

        if sender and message then
            self.stats.received = self.stats.received + 1

            -- Remember the computer ID
            if not self.computerId then
                self.computerId = sender
                print.info("[bridge] Set computer ID to", sender)
            end

            -- Process if it's a table with an action
            if type(message) == "table" and message.action then
                print.info("[bridge] Received", message.action, "from", sender)

                local handler = self.handlers[message.action]
                if handler then
                    -- Submit handler to executor for processing
                    if self.executor then
                        self.executor:submit(function()
                            local ok, err = pcall(handler, sender, message)
                            if not ok then
                                print.error("[bridge] Handler failed for", message.action, ":", err)
                                self.stats.errors = self.stats.errors + 1

                                -- Send error response
                                self:send({
                                    action = message.action .. "_error",
                                    error = err,
                                    originalAction = message.action
                                }, sender)
                            end
                        end, "handle_" .. message.action, 7)
                    else
                        -- Direct execution if no executor
                        local ok, err = pcall(handler, sender, message)
                        if not ok then
                            print.error("[bridge] Handler failed for", message.action, ":", err)
                            self.stats.errors = self.stats.errors + 1
                        end
                    end
                else
                    print.warn("[bridge] No handler for action:", message.action)
                end
            else
                print.debug("[bridge] Received non-action message from", sender)
            end
        end
    end
end

-- Stop the bridge
function Bridge:stop()
    self.running = false
    print.info("[bridge] Stopping...")
end

-- Get statistics
function Bridge:getStats()
    return {
        received = self.stats.received,
        sent = self.stats.sent,
        errors = self.stats.errors,
        handlers = self:getHandlerCount(),
        computerId = self.computerId
    }
end

function Bridge:getHandlerCount()
    local count = 0
    for _ in pairs(self.handlers) do
        count = count + 1
    end
    return count
end

return Bridge