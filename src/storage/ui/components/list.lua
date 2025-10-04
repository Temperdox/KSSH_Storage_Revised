-- List component with scrolling
local Component = require("ui.framework.component")

local List = setmetatable({}, {__index = Component})
List.__index = List

function List:new(x, y, width, height)
    local o = Component.new(self, "list")

    o.x = x or 1
    o.y = y or 1
    o.width = width or 20
    o.height = height or 10
    o.items = {}
    o.selectedIndex = nil
    o.scrollOffset = 0
    o.itemHeight = 1
    o.onItemClick = nil

    -- Style
    o.styles.bg = colors.black
    o.styles.fg = colors.white
    o.styles.selectedBg = colors.gray
    o.styles.selectedFg = colors.yellow
    o.styles.hoverBg = colors.lightGray

    return o
end

function List:setItems(items)
    self.items = items
    self.scrollOffset = 0
    self.selectedIndex = nil
    return self
end

function List:addItem(item)
    table.insert(self.items, item)
    return self
end

function List:removeItem(index)
    table.remove(self.items, index)
    if self.selectedIndex == index then
        self.selectedIndex = nil
    end
    return self
end

function List:clear()
    self.items = {}
    self.selectedIndex = nil
    self.scrollOffset = 0
    return self
end

function List:setItemHeight(height)
    self.itemHeight = height
    return self
end

function List:setOnItemClick(callback)
    self.onItemClick = callback
    return self
end

function List:handleClick(x, y)
    if not self.enabled or not self.visible then return false end

    if self:containsPoint(x, y) then
        local absX = self:getAbsoluteX()
        local absY = self:getAbsoluteY()

        local relY = y - absY
        local itemIndex = self.scrollOffset + math.floor(relY / self.itemHeight) + 1

        if itemIndex >= 1 and itemIndex <= #self.items then
            self.selectedIndex = itemIndex

            if self.onItemClick then
                self.onItemClick(self, itemIndex, self.items[itemIndex])
            end

            if self.handlers.onClick then
                self.handlers.onClick(self, x, y)
            end
        end

        return true
    end

    return false
end

function List:handleScroll(direction, x, y)
    if not self.enabled or not self.visible then return false end

    if self:containsPoint(x, y) then
        if direction > 0 then
            self.scrollOffset = math.max(0, self.scrollOffset - 1)
        else
            local maxScroll = math.max(0, #self.items - math.floor(self.height / self.itemHeight))
            self.scrollOffset = math.min(maxScroll, self.scrollOffset + 1)
        end

        if self.handlers.onScroll then
            self.handlers.onScroll(self, direction)
        end

        return true
    end

    return false
end

function List:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Draw background
    term.setBackgroundColor(self:getCurrentBg())
    for dy = 0, self.height - 1 do
        term.setCursorPos(absX, absY + dy)
        term.write(string.rep(" ", self.width))
    end

    -- Draw items
    local visibleItems = math.floor(self.height / self.itemHeight)
    local y = absY

    for i = 1, visibleItems do
        local itemIndex = self.scrollOffset + i

        if itemIndex > #self.items then break end

        local item = self.items[itemIndex]
        local bg = self.styles.bg
        local fg = self.styles.fg

        if itemIndex == self.selectedIndex then
            bg = self.styles.selectedBg
            fg = self.styles.selectedFg
        end

        term.setBackgroundColor(bg)
        term.setTextColor(fg)

        term.setCursorPos(absX, y)

        local text = type(item) == "table" and (item.text or tostring(item)) or tostring(item)
        if #text > self.width then
            text = text:sub(1, self.width - 3) .. "..."
        else
            text = text .. string.rep(" ", self.width - #text)
        end

        term.write(text)

        y = y + self.itemHeight
    end

    -- Draw scrollbar if needed
    if #self.items > visibleItems then
        self:drawScrollbar(absX + self.width - 1, absY, self.height)
    end
end

function List:drawScrollbar(x, y, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)

    -- Draw track
    for dy = 0, height - 1 do
        term.setCursorPos(x, y + dy)
        term.write("|")
    end

    -- Draw thumb
    local visibleItems = math.floor(self.height / self.itemHeight)
    local thumbHeight = math.max(1, math.floor(height * visibleItems / #self.items))
    local thumbPos = math.floor(height * self.scrollOffset / #self.items)

    term.setBackgroundColor(colors.white)
    for dy = 0, thumbHeight - 1 do
        if thumbPos + dy < height then
            term.setCursorPos(x, y + thumbPos + dy)
            term.write("#")
        end
    end
end

return List
