-- Window manager for dialogs, modals, and windowed components
local Component = require("ui.framework.component")

local Window = setmetatable({}, {__index = Component})
Window.__index = Window

function Window:new(title, width, height)
    local o = Component.new(self, "window")

    o.title = title or "Window"
    o.width = width or 40
    o.height = height or 15
    o.draggable = true
    o.resizable = false
    o.modal = false
    o.closeButton = true

    -- Window state
    o.dragging = false
    o.dragOffsetX = 0
    o.dragOffsetY = 0

    -- Content area
    o.contentX = 1
    o.contentY = 2 -- Below title bar
    o.contentWidth = o.width
    o.contentHeight = o.height - 1

    -- Callbacks
    o.onClose = nil

    return o
end

function Window:setTitle(title)
    self.title = title
    return self
end

function Window:setModal(modal)
    self.modal = modal
    return self
end

function Window:setDraggable(draggable)
    self.draggable = draggable
    return self
end

function Window:setResizable(resizable)
    self.resizable = resizable
    return self
end

function Window:setCloseButton(enabled)
    self.closeButton = enabled
    return self
end

function Window:onClose(callback)
    self.onClose = callback
    return self
end

function Window:center(screenWidth, screenHeight)
    self.x = math.floor((screenWidth - self.width) / 2)
    self.y = math.floor((screenHeight - self.height) / 2)
    return self
end

function Window:handleClick(x, y)
    if not self.enabled or not self.visible then return false end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Check close button
    if self.closeButton then
        local closeX = absX + self.width - 3
        local closeY = absY

        if x >= closeX and x <= closeX + 2 and y == closeY then
            self:close()
            return true
        end
    end

    -- Check if clicking title bar (for dragging)
    if self.draggable and y == absY and x >= absX and x < absX + self.width then
        self.dragging = true
        self.dragOffsetX = x - absX
        self.dragOffsetY = y - absY
        return true
    end

    -- Check children
    for i = #self.children, 1, -1 do
        if self.children[i]:handleClick(x, y) then
            return true
        end
    end

    -- Click inside window
    if self:containsPoint(x, y) then
        return true
    end

    return false
end

function Window:handleMouseMove(x, y)
    if self.dragging then
        self.x = x - self.dragOffsetX - (self.parent and self.parent:getAbsoluteX() or 0)
        self.y = y - self.dragOffsetY - (self.parent and self.parent:getAbsoluteY() or 0)
        return true
    end

    return Component.handleMouseMove(self, x, y)
end

function Window:handleMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        return true
    end

    return false
end

function Window:close()
    if self.onClose then
        self.onClose(self)
    end

    self:hide()

    if self.parent then
        self.parent:remove(self)
    end
end

function Window:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Draw shadow (if not modal)
    if not self.modal then
        term.setBackgroundColor(colors.gray)
        for dy = 1, self.height do
            term.setCursorPos(absX + 1, absY + dy)
            term.write(string.rep(" ", self.width))
        end
    end

    -- Draw window background
    term.setBackgroundColor(self:getCurrentBg())
    for dy = 0, self.height - 1 do
        term.setCursorPos(absX, absY + dy)
        term.write(string.rep(" ", self.width))
    end

    -- Draw title bar
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(absX, absY)
    local titleText = " " .. self.title
    if #titleText > self.width - 4 then
        titleText = titleText:sub(1, self.width - 7) .. "..."
    end
    term.write(titleText .. string.rep(" ", self.width - #titleText))

    -- Draw close button
    if self.closeButton then
        term.setCursorPos(absX + self.width - 3, absY)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" X ")
    end

    -- Draw border
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    -- Left and right borders
    for dy = 1, self.height - 1 do
        term.setCursorPos(absX, absY + dy)
        term.write("|")
        term.setCursorPos(absX + self.width - 1, absY + dy)
        term.write("|")
    end

    -- Bottom border
    term.setCursorPos(absX, absY + self.height - 1)
    term.write("+" .. string.rep("-", self.width - 2) .. "+")

    -- Render children in content area
    for _, child in ipairs(self.children) do
        child:render()
    end
end

-- Window Manager
local WindowManager = {}
WindowManager.__index = WindowManager

function WindowManager:new()
    local o = setmetatable({}, self)
    o.windows = {}
    o.modalStack = {}
    return o
end

function WindowManager:add(window)
    table.insert(self.windows, window)

    if window.modal then
        table.insert(self.modalStack, window)
    end

    return window
end

function WindowManager:remove(window)
    for i, w in ipairs(self.windows) do
        if w == window then
            table.remove(self.windows, i)
            break
        end
    end

    if window.modal then
        for i, w in ipairs(self.modalStack) do
            if w == window then
                table.remove(self.modalStack, i)
                break
            end
        end
    end
end

function WindowManager:handleClick(x, y)
    -- Handle topmost modal first
    if #self.modalStack > 0 then
        local modal = self.modalStack[#self.modalStack]
        return modal:handleClick(x, y)
    end

    -- Handle windows in reverse order (top to bottom)
    for i = #self.windows, 1, -1 do
        if self.windows[i]:handleClick(x, y) then
            -- Bring to front
            local window = table.remove(self.windows, i)
            table.insert(self.windows, window)
            return true
        end
    end

    return false
end

function WindowManager:handleMouseMove(x, y)
    for i = #self.windows, 1, -1 do
        if self.windows[i]:handleMouseMove(x, y) then
            return true
        end
    end
    return false
end

function WindowManager:handleMouseUp(x, y)
    for i = #self.windows, 1, -1 do
        if self.windows[i]:handleMouseUp(x, y) then
            return true
        end
    end
    return false
end

function WindowManager:render()
    -- Render all windows
    for _, window in ipairs(self.windows) do
        if not window.modal then
            window:render()
        end
    end

    -- Render modals on top
    for _, modal in ipairs(self.modalStack) do
        modal:render()
    end
end

-- Dialog helper function
function WindowManager:dialog(title, message, buttons)
    local dialog = Window:new(title, 50, 10)
    dialog:setModal(true)
    dialog:center(term.getSize())

    -- TODO: Add message label and button components

    self:add(dialog)
    return dialog
end

return {
    Window = Window,
    WindowManager = WindowManager
}
