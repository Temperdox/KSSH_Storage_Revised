local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")
local LogConsole = require("ui.components.log_console")

local ConsolePage = setmetatable({}, {__index = BasePage})
ConsolePage.__index = ConsolePage

function ConsolePage:new(context)
    local o = BasePage.new(self, context, "console")

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
    o.editingSearch = false  -- Track if user is editing search

    -- Available filters
    o.logTypes = {"all", "trace", "debug", "info", "warn", "error"}
    o.eventTypes = {"all"}

    -- Logo bitmap
    o.logoBitmap = nil
    o.logoX = 0
    o.logoY = 0
    o.logoWidth = 0
    o.logoHeight = 0
    o:buildLogoBitmap()

    -- Custom header - don't use base page header
    o.header:removeAll()
    o.header.height = 0  -- Hide the header panel completely
    o:buildCustomHeader()

    -- Build console UI
    o:buildConsoleUI()

    return o
end

function ConsolePage:buildLogoBitmap()
    local success, graphicModule = pcall(require, "ui.graphics.logo")
    if not success or not graphicModule or not graphicModule.sergal then
        return
    end

    local graphic = graphicModule.sergal
    self.logoWidth = graphic.width
    self.logoHeight = graphic.height

    local consoleHeight = self.height - 6  -- Adjusted for new layout
    self.logoX = math.floor((self.width - self.logoWidth) / 2)
    self.logoY = 5 + math.floor((consoleHeight - self.logoHeight) / 2)

    self.logoBitmap = {}
    for row = 1, self.logoHeight do
        self.logoBitmap[row] = {}
        for col = 1, self.logoWidth do
            self.logoBitmap[row][col] = false
        end
    end

    local idx = 1
    for row = 1, self.logoHeight do
        for col = 1, self.logoWidth do
            if idx <= #graphic.image then
                local binaryStr = graphic.image[idx]
                local hasPixel = binaryStr:find("1") ~= nil
                self.logoBitmap[row][col] = hasPixel
                idx = idx + 1
            end
        end
    end
end

function ConsolePage:buildCustomHeader()
    -- Draw header manually for better control
    self.header:removeAll()

    -- We'll render header in the render method instead
end

function ConsolePage:renderHeader()
    -- Draw header background (DON'T use clearLine - it overwrites scrollbar!)
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ", self.width - 1))  -- Reserve column for scrollbar

    -- Store clickable regions
    self.navButtons = {}

    -- Navigation bar
    local x = 2

    -- Console button (active)
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.lightGray)
    term.setTextColor(colors.black)
    term.write("[Console]")
    self.navButtons.console = {y = 1, x1 = x, x2 = x + 8}
    x = x + 10

    -- Net button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightBlue)
    term.write("[Net]")
    self.navButtons.net = {y = 1, x1 = x, x2 = x + 4}
    x = x + 6

    -- Stats button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.cyan)
    term.write("[Stats]")
    self.navButtons.stats = {y = 1, x1 = x, x2 = x + 6}
    x = x + 8

    -- Tests button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lime)
    term.write("[Tests]")
    self.navButtons.tests = {y = 1, x1 = x, x2 = x + 6}
    x = x + 8

    -- Settings button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.orange)
    term.write("[Settings]")
    self.navButtons.settings = {y = 1, x1 = x, x2 = x + 9}

    term.setBackgroundColor(colors.black)
end

function ConsolePage:renderFilters()
    -- Clear lines 2 and 3 (DON'T use clearLine - it overwrites scrollbar!)
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.black)
    term.write(string.rep(" ", self.width - 1))

    term.setCursorPos(1, 3)
    term.setBackgroundColor(colors.black)
    term.write(string.rep(" ", self.width - 1))

    -- Initialize clickable regions
    self.filterButtons = {}

    if self.width >= 40 then
        -- Wide terminal: full display
        term.setCursorPos(1, 3)
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.black)
        term.write("Search: ")

        local searchDisplay = self.searchQuery
        if #searchDisplay > 18 then
            searchDisplay = searchDisplay:sub(1, 15) .. "..."
        end
        searchDisplay = searchDisplay .. string.rep(" ", 20 - #searchDisplay)

        local searchX = 9
        term.setTextColor(colors.white)
        term.setBackgroundColor(self.editingSearch and colors.lightGray or colors.gray)
        term.write(searchDisplay)

        -- Store search box clickable region
        self.filterButtons.search = {y = 3, x1 = searchX, x2 = searchX + 19}

        -- Log type filter
        term.setCursorPos(30, 3)
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.black)
        term.write("Type: ")

        local filterX = 36
        term.setTextColor(colors.yellow)
        term.write("[" .. self.selectedLogType .. "]")

        -- Store filter button clickable region
        self.filterButtons.logType = {y = 3, x1 = filterX, x2 = filterX + #self.selectedLogType + 1}
    else
        -- Narrow terminal: compact display
        term.setCursorPos(1, 3)
        term.setTextColor(colors.lightGray)
        term.setBackgroundColor(colors.black)
        term.write("Q: ")

        local searchDisplay = self.searchQuery
        local maxLen = self.width - 10
        if #searchDisplay > maxLen then
            searchDisplay = searchDisplay:sub(1, maxLen - 3) .. "..."
        end
        searchDisplay = searchDisplay .. string.rep(" ", math.max(0, maxLen - #searchDisplay))

        local searchX = 4
        term.setTextColor(colors.white)
        term.setBackgroundColor(self.editingSearch and colors.lightGray or colors.gray)
        term.write(searchDisplay)

        -- Store search box clickable region
        self.filterButtons.search = {y = 3, x1 = searchX, x2 = searchX + maxLen - 1}

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.yellow)
        local filterText = " [" .. self.selectedLogType:sub(1, 1):upper() .. "]"
        local filterX = searchX + maxLen + 1
        term.write(filterText)

        -- Store filter button clickable region
        self.filterButtons.logType = {y = 3, x1 = filterX, x2 = filterX + #filterText - 1}
    end

    term.setBackgroundColor(colors.black)
end

function ConsolePage:buildConsoleUI()
    self.content:removeAll()

    -- Filter display will be rendered manually in renderFilters()

    -- Log console (move up by 2 rows - starts at row 1 relative to content)
    -- Height calculation: starts at abs row 3, ends before command line at height-3
    -- So height = (height - 3) - 3 + 1 = height - 5
    -- WIDTH: Use content width, not screen width!
    local consoleWidth = self.content.width
    local consoleHeight = self.height - 5

    self.logConsole = LogConsole:new(1, 1, consoleWidth, consoleHeight)
        :setLogo(self.logoBitmap, self.logoX, self.logoY, self.logoWidth, self.logoHeight)
        :setFilter(function(log)
            return self:filterLog(log)
        end)

    -- Update logs
    self:updateLogs()

    self.content:add(self.logConsole)

    -- Command line will be rendered manually in renderCommandLine()
end

function ConsolePage:updateLogs()
    if not self.logConsole then return end

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

    self.logConsole:setLogs(logs)
end

function ConsolePage:filterLog(log)
    -- Filter by log type
    if self.selectedLogType ~= "all" and log.level ~= self.selectedLogType then
        return false
    end

    -- Filter by search query
    if self.searchQuery ~= "" then
        local searchLower = self.searchQuery:lower()
        local messageLower = (log.message or ""):lower()
        local sourceLower = (log.source or ""):lower()

        if not messageLower:find(searchLower, 1, true) and not sourceLower:find(searchLower, 1, true) then
            return false
        end
    end

    return true
end

function ConsolePage:onEnter()
    -- Subscribe to log events
    self.eventBus:subscribe("log%..*", function(event, data)
        self:onNewLog(event, data)
    end)

    self:updateLogs()
    self:render()
end

function ConsolePage:onNewLog(event, data)
    -- Update logs when new log arrives
    self:updateLogs()
    -- Don't render here - the render loop will pick it up at 10 FPS
end

function ConsolePage:executeCommand()
    if self.currentCommand == "" then return end

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

    self.currentCommand = ""
    self:updateLogs()
    self:render()
end

function ConsolePage:handleInput(event, param1, param2, param3)
    if event == "term_resize" then
        self.width, self.height = term.getSize()

        -- Rebuild UI components with new dimensions
        self.root:setSize(self.width, self.height)
        self.header:setSize(self.width, 1)
        self.content:setSize(self.width, self.height - 2)
        self.footer:setPosition(1, self.height)
        self.footer:setSize(self.width, 1)

        -- Rebuild logo bitmap with new positioning
        self:buildLogoBitmap()

        -- Rebuild console UI
        self:buildConsoleUI()

        -- Rebuild header
        self.header:removeAll()
        self:buildCustomHeader()

        self:render()
        return

    elseif event == "key" then
        local key = param1

        -- Handle search editing mode
        if self.editingSearch then
            if key == keys.escape then
                self.editingSearch = false
                self:render()
                return
            elseif key == keys.enter then
                self.editingSearch = false
                self:render()
                return
            elseif key == keys.backspace then
                self.searchQuery = self.searchQuery:sub(1, -2)
                self:render()
                return
            end
            return  -- Consume all key events in search mode
        end

        if key == keys.f1 then
            self:showHelp()
            self:render()
            return

        elseif key == keys.enter then
            self:executeCommand()
            return

        elseif key == keys.backspace then
            self.currentCommand = self.currentCommand:sub(1, -2)
            self:render()
            return

        elseif key == keys.up then
            if #self.currentCommand == 0 then
                -- Navigate history
                if self.historyIndex > 1 then
                    self.historyIndex = self.historyIndex - 1
                    self.currentCommand = self.commandHistory[self.historyIndex] or ""
                    self:render()
                end
            else
                -- Scroll
                if self.logConsole then
                    self.logConsole:handleScroll(-1, 1, 2)
                    self:render()
                end
            end
            return

        elseif key == keys.down then
            if #self.currentCommand == 0 then
                -- Navigate history
                if self.historyIndex <= #self.commandHistory then
                    self.historyIndex = self.historyIndex + 1
                    self.currentCommand = self.commandHistory[self.historyIndex] or ""
                    self:render()
                end
            else
                -- Scroll
                if self.logConsole then
                    self.logConsole:handleScroll(1, 1, 2)
                    self:render()
                end
            end
            return

        elseif key == keys.pageUp then
            if self.logConsole then
                for i = 1, 10 do
                    self.logConsole:handleScroll(-1, 1, 2)
                end
                self:render()
            end
            return

        elseif key == keys.pageDown then
            if self.logConsole then
                for i = 1, 10 do
                    self.logConsole:handleScroll(1, 1, 2)
                end
                self:render()
            end
            return

        elseif key == keys.home then
            if self.logConsole then
                self.logConsole.scrollOffset = 0
                self.logConsole.autoScroll = false
                self:render()
            end
            return

        elseif key == keys["end"] then
            if self.logConsole then
                self.logConsole:scrollToBottom()
                self:render()
            end
            return

        elseif key == keys.tab then
            self:autocomplete()
            self:render()
            return
        end

    elseif event == "char" then
        -- Route input to search or command based on mode
        if self.editingSearch then
            self.searchQuery = self.searchQuery .. param1
        else
            self.currentCommand = self.currentCommand .. param1
        end
        self:render()
        return

    elseif event == "mouse_click" then
        local button, x, y = param1, param2, param3

        -- Check navigation button clicks
        if self.navButtons then
            if self.navButtons.console and y == self.navButtons.console.y and
               x >= self.navButtons.console.x1 and x <= self.navButtons.console.x2 then
                -- Already on console page
                return
            elseif self.navButtons.net and y == self.navButtons.net.y and
               x >= self.navButtons.net.x1 and x <= self.navButtons.net.x2 then
                if self.context.router then
                    self.context.router:navigate("net")
                end
                return
            elseif self.navButtons.stats and y == self.navButtons.stats.y and
                   x >= self.navButtons.stats.x1 and x <= self.navButtons.stats.x2 then
                if self.context.router then
                    self.context.router:navigate("stats")
                end
                return
            elseif self.navButtons.tests and y == self.navButtons.tests.y and
                   x >= self.navButtons.tests.x1 and x <= self.navButtons.tests.x2 then
                if self.context.router then
                    self.context.router:navigate("tests")
                end
                return
            elseif self.navButtons.settings and y == self.navButtons.settings.y and
                   x >= self.navButtons.settings.x1 and x <= self.navButtons.settings.x2 then
                if self.context.router then
                    self.context.router:navigate("settings")
                end
                return
            end
        end

        -- Check filter button clicks
        if self.filterButtons then
            -- Search box click - toggle editing mode
            if self.filterButtons.search and y == self.filterButtons.search.y and
               x >= self.filterButtons.search.x1 and x <= self.filterButtons.search.x2 then
                self.editingSearch = not self.editingSearch
                if self.editingSearch then
                    self.searchQuery = ""  -- Clear search when starting to edit
                end
                self:render()
                return
            end

            -- Log type filter click - cycle through types
            if self.filterButtons.logType and y == self.filterButtons.logType.y and
               x >= self.filterButtons.logType.x1 and x <= self.filterButtons.logType.x2 then
                -- Find current index and cycle to next
                local currentIndex = 1
                for i, logType in ipairs(self.logTypes) do
                    if logType == self.selectedLogType then
                        currentIndex = i
                        break
                    end
                end
                -- Cycle to next type
                currentIndex = (currentIndex % #self.logTypes) + 1
                self.selectedLogType = self.logTypes[currentIndex]
                self:render()
                return
            end
        end
    end

    BasePage.handleInput(self, event, param1, param2, param3)
end

function ConsolePage:autocomplete()
    if self.context.commandFactory then
        local suggestions = self.context.commandFactory:getAutocomplete(self.currentCommand)
        if suggestions and #suggestions == 1 then
            self.currentCommand = suggestions[1]
        elseif suggestions and #suggestions > 1 then
            -- Show suggestions in log
            self.logger:info("Autocomplete", table.concat(suggestions, ", "))
        end
    end
end

function ConsolePage:showHelp()
    self.logger:info("Help", "Navigation: Click links or use keyboard shortcuts")
    self.logger:info("Help", "Scrolling: PgUp/PgDown, Home/End, Mouse Wheel")
    self.logger:info("Help", "Commands: Type and press Enter, Tab for autocomplete")
    self.logger:info("Help", "History: Up/Down arrows (when command line is empty)")
end

function ConsolePage:renderCommandLine()
    local cmdY = self.height - 3

    term.setCursorPos(1, cmdY)
    term.setBackgroundColor(colors.black)
    term.write(string.rep(" ", self.width - 1))  -- Don't overwrite scrollbar!

    term.setCursorPos(1, cmdY)  -- Reset cursor position
    term.setTextColor(colors.lime)
    term.write("> ")

    term.setTextColor(colors.white)
    local cmdDisplay = self.currentCommand
    local maxCmdLen = self.width - 3

    if #cmdDisplay > maxCmdLen then
        cmdDisplay = "..." .. cmdDisplay:sub(#cmdDisplay - maxCmdLen + 4)
    end

    term.write(cmdDisplay)

    -- Store cursor position for later (after all rendering is done)
    self.cursorX = math.min(3 + #self.currentCommand, self.width)
    self.cursorY = cmdY
end

function ConsolePage:render()
    term.setBackgroundColor(colors.black)
    -- DON'T clear screen every frame - causes flickering!
    -- Each render method clears its own area

    -- Update and render framework components first
    -- NOTE: updateLogs() is already called by onNewLog event handler
    -- Don't update every frame - only when logs change
    -- self:updateLogs()

    UI.update()
    self.root:render()
    UI.renderWindows()

    -- Then render manual overlays on top
    self:renderHeader()
    self:renderFilters()
    self:renderCommandLine()
    self:renderFooter()

    -- IMPORTANT: Set cursor position LAST (after all rendering)
    if self.editingSearch then
        -- Position cursor in search box
        local searchX = self.width >= 40 and 9 or 4
        term.setCursorPos(searchX + #self.searchQuery, 3)
    else
        -- Position cursor at command line (after "> ")
        if self.cursorX and self.cursorY then
            term.setCursorPos(self.cursorX, self.cursorY)
        end
    end
    term.setCursorBlink(true)
end

function ConsolePage:renderFooter()
    local logCount = #self.printBuffer
    if self.logger and self.logger.ringBuffer then
        logCount = logCount + #self.logger.ringBuffer
    end

    local scrollMode = (self.logConsole and self.logConsole.autoScroll) and "AUTO" or "MANUAL"

    term.setCursorPos(1, self.height)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ", self.width - 1))  -- Don't overwrite scrollbar!
    term.setCursorPos(1, self.height)  -- Reset cursor
    term.setTextColor(colors.white)

    if self.width >= 40 then
        -- Wide terminal: full status
        local status = string.format(
            "Logs: %d | Scroll: %s | F1: Help",
            logCount,
            scrollMode
        )
        term.write(status)
    else
        -- Narrow terminal: compact status
        local status = string.format(
            "L:%d | %s",
            logCount,
            scrollMode:sub(1, 1)
        )
        term.write(status)
    end

    term.setBackgroundColor(colors.black)
end

return ConsolePage
