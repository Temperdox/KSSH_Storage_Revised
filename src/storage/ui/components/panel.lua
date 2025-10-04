-- Panel/Container component
local Component = require("ui.framework.component")

local Panel = setmetatable({}, {__index = Component})
Panel.__index = Panel

function Panel:new(x, y, width, height)
    local o = Component.new(self, "panel")

    o.x = x or 1
    o.y = y or 1
    o.width = width or 20
    o.height = height or 10
    o.layout = nil -- Layout manager

    return o
end

function Panel:setLayout(layout)
    self.layout = layout
    return self
end

function Panel:render()
    if not self.visible then return end

    -- Apply layout if set
    if self.layout then
        self.layout:apply(self)
    end

    -- Call parent render
    Component.render(self)
end

return Panel
