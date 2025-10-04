-- Animation system with easing functions
local Animation = {}
Animation.__index = Animation

-- Easing functions
local Easing = {
    linear = function(t) return t end,

    easeInQuad = function(t) return t * t end,
    easeOutQuad = function(t) return t * (2 - t) end,
    easeInOutQuad = function(t)
        if t < 0.5 then
            return 2 * t * t
        else
            return -1 + (4 - 2 * t) * t
        end
    end,

    easeInCubic = function(t) return t * t * t end,
    easeOutCubic = function(t)
        local f = t - 1
        return f * f * f + 1
    end,
    easeInOutCubic = function(t)
        if t < 0.5 then
            return 4 * t * t * t
        else
            local f = 2 * t - 2
            return 0.5 * f * f * f + 1
        end
    end,

    easeInQuart = function(t) return t * t * t * t end,
    easeOutQuart = function(t)
        local f = t - 1
        return 1 - f * f * f * f
    end,

    easeInElastic = function(t)
        if t == 0 or t == 1 then return t end
        local p = 0.3
        local s = p / 4
        local a = 1
        return -(a * math.pow(2, 10 * (t - 1)) * math.sin((t - 1 - s) * (2 * math.pi) / p))
    end,

    easeOutElastic = function(t)
        if t == 0 or t == 1 then return t end
        local p = 0.3
        local s = p / 4
        local a = 1
        return a * math.pow(2, -10 * t) * math.sin((t - s) * (2 * math.pi) / p) + 1
    end,

    easeInBounce = function(t)
        return 1 - Easing.easeOutBounce(1 - t)
    end,

    easeOutBounce = function(t)
        if t < 1 / 2.75 then
            return 7.5625 * t * t
        elseif t < 2 / 2.75 then
            local f = t - 1.5 / 2.75
            return 7.5625 * f * f + 0.75
        elseif t < 2.5 / 2.75 then
            local f = t - 2.25 / 2.75
            return 7.5625 * f * f + 0.9375
        else
            local f = t - 2.625 / 2.75
            return 7.5625 * f * f + 0.984375
        end
    end,

    easeInOutBounce = function(t)
        if t < 0.5 then
            return Easing.easeInBounce(t * 2) * 0.5
        else
            return Easing.easeOutBounce(t * 2 - 1) * 0.5 + 0.5
        end
    end
}

function Animation:new(component, property, startValue, endValue, duration, easingFunc)
    local o = setmetatable({}, self)
    o.component = component
    o.property = property
    o.startValue = startValue
    o.endValue = endValue
    o.duration = duration or 1000 -- milliseconds
    o.easing = easingFunc or "linear"
    o.startTime = nil
    o.running = false
    o.completed = false
    o.onComplete = nil

    return o
end

function Animation:start()
    self.startTime = os.epoch("utc")
    self.running = true
    self.completed = false
    return self
end

function Animation:stop()
    self.running = false
    return self
end

function Animation:update()
    if not self.running or self.completed then
        return false
    end

    local now = os.epoch("utc")
    local elapsed = now - self.startTime

    if elapsed >= self.duration then
        -- Animation complete
        self:setValue(self.endValue)
        self.running = false
        self.completed = true

        if self.onComplete then
            self.onComplete(self.component)
        end

        return true
    end

    -- Calculate progress (0 to 1)
    local progress = elapsed / self.duration

    -- Apply easing
    local easingFunc = Easing[self.easing] or Easing.linear
    local easedProgress = easingFunc(progress)

    -- Interpolate value
    local value = self:interpolate(self.startValue, self.endValue, easedProgress)

    -- Set value
    self:setValue(value)

    return false
end

function Animation:interpolate(start, endVal, progress)
    if type(start) == "number" then
        return start + (endVal - start) * progress
    elseif type(start) == "table" then
        local result = {}
        for k, v in pairs(start) do
            result[k] = self:interpolate(v, endVal[k] or v, progress)
        end
        return result
    else
        return progress < 0.5 and start or endVal
    end
end

function Animation:setValue(value)
    -- Handle nested properties (e.g., "styles.bg")
    local parts = {}
    for part in self.property:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    local obj = self.component
    for i = 1, #parts - 1 do
        obj = obj[parts[i]]
    end

    obj[parts[#parts]] = value
end

function Animation:setOnComplete(callback)
    self.onComplete = callback
    return self
end

-- Animation Manager
local AnimationManager = {}
AnimationManager.__index = AnimationManager

function AnimationManager:new()
    local o = setmetatable({}, self)
    o.animations = {}
    return o
end

function AnimationManager:add(animation)
    table.insert(self.animations, animation)
    return animation
end

function AnimationManager:remove(animation)
    for i, anim in ipairs(self.animations) do
        if anim == animation then
            table.remove(self.animations, i)
            break
        end
    end
end

function AnimationManager:update()
    local i = 1
    while i <= #self.animations do
        local anim = self.animations[i]
        local completed = anim:update()

        if completed then
            table.remove(self.animations, i)
        else
            i = i + 1
        end
    end
end

function AnimationManager:clear()
    self.animations = {}
end

-- Utility function to create animations easily
local function animate(component, property, endValue, duration, easing)
    local startValue = nil

    -- Get start value from component
    local parts = {}
    for part in property:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    local obj = component
    for i = 1, #parts - 1 do
        obj = obj[parts[i]]
    end
    startValue = obj[parts[#parts]]

    local anim = Animation:new(component, property, startValue, endValue, duration, easing)
    return anim
end

return {
    Animation = Animation,
    AnimationManager = AnimationManager,
    Easing = Easing,
    animate = animate
}
