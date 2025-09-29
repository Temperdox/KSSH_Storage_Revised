-- modules/terminal.lua
-- Terminal UI with command interface

local Terminal = {}
Terminal.__index = Terminal

function Terminal:new(appName, version, logger)
    local self = setmetatable({}, Terminal)
    self.appName = appName
    self.version = version
    self.logger = logger
    self.commands = {}
    self.commandHistory = {}
    self.historyIndex = 0
    self.currentInput = ""
    self.cursorPos = 1
    self.scrollOffset = 0
    self.logLines = {}
    self.maxLogLines = 50  -- Reduced from 100 to prevent lag
    self.running = true
    self.autoScroll = true  -- Auto-scroll by default

    -- Register default commands
    self:registerDefaultCommands()

    -- Subscribe to logger
    logger:addListener(function(entry)
        self:addLogLine(entry)
    end)

    return self
end

function Terminal:registerCommand(name, callback, description, autocomplete)
    self.commands[name] = {
        callback = callback,
        description = description or "No description",
        autocomplete = autocomplete or function() return {} end
    }
end

function Terminal:registerDefaultCommands()
    self:registerCommand("help", function(args)
        self.logger:info("Available commands:")
        for name, cmd in pairs(self.commands) do
            self.logger:info("  " .. name .. " - " .. cmd.description)
        end
    end, "Show this help message")

    self:registerCommand("clear", function(args)
        self.logLines = {}
        self.scrollOffset = 0
    end, "Clear the console")

    self:registerCommand("autoscroll", function(args)
        if args[1] == "on" then
            self.autoScroll = true
            self.logger:info("Auto-scroll enabled")
        elseif args[1] == "off" then
            self.autoScroll = false
            self.logger:info("Auto-scroll disabled")
        else
            self.autoScroll = not self.autoScroll
            self.logger:info("Auto-scroll " .. (self.autoScroll and "enabled" or "disabled"))
        end
    end, "Toggle auto-scroll (on/off)")

    self:registerCommand("status", function(args)
        local statuses = _G.processManager:getAllStatus()
        self.logger:info("Process Status:")
        for name, status in pairs(statuses) do
            local statusStr = string.format("  %s [PID: %s] - %s",
                    name,
                    status.pid or "N/A",
                    status.status)
            if status.status == "running" then
                self.logger:success(statusStr)
            elseif status.status == "crashed" then
                self.logger:error(statusStr .. " (" .. tostring(status.error) .. ")")
            else
                self.logger:info(statusStr)
            end
        end
    end, "Show process status")

    self:registerCommand("restart", function(args)
        if args[1] then
            local ok, err = _G.processManager:restart(args[1])
            if ok then
                self.logger:success("Process " .. args[1] .. " restarted")
            else
                self.logger:error("Failed to restart " .. args[1] .. ": " .. tostring(err))
            end
        else
            self.logger:error("Usage: restart <process_name>")
        end
    end, "Restart a process", function(partial)
        local matches = {}
        for name, _ in pairs(_G.processManager.processes) do
            if name:find("^" .. partial) then
                table.insert(matches, name)
            end
        end
        return matches
    end)

    self:registerCommand("reload", function(args)
        _G.eventBus:emit("storage:reload")
        self.logger:info("Reload requested")
    end, "Reload storage data")

    self:registerCommand("sort", function(args)
        _G.eventBus:emit("storage:sort", true)
        self.logger:info("Sort requested")
    end, "Sort all storage")

    self:registerCommand("reformat", function(args)
        _G.eventBus:emit("storage:reformat")
        self.logger:info("Reformat requested")
    end, "Reformat storage layout")

    self:registerCommand("exit", function(args)
        self.running = false
        os.queueEvent("terminate")
    end, "Exit the program")
end

function Terminal:addLogLine(entry)
    local line = {
        text = entry.message,
        color = entry.level.color,
        timestamp = entry.timestamp
    }

    table.insert(self.logLines, line)

    -- Keep only the last maxLogLines entries
    while #self.logLines > self.maxLogLines do
        table.remove(self.logLines, 1)
        -- Adjust scroll offset if we removed lines above current view
        if self.scrollOffset > 0 then
            self.scrollOffset = self.scrollOffset - 1
        end
    end

    -- Auto-scroll to bottom if enabled
    if self.autoScroll then
        local w, h = term.getSize()
        local consoleHeight = h - 4
        self.scrollOffset = math.max(0, #self.logLines - consoleHeight)
    end
end

function Terminal:drawHeader()
    local w, h = term.getSize()

    -- Draw header background
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()

    -- App name and version
    term.setCursorPos(2, 1)
    term.write(self.appName .. " v" .. self.version)

    -- Log count indicator
    term.setCursorPos(w - 15, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    term.write("[" .. #self.logLines .. "/" .. self.maxLogLines .. "]")

    -- Auto-scroll indicator
    if self.autoScroll then
        term.setTextColor(colors.lime)
        term.write(" [AS]")
    end

    term.setBackgroundColor(colors.black)
end

function Terminal:drawConsole()
    local w, h = term.getSize()
    local consoleHeight = h - 4

    -- Clear console area
    for y = 2, h - 2 do
        term.setCursorPos(1, y)
        term.clearLine()
    end

    -- Draw log lines
    local startIdx = self.scrollOffset + 1
    local endIdx = math.min(startIdx + consoleHeight - 1, #self.logLines)

    for i = startIdx, endIdx do
        local line = self.logLines[i]
        if line then
            local y = 2 + (i - startIdx)
            term.setCursorPos(1, y)
            term.setTextColor(line.color)

            -- Truncate long lines to prevent wrapping
            local maxWidth = w - 1
            local displayText = line.text
            if #displayText > maxWidth then
                displayText = displayText:sub(1, maxWidth - 3) .. "..."
            end
            term.write(displayText)
        end
    end

    -- Draw scroll bar if needed
    if #self.logLines > consoleHeight then
        local barHeight = math.max(1, math.floor(consoleHeight * consoleHeight / #self.logLines))
        local barPos = math.floor((self.scrollOffset / (#self.logLines - consoleHeight)) * (consoleHeight - barHeight))

        for y = 2, h - 2 do
            term.setCursorPos(w, y)
            if y >= 2 + barPos and y < 2 + barPos + barHeight then
                term.setBackgroundColor(colors.gray)
            else
                term.setBackgroundColor(colors.black)
            end
            term.write(" ")
        end
        term.setBackgroundColor(colors.black)
    end

    term.setTextColor(colors.white)
end

function Terminal:drawInputArea()
    local w, h = term.getSize()

    -- Draw separator
    term.setCursorPos(1, h - 1)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", w))

    -- Draw input prompt
    term.setCursorPos(1, h)
    term.setTextColor(colors.yellow)
    term.write("> ")
    term.setTextColor(colors.white)

    -- Draw current input (handle long input with scrolling)
    local maxInputWidth = w - 3
    local inputDisplay = self.currentInput

    if #self.currentInput > maxInputWidth then
        -- Scroll the input to keep cursor visible
        local scrollStart = math.max(1, self.cursorPos - maxInputWidth + 1)
        inputDisplay = self.currentInput:sub(scrollStart, scrollStart + maxInputWidth - 1)
    end

    term.write(inputDisplay)

    -- Position cursor
    local cursorX = 3 + math.min(self.cursorPos - 1, maxInputWidth - 1)
    term.setCursorPos(cursorX, h)
    term.setCursorBlink(true)
end

function Terminal:draw()
    term.clear()
    self:drawHeader()
    self:drawConsole()
    self:drawInputArea()
end

function Terminal:handleKey(key)
    if key == keys.enter then
        if self.currentInput:len() > 0 then
            self:executeCommand(self.currentInput)
            table.insert(self.commandHistory, self.currentInput)
            -- Limit command history
            while #self.commandHistory > 50 do
                table.remove(self.commandHistory, 1)
            end
            self.historyIndex = #self.commandHistory + 1
            self.currentInput = ""
            self.cursorPos = 1
        end
    elseif key == keys.backspace then
        if self.cursorPos > 1 then
            self.currentInput = self.currentInput:sub(1, self.cursorPos - 2) ..
                    self.currentInput:sub(self.cursorPos)
            self.cursorPos = self.cursorPos - 1
        end
    elseif key == keys.delete then
        if self.cursorPos <= self.currentInput:len() then
            self.currentInput = self.currentInput:sub(1, self.cursorPos - 1) ..
                    self.currentInput:sub(self.cursorPos + 1)
        end
    elseif key == keys.left then
        if self.cursorPos > 1 then
            self.cursorPos = self.cursorPos - 1
        end
    elseif key == keys.right then
        if self.cursorPos <= self.currentInput:len() then
            self.cursorPos = self.cursorPos + 1
        end
    elseif key == keys.up then
        if self.historyIndex > 1 then
            self.historyIndex = self.historyIndex - 1
            self.currentInput = self.commandHistory[self.historyIndex]
            self.cursorPos = self.currentInput:len() + 1
        end
    elseif key == keys.down then
        if self.historyIndex < #self.commandHistory then
            self.historyIndex = self.historyIndex + 1
            self.currentInput = self.commandHistory[self.historyIndex]
            self.cursorPos = self.currentInput:len() + 1
        elseif self.historyIndex == #self.commandHistory then
            self.historyIndex = #self.commandHistory + 1
            self.currentInput = ""
            self.cursorPos = 1
        end
    elseif key == keys.pageUp then
        self.autoScroll = false
        self.scrollOffset = math.max(0, self.scrollOffset - 5)
    elseif key == keys.pageDown then
        local w, h = term.getSize()
        local maxScroll = math.max(0, #self.logLines - (h - 4))
        self.scrollOffset = math.min(maxScroll, self.scrollOffset + 5)
        -- Re-enable autoscroll if we scroll to bottom
        if self.scrollOffset >= maxScroll then
            self.autoScroll = true
        end
    elseif key == keys.home then
        self.autoScroll = false
        self.scrollOffset = 0
    elseif key == keys["end"] then
        local w, h = term.getSize()
        self.scrollOffset = math.max(0, #self.logLines - (h - 4))
        self.autoScroll = true
    elseif key == keys.tab then
        self:handleAutocomplete()
    end
end

function Terminal:handleAutocomplete()
    local parts = {}
    for part in self.currentInput:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then
        return
    end

    local cmdName = parts[1]

    if #parts == 1 then
        -- Autocomplete command name
        local matches = {}
        for name, _ in pairs(self.commands) do
            if name:find("^" .. cmdName) then
                table.insert(matches, name)
            end
        end

        if #matches == 1 then
            self.currentInput = matches[1] .. " "
            self.cursorPos = self.currentInput:len() + 1
        elseif #matches > 1 then
            self.logger:info("Matches: " .. table.concat(matches, ", "))
        end
    else
        -- Autocomplete command arguments
        local cmd = self.commands[cmdName]
        if cmd and cmd.autocomplete then
            local partial = parts[#parts]
            local matches = cmd.autocomplete(partial)

            if #matches == 1 then
                parts[#parts] = matches[1]
                self.currentInput = table.concat(parts, " ")
                self.cursorPos = self.currentInput:len() + 1
            elseif #matches > 1 then
                self.logger:info("Matches: " .. table.concat(matches, ", "))
            end
        end
    end
end

function Terminal:handleChar(char)
    self.currentInput = self.currentInput:sub(1, self.cursorPos - 1) ..
            char ..
            self.currentInput:sub(self.cursorPos)
    self.cursorPos = self.cursorPos + 1
end

function Terminal:executeCommand(input)
    self.logger:info("> " .. input)

    local parts = {}
    for part in input:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then
        return
    end

    local cmdName = table.remove(parts, 1)
    local cmd = self.commands[cmdName]

    if cmd then
        local ok, err = pcall(cmd.callback, parts)
        if not ok then
            self.logger:error("Command error: " .. tostring(err))
        end
    else
        self.logger:error("Unknown command: " .. cmdName .. " (type 'help' for commands)")
    end
end

function Terminal:run()
    self:draw()

    local drawTimer = os.startTimer(0.1)

    while self.running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "process:stop:terminal" then
            self.running = false
        elseif event == "timer" and p1 == drawTimer then
            self:draw()
            drawTimer = os.startTimer(0.1)
        elseif event == "key" then
            self:handleKey(p1)
        elseif event == "char" then
            self:handleChar(p1)
        elseif event == "mouse_scroll" then
            local direction = p1
            self.autoScroll = false  -- Disable auto-scroll when manually scrolling
            if direction == -1 then
                self.scrollOffset = math.max(0, self.scrollOffset - 1)
            else
                local w, h = term.getSize()
                local maxScroll = math.max(0, #self.logLines - (h - 4))
                self.scrollOffset = math.min(maxScroll, self.scrollOffset + 1)
                -- Re-enable autoscroll if we scroll to bottom
                if self.scrollOffset >= maxScroll then
                    self.autoScroll = true
                end
            end
        end
    end

    term.setCursorBlink(false)
end

return Terminal