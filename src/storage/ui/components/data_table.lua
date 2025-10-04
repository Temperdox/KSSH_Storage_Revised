-- Data Table component with headers, alternating row colors, and click support
local Component = require("ui.framework.component")

local DataTable = setmetatable({}, {__index = Component})
DataTable.__index = DataTable

function DataTable:new(x, y, width, height)
    local o = Component.new(self, "datatable")

    o.x = x or 1
    o.y = y or 1
    o.width = width or 50
    o.height = height or 10
    o.headers = {}
    o.rows = {}
    o.onRowClick = nil
    o.columnWidths = {}

    return o
end

function DataTable:setHeaders(headers)
    self.headers = headers
    return self
end

function DataTable:setRows(rows)
    self.rows = rows
    return self
end

function DataTable:setColumnWidths(widths)
    self.columnWidths = widths
    return self
end

function DataTable:setOnRowClick(callback)
    self.onRowClick = callback
    return self
end

function DataTable:handleClick(x, y)
    if not self.enabled or not self.visible then return false end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Check if click is on a row (skip header row)
    local rowY = y - absY - 1  -- -1 for header
    if rowY >= 0 and rowY < #self.rows then
        if self.onRowClick then
            self.onRowClick(self, rowY + 1, self.rows[rowY + 1])
        end
        return true
    end

    return Component.handleClick(self, x, y)
end

function DataTable:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Draw header
    term.setCursorPos(absX, absY)
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
    for i = 1, self.width do
        term.write(" ")
    end

    -- Draw header text
    for i, header in ipairs(self.headers) do
        local colX = self.columnWidths[i] or (absX + (i-1) * 15)
        term.setCursorPos(colX, absY)
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
        term.write(header)
    end

    -- Draw rows
    local maxRows = math.min(#self.rows, self.height - 1)
    for i = 1, maxRows do
        local row = self.rows[i]
        local rowY = absY + i

        -- Alternating row colors
        if i % 2 == 0 then
            term.setBackgroundColor(colors.gray)
        else
            term.setBackgroundColor(colors.black)
        end

        term.setCursorPos(absX, rowY)
        for j = 1, self.width do
            term.write(" ")
        end

        -- Draw row data
        for j, cell in ipairs(row) do
            local colX = self.columnWidths[j] or (absX + (j-1) * 15)
            term.setCursorPos(colX, rowY)

            -- Cell can be a table with {text, color} or just text
            if type(cell) == "table" and cell.text then
                if i % 2 == 0 then
                    term.setBackgroundColor(colors.gray)
                else
                    term.setBackgroundColor(colors.black)
                end
                term.setTextColor(cell.color or colors.white)
                term.write(cell.text)
            else
                if i % 2 == 0 then
                    term.setBackgroundColor(colors.gray)
                else
                    term.setBackgroundColor(colors.black)
                end
                term.setTextColor(colors.white)
                term.write(tostring(cell))
            end
        end
    end

    term.setBackgroundColor(colors.black)
end

return DataTable
