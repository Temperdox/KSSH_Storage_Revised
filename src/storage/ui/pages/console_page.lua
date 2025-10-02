local ConsolePage = {}
ConsolePage.__index = ConsolePage

function ConsolePage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger
    o.printBuffer = context.printBuffer or {}

    -- UI state
    o.scrollOffset = 0
    o.autoScroll = true
    o.searchQuery = ""
    o.selectedLogType = "all"
    o.selectedEventType = "all"
    o.commandHistory = {}
    o.historyIndex = 0
    o.currentCommand = ""

    -- Available filters
    o.logTypes = {"all", "trace", "debug", "info", "warn", "error"}
    o.eventTypes = {"all"}

    -- Terminal dimensions
    o.width, o.height = term.getSize()

    -- Layout
    o.headerHeight = 1
    o.filterHeight = 2
    o.consoleTop = 4
    o.consoleBottom = o.height - 2
    o.commandY = o.height - 1
    o.footerY = o.height

    -- Navigation link positions (for click detection)
    o.navLinks = {}

    -- Logo bitmap for efficient rendering
    o.logoBitmap = nil
    o.logoX = 0
    o.logoY = 0
    o.logoWidth = 0
    o.logoHeight = 0
    o:buildLogoBitmap()

    return o
end

function ConsolePage:buildLogoBitmap()
    -- Load logo graphic
    local success, graphicModule = pcall(require, "ui.graphics.logo")
    if not success or not graphicModule or not graphicModule.sergal then
        return
    end

    local graphic = graphicModule.sergal
    self.logoWidth = graphic.width
    self.logoHeight = graphic.height

    -- Calculate centered position
    local consoleHeight = self.consoleBottom - self.consoleTop - 1
    self.logoX = math.floor((self.width - self.logoWidth) / 2)
    self.logoY = self.consoleTop + 1 + math.floor((consoleHeight - self.logoHeight) / 2)

    -- Build 2D bitmap: true = logo pixel (purple), false = transparent
    self.logoBitmap = {}
    for row = 1, self.logoHeight do
        self.logoBitmap[row] = {}
        for col = 1, self.logoWidth do
            self.logoBitmap[row][col] = false  -- Default transparent
        end
    end

    -- Process graphic data into bitmap
    local idx = 1
    for row = 1, self.logoHeight do
        for col = 1, self.logoWidth do
            if idx <= #graphic.image then
                local binaryStr = graphic.image[idx]
                -- Check if any bit is set to 1 (indicating logo pixel)
                local hasPixel = binaryStr:find("1") ~= nil
                self.logoBitmap[row][col] = hasPixel
                idx = idx + 1
            end
        end
    end
end

function ConsolePage:isLogoPixel(x, y)
    -- Check if position (x, y) is within logo area and should show logo
    if not self.logoBitmap then return false end

    local relX = x - self.logoX + 1
    local relY = y - self.logoY + 1

    if relX >= 1 and relX <= self.logoWidth and relY >= 1 and relY <= self.logoHeight then
        return self.logoBitmap[relY] and self.logoBitmap[relY][relX] or false
    end

    return false
end

function ConsolePage:onEnter()
    -- Subscribe to log events
    self.eventBus:subscribe("log%..*", function(event, data)
        self:onNewLog(event, data)
    end)

    -- Clear screen and set up UI
    term.setBackgroundColor(colors.black)
    term.clear()
end

function ConsolePage:onLeave()
    -- Cleanup if needed
end

function ConsolePage:render()
    -- Don't clear entire screen, just update regions

    -- Draw header
    self:drawHeader()

    -- Draw filters
    self:drawFilters()

    -- Draw log console
    self:drawLogConsole()

    -- Draw command line
    self:drawCommandLine()

    -- Draw footer
    self:drawFooter()

    -- Reset cursor to command line
    term.setCursorPos(3, self.commandY)
end

function ConsolePage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)

    -- Title on the left
    term.setCursorPos(2, 1)
    term.write("STORAGE CONSOLE")

    -- Navigation links on the right (right-aligned with more spacing)
    self.navLinks = {}

    -- Calculate positions from right to left
    local x = self.width - 8
    term.setCursorPos(x, 1)
    term.setTextColor(colors.orange)
    term.write("Settings")
    self.navLinks.settings = {x1 = x, x2 = x + 7, y = 1, page = "settings"}

    x = x - 8
    term.setCursorPos(x, 1)
    term.setTextColor(colors.lime)
    term.write("Tests")
    self.navLinks.tests = {x1 = x, x2 = x + 4, y = 1, page = "tests"}

    x = x - 8
    term.setCursorPos(x, 1)
    term.setTextColor(colors.yellow)
    term.write("Stats")
    self.navLinks.stats = {x1 = x, x2 = x + 4, y = 1, page = "stats"}

    x = x - 6
    term.setCursorPos(x, 1)
    term.setTextColor(colors.cyan)
    term.write("Net")
    self.navLinks.net = {x1 = x, x2 = x + 2, y = 1, page = "net"}

    term.setBackgroundColor(colors.black)
end

function ConsolePage:drawFilters()
    term.setCursorPos(1, 2)
    term.clearLine()
    term.setCursorPos(1, 3)
    term.clearLine()

    term.setCursorPos(1, 3)

    -- Search bar
    term.setTextColor(colors.lightGray)
    term.write("Search: ")
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)

    local searchBoxWidth = 20
    local searchDisplay = self.searchQuery
    if #searchDisplay > searchBoxWidth - 2 then
        searchDisplay = searchDisplay:sub(1, searchBoxWidth - 5) .. "..."
    end
    searchDisplay = searchDisplay .. string.rep(" ", searchBoxWidth - #searchDisplay)
    term.write(searchDisplay)

    term.setBackgroundColor(colors.black)

    -- Log type filter
    term.setCursorPos(30, 3)
    term.setTextColor(colors.lightGray)
    term.write("Type: ")
    term.setTextColor(colors.yellow)
    term.write("[" .. self.selectedLogType .. "]")

    -- Event type filter
    if self.width > 60 then
        term.setCursorPos(45, 3)
        term.setTextColor(colors.lightGray)
        term.write("Event: ")
        term.setTextColor(colors.cyan)
        term.write("[" .. self.selectedEventType .. "]")
    end
end

function ConsolePage:drawLogConsole()
    -- Draw border
    term.setCursorPos(1, self.consoleTop)
    term.setTextColor(colors.gray)
    term.clearLine()
    term.write(string.rep("-", self.width))

    -- Get logs from print buffer and logger
    local logs = {}

    -- Add print buffer entries
    for _, entry in ipairs(self.printBuffer) do
        table.insert(logs, {
            time = entry.time,
            level = "print",
            source = "System",
            message = entry.text
        })
    end

    -- Add logger entries
    if self.logger and self.logger.ringBuffer then
        for _, entry in ipairs(self.logger.ringBuffer) do
            table.insert(logs, entry)
        end
    end

    -- Filter logs
    local filteredLogs = self:filterLogs(logs)

    -- Calculate visible range
    local consoleHeight = self.consoleBottom - self.consoleTop - 1
    local visibleStart = 1
    local visibleEnd = math.min(#filteredLogs, consoleHeight)

    if self.autoScroll then
        if #filteredLogs > consoleHeight then
            visibleStart = #filteredLogs - consoleHeight + 1
            visibleEnd = #filteredLogs
        end
    else
        visibleStart = self.scrollOffset + 1
        visibleEnd = math.min(self.scrollOffset + consoleHeight, #filteredLogs)
    end

    -- Clear all lines and draw logo + text together
    for clearY = self.consoleTop + 1, self.consoleBottom do
        term.setCursorPos(1, clearY)

        -- Draw entire line with logo background where applicable
        for x = 1, self.width do
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

    -- Draw logs on top with intelligent background handling
    local y = self.consoleTop + 1
    for i = visibleStart, visibleEnd do
        local log = filteredLogs[i]
        if log then
            self:drawLogLine(log, y)
            y = y + 1
        end
    end

    -- Draw bottom border
    term.setCursorPos(1, self.consoleBottom + 1)
    term.setTextColor(colors.gray)
    term.clearLine()
    term.write(string.rep("-", self.width))

    -- Draw scroll bar on the right edge
    if #filteredLogs > consoleHeight then
        local scrollBarHeight = consoleHeight
        local scrollBarPos = math.floor((visibleStart - 1) / (#filteredLogs - consoleHeight) * (scrollBarHeight - 1))

        for i = 0, scrollBarHeight - 1 do
            term.setCursorPos(self.width, self.consoleTop + 1 + i)
            if i == scrollBarPos then
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
                term.write("\138")  -- Slim scroll indicator
            else
                term.setBackgroundColor(colors.lightGray)
                term.setTextColor(colors.black)
                term.write("\149")  -- Track character
            end
        end
        term.setBackgroundColor(colors.black)
    end

    -- Scroll to bottom button (when not at bottom)
    if not self.autoScroll and visibleEnd < #filteredLogs then
        local btnY = self.consoleBottom - 1
        local btnText = " \25 Bottom "
        local btnX = math.floor((self.width - #btnText) / 2)

        -- Draw button character by character to respect logo background
        for i = 1, #btnText do
            local x = btnX + i - 1
            local char = btnText:sub(i, i)

            term.setCursorPos(x, btnY)

            -- Always use orange background for button, overriding logo
            term.setBackgroundColor(colors.orange)
            term.setTextColor(colors.white)
            term.write(char)
        end

        -- Store button position for click detection
        self.scrollToBottomBtn = {x1 = btnX, x2 = btnX + #btnText - 1, y = btnY}
        term.setBackgroundColor(colors.black)
    else
        self.scrollToBottomBtn = nil
    end
end

function ConsolePage:drawLogLine(log, y)
    -- Build the log line string with color codes
    local levelColors = {
        trace = colors.gray,
        debug = colors.lightGray,
        info = colors.white,
        warn = colors.yellow,
        error = colors.red,
        print = colors.cyan
    }

    -- Build segments with their colors
    local segments = {}

    -- Time
    table.insert(segments, {text = log.time or "00:00:00", color = colors.gray})
    table.insert(segments, {text = " ", color = colors.gray})

    -- Level/Type
    local levelStr = (log.level or "INFO"):upper()
    if #levelStr > 5 then levelStr = levelStr:sub(1, 5) end
    table.insert(segments, {text = "[" .. levelStr .. "]", color = levelColors[log.level] or colors.white})
    table.insert(segments, {text = " ", color = colors.white})

    -- Source
    local source = log.source or "System"
    if #source > 12 then
        source = source:sub(1, 10) .. ".."
    end
    table.insert(segments, {text = source, color = colors.cyan})
    table.insert(segments, {text = " ", color = colors.white})

    -- Message
    local message = log.message or ""
    local remainingWidth = self.width - 30
    if #message > remainingWidth then
        message = message:sub(1, remainingWidth - 3) .. "..."
    end
    table.insert(segments, {text = message, color = colors.white})

    -- Draw character by character with smart background handling
    local x = 1
    term.setCursorPos(x, y)

    for _, segment in ipairs(segments) do
        term.setTextColor(segment.color)

        for i = 1, #segment.text do
            local char = segment.text:sub(i, i)

            -- Check if this position has a logo pixel
            if not self:isLogoPixel(x, y) then
                -- No logo here, use black background
                term.setBackgroundColor(colors.black)
            end
            -- If logo pixel, keep the purple background already drawn

            term.write(char)
            x = x + 1
        end
    end
end

function ConsolePage:drawCommandLine()
    term.setCursorPos(1, self.commandY)
    term.clearLine()
    term.setTextColor(colors.lime)
    term.write("> ")

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)

    -- Command input
    local cmdDisplay = self.currentCommand
    local maxCmdLen = self.width - 3

    if #cmdDisplay > maxCmdLen then
        cmdDisplay = "..." .. cmdDisplay:sub(#cmdDisplay - maxCmdLen + 4)
    end

    term.write(cmdDisplay)

    -- Show cursor
    term.setCursorBlink(true)
end

function ConsolePage:drawFooter()
    term.setCursorPos(1, self.footerY)
    term.clearLine()
    term.setTextColor(colors.gray)

    -- Status info
    local logCount = #self.printBuffer + (self.logger and #self.logger.ringBuffer or 0)
    local status = string.format(
            "Logs: %d | Scroll: %s | F1: Help",
            logCount,
            self.autoScroll and "AUTO" or "MANUAL"
    )

    term.write(status)
end

function ConsolePage:filterLogs(logs)
    local filtered = {}

    for _, log in ipairs(logs) do
        local includeLog = true

        -- Filter by log type
        if self.selectedLogType ~= "all" and log.level ~= self.selectedLogType then
            includeLog = false
        end

        -- Filter by search query
        if self.searchQuery ~= "" and includeLog then
            local searchLower = self.searchQuery:lower()
            local messageMatch = (log.message or ""):lower():find(searchLower)
            local sourceMatch = (log.source or ""):lower():find(searchLower)

            if not (messageMatch or sourceMatch) then
                includeLog = false
            end
        end

        if includeLog then
            table.insert(filtered, log)
        end
    end

    return filtered
end

function ConsolePage:onNewLog(event, data)
    -- Track event type
    local eventType = event:match("^log%.(.+)")
    if eventType and not self:hasEventType(eventType) then
        table.insert(self.eventTypes, eventType)
    end
end

function ConsolePage:hasEventType(eventType)
    for _, et in ipairs(self.eventTypes) do
        if et == eventType then
            return true
        end
    end
    return false
end

function ConsolePage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1

        -- Navigation removed - use clickable links instead to avoid conflicts with command input
        if key == keys.f1 then
            self:showHelp()
        elseif key == keys.up then
            if #self.currentCommand == 0 then
                self:navigateHistory(-1)
            else
                self:scroll(-1)
            end
        elseif key == keys.down then
            if #self.currentCommand == 0 then
                self:navigateHistory(1)
            else
                self:scroll(1)
            end
        elseif key == keys.pageUp then
            self:scroll(-10)
        elseif key == keys.pageDown then
            self:scroll(10)
        elseif key == keys.home then
            self.scrollOffset = 0
            self.autoScroll = false
        elseif key == keys["end"] then
            self.autoScroll = true
        elseif key == keys.tab then
            self:autocomplete()
        elseif key == keys.enter then
            self:executeCommand()
        elseif key == keys.backspace then
            if #self.currentCommand > 0 then
                self.currentCommand = self.currentCommand:sub(1, -2)
            end
        end
    elseif event == "char" then
        self.currentCommand = self.currentCommand .. param1
    elseif event == "mouse_scroll" then
        self:scroll(param1 * 3)
    elseif event == "mouse_click" then
        self:handleClick(param2, param3)
    end
end

function ConsolePage:handleClick(x, y)
    -- Check scroll to bottom button
    if self.scrollToBottomBtn then
        if y == self.scrollToBottomBtn.y and x >= self.scrollToBottomBtn.x1 and x <= self.scrollToBottomBtn.x2 then
            self.autoScroll = true
            self.scrollOffset = 0
            return
        end
    end

    -- Check navigation links
    for _, link in pairs(self.navLinks) do
        if y == link.y and x >= link.x1 and x <= link.x2 then
            self.context.router:navigate(link.page)
            return
        end
    end
end

function ConsolePage:executeCommand()
    if self.currentCommand == "" then
        return
    end

    -- Add to history
    table.insert(self.commandHistory, self.currentCommand)
    self.historyIndex = #self.commandHistory + 1

    -- Log the command
    self.logger:info("Command", self.currentCommand)

    -- Execute via command factory
    if self.context.commandFactory then
        local success, result = self.context.commandFactory:execute(self.currentCommand)

        if success then
            self.logger:info("Result", tostring(result))
        else
            self.logger:error("Error", tostring(result))
        end
    end

    -- Clear command
    self.currentCommand = ""
end

function ConsolePage:navigateHistory(direction)
    local newIndex = self.historyIndex + direction

    if newIndex >= 1 and newIndex <= #self.commandHistory then
        self.historyIndex = newIndex
        self.currentCommand = self.commandHistory[self.historyIndex]
    elseif newIndex > #self.commandHistory then
        self.historyIndex = #self.commandHistory + 1
        self.currentCommand = ""
    end
end

function ConsolePage:scroll(amount)
    -- Get total log count
    local logs = {}
    for _, entry in ipairs(self.printBuffer) do
        table.insert(logs, entry)
    end
    if self.logger and self.logger.ringBuffer then
        for _, entry in ipairs(self.logger.ringBuffer) do
            table.insert(logs, entry)
        end
    end
    local filteredLogs = self:filterLogs(logs)
    local consoleHeight = self.consoleBottom - self.consoleTop - 1

    -- Disable auto-scroll when scrolling up
    if amount < 0 then
        self.autoScroll = false
    end

    -- Update scroll offset
    local maxScroll = math.max(0, #filteredLogs - consoleHeight)
    self.scrollOffset = math.max(0, math.min(maxScroll, self.scrollOffset + amount))

    -- Re-enable auto-scroll if we've scrolled to the bottom
    if self.scrollOffset >= maxScroll then
        self.autoScroll = true
    end
end

function ConsolePage:autocomplete()
    if self.context.commandFactory then
        local suggestions = self.context.commandFactory:getAutocomplete(self.currentCommand)
        if #suggestions == 1 then
            self.currentCommand = suggestions[1]
        elseif #suggestions > 1 then
            -- Show suggestions in log
            self.logger:info("Autocomplete", table.concat(suggestions, ", "))
        end
    end
end

function ConsolePage:showHelp()
    self.logger:info("Help", "Navigation: S=Stats, T=Tests, N=Net, X=Settings")
    self.logger:info("Help", "Scrolling: PgUp/PgDown, Home/End")
    self.logger:info("Help", "Commands: Type and press Enter, Tab for autocomplete")
    self.logger:info("Help", "History: Up/Down arrows")
end

return ConsolePage