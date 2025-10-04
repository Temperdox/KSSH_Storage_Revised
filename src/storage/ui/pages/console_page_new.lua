local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")
local LogConsole = require("ui.components.log_console")

local ConsolePage = setmetatable({}, {__index = BasePage})
ConsolePage.__index = ConsolePage

function ConsolePage:new(context)
    local o = BasePage.new(self, context, "console")

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

    -- Logo bitmap
    o.logoBitmap = nil
    o.logoX = 0
    o.logoY = 0
    o.logoWidth = 0
    o.logoHeight = 0
    o:buildLogoBitmap()

    -- Custom header - don't use base page header
    o.header:removeAll()
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
    -- Title
    local title = UI.label("STORAGE CONSOLE", 2, 1)
        :fg(colors.white)
        :bg(colors.gray)

    self.header:add(title)

    -- Navigation links
    local navPanel = UI.panel(self.width - 35, 1, 35, 1)
        :bg(colors.gray)

    local navLayout = UI.flexLayout("row", "end", "center"):setGap(2)
    navPanel:setLayout(navLayout)

    local netBtn = UI.label("Net", 0, 0)
        :fg(colors.cyan)
        :bg(colors.gray)
        :onClick(function()
            self.context.router:navigate("net")
        end)

    local statsBtn = UI.label("Stats", 0, 0)
        :fg(colors.yellow)
        :bg(colors.gray)
        :onClick(function()
            self.context.router:navigate("stats")
        end)

    local testsBtn = UI.label("Tests", 0, 0)
        :fg(colors.lime)
        :bg(colors.gray)
        :onClick(function()
            self.context.router:navigate("tests")
        end)

    local settingsBtn = UI.label("Settings", 0, 0)
        :fg(colors.orange)
        :bg(colors.gray)
        :onClick(function()
            self.context.router:navigate("settings")
        end)

    navPanel:add(netBtn)
    navPanel:add(statsBtn)
    navPanel:add(testsBtn)
    navPanel:add(settingsBtn)

    self.header:add(navPanel)
end

function ConsolePage:buildConsoleUI()
    self.content:removeAll()

    -- Search and filters row
    local filterPanel = UI.panel(1, 1, self.width, 1)
        :bg(colors.black)

    local searchLabel = UI.label("Search:", 1, 0)
        :fg(colors.lightGray)

    local searchBox = UI.panel(9, 0, 20, 1)
        :bg(colors.gray)

    local searchText = UI.label(self.searchQuery, 1, 0)
        :fg(colors.white)
        :bg(colors.gray)

    searchBox:add(searchText)

    local typeLabel = UI.label("Type: [" .. self.selectedLogType .. "]", 31, 0)
        :fg(colors.lightGray)

    filterPanel:add(searchLabel)
    filterPanel:add(searchBox)
    filterPanel:add(typeLabel)

    self.content:add(filterPanel)

    -- Log console
    self.logConsole = LogConsole:new(1, 2, self.width, self.height - 6)
        :setLogo(self.logoBitmap, self.logoX, self.logoY, self.logoWidth, self.logoHeight)
        :setFilter(function(log)
            return self:filterLog(log)
        end)

    -- Update logs
    self:updateLogs()

    self.content:add(self.logConsole)

    -- Command line
    local cmdLabel = UI.label("> ", 1, self.height - 3)
        :fg(colors.lime)

    local cmdBox = UI.panel(3, self.height - 3, self.width - 3, 1)
        :bg(colors.black)

    local cmdText = UI.label(self.currentCommand .. "_", 0, 0)
        :fg(colors.white)

    cmdBox:add(cmdText)

    self.content:add(cmdLabel)
    self.content:add(cmdBox)

    self.cmdText = cmdText
    self.searchText = searchText
    self.typeLabel = typeLabel
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
    self.cmdText:setText(self.currentCommand .. "_")
    self:updateLogs()
    self:render()
end

function ConsolePage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1

        if key == keys.f1 then
            self:showHelp()
            self:render()
            return

        elseif key == keys.enter then
            self:executeCommand()
            return

        elseif key == keys.backspace then
            self.currentCommand = self.currentCommand:sub(1, -2)
            self.cmdText:setText(self.currentCommand .. "_")
            self:render()
            return

        elseif key == keys.up then
            if #self.currentCommand == 0 then
                -- Navigate history
                if self.historyIndex > 1 then
                    self.historyIndex = self.historyIndex - 1
                    self.currentCommand = self.commandHistory[self.historyIndex] or ""
                    self.cmdText:setText(self.currentCommand .. "_")
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
                    self.cmdText:setText(self.currentCommand .. "_")
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
        self.currentCommand = self.currentCommand .. param1
        self.cmdText:setText(self.currentCommand .. "_")
        self:render()
        return
    end

    BasePage.handleInput(self, event, param1, param2, param3)
end

function ConsolePage:autocomplete()
    if self.context.commandFactory then
        local suggestions = self.context.commandFactory:getAutocomplete(self.currentCommand)
        if suggestions and #suggestions == 1 then
            self.currentCommand = suggestions[1]
            self.cmdText:setText(self.currentCommand .. "_")
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

function ConsolePage:render()
    term.setBackgroundColor(colors.black)
    term.clear()

    self:updateLogs()
    self:updateFooter()

    UI.update()
    self.root:render()
    UI.renderWindows()

    -- Set cursor to end of command line
    term.setCursorPos(3 + #self.currentCommand, self.height - 3)
    term.setCursorBlink(true)
end

function ConsolePage:updateFooter()
    local logCount = #self.printBuffer
    if self.logger and self.logger.ringBuffer then
        logCount = logCount + #self.logger.ringBuffer
    end

    local scrollMode = (self.logConsole and self.logConsole.autoScroll) and "AUTO" or "MANUAL"
    local status = string.format(
        "Logs: %d | Scroll: %s | F1: Help",
        logCount,
        scrollMode
    )

    self:setFooter(status)
end

return ConsolePage
