local ConsolePage = {}
ConsolePage.__index = ConsolePage

function ConsolePage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    -- UI state
    o.logs = {}
    o.maxLogs = 50
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

    return o
end

function ConsolePage:onEnter()
    -- Subscribe to events
    self.eventBus:subscribe("log%..*", function(event, data)
        self:onNewLog(event, data)
    end)

    -- Load recent logs
    self:loadRecentLogs()

    -- Start render loop
    self:render()
end

function ConsolePage:onLeave()
    -- Cleanup
end

function ConsolePage:render()
    term.clear()

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

    -- Log type dropdown
    term.setCursorPos(30, 3)
    term.setTextColor(colors.lightGray)
    term.write("Type: ")
    term.setTextColor(colors.yellow)
    term.write("[" .. self.selectedLogType .. "]")

    -- Event type dropdown
    term.setCursorPos(45, 3)
    term.setTextColor(colors.lightGray)
    term.write("Event: ")
    term.setTextColor(colors.cyan)
    term.write("[" .. self.selectedEventType .. "]")
end

function ConsolePage:drawLogConsole()
    local startY = 5
    local endY = self.height - 3
    local consoleHeight = endY - startY + 1

    -- Border
    term.setCursorPos(1, startY - 1)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", self.width))

    term.setCursorPos(1, endY + 1)
    term.write(string.rep("-", self.width))

    -- Filter logs
    local filteredLogs = self:filterLogs()

    -- Calculate visible range
    local visibleStart = 1
    local visibleEnd = math.min(#filteredLogs, consoleHeight)

    if not self.autoScroll then
        visibleStart = self.scrollOffset + 1
        visibleEnd = math.min(self.scrollOffset + consoleHeight, #filteredLogs)
    else
        -- Show most recent at bottom
        if #filteredLogs > consoleHeight then
            visibleStart = #filteredLogs - consoleHeight + 1
            visibleEnd = #filteredLogs
        end
    end

    -- Draw logs (newest at bottom)
    local y = startY
    for i = visibleStart, visibleEnd do
        local log = filteredLogs[i]
        if log then
            term.setCursorPos(1, y)
            self:drawLogLine(log)
            y = y + 1
        end
    end

    -- Clear remaining lines
    while y <= endY do
        term.setCursorPos(1, y)
        term.clearLine()
        y = y + 1
    end

    -- Scroll indicators
    if visibleStart > 1 then
        term.setCursorPos(self.width - 2, startY)
        term.setTextColor(colors.yellow)
        term.write("^^")
    end

    if visibleEnd < #filteredLogs then
        term.setCursorPos(self.width - 2, endY)
        term.setTextColor(colors.yellow)
        term.write("vv")
    end
end

function ConsolePage:drawLogLine(log)
    -- Time
    term.setTextColor(colors.gray)
    term.write(log.time or os.date("%H:%M:%S"))
    term.write(" ")

    -- Level/Type
    local levelColors = {
        trace = colors.gray,
        debug = colors.lightGray,
        info = colors.white,
        warn = colors.yellow,
        error = colors.red
    }

    term.setTextColor(levelColors[log.level] or colors.white)
    term.write("[" .. (log.level or "INFO"):upper() .. "]")
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
    local maxMsgLen = self.width - 30
    if #message > maxMsgLen then
        message = message:sub(1, maxMsgLen - 3) .. "..."
    end
    term.write(message)
end

function ConsolePage:drawCommandLine()
    local cmdY = self.height - 1

    term.setCursorPos(1, cmdY)
    term.setTextColor(colors.lime)
    term.write("> ")

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)

    -- Command input with cursor
    local cmdDisplay = self.currentCommand
    local maxCmdLen = self.width - 3

    if #cmdDisplay > maxCmdLen then
        cmdDisplay = "..." .. cmdDisplay:sub(#cmdDisplay - maxCmdLen + 4)
    end

    term.write(cmdDisplay)

    -- Fill rest of line
    local remaining = self.width - 2 - #cmdDisplay
    if remaining > 0 then
        term.write(string.rep(" ", remaining))
    end

    term.setBackgroundColor(colors.black)
end

function ConsolePage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setTextColor(colors.gray)

    -- Status info
    local status = string.format(
            "Logs: %d | Scroll: %s | Press F1 for help",
            #self.logs,
            self.autoScroll and "AUTO" or "MANUAL"
    )

    term.write(status)
end

function ConsolePage:filterLogs()
    local filtered = {}

    for _, log in ipairs(self.logs) do
        local includeLog = true

        -- Filter by log type
        if self.selectedLogType ~= "all" and log.level ~= self.selectedLogType then
            includeLog = false
        end

        -- Filter by event type
        if self.selectedEventType ~= "all" and log.eventType ~= self.selectedEventType then
            includeLog = false
        end

        -- Filter by search query
        if self.searchQuery ~= "" then
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
    -- Add to logs
    table.insert(self.logs, data)

    -- Trim to max size
    while #self.logs > self.maxLogs * 2 do
        table.remove(self.logs, 1)
    end

    -- Track event type
    local eventType = event:match("^log%.(.+)")
    if eventType and not self:hasEventType(eventType) then
        table.insert(self.eventTypes, eventType)
    end

    -- Re-render if auto-scrolling
    if self.autoScroll then
        self:render()
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

function ConsolePage:loadRecentLogs()
    -- Load from logger's ring buffer
    if self.context.logger and self.context.logger.getRecent then
        self.logs = self.context.logger:getRecent(self.maxLogs)
    end

    -- Load from event bus recent events
    if self.context.eventBus and self.context.eventBus.getRecentEvents then
        local recentEvents = self.context.eventBus:getRecentEvents(self.maxLogs)
        for _, event in ipairs(recentEvents) do
            if event.name:match("^log%.") then
                table.insert(self.logs, event.data)
            end
        end
    end
end

function ConsolePage:handleInput(event, key)
    if event == "key" then
        if key == keys.f1 then
            self:showHelp()
        elseif key == keys.up then
            self:navigateHistory(-1)
        elseif key == keys.down then
            self:navigateHistory(1)
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
                self:render()
            end
        end
    elseif event == "char" then
        self.currentCommand = self.currentCommand .. key
        self:render()
    end
end

function ConsolePage:executeCommand()
    if self.currentCommand == "" then
        return
    end

    -- Add to history
    table.insert(self.commandHistory, self.currentCommand)
    self.historyIndex = #self.commandHistory + 1

    -- Execute via command factory
    if self.context.commandFactory then
        local success, result = self.context.commandFactory:execute(self.currentCommand)

        -- Log result
        self.logger:info("Command", self.currentCommand)
        if success then
            self.logger:info("Result", tostring(result))
        else
            self.logger:error("Error", tostring(result))
        end
    end

    -- Clear command
    self.currentCommand = ""
    self:render()
end

function ConsolePage:navigateHistory(direction)
    local newIndex = self.historyIndex + direction

    if newIndex >= 1 and newIndex <= #self.commandHistory then
        self.historyIndex = newIndex
        self.currentCommand = self.commandHistory[self.historyIndex]
        self:render()
    elseif newIndex > #self.commandHistory then
        self.historyIndex = #self.commandHistory + 1
        self.currentCommand = ""
        self:render()
    end
end

function ConsolePage:scroll(amount)
    self.autoScroll = false
    self.scrollOffset = math.max(0, self.scrollOffset + amount)
    self:render()
end

return ConsolePage
