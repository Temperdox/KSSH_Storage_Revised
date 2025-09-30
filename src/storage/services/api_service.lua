local ApiService = {}
ApiService.__index = ApiService

function ApiService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger
    o.scheduler = context.scheduler

    -- Network configuration
    o.protocol = "storage_api"
    o.hostname = "storage_" .. os.getComputerID()
    o.port = 1337

    -- Find wireless modem on bottom
    o.modem = peripheral.find("modem", function(name, p)
        return name == "bottom" and p.isWireless and p.isWireless()
    end)

    if not o.modem then
        o.logger:error("ApiService", "No wireless modem found on bottom!")
    end

    -- Request tracking
    o.activeRequests = {}
    o.requestTimeout = 30
    o.nextRequestId = 1

    -- Rate limiting
    o.rateLimit = {
        maxRequests = 100,
        window = 60,
        requests = {}
    }

    -- Load endpoints
    local Endpoints = require("protocol.endpoints")
    o.endpoints = Endpoints:new(context)

    return o
end

function ApiService:start()
    if not self.modem then
        self.logger:warn("ApiService", "Cannot start - no modem available")
        return
    end

    -- Open rednet
    rednet.open(peripheral.getName(self.modem))

    -- Host protocol
    rednet.host(self.protocol, self.hostname)

    self.logger:info("ApiService", string.format(
            "API service started on protocol '%s' as '%s'",
            self.protocol, self.hostname
    ))

    -- Start request handler
    self.scheduler:submit("net", function()
        self:handleRequests()
    end)

    -- Start timeout checker
    self.scheduler:submit("net", function()
        self:checkTimeouts()
    end)
end

function ApiService:stop()
    if self.modem then
        rednet.unhost(self.protocol)
        rednet.close(peripheral.getName(self.modem))
    end

    self.logger:info("ApiService", "Service stopped")
end

function ApiService:handleRequests()
    while true do
        local senderId, message, protocol = rednet.receive(self.protocol, 1)

        if senderId then
            -- Check rate limit
            if not self:checkRateLimit(senderId) then
                self:sendError(senderId, nil, "RATE_LIMIT", "Too many requests")
            else
                -- Process request
                self.scheduler:submit("api", function()
                    self:processRequest(senderId, message)
                end)
            end
        end
    end
end

function ApiService:processRequest(senderId, message)
    -- Validate message format
    if type(message) ~= "table" or not message.method then
        self:sendError(senderId, nil, "INVALID_REQUEST", "Invalid request format")
        return
    end

    local requestId = message.id or self.nextRequestId
    self.nextRequestId = self.nextRequestId + 1

    -- Track request
    self.activeRequests[requestId] = {
        senderId = senderId,
        method = message.method,
        startTime = os.epoch("utc"),
        timeout = message.timeout or self.requestTimeout
    }

    -- Log request
    self.eventBus:publish("net.rpc.request", {
        senderId = senderId,
        method = message.method,
        params = message.params
    })

    -- Find endpoint using getEndpoint method
    local endpoint = self.endpoints:getEndpoint(message.method)
    if not endpoint then
        self:sendError(senderId, requestId, "METHOD_NOT_FOUND",
                "Unknown method: " .. message.method)
        self.activeRequests[requestId] = nil
        return
    end

    -- Validate parameters
    if endpoint.validate then
        local valid, err = endpoint.validate(message.params)
        if not valid then
            self:sendError(senderId, requestId, "INVALID_PARAMS", err)
            self.activeRequests[requestId] = nil
            return
        end
    end

    -- Execute endpoint
    local ok, result = pcall(endpoint.execute, message.params, {
        senderId = senderId,
        requestId = requestId
    })

    if ok then
        self:sendResponse(senderId, requestId, result)
    else
        self:sendError(senderId, requestId, "INTERNAL_ERROR", tostring(result))
    end

    -- Clean up request
    self.activeRequests[requestId] = nil
end

function ApiService:sendResponse(senderId, requestId, result)
    local response = {
        id = requestId,
        success = true,
        result = result,
        timestamp = os.epoch("utc")
    }

    rednet.send(senderId, response, self.protocol)

    self.eventBus:publish("net.rpc.response", {
        senderId = senderId,
        requestId = requestId,
        success = true
    })
end

function ApiService:sendError(senderId, requestId, code, message)
    local response = {
        id = requestId,
        success = false,
        error = {
            code = code,
            message = message
        },
        timestamp = os.epoch("utc")
    }

    rednet.send(senderId, response, self.protocol)

    self.eventBus:publish("net.rpc.response", {
        senderId = senderId,
        requestId = requestId,
        success = false,
        error = code
    })
end

function ApiService:checkRateLimit(senderId)
    local now = os.epoch("utc") / 1000
    local window = self.rateLimit.window

    -- Clean old requests
    local cutoff = now - window
    local newRequests = {}

    for _, req in ipairs(self.rateLimit.requests) do
        if req.time > cutoff then
            table.insert(newRequests, req)
        end
    end

    self.rateLimit.requests = newRequests

    -- Count requests from this sender
    local count = 0
    for _, req in ipairs(self.rateLimit.requests) do
        if req.senderId == senderId then
            count = count + 1
        end
    end

    -- Check limit
    if count >= self.rateLimit.maxRequests then
        return false
    end

    -- Add new request
    table.insert(self.rateLimit.requests, {
        senderId = senderId,
        time = now
    })

    return true
end

function ApiService:checkTimeouts()
    while true do
        local now = os.epoch("utc") / 1000

        for requestId, request in pairs(self.activeRequests) do
            local elapsed = now - (request.startTime / 1000)

            if elapsed > request.timeout then
                self:sendError(request.senderId, requestId, "TIMEOUT",
                        "Request timed out")
                self.activeRequests[requestId] = nil

                self.logger:warn("ApiService", string.format(
                        "Request %d timed out after %ds",
                        requestId, request.timeout
                ))
            end
        end

        os.sleep(5)
    end
end

function ApiService:broadcast(event, data)
    -- Broadcast event to all listening clients
    local message = {
        type = "event",
        event = event,
        data = data,
        timestamp = os.epoch("utc")
    }

    rednet.broadcast(message, self.protocol)

    self.eventBus:publish("net.broadcast", {
        event = event,
        listeners = "all"
    })
end

return ApiService