local RPC = {}
RPC.__index = RPC

function RPC:new()
    local o = setmetatable({}, self)
    o.version = "1.0.0"
    o.maxMessageSize = 65536
    return o
end

function RPC:encodeRequest(method, params, id)
    local request = {
        jsonrpc = "2.0",
        method = method,
        params = params or {},
        id = id or os.epoch("utc")
    }

    return self:encode(request)
end

function RPC:encodeResponse(result, id)
    local response = {
        jsonrpc = "2.0",
        result = result,
        id = id
    }

    return self:encode(response)
end

function RPC:encodeError(code, message, id)
    local response = {
        jsonrpc = "2.0",
        error = {
            code = code,
            message = message
        },
        id = id
    }

    return self:encode(response)
end

function RPC:encode(message)
    local json = textutils.serialiseJSON(message)

    -- Check size
    if #json > self.maxMessageSize then
        error("Message too large: " .. #json .. " bytes")
    end

    -- Add framing
    return {
        version = self.version,
        size = #json,
        checksum = self:checksum(json),
        payload = json
    }
end

function RPC:decode(frame)
    -- Validate frame
    if type(frame) ~= "table" then
        return nil, "Invalid frame format"
    end

    if frame.version ~= self.version then
        return nil, "Version mismatch: " .. tostring(frame.version)
    end

    if not frame.payload then
        return nil, "Missing payload"
    end

    -- Verify checksum
    local calculated = self:checksum(frame.payload)
    if calculated ~= frame.checksum then
        return nil, "Checksum mismatch"
    end

    -- Parse JSON
    local ok, message = pcall(textutils.unserialiseJSON, frame.payload)
    if not ok then
        return nil, "JSON parse error: " .. tostring(message)
    end

    return message
end

function RPC:checksum(data)
    -- Simple checksum for data integrity
    local sum = 0
    for i = 1, #data do
        sum = (sum + string.byte(data, i)) % 65536
    end
    return sum
end

function RPC:validateRequest(request)
    if type(request) ~= "table" then
        return false, "Request must be a table"
    end

    if request.jsonrpc ~= "2.0" then
        return false, "Invalid JSON-RPC version"
    end

    if not request.method or type(request.method) ~= "string" then
        return false, "Missing or invalid method"
    end

    return true
end

function RPC:validateResponse(response)
    if type(response) ~= "table" then
        return false, "Response must be a table"
    end

    if response.jsonrpc ~= "2.0" then
        return false, "Invalid JSON-RPC version"
    end

    if not response.result and not response.error then
        return false, "Response must have result or error"
    end

    return true
end

return RPC