-- Log Console component with logo background and scrolling
local Component = require("ui.framework.component")

local LogConsole = setmetatable({}, {__index = Component})
LogConsole.__index = LogConsole

function LogConsole:new(x, y, width, height)
    local o = Component.new(self, "logconsole")

    o.x = x or 1
    o.y = y or 1
    o.width = width or 50
    o.height = height or 15
    o.logs = {}
    o.filterFn = nil

    -- Logo bitmap
    o.logoBitmap = nil
    o.logoX = 0
    o.logoY = 0
    o.logoWidth = 0
    o.logoHeight = 0

    -- Scroll to bottom button
    o.scrollToBottomBtn = nil

    -- Fixed scrolling: track which log we're viewing
    o.viewingLogIndex = nil
    o.previousLogCount = 0

    -- Draggable scrollbar
    o.isDraggingScrollbar = false
    o.scrollbarRegion = nil

    -- Enable scrolling with INVERTED mode (bottom-anchored, like console logs)
    o:scrollable(true, Component.ScrollType.INVERTED)

    return o
end

function LogConsole:setLogs(logs)
    self.logs = logs

    -- Fixed scrolling: Keep scrollY UNCHANGED when in manual scroll mode
    -- New logs are added to END, existing log indices stay the same
    -- scrollY stays constant → same log indices visible
    -- Scrollbar thumb naturally moves UP as maxScroll increases

    return self
end

function LogConsole:addLog(log)
    table.insert(self.logs, log)
    return self
end

function LogConsole:setFilter(filterFn)
    self.filterFn = filterFn
    return self
end

function LogConsole:setAutoScroll(auto)
    self.autoScroll = auto
    return self
end

-- Override: Check if scrollbar is needed based on log count
function LogConsole:needsScrollbar()
    local filteredLogs = self:getFilteredLogs()
    local consoleHeight = self.height - 2  -- Account for borders
    return #filteredLogs > consoleHeight
end

-- Override: Get maximum scroll value based on log count
function LogConsole:getMaxScroll()
    local filteredLogs = self:getFilteredLogs()
    local consoleHeight = self.height - 2
    return math.max(0, #filteredLogs - consoleHeight)
end

function LogConsole:setLogo(logoBitmap, logoX, logoY, logoWidth, logoHeight)
    self.logoBitmap = logoBitmap
    self.logoX = logoX
    self.logoY = logoY
    self.logoWidth = logoWidth
    self.logoHeight = logoHeight
    return self
end

function LogConsole:isLogoPixel(x, y)
    if not self.logoBitmap then return false end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    local relX = x - self.logoX + 1
    local relY = y - self.logoY + 1

    if relX >= 1 and relX <= self.logoWidth and relY >= 1 and relY <= self.logoHeight then
        return self.logoBitmap[relY] and self.logoBitmap[relY][relX] or false
    end

    return false
end

-- handleScroll is inherited from Component base class with proper INVERTED mode support

function LogConsole:handleClick(x, y)
    if not self.enabled or not self.visible then return false end

    -- Check scrollbar click for dragging
    if self.scrollbarRegion and x == self.scrollbarRegion.x and
       y >= self.scrollbarRegion.y1 and y <= self.scrollbarRegion.y2 then
        self.isDraggingScrollbar = true
        self:handleScrollbarDrag(y)
        return true
    end

    -- Check scroll to bottom button
    if self.scrollToBottomBtn then
        if y == self.scrollToBottomBtn.y and x >= self.scrollToBottomBtn.x1 and x <= self.scrollToBottomBtn.x2 then
            self:scrollToBottom()
            return true
        end
    end

    return Component.handleClick(self, x, y)
end

-- Handle scrollbar dragging
function LogConsole:handleScrollbarDrag(mouseY)
    if not self.scrollbarRegion then return end

    -- Disable auto-scroll and enable fixed scrolling
    self.autoScroll = false
    self.viewingLogIndex = true  -- Flag that we're in manual mode

    local consoleHeight = self.height - 2
    local scrollbarHeight = self.scrollbarRegion.y2 - self.scrollbarRegion.y1 + 1
    local relativeY = mouseY - self.scrollbarRegion.y1

    -- Calculate scroll position from mouse position
    local scrollPercent = math.max(0, math.min(1, relativeY / scrollbarHeight))
    local maxScroll = self:getMaxScroll()
    self.scrollY = math.floor(scrollPercent * maxScroll)
    self.scrollY = math.max(0, math.min(maxScroll, self.scrollY))
end

-- Handle mouse move for dragging
function LogConsole:handleMouseMove(x, y)
    if self.isDraggingScrollbar then
        self:handleScrollbarDrag(y)
        return true
    end

    return Component.handleMouseMove(self, x, y)
end

-- Handle mouse release
function LogConsole:handleMouseUp(x, y)
    self.isDraggingScrollbar = false
    return false
end

function LogConsole:getFilteredLogs()
    if self.filterFn then
        local filtered = {}
        for _, log in ipairs(self.logs) do
            if self.filterFn(log) then
                table.insert(filtered, log)
            end
        end
        return filtered
    end
    return self.logs
end

function LogConsole:render()
    if not self.visible then return end

    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()

    -- Get filtered logs
    local filteredLogs = self:getFilteredLogs()
    local consoleHeight = self.height - 2

    -- FORCE contentWidth to reserve scrollbar space - DO NOT rely on framework
    local contentWidth = self.width - 1

    -- Draw top border
    term.setCursorPos(absX, absY)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write(string.rep("-", contentWidth))

    -- Auto-scroll to bottom for INVERTED mode (keep showing newest logs)
    -- ONLY update scrollY if explicitly in auto-scroll mode
    if self.autoScroll and self.scrollType == Component.ScrollType.INVERTED then
        local maxScroll = self:getMaxScroll()
        -- Only update if actually at bottom or if scrollY is invalid
        if self.scrollY >= maxScroll - 1 or self.scrollY > maxScroll then
            self.scrollY = maxScroll
        end
        self.viewingLogIndex = nil  -- Clear tracked index when auto-scrolling
    else
        -- Manual scroll mode: NEVER modify scrollY during render
        -- Clamp to valid range without changing the view
        local maxScroll = self:getMaxScroll()
        if self.scrollY > maxScroll then
            self.scrollY = maxScroll
        end
    end

    -- Calculate visible range based on scroll position
    -- scrollY = 0 shows first page (oldest logs for INVERTED)
    -- scrollY = maxScroll shows last page (newest logs for INVERTED)
    local visibleStart = math.max(1, self.scrollY + 1)
    local visibleEnd = math.min(self.scrollY + consoleHeight, #filteredLogs)

    -- Ensure we don't show empty space
    if visibleEnd - visibleStart + 1 < consoleHeight and visibleStart > 1 then
        visibleStart = math.max(1, visibleEnd - consoleHeight + 1)
    end

    -- Track which log we're viewing for fixed scrolling
    if not self.autoScroll then
        -- Store the FIRST visible log index as our anchor point
        self.viewingLogIndex = visibleStart
    end

    -- Clear console area with logo
    for clearY = absY + 1, absY + self.height - 2 do
        term.setCursorPos(absX, clearY)

        for x = absX, absX + contentWidth - 1 do
            if self:isLogoPixel(x, clearY) then
                term.setBackgroundColor(colors.purple)
                term.setTextColor(colors.purple)
                term.write(" ")
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.black)
                term.write(" ")
            end
        end
    end

    -- Draw logs
    local y = absY + 1
    for i = visibleStart, visibleEnd do
        local log = filteredLogs[i]
        if log then
            self:drawLogLine(log, absX, y, contentWidth)
            y = y + 1
        end
    end

    -- Draw bottom border
    term.setCursorPos(absX, absY + self.height - 1)
    term.setTextColor(colors.gray)
    term.setBackgroundColor(colors.black)
    term.write(string.rep("-", contentWidth))

    -- Scroll to bottom button
    if not self.autoScroll and visibleEnd < #filteredLogs then
        local btnY = absY + self.height - 3
        local btnText = " \25 Bottom "
        local btnX = absX + math.floor((contentWidth - #btnText) / 2)

        for i = 1, #btnText do
            local x = btnX + i - 1
            local char = btnText:sub(i, i)

            term.setCursorPos(x, btnY)
            term.setBackgroundColor(colors.orange)
            term.setTextColor(colors.white)
            term.write(char)
        end

        self.scrollToBottomBtn = {x1 = btnX, x2 = btnX + #btnText - 1, y = btnY}
        term.setBackgroundColor(colors.black)
    else
        self.scrollToBottomBtn = nil
    end

    -- Draw scrollbar ONLY in log console area (not full screen!)
    local screenW = term.getSize()

    -- Store scrollbar region for click detection
    self.scrollbarRegion = {
        x = screenW,
        y1 = absY,
        y2 = absY + self.height - 1
    }

    -- Draw scrollbar only for THIS component's height
    for i = 0, self.height - 1 do
        term.setCursorPos(screenW, absY + i)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
        term.write("|")
    end

    -- Draw scrollbar thumb position indicator
    if self:needsScrollbar() then
        local scrollRange = self:getMaxScroll()
        if scrollRange > 0 then
            local consoleHeight = self.height - 2
            local thumbPos = math.floor((self.scrollY / scrollRange) * (consoleHeight - 1))

            term.setCursorPos(screenW, absY + 1 + thumbPos)
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.white)
            term.write("\149")
        end
    end

    term.setBackgroundColor(colors.black)
end

function LogConsole:drawLogLine(log, absX, y, contentWidth)
    local levelColors = {
        trace = colors.gray,
        debug = colors.blue,
        info = colors.white,
        warn = colors.orange,
        error = colors.red,
        print = colors.white
    }

    -- Build prefix (time, level, source)
    local prefix = ""

    -- Time
    prefix = prefix .. (log.time or "00:00:00") .. " "

    -- Level
    local levelStr = (log.level or "INFO"):upper()
    if #levelStr > 5 then levelStr = levelStr:sub(1, 5) end
    prefix = prefix .. "[" .. levelStr .. "] "

    -- Source
    local source = log.source or "System"
    if #source > 12 then
        source = source:sub(1, 10) .. ".."
    end
    prefix = prefix .. source .. " "

    -- Calculate EXACT remaining space for message
    local prefixLen = #prefix
    local messageSpace = math.max(0, contentWidth - prefixLen)

    -- Build message with EXACT truncation accounting for "..."
    local message = log.message or ""
    if #message > messageSpace then
        -- Need to truncate: reserve 3 chars for "..."
        local truncateAt = math.max(0, messageSpace - 3)
        message = message:sub(1, truncateAt) .. "..."
    end

    -- Final log text - should be exactly contentWidth or less
    local logText = prefix .. message

    -- Absolute safety check: should never exceed contentWidth
    if #logText > contentWidth then
        logText = logText:sub(1, contentWidth)
    end

    -- Draw character by character - ABSOLUTELY LIMITED to contentWidth
    local levelColor = levelColors[log.level] or colors.white
    local maxChars = math.min(#logText, contentWidth)

    for charIdx = 1, maxChars do
        local screenX = absX + charIdx - 1

        -- SAFETY CHECK: never draw past contentWidth boundary
        if screenX >= absX + contentWidth then
            break
        end

        local char = logText:sub(charIdx, charIdx)

        term.setCursorPos(screenX, y)

        local isOverLogo = self:isLogoPixel(screenX, y)

        -- Set background color
        if isOverLogo then
            term.setBackgroundColor(colors.purple)
        else
            term.setBackgroundColor(colors.black)
        end

        -- All text uses the level color - no separate coloring for time/source/message
        term.setTextColor(levelColor)

        term.write(char)
    end
end

return LogConsole
