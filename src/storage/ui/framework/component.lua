-- Base Component class for all UI elements
local Component = {}
Component.__index = Component

-- Scroll type constants
Component.ScrollType = {
    NORMAL = "normal",      -- Scroll down to see more (top-anchored)
    INVERTED = "inverted"   -- Scroll up to see more (bottom-anchored, like console logs)
}

-- Component counter for unique IDs
local componentIdCounter = 0

function Component:new(type)
    componentIdCounter = componentIdCounter + 1

    local o = setmetatable({}, self)
    o.id = "component_" .. componentIdCounter
    o.type = type or "component"
    o.x = 1
    o.y = 1
    o.width = 10
    o.height = 1
    o.visible = true
    o.enabled = true

    -- Style properties
    o.styles = {
        bg = colors.black,
        fg = colors.white,
        hoverBg = nil,
        hoverFg = nil,
        clickBg = nil,
        clickFg = nil,
        disabledBg = colors.gray,
        disabledFg = colors.lightGray,
        padding = {top = 0, right = 0, bottom = 0, left = 0},
        margin = {top = 0, right = 0, bottom = 0, left = 0},
        border = {enabled = false, color = colors.white, char = "-"},
        overflow = "visible" -- visible, hidden, scroll
    }

    -- State
    o.hovered = false
    o.clicked = false
    o.focused = false

    -- Children
    o.children = {}
    o.parent = nil

    -- Scroll state
    o.scrollX = 0
    o.scrollY = 0
    o.scrollEnabled = false
    o.scrollType = Component.ScrollType.NORMAL
    o.showScrollbar = true
    o.scrollbarWidth = 1
    o.autoScroll = false  -- For INVERTED mode, keep scrolled to bottom

    -- Event handlers
    o.handlers = {
        onClick = nil,
        onHover = nil,
        onLeave = nil,
        onFocus = nil,
        onBlur = nil,
        onScroll = nil
    }

    -- Animation state
    o.animations = {}

    return o
end

-- Chainable setters
function Component:setId(id)
    self.id = id
    return self
end

function Component:setPosition(x, y)
    self.x = x
    self.y = y
    return self
end

function Component:setSize(width, height)
    self.width = width
    self.height = height
    return self
end

function Component:setBounds(x, y, width, height)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    return self
end

function Component:bg(color)
    if color then
        self.styles.bg = color
        return self
    end
    return self.styles.bg
end

function Component:fg(color)
    if color then
        self.styles.fg = color
        return self
    end
    return self.styles.fg
end

function Component:hoverBg(color)
    self.styles.hoverBg = color
    return self
end

function Component:hoverFg(color)
    self.styles.hoverFg = color
    return self
end

function Component:clickBg(color)
    self.styles.clickBg = color
    return self
end

function Component:clickFg(color)
    self.styles.clickFg = color
    return self
end

function Component:padding(top, right, bottom, left)
    self.styles.padding = {
        top = top or 0,
        right = right or top or 0,
        bottom = bottom or top or 0,
        left = left or right or top or 0
    }
    return self
end

function Component:margin(top, right, bottom, left)
    self.styles.margin = {
        top = top or 0,
        right = right or top or 0,
        bottom = bottom or top or 0,
        left = left or right or top or 0
    }
    return self
end

function Component:border(enabled, color, char)
    self.styles.border = {
        enabled = enabled,
        color = color or colors.white,
        char = char or "-"
    }
    return self
end

function Component:overflow(mode)
    self.styles.overflow = mode
    return self
end

function Component:scrollable(enabled, scrollType)
    self.scrollEnabled = enabled
    if scrollType then
        self.scrollType = scrollType
    end
    if enabled then
        self.styles.overflow = "scroll"
        -- For inverted mode, enable auto-scroll by default
        if self.scrollType == Component.ScrollType.INVERTED then
            self.autoScroll = true
        end
    else
        self.styles.overflow = "visible"
    end
    return self
end

function Component:show()
    self.visible = true
    return self
end

function Component:hide()
    self.visible = false
    return self
end

function Component:setVisible(visible)
    self.visible = visible
    return self
end

function Component:isVisible()
    return self.visible
end

function Component:enable()
    self.enabled = true
    return self
end

function Component:disable()
    self.enabled = false
    return self
end

function Component:setEnabled(enabled)
    self.enabled = enabled
    return self
end

function Component:isEnabled()
    return self.enabled
end

-- Event handlers
function Component:onClick(handler)
    self.handlers.onClick = handler
    return self
end

function Component:onHover(handler)
    self.handlers.onHover = handler
    return self
end

function Component:onLeave(handler)
    self.handlers.onLeave = handler
    return self
end

function Component:onFocus(handler)
    self.handlers.onFocus = handler
    return self
end

function Component:onBlur(handler)
    self.handlers.onBlur = handler
    return self
end

function Component:onScroll(handler)
    self.handlers.onScroll = handler
    return self
end

-- Child management
function Component:add(child)
    table.insert(self.children, child)
    child.parent = self
    return self
end

function Component:remove(child)
    for i, c in ipairs(self.children) do
        if c == child then
            table.remove(self.children, i)
            child.parent = nil
            break
        end
    end
    return self
end

function Component:removeAll()
    for _, child in ipairs(self.children) do
        child.parent = nil
    end
    self.children = {}
    return self
end

-- Get content dimensions (accounting for scrollbar if visible)
function Component:getContentWidth()
    local width = self.width
    -- ALWAYS reserve space for scrollbar if scrolling is enabled (prevents text overflow)
    if self.scrollEnabled and self.showScrollbar then
        width = width - self.scrollbarWidth
    end
    return width
end

function Component:getContentHeight()
    local height = self.height
    -- Account for borders if enabled
    if self.styles.border.enabled then
        height = height - 2
    end
    return height
end

-- Check if scrollbar is needed (override in subclasses for custom logic)
function Component:needsScrollbar()
    -- Default: check if children overflow
    if #self.children == 0 then return false end

    local contentHeight = self:getContentHeight()
    local totalChildHeight = 0
    for _, child in ipairs(self.children) do
        totalChildHeight = totalChildHeight + child.height + child.styles.margin.top + child.styles.margin.bottom
    end

    return totalChildHeight > contentHeight
end

-- Get absolute position (accounting for parent offsets)
function Component:getAbsoluteX()
    local x = self.x + self.styles.margin.left
    if self.parent then
        x = x + self.parent:getAbsoluteX() + self.parent.styles.padding.left - self.parent.scrollX
    end
    return x
end

function Component:getAbsoluteY()
    local y = self.y + self.styles.margin.top
    if self.parent then
        y = y + self.parent:getAbsoluteY() + self.parent.styles.padding.top - self.parent.scrollY
    end
    return y
end

-- Check if point is within bounds
function Component:containsPoint(x, y)
    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    return x >= absX and x < absX + self.width and
           y >= absY and y < absY + self.height
end

-- Handle events
function Component:handleClick(x, y)
    if not self.enabled or not self.visible then return false end

    -- Check children first (reverse order for top-down)
    for i = #self.children, 1, -1 do
        if self.children[i]:handleClick(x, y) then
            return true
        end
    end

    if self:containsPoint(x, y) then
        self.clicked = true
        if self.handlers.onClick then
            self.handlers.onClick(self, x, y)
        end
        return true
    end

    return false
end

function Component:handleMouseMove(x, y)
    if not self.enabled or not self.visible then return false end

    local wasHovered = self.hovered
    self.hovered = self:containsPoint(x, y)

    if self.hovered and not wasHovered then
        if self.handlers.onHover then
            self.handlers.onHover(self, x, y)
        end
    elseif not self.hovered and wasHovered then
        if self.handlers.onLeave then
            self.handlers.onLeave(self, x, y)
        end
    end

    -- Check children
    for _, child in ipairs(self.children) do
        child:handleMouseMove(x, y)
    end
end

function Component:handleMouseUp(x, y)
    if not self.enabled or not self.visible then return false end

    -- Check children
    for _, child in ipairs(self.children) do
        if child:handleMouseUp(x, y) then
            return true
        end
    end

    return false
end

function Component:handleScroll(direction, x, y)
    if not self.enabled or not self.visible then return false end

    if self:containsPoint(x, y) and self.scrollEnabled then
        -- Disable auto-scroll when user manually scrolls
        self.autoScroll = false

        local maxScroll = self:getMaxScroll()

        -- Mouse scroll: UP = -1, DOWN = 1
        -- Scroll wheel DOWN (direction > 0) = move forward in content (increase scrollY)
        -- Scroll wheel UP (direction < 0) = move backward in content (decrease scrollY)
        if direction > 0 then
            -- Scroll wheel DOWN: increase scrollY (scroll toward end/newer content)
            self.scrollY = math.min(maxScroll, self.scrollY + 1)
        else
            -- Scroll wheel UP: decrease scrollY (scroll toward start/older content)
            self.scrollY = math.max(0, self.scrollY - 1)
        end

        if self.handlers.onScroll then
            self.handlers.onScroll(self, direction)
        end
        return true
    end

    -- Check children
    for i = #self.children, 1, -1 do
        if self.children[i]:handleScroll(direction, x, y) then
            return true
        end
    end

    return false
end

-- Scroll to bottom (show the last page of content)
function Component:scrollToBottom()
    self.autoScroll = true
    self.scrollY = self:getMaxScroll()
    return self
end

-- Scroll to top (show the first page of content)
function Component:scrollToTop()
    self.autoScroll = false
    self.scrollY = 0
    return self
end

-- Get current background color based on state
function Component:getCurrentBg()
    if not self.enabled then
        return self.styles.disabledBg
    elseif self.clicked and self.styles.clickBg then
        return self.styles.clickBg
    elseif self.hovered and self.styles.hoverBg then
        return self.styles.hoverBg
    else
        return self.styles.bg
    end
end

-- Get current foreground color based on state
function Component:getCurrentFg()
    if not self.enabled then
        return self.styles.disabledFg
    elseif self.clicked and self.styles.clickFg then
        return self.styles.clickFg
    elseif self.hovered and self.styles.hoverFg then
        return self.styles.hoverFg
    else
        return self.styles.fg
    end
end

-- Render (to be overridden by subclasses)
function Component:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Draw background
    term.setBackgroundColor(self:getCurrentBg())
    term.setTextColor(self:getCurrentFg())

    for dy = 0, self.height - 1 do
        term.setCursorPos(absX, absY + dy)
        term.write(string.rep(" ", self.width))
    end

    -- Draw border if enabled
    if self.styles.border.enabled then
        term.setTextColor(self.styles.border.color)

        -- Top and bottom
        term.setCursorPos(absX, absY)
        term.write(string.rep(self.styles.border.char, self.width))
        term.setCursorPos(absX, absY + self.height - 1)
        term.write(string.rep(self.styles.border.char, self.width))

        -- Left and right
        for dy = 1, self.height - 2 do
            term.setCursorPos(absX, absY + dy)
            term.write("|")
            term.setCursorPos(absX + self.width - 1, absY + dy)
            term.write("|")
        end
    end

    -- Render children
    for _, child in ipairs(self.children) do
        child:render()
    end

    -- Render scrollbar LAST (on top of everything)
    if self.scrollEnabled and self.showScrollbar and self:needsScrollbar() then
        self:renderScrollbar()
    end
end

-- Render scrollbar
function Component:renderScrollbar()
    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()
    local scrollbarX = absX + self.width - 1
    local contentHeight = self:getContentHeight()

    -- Draw full-height scrollbar background
    for i = 0, self.height - 1 do
        term.setCursorPos(scrollbarX, absY + i)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
        term.write(" ")
    end

    -- Calculate scrollbar thumb position (same for both modes - scroll direction is always natural)
    local scrollRange = self:getMaxScroll()
    if scrollRange > 0 then
        local thumbPos = math.floor((self.scrollY / scrollRange) * (contentHeight - 1))

        -- Draw scrollbar track
        local trackStart = self.styles.border.enabled and 1 or 0
        local trackEnd = trackStart + contentHeight - 1

        for i = trackStart, trackEnd do
            term.setCursorPos(scrollbarX, absY + i)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.gray)
            term.write("|")
        end

        -- Draw thumb
        local thumbY = absY + trackStart + thumbPos
        term.setCursorPos(scrollbarX, thumbY)
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.white)
        term.write("\149")
    end

    term.setBackgroundColor(colors.black)
end

-- Get maximum scroll value (override in subclasses)
function Component:getMaxScroll()
    local contentHeight = self:getContentHeight()
    local totalHeight = 0
    for _, child in ipairs(self.children) do
        totalHeight = totalHeight + child.height + child.styles.margin.top + child.styles.margin.bottom
    end
    return math.max(0, totalHeight - contentHeight)
end

-- Apply style from theme
function Component:applyStyle(styleData)
    if styleData.bg then self.styles.bg = styleData.bg end
    if styleData.fg then self.styles.fg = styleData.fg end
    if styleData.hoverBg then self.styles.hoverBg = styleData.hoverBg end
    if styleData.hoverFg then self.styles.hoverFg = styleData.hoverFg end
    if styleData.clickBg then self.styles.clickBg = styleData.clickBg end
    if styleData.clickFg then self.styles.clickFg = styleData.clickFg end
    if styleData.padding then self.styles.padding = styleData.padding end
    if styleData.margin then self.styles.margin = styleData.margin end
    if styleData.border then self.styles.border = styleData.border end

    return self
end

return Component
