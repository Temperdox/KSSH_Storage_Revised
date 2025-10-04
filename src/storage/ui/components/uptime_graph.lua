-- Uptime Graph component - ASCII art bar graph with hover support
local Component = require("ui.framework.component")

local UptimeGraph = setmetatable({}, {__index = Component})
UptimeGraph.__index = UptimeGraph

function UptimeGraph:new(x, y, width, height)
    local o = Component.new(self, "uptimegraph")

    o.x = x or 1
    o.y = y or 1
    o.width = width or 50
    o.height = height or 8
    o.data = {}
    o.hoveredIndex = nil

    return o
end

function UptimeGraph:setData(data)
    self.data = data
    return self
end

function UptimeGraph:getHoveredValue()
    if self.hoveredIndex and self.data[self.hoveredIndex] then
        return self.data[self.hoveredIndex]
    end
    return nil
end

function UptimeGraph:handleMouseMove(x, y)
    if not self.enabled or not self.visible then return false end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Graph area starts at offset (5, 0) with dimensions (width-10, height-2)
    local graphX = absX + 5
    local graphY = absY
    local graphWidth = self.width - 10
    local graphHeight = self.height - 2

    if x >= graphX and x < graphX + graphWidth and y >= graphY and y < graphY + graphHeight then
        -- Calculate which data point is being hovered
        local columnIndex = x - graphX + 1
        local dataPoints = math.min(#self.data, graphWidth)
        local startIdx = math.max(1, #self.data - dataPoints + 1)
        local hoveredIdx = startIdx + columnIndex - 1

        if hoveredIdx ~= self.hoveredIndex and hoveredIdx <= #self.data then
            self.hoveredIndex = hoveredIdx
            return true
        end
    else
        -- Mouse left graph area
        if self.hoveredIndex then
            self.hoveredIndex = nil
            return true
        end
    end

    return Component.handleMouseMove(self, x, y)
end

function UptimeGraph:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    local graphWidth = self.width - 10
    local graphHeight = self.height - 2

    -- Draw graph border
    for row = 0, graphHeight do
        term.setCursorPos(absX, absY + row)
        if row == 0 then
            term.setTextColor(colors.gray)
            term.setBackgroundColor(colors.black)
            term.write("100%|")
        elseif row == graphHeight then
            term.setTextColor(colors.gray)
            term.setBackgroundColor(colors.black)
            term.write("  0%|")
            term.write(string.rep("-", graphWidth))
        else
            term.setTextColor(colors.gray)
            term.setBackgroundColor(colors.black)
            term.write("    |")
        end
    end

    -- Plot uptime data - always draw full width
    local dataPoints = #self.data
    local startIdx = math.max(1, dataPoints - graphWidth + 1)

    -- Draw columns from left to right (oldest to newest)
    for i = 0, graphWidth - 1 do
        local dataIdx = startIdx + i
        local uptime = 0

        -- Only use data if we have it, otherwise default to 0
        if dataIdx >= 1 and dataIdx <= dataPoints then
            uptime = self.data[dataIdx] or 0
        end

        local downtime = 100 - uptime

        -- Calculate bar heights
        local uptimeBarHeight = math.floor(uptime * graphHeight / 100)
        local downtimeBarHeight = math.floor(downtime * graphHeight / 100)

        -- Draw from bottom up: uptime (green) from bottom
        for h = 0, uptimeBarHeight - 1 do
            term.setCursorPos(absX + 5 + i, absY + graphHeight - h - 1)
            term.setTextColor(colors.green)
            term.setBackgroundColor(colors.black)
            term.write("#")
        end

        -- Draw downtime (red) stacked on top
        for h = 0, downtimeBarHeight - 1 do
            term.setCursorPos(absX + 5 + i, absY + graphHeight - uptimeBarHeight - h - 1)
            term.setTextColor(colors.red)
            term.setBackgroundColor(colors.black)
            term.write("#")
        end
    end

    -- Time labels
    term.setCursorPos(absX + 5, absY + graphHeight + 1)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write("24h ago" .. string.rep(" ", graphWidth - 13) .. "Now")
end

return UptimeGraph
