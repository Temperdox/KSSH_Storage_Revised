-- UI system for turtle with console and controls
local UIManager = {}

-- Constants
local VERSION = "1.2.0"
local TITLE = "KSSH Turtle Crafter v" .. VERSION

-- Color scheme (modern dark theme)
local COLORS = {
    background = colors.black,
    primary = colors.cyan,
    secondary = colors.lightBlue,
    success = colors.lime,
    warning = colors.orange,
    error = colors.red,
    text = colors.white,
    textDim = colors.lightGray,
    border = colors.gray,
    buttonActive = colors.cyan,   -- used to tint active bracket text
    buttonInactive = colors.gray
}

function UIManager.new()
    local self = {
        term = term.current(),
        width = 0,
        height = 0,
        consoleLines = {},
        maxConsoleLines = 100,
        consoleScroll = 0,
        connectionStatus = "DISCONNECTED",
        computerID = nil,
        buttons = {},
        activeButton = nil,
        stats = {
            crafted = 0,
            recipes = 0,
            uptime = 0
        },
        executor = nil,
        bridge = nil,
        services = {},
        recipeUI = nil,  -- Recipe save mode UI
        recipeUIActive = false
    }

    setmetatable(self, {__index = UIManager})
    return self
end

function UIManager:init(executor, bridge, services)
    self.executor = executor
    self.bridge = bridge
    self.services = services

    -- Get terminal size
    self.width, self.height = self.term.getSize()

    -- Initialize recipe UI
    if services.recipes then
        local RecipeUI = require("ui.recipe_ui")
        self.recipeUI = RecipeUI.new(services.recipes)
    end

    -- Initialize buttons
    self:initButtons()

    -- Clear screen
    self:clear()

    -- Draw initial UI
    self:draw()

    -- Start UI update loop
    if self.executor then
        self.executor:submitRecurring(function()
            self:updateStatus()
            if not self.recipeUIActive then
                self:draw()
            elseif self.recipeUI and self.recipeUI.active then
                self.recipeUI:draw()
            end
        end, 1, "ui_update", 3)
    end

    return self
end

function UIManager:initButtons()
    -- Store Recipe button
    self.buttons.storeRecipe = {
        x = 2,
        y = self.height - 3,   -- tightened a bit (we only draw one text line)
        width = 16,
        height = 3,
        label = "Store Recipe",
        active = true,
        color = COLORS.primary,
        action = function() self:onStoreRecipe() end
    }

    -- Clear Console button
    self.buttons.clearConsole = {
        x = 22,
        y = self.height - 3,
        width = 14,
        height = 3,
        label = "Clear Log",
        active = true,
        color = COLORS.secondary,
        action = function() self:clearConsole() end
    }

    -- Status button
    self.buttons.status = {
        x = 38,
        y = self.height - 3,
        width = 12,
        height = 3,
        label = "Status",
        active = true,
        color = COLORS.secondary,
        action = function() self:showStatus() end
    }
end

function UIManager:clear()
    self.term.setBackgroundColor(COLORS.background)
    self.term.clear()
end

function UIManager:draw()
    -- Draw header
    self:drawHeader()

    -- Draw console area
    self:drawConsole()

    -- Draw buttons
    self:drawButtons()

    -- Draw status bar
    self:drawStatusBar()
end

function UIManager:drawHeader()
    -- Header background
    self.term.setCursorPos(1, 1)
    self.term.setBackgroundColor(COLORS.primary)
    self.term.setTextColor(COLORS.background)
    self.term.clearLine()

    -- Center the title
    local titleX = math.floor((self.width - #TITLE) / 2) + 1
    self.term.setCursorPos(titleX, 1)
    self.term.write(TITLE)

    -- Draw separator line
    self.term.setCursorPos(1, 2)
    self.term.setBackgroundColor(COLORS.border)
    self.term.clearLine()
end

function UIManager:drawConsole()
    -- Console area (from row 3 to height-5)
    local consoleTop = 3
    local consoleBottom = self.height - 5
    local consoleHeight = consoleBottom - consoleTop + 1

    -- Console background
    self.term.setBackgroundColor(COLORS.background)
    self.term.setTextColor(COLORS.text)

    -- Draw console border/header
    for y = consoleTop, consoleBottom do
        self.term.setCursorPos(1, y)
        self.term.setBackgroundColor(COLORS.background)
        if y == consoleTop then
            self.term.setBackgroundColor(COLORS.border)
            self.term.clearLine()
            self.term.setTextColor(COLORS.textDim)
            self.term.write(" Console Output")
        else
            self.term.clearLine()
            local lineIndex = (y - consoleTop) + self.consoleScroll
            if lineIndex > 0 and lineIndex <= #self.consoleLines then
                local line = self.consoleLines[lineIndex]
                if line then
                    if line:find("%[ERROR%]") then
                        self.term.setTextColor(COLORS.error)
                    elseif line:find("%[WARN%]") then
                        self.term.setTextColor(COLORS.warning)
                    elseif line:find("%[INFO%]") then
                        self.term.setTextColor(COLORS.secondary)
                    elseif line:find("Success") or line:find("Complete") then
                        self.term.setTextColor(COLORS.success)
                    else
                        self.term.setTextColor(COLORS.text)
                    end

                    local displayLine = line
                    if #displayLine > self.width - 2 then
                        displayLine = displayLine:sub(1, self.width - 5) .. "..."
                    end
                    self.term.setCursorPos(2, y)
                    self.term.write(displayLine)
                end
            end
        end
    end

    -- Scroll indicator
    if #self.consoleLines > consoleHeight - 1 then
        self.term.setCursorPos(self.width - 1, consoleTop + 1)
        self.term.setBackgroundColor(COLORS.border)
        self.term.setTextColor(COLORS.textDim)

        local scrollBarHeight = consoleHeight - 2
        local scrollPos = math.floor((self.consoleScroll / math.max(1, #self.consoleLines - consoleHeight + 1)) * scrollBarHeight)

        for i = 1, scrollBarHeight do
            self.term.setCursorPos(self.width, consoleTop + i)
            if i == scrollPos + 1 then
                self.term.setBackgroundColor(COLORS.primary)
                self.term.write(" ")
            else
                self.term.setBackgroundColor(COLORS.border)
                self.term.write(" ")
            end
        end
    end
end

function UIManager:drawButtons()
    for _, button in pairs(self.buttons) do
        self:drawButton(button)
    end
end

-- *** simplified bracket-style buttons ***
function UIManager:drawButton(button)
    -- Clear the button area to background (so no large boxes remain)
    self.term.setBackgroundColor(COLORS.background)
    for y = button.y, button.y + button.height - 1 do
        self.term.setCursorPos(button.x, y)
        self.term.clearLine()
    end

    -- Compose bracketed label
    local label = "[" .. button.label .. "]"
    local labelY = button.y + math.floor(button.height / 2)

    -- Clamp so brackets never draw outside the allocated width
    local maxLen = math.max(1, button.width)
    if #label > maxLen then
        label = "[" .. button.label:sub(1, maxLen - 2) .. "]"
    end
    local labelX = button.x + math.floor((button.width - #label) / 2)

    -- Choose color: inactive dim, active bright; pressed uses accent
    local color = button.active and COLORS.text or COLORS.textDim
    if self.activeButton == button then color = COLORS.buttonActive end

    self.term.setCursorPos(labelX, labelY)
    self.term.setTextColor(color)
    self.term.write(label)
end

function UIManager:drawStatusBar()
    -- Status bar at bottom
    self.term.setCursorPos(1, self.height)
    self.term.setBackgroundColor(COLORS.border)
    self.term.clearLine()

    -- Connection status
    local statusColor = COLORS.error
    local statusIcon = "○"

    if self.connectionStatus == "CONNECTED" then
        statusColor = COLORS.success
        statusIcon = "●"
    elseif self.connectionStatus == "CONNECTING" then
        statusColor = COLORS.warning
        statusIcon = "◐"
    end

    self.term.setCursorPos(2, self.height)
    self.term.setTextColor(statusColor)
    self.term.write(statusIcon .. " ")
    self.term.setTextColor(COLORS.text)
    self.term.write(self.connectionStatus)

    if self.computerID then
        self.term.write(" [PC:" .. self.computerID .. "]")
    end

    local statsText = string.format("Crafted:%d Recipes:%d",
            self.stats.crafted, self.stats.recipes)
    self.term.setCursorPos(self.width - #statsText - 1, self.height)
    self.term.setTextColor(COLORS.textDim)
    self.term.write(statsText)
end

function UIManager:addConsoleMessage(message)
    local time = os.date("%H:%M:%S")
    local msgStr = tostring(message)

    -- Truncate very long messages to prevent UI overflow
    local maxMsgLength = self.width - 15  -- Leave room for timestamp
    if #msgStr > maxMsgLength then
        msgStr = msgStr:sub(1, maxMsgLength - 3) .. "..."
    end

    local fullMessage = "[" .. time .. "] " .. msgStr
    table.insert(self.consoleLines, fullMessage)

    -- Keep console history limited
    while #self.consoleLines > self.maxConsoleLines do
        table.remove(self.consoleLines, 1)
    end

    -- Auto-scroll to bottom
    local consoleHeight = self.height - 8
    if #self.consoleLines > consoleHeight then
        self.consoleScroll = #self.consoleLines - consoleHeight + 1
    end
end

function UIManager:clearConsole()
    self.consoleLines = {}
    self.consoleScroll = 0
    self:addConsoleMessage("Console cleared")
    self:draw()
end

function UIManager:updateStatus()
    if self.bridge then
        local s = self.bridge:getStats()
        if s.computerId then
            self.connectionStatus = "CONNECTED"
            self.computerID = s.computerId
        else
            self.connectionStatus = "DISCONNECTED"
            self.computerID = nil
        end
    end
    if self.services.crafter then
        self.stats.crafted = self.services.crafter.stats.crafted or 0
    end
    if self.services.recipes then
        self.stats.recipes = self.services.recipes.stats.learned or 0
    end
end

function UIManager:onStoreRecipe()
    if not self.recipeUI then
        self:addConsoleMessage("[ERROR] Recipe UI not available")
        return
    end

    self:enterRecipeMode()
end

function UIManager:enterRecipeMode(itemName)
    if not self.recipeUI then
        self:addConsoleMessage("[ERROR] Recipe UI not available")
        return
    end

    self.recipeUIActive = true
    self.recipeUI:enter(itemName)
end

function UIManager:exitRecipeMode()
    self.recipeUIActive = false
    if self.recipeUI then
        self.recipeUI:exit()
    end
    self:draw()
end

function UIManager:learnRecipeUI()
    local recipe = self.services.recipes
    if not recipe then return false, "No recipe service" end
    self:addConsoleMessage("Analyzing crafting grid...")
    local success, err = turtle.craft()
    if not success then return false, err or "Craft failed" end
    local result = turtle.getItemDetail(1)
    if not result then return false, "No result" end
    self:addConsoleMessage("Crafted: " .. (result.displayName or result.name) .. " x" .. result.count)
    return true
end

function UIManager:showStatus()
    self:addConsoleMessage("=== System Status ===")
    if self.executor then
        local stats = self.executor:getStats()
        self:addConsoleMessage("Tasks: " .. stats.tasks.completed .. "/" .. stats.tasks.submitted)
    end
    if self.bridge then
        local s = self.bridge:getStats()
        self:addConsoleMessage("Network: RX:" .. s.received .. " TX:" .. s.sent)
    end
    self:addConsoleMessage("Uptime: " .. math.floor(os.clock()) .. " seconds")
end

function UIManager:handleTouch(x, y)
    -- If recipe UI is active, delegate to it
    if self.recipeUIActive and self.recipeUI then
        local handled = self.recipeUI:handleTouch(x, y)

        -- Check if recipe UI was exited
        if not self.recipeUI.active then
            self:exitRecipeMode()
        end

        return handled
    end

    for _, button in pairs(self.buttons) do
        if button.active and
                x >= button.x and x < button.x + button.width and
                y >= button.y and y < button.y + button.height then
            self.activeButton = button
            self:draw()
            if button.action then button.action() end
            if self.executor then
                self.executor:submit(function()
                    sleep(0.2)
                    self.activeButton = nil
                    self:draw()
                end, "button_reset", 1)
            end
            return true
        end
    end

    local consoleTop = 3
    local consoleBottom = self.height - 5
    if x >= 1 and x <= self.width and y > consoleTop and y <= consoleBottom then
        if y < (consoleTop + consoleBottom) / 2 then
            self.consoleScroll = math.max(0, self.consoleScroll - 1)
        else
            local maxScroll = math.max(0, #self.consoleLines - (consoleBottom - consoleTop))
            self.consoleScroll = math.min(maxScroll, self.consoleScroll + 1)
        end
        self:draw()
        return true
    end
    return false
end

function UIManager:createPrintOverride()
    local ui = self
    return function(...)
        local args = {...}
        local message = table.concat(args, " ")
        ui:addConsoleMessage(message)
    end
end

return UIManager
