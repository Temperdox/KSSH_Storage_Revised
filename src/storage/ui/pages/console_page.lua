-- ============================================================================
-- FIXED CONSOLE PAGE THAT USES PRINT BUFFER
-- ============================================================================

-- /storage/ui/pages/console_page.lua
-- Terminal UI console page that displays captured print output

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

    return o
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

    -- Title
    local title = " STORAGE CONSOLE "
    term.setCursorPos(math.floor((self.width - #title) / 2), 1)
    term.write(title)

    -- Navigation links
    term.setCursorPos(self.width - 20, 1)
    term.setTextColor(colors.yellow)
    term.write("[S]tats ")
    term.setTextColor(colors.lime)
    term.write("[T]ests ")
    term.setTextColor(colors.orange)
    term.write("[X]ettings")

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

    -- Draw logs
    local y = self.consoleTop + 1
    for i = visibleStart, visibleEnd do
        local log = filteredLogs[i]
        if log then
            term.setCursorPos(1, y)
            term.clearLine()
            self:drawLogLine(log)
            y = y + 1
        end
    end

    -- Clear remaining lines
    while y <= self.consoleBottom do
        term.setCursorPos(1, y)
        term.clearLine()
        y = y + 1
    end

    -- Draw bottom border
    term.setCursorPos(1, self.consoleBottom + 1)
    term.setTextColor(colors.gray)
    term.clearLine()
    term.write(string.rep("-", self.width))

    -- Scroll indicators
    if visibleStart > 1 then
        term.setCursorPos(self.width - 2, self.consoleTop + 1)
        term.setTextColor(colors.yellow)
        term.write("^^")
    end

    if visibleEnd < #filteredLogs then
        term.setCursorPos(self.width - 2, self.consoleBottom)
        term.setTextColor(colors.yellow)
        term.write("vv")
    end
end

function ConsolePage:drawLogLine(log)
    -- Time
    term.setTextColor(colors.gray)
    term.write(log.time or "00:00:00")
    term.write(" ")

    -- Level/Type
    local levelColors = {
        trace = colors.gray,
        debug = colors.lightGray,
        info = colors.white,
        warn = colors.yellow,
        error = colors.red,
        print = colors.cyan
    }

    term.setTextColor(levelColors[log.level] or colors.white)
    local levelStr = (log.level or "INFO"):upper()
    if #levelStr > 5 then levelStr = levelStr:sub(1, 5) end
    term.write("[" .. levelStr .. "]")
    term.write(" ")

    -- Source
    term.setTextColor(colors.cyan)
    local source = log.source or "System"
    if #source > 12 then
        source = source:sub(1, 10) .. ".."
    end
    term.write(source)
    term.write(" ")

    -- Message
    term.setTextColor(colors.white)
    local message = log.message or ""
    local remainingWidth = self.width - 30
    if #message > remainingWidth then
        message = message:sub(1, remainingWidth - 3) .. "..."
    end
    term.write(message)
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

        if key == keys.s and not keys.isPressed(keys.leftCtrl) then
            -- Switch to stats page
            self.context.router:navigate("stats")
        elseif key == keys.t and not keys.isPressed(keys.leftCtrl) then
            -- Switch to tests page
            self.context.router:navigate("tests")
        elseif key == keys.x and not keys.isPressed(keys.leftCtrl) then
            -- Switch to settings page
            self.context.router:navigate("settings")
        elseif key == keys.f1 then
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
    self.autoScroll = false
    self.scrollOffset = math.max(0, self.scrollOffset + amount)
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
    self.logger:info("Help", "Navigation: S=Stats, T=Tests, X=Settings")
    self.logger:info("Help", "Scrolling: PgUp/PgDown, Home/End")
    self.logger:info("Help", "Commands: Type and press Enter, Tab for autocomplete")
    self.logger:info("Help", "History: Up/Down arrows")
end

return ConsolePage