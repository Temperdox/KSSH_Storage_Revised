local TimeWheel = {}
TimeWheel.__index = TimeWheel

function TimeWheel:new(eventBus)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.slots = {}
    o.slotCount = 60
    o.currentSlot = 0
    o.running = false

    for i = 1, o.slotCount do
        o.slots[i] = {}
    end

    return o
end

function TimeWheel:schedule(delay, callback)
    local targetSlot = (self.currentSlot + delay) % self.slotCount + 1
    table.insert(self.slots[targetSlot], callback)
end

function TimeWheel:start()
    self.running = true

    local function tick()
        while self.running do
            os.sleep(1)
            self.currentSlot = (self.currentSlot % self.slotCount) + 1

            -- Process current slot
            local callbacks = self.slots[self.currentSlot]
            self.slots[self.currentSlot] = {}

            for _, callback in ipairs(callbacks) do
                pcall(callback)
            end

            -- Emit minute tick
            if self.currentSlot == 1 then
                self.eventBus:publish("stats.minuteTick", {
                    timestamp = os.epoch("utc")
                })
            end
        end
    end

    -- Run in parallel
    parallel.waitForAny(tick)
end

function TimeWheel:stop()
    self.running = false
end

return TimeWheel