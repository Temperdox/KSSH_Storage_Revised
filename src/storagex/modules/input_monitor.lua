-- modules/input_monitor.lua
-- Dedicated input chest monitoring module

local InputMonitor = {}
InputMonitor.__index = InputMonitor

function InputMonitor:new(logger, eventBus, inputChest)
    local self = setmetatable({}, InputMonitor)
    self.logger = logger
    self.eventBus = eventBus
    self.inputChest = inputChest
    self.running = true
    self.lastState = {}
    self.checkInterval = 0.5 -- Check twice per second

    return self
end

function InputMonitor:getInputState()
    if not self.inputChest then
        return {}
    end

    local state = {}
    for slot = 1, self.inputChest.size() do
        local item = self.inputChest.getItemDetail(slot)
        if item then
            state[slot] = {
                name = item.name,
                count = item.count,
                displayName = item.displayName
            }
        end
    end
    return state
end

function InputMonitor:hasStateChanged(oldState, newState)
    -- Check if any items were added
    for slot, item in pairs(newState) do
        if not oldState[slot] then
            return true -- New item in slot
        elseif oldState[slot].count ~= item.count then
            return true -- Count changed
        end
    end

    -- Check if any items were removed
    for slot, _ in pairs(oldState) do
        if not newState[slot] then
            return true -- Item removed
        end
    end

    return false
end

function InputMonitor:countItems(state)
    local count = 0
    for _, item in pairs(state) do
        count = count + item.count
    end
    return count
end

function InputMonitor:run()
    if not self.inputChest then
        self.logger:warning("No input chest to monitor", "InputMonitor")
        while self.running do
            sleep(5)
        end
        return
    end

    self.logger:info("Input monitor started", "InputMonitor")

    -- Get initial state
    self.lastState = self:getInputState()
    local lastCount = self:countItems(self.lastState)

    while self.running do
        -- Get current state
        local currentState = self:getInputState()
        local currentCount = self:countItems(currentState)

        -- Check for changes
        if self:hasStateChanged(self.lastState, currentState) then
            if currentCount > lastCount then
                -- Items added
                self.logger:info(string.format("Items detected in input chest: %d items", currentCount), "InputMonitor")
                self.eventBus:emit("input:items_detected", currentCount)

                -- Play sound for feedback
                if _G.sound then
                    _G.sound:play("minecraft:block.note_block.chime", 1)
                end
            elseif currentCount < lastCount then
                -- Items removed
                self.logger:debug(string.format("Items removed from input chest: %d remaining", currentCount), "InputMonitor")
                self.eventBus:emit("input:items_removed", currentCount)
            end

            self.lastState = currentState
            lastCount = currentCount
        elseif currentCount > 0 then
            -- Items present but no change - periodic reminder
            self.eventBus:emit("input:items_present", currentCount)
        end

        sleep(self.checkInterval)
    end

    self.logger:info("Input monitor stopped", "InputMonitor")
end

function InputMonitor:stop()
    self.running = false
end

return InputMonitor