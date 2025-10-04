-- Label component
local Component = require("ui.framework.component")

local Label = setmetatable({}, {__index = Component})
Label.__index = Label

function Label:new(text, x, y)
    local o = Component.new(self, "label")

    o.text = text or ""
    o.x = x or 1
    o.y = y or 1
    o.width = #o.text
    o.height = 1
    o.textAlign = "left" -- left, center, right

    return o
end

function Label:setText(text)
    self.text = text
    self.width = #text
    return self
end

function Label:getText()
    return self.text
end

function Label:setTextAlign(align)
    self.textAlign = align
    return self
end

function Label:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    term.setBackgroundColor(self:getCurrentBg())
    term.setTextColor(self:getCurrentFg())

    local displayText = self.text
    if #displayText > self.width then
        displayText = displayText:sub(1, self.width)
    end

    -- Apply text alignment
    local x = absX
    if self.textAlign == "center" then
        x = absX + math.floor((self.width - #displayText) / 2)
    elseif self.textAlign == "right" then
        x = absX + (self.width - #displayText)
    end

    term.setCursorPos(x, absY)
    term.write(displayText)
end

return Label
