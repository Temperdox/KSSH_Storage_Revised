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

    term.setBackgroundColor(colors.black)

    -- Draw 3x3 grid (top left)
    self:drawGrid(2, 3)

    -- Draw legend (top right)
    self:drawLegend(w - 22, 3)

    -- Draw result if crafted (center right of grid)
    if self.result then
        self:drawResult(18, 6)
    end

    -- Draw substitution checkbox (bottom area)
    self:drawSubstitutionToggle(2, h - 4)

    -- Draw buttons (bottom)
    if not self.awaitingConfirmation then
        self:drawButton("Craft & Save", 2, h - 1, colors.green)
        self:drawButton("Cancel", w - 9, h - 1, colors.red)
    else
        -- Confirmation buttons
        self:drawButton("Confirm", 2, h - 1, colors.green)
        self:drawButton("Discard", w - 10, h - 1, colors.red)
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
    term.write("Grid:")

    -- Draw grid (skip slots 4 and 5)
    y = y + 1
    local slotMap = {1, 2, 3, 6, 7, 8, 11, 12, 13}  -- Actual turtle slots for crafting
    local gridIdx = 1

    for row = 0, 2 do
        term.setCursorPos(x, y + row)
        term.setTextColor(colors.white)

        for col = 0, 2 do
            local slot = slotMap[gridIdx]
            local symbol = self.gridSymbols[slot] or " "
            gridIdx = gridIdx + 1

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
    term.write("Legend:")

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
        term.write(" ")
        term.setTextColor(colors.lightGray)

        -- Show shortened name
        local displayItem = info.item
        if self.enableSubstitutions and info.availableTag then
            displayItem = self:shortenTagName(info.availableTag)
            term.setTextColor(colors.lime)
        else
            displayItem = self:shortenTagName(info.itemName)
        end

        term.write(displayItem)
    end
end

-- Shorten tag names to just the material/type
function RecipeUI:shortenTagName(itemId)
    -- Extract just the material name from tags
    -- minecraft:oak_planks -> oak
    -- minecraft:planks -> planks
    -- c:iron_ingots -> iron
    -- minecraft:logs -> logs

    if not itemId then return "unknown" end

    itemId = itemId:lower()

    -- Handle c: or forge: tags
    if itemId:match("^c:") or itemId:match("^forge:") then
        local material = itemId:match("^[^:]+:(.+)$")
        if material then
            -- Remove _ingots, _nuggets, _ores, etc.
            material = material:gsub("_ingots$", "")
            material = material:gsub("_nuggets$", "")
            material = material:gsub("_ores$", "")
            material = material:gsub("_dusts$", "")
            return material
        end
    end

    -- Handle minecraft: tags
    if itemId:match("^minecraft:") then
        local item = itemId:match("^minecraft:(.+)$")
        if item then
            -- If it's a plural tag (planks, logs), just return it
            if item == "planks" or item == "logs" or item == "wool" or
               item == "wooden_slabs" or item == "wooden_stairs" or
               item == "saplings" or item == "leaves" or item == "coals" then
                return item
            end

            -- Otherwise extract the wood type or material
            -- oak_planks -> oak
            -- birch_log -> birch
            local material = item:match("^(.+)_planks$") or
                           item:match("^(.+)_log$") or
                           item:match("^(.+)_wood$") or
                           item:match("^(.+)_ingot$") or
                           item:match("^(.+)_nugget$")

            if material then
                return material
            end

            -- Return shortened version if no pattern matches
            if #item > 12 then
                return item:sub(1, 9) .. "..."
            end
            return item
        end
    end

    -- Fallback: just return last part after :
    local shortName = itemId:match("([^:]+)$") or itemId
    if #shortName > 12 then
        return shortName:sub(1, 9) .. "..."
    end
    return shortName
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
    term.write("Substitutions")
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

    -- Crafting grid slots (skipping fuel slots 4, 5, 9, 10, 14, 15, 16)
    local craftingSlots = {1, 2, 3, 6, 7, 8, 11, 12, 13}

    for _, slot in ipairs(craftingSlots) do
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
    if y == h - 4 and x >= 2 and x <= 3 then
        self.enableSubstitutions = not self.enableSubstitutions
        self:draw()
        return true
    end

    if not self.awaitingConfirmation then
        -- Check Craft & Save button
        if y == h - 1 and x >= 2 and x <= 15 then
            self:craftAndSave()
            return true
        end

        -- Check Cancel button
        if y == h - 1 and x >= w - 9 and x <= w - 3 then
            self:exit()
            return true
        end
    else
        -- Check Confirm button
        if y == h - 1 and x >= 2 and x <= 11 then
            self:confirmSave()
            return true
        end

        -- Check Discard button
        if y == h - 1 and x >= w - 10 and x <= w - 3 then
            self:discardRecipe()
            return true
        end
    end

    return false
end

-- Craft and prepare to save
function RecipeUI:craftAndSave()
    -- Check if grid has items (check crafting slots only)
    local craftingSlots = {1, 2, 3, 6, 7, 8, 11, 12, 13}
    local hasItems = false
    for _, slot in ipairs(craftingSlots) do
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
