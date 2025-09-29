-- Recipe learning UI component
local RecipeUI = {}

function RecipeUI.new(uiManager, recipeService, bridge)
    local self = {
        ui = uiManager,
        service = recipeService,
        bridge = bridge,
        isLearning = false
    }

    setmetatable(self, {__index = RecipeUI})
    return self
end

-- Interactive recipe learning with UI feedback
function RecipeUI:startLearning()
    if self.isLearning then
        self.ui:addConsoleMessage("[WARN] Recipe learning already in progress")
        return false
    end

    self.isLearning = true
    self.ui:addConsoleMessage("=== Recipe Learning Mode ===")

    -- Check inventory
    local hasItems = false
    local gridItems = {}

    for slot = 1, 9 do
        local item = turtle.getItemDetail(slot)
        if item then
            hasItems = true
            local row = math.floor((slot - 1) / 3) + 1
            local col = ((slot - 1) % 3) + 1
            gridItems[slot] = item
            self.ui:addConsoleMessage(string.format("[%d,%d] %s x%d",
                    row, col, item.displayName or item.name, item.count))
        end
    end

    if not hasItems then
        self.ui:addConsoleMessage("[ERROR] No items in crafting grid!")
        self.ui:addConsoleMessage("Place items in slots 1-9 and try again")
        self.isLearning = false
        return false
    end

    -- Show dialog for recipe name (simplified for turtle)
    self.ui:addConsoleMessage("Recipe detected! Attempting craft...")

    -- Analyze grid
    local recipe, key = self:analyzeGrid(gridItems)

    -- Try to craft
    local success, error = turtle.craft()

    if not success then
        self.ui:addConsoleMessage("[ERROR] Craft failed: " .. (error or "unknown"))
        self.ui:addConsoleMessage("Check your pattern and try again")
        self.isLearning = false
        return false
    end

    -- Get result
    local result = turtle.getItemDetail(1)
    if not result then
        self.ui:addConsoleMessage("[ERROR] No result after crafting!")
        self.isLearning = false
        return false
    end

    self.ui:addConsoleMessage("[SUCCESS] Crafted: " .. result.displayName .. " x" .. result.count)

    -- Determine if wildcard
    local isWildcard = self:detectWildcard(result.name)

    -- Build recipe data
    local recipeData = {
        display = result.displayName or result.name,
        wildcard = isWildcard,
        key = key,
        recipe = recipe,
        result = {
            item = result.name,
            count = result.count,
            wildcard = isWildcard
        }
    }

    -- Send to computer
    self.ui:addConsoleMessage("Sending recipe to computer...")
    self:sendRecipe(result.name, recipeData)

    -- Update stats
    if self.service then
        self.service.stats.learned = (self.service.stats.learned or 0) + 1
    end

    self.ui:addConsoleMessage("[INFO] Recipe learning complete!")
    self.ui:addConsoleMessage("Drop items? Place new items to learn another recipe")

    self.isLearning = false
    return true
end

-- Analyze the crafting grid
function RecipeUI:analyzeGrid(gridItems)
    local grid = {}
    local uniqueItems = {}
    local symbolMap = {}
    local nextSymbol = 97 -- 'a' in ASCII

    -- Process each slot
    for slot = 1, 9 do
        local item = gridItems[slot]
        if item then
            local itemKey = item.name .. "@" .. (item.nbt or "")

            if not symbolMap[itemKey] then
                local symbol = string.char(nextSymbol)
                symbolMap[itemKey] = symbol

                -- Check for tag
                local tag = self:getItemTag(item.name)
                uniqueItems[symbol] = {
                    item = tag or item.name,
                    wildcard = (tag ~= nil)
                }

                nextSymbol = nextSymbol + 1
            end

            grid[slot] = symbolMap[itemKey]
        else
            grid[slot] = "e"
        end
    end

    -- Convert to recipe pattern
    local recipe = {}
    for row = 0, 2 do
        local rowStr = ""
        for col = 1, 3 do
            local slot = row * 3 + col
            rowStr = rowStr .. grid[slot]
            if col < 3 then rowStr = rowStr .. " " end
        end
        table.insert(recipe, rowStr)
    end

    -- Add empty key
    uniqueItems["e"] = { item = "none" }

    return recipe, uniqueItems
end

-- Get item tag if applicable
function RecipeUI:getItemTag(itemId)
    itemId = itemId:lower()

    if itemId:match("_log$") or itemId:match("_stem$") then
        return "tag:log"
    elseif itemId:match("_planks$") then
        return "tag:planks"
    elseif itemId == "minecraft:coal" or itemId == "minecraft:charcoal" then
        return "tag:coal"
    elseif itemId:match("_slab$") and not itemId:match("stone") then
        return "tag:wood_slabs"
    elseif itemId:match("_stairs$") and not itemId:match("stone") then
        return "tag:wood_stairs"
    end

    return nil
end

-- Detect if result should be wildcard
function RecipeUI:detectWildcard(itemName)
    local tag = self:getItemTag(itemName)
    return tag ~= nil
end

-- Send recipe to computer
function RecipeUI:sendRecipe(recipeId, recipeData)
    if self.bridge then
        self.bridge:send({
            action = "store_recipe",
            recipe_id = recipeId,
            recipe_data = recipeData
        })
    else
        -- Fallback to direct broadcast
        rednet.broadcast({
            action = "store_recipe",
            recipe_id = recipeId,
            recipe_data = recipeData
        })
    end
end

return RecipeUI