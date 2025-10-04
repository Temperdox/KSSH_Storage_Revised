-- Recipe Save Mode UI - Shows 3x3 grid with legend
local print = require("util.log_print")

local RecipeUI = {}

function RecipeUI.new(recipeService)
    local self = {
        service = recipeService,
        active = false,
        enableSubstitutions = true,  -- Default to enabled
        gridSymbols = {},  -- Maps slot -> symbol
        legend = {},  -- Maps symbol -> item info
        result = nil,  -- Crafted result item
        awaitingConfirmation = false
    }

    setmetatable(self, {__index = RecipeUI})
    return self
end

-- Enter recipe save mode
function RecipeUI:enter(itemName)
    self.active = true
    self.itemName = itemName
    self.gridSymbols = {}
    self.legend = {}
    self.result = nil
    self.awaitingConfirmation = false

    self:draw()
end

-- Exit recipe save mode
function RecipeUI:exit()
    self.active = false
    term.setBackgroundColor(colors.black)
    term.clear()
end

-- Draw the recipe save UI
function RecipeUI:draw()
    if not self.active then return end

    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Title
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    local title = " RECIPE SAVE MODE "
    term.setCursorPos(math.floor((w - #title) / 2), 1)
    term.write(title)

    -- Instructions
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, 3)
    term.setTextColor(colors.lightGray)
    term.write("Place items in slots 1-9")

    -- Draw 3x3 grid
    self:drawGrid(3, 5)

    -- Draw legend
    self:drawLegend(3, 12)

    -- Draw result if crafted
    if self.result then
        self:drawResult(w - 15, 7)
    end

    -- Draw substitution checkbox
    self:drawSubstitutionToggle(3, h - 5)

    -- Draw buttons
    if not self.awaitingConfirmation then
        self:drawButton("Craft & Save", 3, h - 2, colors.green)
        self:drawButton("Cancel", w - 10, h - 2, colors.red)
    else
        -- Confirmation buttons
        self:drawButton("Confirm", 3, h - 2, colors.green)
        self:drawButton("Discard", w - 11, h - 2, colors.red)
    end

    term.setBackgroundColor(colors.black)
end

-- Draw 3x3 crafting grid
function RecipeUI:drawGrid(x, y)
    -- Update grid symbols from current inventory
    self:updateGridFromInventory()

    -- Grid header
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("Crafting Grid:")

    -- Draw grid
    y = y + 1
    for row = 0, 2 do
        term.setCursorPos(x, y + row)
        term.setTextColor(colors.white)

        for col = 0, 2 do
            local slot = row * 3 + col + 1
            local symbol = self.gridSymbols[slot] or " "

            -- Draw cell
            term.setBackgroundColor(colors.gray)
            term.write("[")
            term.setTextColor(colors.yellow)
            term.write(symbol)
            term.setTextColor(colors.white)
            term.write("]")
            term.setBackgroundColor(colors.black)

            if col < 2 then
                term.write(" ")
            end
        end
    end
end

-- Draw item legend
function RecipeUI:drawLegend(x, y)
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("Item Legend:")

    y = y + 1

    if next(self.legend) == nil then
        term.setCursorPos(x, y)
        term.setTextColor(colors.gray)
        term.write("(empty)")
        return
    end

    -- Sort symbols alphabetically
    local symbols = {}
    for symbol, _ in pairs(self.legend) do
        if symbol ~= "e" then
            table.insert(symbols, symbol)
        end
    end
    table.sort(symbols)

    -- Draw each legend entry
    for i, symbol in ipairs(symbols) do
        local info = self.legend[symbol]
        term.setCursorPos(x, y + i - 1)
        term.setTextColor(colors.yellow)
        term.write("[" .. symbol .. "]")
        term.setTextColor(colors.white)
        term.write(" = ")
        term.setTextColor(colors.lightGray)

        -- Show substitution tag or exact item
        local displayItem = info.item
        if self.enableSubstitutions and info.availableTag then
            displayItem = info.availableTag
            term.setTextColor(colors.lime)
        end

        -- Truncate if too long
        if #displayItem > 20 then
            displayItem = displayItem:sub(1, 17) .. "..."
        end

        term.write(displayItem)
    end
end

-- Draw result
function RecipeUI:drawResult(x, y)
    term.setCursorPos(x, y)
    term.setTextColor(colors.white)
    term.write("=")

    term.setCursorPos(x, y + 1)
    term.setBackgroundColor(colors.gray)
    term.write("          ")
    term.setCursorPos(x + 1, y + 1)
    term.setTextColor(colors.yellow)

    local name = self.result.displayName or self.result.name
    if #name > 8 then
        name = name:sub(1, 5) .. "..."
    end
    term.write(name)

    term.setBackgroundColor(colors.black)
    term.setCursorPos(x, y + 2)
    term.setTextColor(colors.white)
    term.write("x" .. self.result.count)
end

-- Draw substitution checkbox
function RecipeUI:drawSubstitutionToggle(x, y)
    term.setCursorPos(x, y)
    term.setTextColor(colors.white)
    term.write("[")

    term.setTextColor(self.enableSubstitutions and colors.lime or colors.gray)
    term.write(self.enableSubstitutions and "X" or " ")

    term.setTextColor(colors.white)
    term.write("] ")

    term.setTextColor(colors.lightGray)
    term.write("Enable Substitutions")
end

-- Draw button
function RecipeUI:drawButton(label, x, y, color)
    term.setCursorPos(x, y)
    term.setBackgroundColor(color)
    term.setTextColor(colors.white)
    term.write(" " .. label .. " ")
    term.setBackgroundColor(colors.black)
end

-- Update grid symbols from turtle inventory
function RecipeUI:updateGridFromInventory()
    self.gridSymbols = {}
    self.legend = {}

    local symbolMap = {}
    local nextSymbol = string.byte('A')  -- Start with 'A'

    for slot = 1, 9 do
        local item = turtle.getItemDetail(slot)

        if item then
            local itemKey = item.name .. "@" .. (item.nbt or "")

            -- Assign symbol if new item
            if not symbolMap[itemKey] then
                local symbol = string.char(nextSymbol)
                symbolMap[itemKey] = symbol

                -- Get substitution tag
                local tag = self.service:getItemTag(item.name)

                self.legend[symbol] = {
                    itemName = item.name,
                    displayName = item.displayName or item.name,
                    availableTag = tag,
                    item = item.name
                }

                nextSymbol = nextSymbol + 1
            end

            self.gridSymbols[slot] = symbolMap[itemKey]
        end
    end
end

-- Handle touch events
function RecipeUI:handleTouch(x, y)
    if not self.active then return false end

    local w, h = term.getSize()

    -- Check substitution checkbox
    if y == h - 5 and x >= 3 and x <= 4 then
        self.enableSubstitutions = not self.enableSubstitutions
        self:draw()
        return true
    end

    if not self.awaitingConfirmation then
        -- Check Craft & Save button
        if y == h - 2 and x >= 3 and x <= 16 then
            self:craftAndSave()
            return true
        end

        -- Check Cancel button
        if y == h - 2 and x >= w - 10 and x <= w - 4 then
            self:exit()
            return true
        end
    else
        -- Check Confirm button
        if y == h - 2 and x >= 3 and x <= 12 then
            self:confirmSave()
            return true
        end

        -- Check Discard button
        if y == h - 2 and x >= w - 11 and x <= w - 4 then
            self:discardRecipe()
            return true
        end
    end

    return false
end

-- Craft and prepare to save
function RecipeUI:craftAndSave()
    -- Check if grid has items
    local hasItems = false
    for slot = 1, 9 do
        if turtle.getItemDetail(slot) then
            hasItems = true
            break
        end
    end

    if not hasItems then
        print.warn("[recipe] No items in grid!")
        return
    end

    -- Analyze grid with substitution preferences
    local substitutionPrefs = {}
    for symbol, info in pairs(self.legend) do
        substitutionPrefs[symbol] = self.enableSubstitutions and (info.availableTag ~= nil)
    end

    local recipe, key = self.service:analyzeGrid(substitutionPrefs)

    -- Try to craft
    print.info("[recipe] Crafting...")
    local success, error = turtle.craft()

    if not success then
        print.error("[recipe] Craft failed:", error or "unknown")
        return
    end

    -- Get result
    local result = turtle.getItemDetail(1)
    if not result then
        print.error("[recipe] No result after crafting!")
        return
    end

    self.result = result
    self.recipePattern = recipe
    self.recipeKey = key
    self.awaitingConfirmation = true

    print.info("[recipe] Crafted:", result.displayName or result.name, "x" .. result.count)
    self:draw()
end

-- Confirm and save recipe
function RecipeUI:confirmSave()
    if not self.result then return end

    -- Determine if result should use substitution tag
    local resultTag = nil
    local resultWildcard = false

    if self.enableSubstitutions then
        resultTag = self.service:getItemTag(self.result.name)
        if resultTag then
            resultWildcard = true
        end
    end

    -- Create recipe data
    local recipeId = self.result.name
    local recipeData = {
        display = self.result.displayName or self.result.name,
        wildcard = self.enableSubstitutions,
        key = self.recipeKey,
        recipe = self.recipePattern,
        result = {
            item = (resultWildcard and resultTag) or self.result.name,
            count = self.result.count,
            wildcard = resultWildcard
        }
    }

    -- Store recipe
    self.service:storeRecipe(recipeId, recipeData)

    -- Send to computer
    print.info("[recipe] Sending recipe to computer...")
    self.service:sendRecipe(recipeId, recipeData)

    print.info("[recipe] Recipe saved:", recipeId)

    -- Exit recipe mode
    self:exit()
end

-- Discard crafted item and reset
function RecipeUI:discardRecipe()
    print.info("[recipe] Recipe discarded")

    -- Ask user to remove item from slot 1
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("Please remove the crafted item from slot 1")
    print("Press any key when done...")
    os.pullEvent("key")

    -- Reset state
    self.result = nil
    self.awaitingConfirmation = false
    self:draw()
end

return RecipeUI
