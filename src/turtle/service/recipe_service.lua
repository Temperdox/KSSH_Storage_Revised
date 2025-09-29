-- Service for learning and storing recipes from turtle inventory
local print = require("util.log_print")

local RecipeService = {}

function RecipeService.new(bridge)
    local self = {
        bridge = bridge,
        stats = {
            learned = 0,
            sent = 0,
            failed = 0
        }
    }

    setmetatable(self, {__index = RecipeService})
    return self
end

function RecipeService:init()
    print.info("[recipe] Initializing recipe service...")

    -- Register command handler if needed
    self.bridge:register("learn_recipe", function(sender, msg)
        return self:learnFromInventory(sender)
    end)

    print.info("[recipe] Recipe service ready")
end

-- Map item IDs to tag categories
function RecipeService:getItemTag(itemId)
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

-- Analyze the 3x3 grid to create pattern and key
function RecipeService:analyzeGrid()
    print.debug("[recipe] Analyzing crafting grid...")

    local grid = {}
    local uniqueItems = {}
    local symbolMap = {}
    local nextSymbol = 97  -- 'a' in ASCII

    -- Read the 3x3 grid (slots 1-9)
    for slot = 1, 9 do
        local item = turtle.getItemDetail(slot)
        if item then
            local itemKey = item.name .. "@" .. (item.nbt or "")

            -- Assign a symbol if we haven't seen this item yet
            if not symbolMap[itemKey] then
                local symbol = string.char(nextSymbol)
                symbolMap[itemKey] = symbol

                -- Determine if this item should use a tag
                local tag = self:getItemTag(item.name)
                local useTag = tag ~= nil

                uniqueItems[symbol] = {
                    item = useTag and tag or item.name,
                    wildcard = useTag
                }

                print.debug("[recipe] Symbol", symbol, "=", useTag and tag or item.name)
                nextSymbol = nextSymbol + 1
            end

            grid[slot] = symbolMap[itemKey]
        else
            grid[slot] = "e"  -- empty
        end
    end

    -- Convert grid to recipe pattern (3 strings)
    local recipe = {}
    for row = 0, 2 do
        local rowStr = ""
        for col = 1, 3 do
            local slot = row * 3 + col
            rowStr = rowStr .. grid[slot]
            if col < 3 then rowStr = rowStr .. " " end
        end
        table.insert(recipe, rowStr)
        print.debug("[recipe] Row", row + 1, ":", rowStr)
    end

    -- Add 'e' for empty to the key
    uniqueItems["e"] = { item = "none" }

    return recipe, uniqueItems
end

-- Interactive recipe learning
function RecipeService:learnRecipe()
    print.info("[recipe] Starting interactive recipe learning...")

    print("=== Recipe Learning Mode ===")
    print("Place ingredients in slots 1-9 (3x3 grid)")
    print("Current grid contents:")

    -- Show what's in the grid
    local hasItems = false
    for slot = 1, 9 do
        local item = turtle.getItemDetail(slot)
        if item then
            local row = math.floor((slot - 1) / 3) + 1
            local col = ((slot - 1) % 3) + 1
            print(string.format("  [%d,%d]: %s x%d", row, col, item.displayName or item.name, item.count))
            hasItems = true
        end
    end

    if not hasItems then
        print("Grid is empty! Place items first.")
        return false, "Empty grid"
    end

    print("\nEnter display name for this recipe:")
    local displayName = read()

    print("Is this a wildcard recipe? (y/n):")
    print("(outputs different items based on input)")
    local wildcardInput = read()
    local isWildcard = (wildcardInput:lower() == "y")

    -- Analyze the current grid
    print.info("[recipe] Analyzing crafting grid...")
    local recipe, key = self:analyzeGrid()

    -- Display the pattern
    print("\nDetected pattern:")
    for i, row in ipairs(recipe) do
        print("  " .. row)
    end

    print("\nKey mapping:")
    for symbol, data in pairs(key) do
        if symbol ~= "e" then
            print(string.format("  %s = %s%s",
                    symbol,
                    data.item,
                    data.wildcard and " (wildcard)" or ""))
        end
    end

    -- Try to craft
    print("\nAttempting to craft...")
    local success, error = turtle.craft()

    if not success then
        print.error("[recipe] Craft failed:", error or "unknown error")
        self.stats.failed = self.stats.failed + 1
        return false, error or "Craft failed"
    end

    -- Analyze the result
    local result = turtle.getItemDetail(1)
    if not result then
        print.error("[recipe] No result found after crafting!")
        self.stats.failed = self.stats.failed + 1
        return false, "No result"
    end

    print.info("[recipe] Crafted:", result.displayName or result.name, "x" .. result.count)

    -- Determine result tag
    local resultTag = nil
    local resultWildcard = false

    if isWildcard then
        resultTag = self:getItemTag(result.name)
        if resultTag then
            resultWildcard = true
        end
    end

    -- Create the recipe object
    local recipeId = result.name
    local recipeData = {
        display = displayName,
        wildcard = isWildcard,
        key = key,
        recipe = recipe,
        result = {
            item = resultWildcard and resultTag or result.name,
            count = result.count,
            wildcard = resultWildcard
        }
    }

    self.stats.learned = self.stats.learned + 1

    -- Send to computer
    print.info("[recipe] Sending recipe to storage system...")
    self:sendRecipe(recipeId, recipeData)

    -- Clear inventory option
    print("\nDrop crafted items? (y/n):")
    local dropInput = read()
    if dropInput:lower() == "y" then
        for slot = 1, 16 do
            if turtle.getItemDetail(slot) then
                turtle.select(slot)
                turtle.drop()
            end
        end
        print("Inventory cleared.")
    end

    return true, recipeId
end

-- Send recipe to computer
function RecipeService:sendRecipe(recipeId, recipeData)
    local packet = {
        action = "store_recipe",
        recipe_id = recipeId,
        recipe_data = recipeData
    }

    self.bridge:send(packet)
    self.stats.sent = self.stats.sent + 1

    print.info("[recipe] Recipe sent:", recipeId)

    -- Wait for confirmation (handled by bridge)
    -- The response will come through as a separate message
end

-- Learn from current inventory (called via bridge)
function RecipeService:learnFromInventory(sender)
    print.info("[recipe] Remote recipe learning request from", sender)

    local recipe, key = self:analyzeGrid()

    -- Try to craft to determine output
    local success, error = turtle.craft()

    if not success then
        self.bridge:send({
            action = "learn_recipe_response",
            success = false,
            error = error or "Craft failed"
        }, sender)
        return
    end

    local result = turtle.getItemDetail(1)
    if not result then
        self.bridge:send({
            action = "learn_recipe_response",
            success = false,
            error = "No result"
        }, sender)
        return
    end

    -- Build recipe data
    local recipeData = {
        display = result.displayName or result.name,
        wildcard = false,  -- Default to non-wildcard
        key = key,
        recipe = recipe,
        result = {
            item = result.name,
            count = result.count,
            wildcard = false
        }
    }

    -- Send back to requester
    self.bridge:send({
        action = "store_recipe",
        recipe_id = result.name,
        recipe_data = recipeData
    }, sender)

    self.stats.learned = self.stats.learned + 1
    print.info("[recipe] Recipe learned and sent:", result.name)
end

-- Get statistics
function RecipeService:getStats()
    return self.stats
end

return RecipeService