-- Button component
local Component = require("ui.framework.component")

local Button = setmetatable({}, {__index = Component})
Button.__index = Button

function Button:new(text, x, y)
    local o = Component.new(self, "button")

    o.text = text or "Button"
    o.x = x or 1
    o.y = y or 1
    o.width = #o.text + 4 -- Padding
    o.height = 1

    -- Button-specific styles
    o.styles.bg = colors.gray
    o.styles.fg = colors.white
    o.styles.hoverBg = colors.lightGray
    o.styles.clickBg = colors.white
    o.styles.clickFg = colors.black

    return o
end

function Button:setText(text)
    self.text = text
    self.width = #text + 4
    return self
end

function Button:getText()
    return self.text
end

function Button:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    term.setBackgroundColor(self:getCurrentBg())
    term.setTextColor(self:getCurrentFg())

    term.setCursorPos(absX, absY)
    term.write(string.rep(" ", self.width))

    local textX = absX + math.floor((self.width - #self.text) / 2)
    term.setCursorPos(textX, absY)
    term.write(self.text)

    -- Reset clicked state after render
    self.clicked = false
end

return Button
