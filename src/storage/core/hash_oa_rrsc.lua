local HashOA_RRSC = {}
HashOA_RRSC.__index = HashOA_RRSC

function HashOA_RRSC:new(eventBus)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.buckets = {}
    o.size = 0
    o.capacity = 256
    o.loadFactor = 0.75
    o.probeIndex = 0

    -- Initialize buckets
    for i = 1, o.capacity do
        o.buckets[i] = nil
    end

    return o
end

function HashOA_RRSC:hash(key)
    -- Simple hash function
    local hash = 0
    for i = 1, #key do
        hash = (hash * 31 + string.byte(key, i)) % self.capacity
    end
    return hash + 1
end

function HashOA_RRSC:put(key, value)
    if self.size >= self.capacity * self.loadFactor then
        self:resize()
    end

    local index = self:hash(key)
    local originalIndex = index

    -- Round-robin probing
    local probes = 0
    while self.buckets[index] ~= nil and probes < self.capacity do
        if self.buckets[index].key == key then
            -- Update existing
            local oldValue = self.buckets[index].value
            self.buckets[index].value = value

            if self.eventBus then
                self.eventBus:publish("index.update", {
                    key = key,
                    oldValue = oldValue,
                    newValue = value
                })
            end
            return
        end

        -- Round-robin probe
        self.probeIndex = (self.probeIndex + 1) % self.capacity
        index = ((originalIndex - 1 + self.probeIndex) % self.capacity) + 1
        probes = probes + 1

        -- Separate chaining fallback
        if probes >= self.capacity then
            if not self.buckets[originalIndex].chain then
                self.buckets[originalIndex].chain = {}
            end
            self.buckets[originalIndex].chain[key] = value
            self.size = self.size + 1

            if self.eventBus then
                self.eventBus:publish("storage.itemIndexed", {
                    key = key,
                    value = value,
                    method = "chain"
                })
            end
            return
        end
    end

    -- Insert new
    self.buckets[index] = {
        key = key,
        value = value
    }
    self.size = self.size + 1

    if self.eventBus then
        self.eventBus:publish("storage.itemIndexed", {
            key = key,
            value = value,
            method = "direct"
        })
    end
end

function HashOA_RRSC:get(key)
    local index = self:hash(key)
    local originalIndex = index
    local probes = 0

    while self.buckets[index] ~= nil and probes < self.capacity do
        if self.buckets[index].key == key then
            return self.buckets[index].value
        end

        -- Check chain
        if self.buckets[index].chain and self.buckets[index].chain[key] then
            return self.buckets[index].chain[key]
        end

        index = ((index - 1 + 1) % self.capacity) + 1
        probes = probes + 1

        if index == originalIndex then
            break
        end
    end

    return nil
end

function HashOA_RRSC:remove(key)
    local index = self:hash(key)
    local originalIndex = index
    local probes = 0

    while self.buckets[index] ~= nil and probes < self.capacity do
        if self.buckets[index].key == key then
            self.buckets[index] = nil
            self.size = self.size - 1
            return true
        end

        -- Check chain
        if self.buckets[index].chain and self.buckets[index].chain[key] then
            self.buckets[index].chain[key] = nil
            self.size = self.size - 1
            return true
        end

        index = ((index - 1 + 1) % self.capacity) + 1
        probes = probes + 1

        if index == originalIndex then
            break
        end
    end

    return false
end

function HashOA_RRSC:resize()
    local oldBuckets = self.buckets
    local oldCapacity = self.capacity
    self.capacity = self.capacity * 2
    self.buckets = {}
    self.size = 0

    for i = 1, self.capacity do
        self.buckets[i] = nil
    end

    -- Use numeric for loop instead of ipairs to iterate all bucket indices
    for i = 1, oldCapacity do
        local bucket = oldBuckets[i]
        if bucket then
            self:put(bucket.key, bucket.value)
            if bucket.chain then
                for k, v in pairs(bucket.chain) do
                    self:put(k, v)
                end
            end
        end
    end
end

function HashOA_RRSC:getAllItems()
    local items = {}
    local bucketCount = 0
    local chainCount = 0

    -- Use numeric for loop instead of ipairs to iterate all bucket indices
    -- ipairs stops at first nil, but hash table has sparse buckets
    for i = 1, self.capacity do
        local bucket = self.buckets[i]
        if bucket then
            bucketCount = bucketCount + 1
            table.insert(items, {key = bucket.key, value = bucket.value})
            if bucket.chain then
                for k, v in pairs(bucket.chain) do
                    chainCount = chainCount + 1
                    table.insert(items, {key = k, value = v})
                end
            end
        end
    end

    -- Debug logging
    if self.eventBus then
        self.eventBus:publish("log.debug", {
            source = "HashOA_RRSC",
            message = string.format(
                "getAllItems: %d items (%d buckets, %d chains), size=%d",
                #items, bucketCount, chainCount, self.size
            )
        })
    end

    return items
end

function HashOA_RRSC:getSize()
    return self.size
end

function HashOA_RRSC:clear()
    self.buckets = {}
    self.size = 0
    for i = 1, self.capacity do
        self.buckets[i] = nil
    end
end

function HashOA_RRSC:save(path)
    local items = self:getAllItems()

    -- Ensure items is treated as array, not object
    if #items == 0 then
        items = textutils.empty_json_array or {}
    end

    local data = {
        size = self.size,
        capacity = self.capacity,
        items = items
    }

    local file = fs.open(path, "w")
    if file then
        local json = textutils.serialiseJSON(data)
        -- Fix empty array serialization
        json = json:gsub('"items":%s*{}', '"items":[]')
        file.write(json)
        file.close()

        if self.eventBus then
            self.eventBus:publish("log.info", {
                source = "HashOA_RRSC",
                message = string.format("Saved %d items to %s", #items, path)
            })
        end

        return true
    end
    return false
end

function HashOA_RRSC:load(path)
    if not fs.exists(path) then
        if self.eventBus then
            self.eventBus:publish("log.info", {
                source = "HashOA_RRSC",
                message = "No index file found, starting fresh"
            })
        end
        return false
    end

    local file = fs.open(path, "r")
    if not file then
        return false
    end

    local content = file.readAll()
    file.close()

    -- Fix malformed JSON where items is {} instead of []
    content = content:gsub('"items":%s*{}', '"items":[]')

    local ok, data = pcall(textutils.unserialiseJSON, content)
    if not ok or not data then
        if self.eventBus then
            self.eventBus:publish("log.error", {
                source = "HashOA_RRSC",
                message = "Failed to parse index file: " .. tostring(data)
            })
        end
        return false
    end

    self:clear()
    self.capacity = data.capacity or 256

    local itemCount = 0
    for _, item in ipairs(data.items or {}) do
        self:put(item.key, item.value)
        itemCount = itemCount + 1
    end

    if self.eventBus then
        self.eventBus:publish("log.info", {
            source = "HashOA_RRSC",
            message = string.format("Loaded %d items from %s", itemCount, path)
        })
    end

    return true
end

return HashOA_RRSC