-- Service for learning and storing recipes from turtle inventory
local print = require("util.log_print")

local RecipeService = {}

function RecipeService.new(bridge)
    local self = {
        bridge = bridge,
        recipes = {},  -- In-memory recipe cache
        recipePath = "/disk/recipes.json",  -- Disk storage path
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

    -- Load recipes from disk
    self:loadRecipesFromDisk()

    -- Register command handlers
    self.bridge:register("learn_recipe", function(sender, msg)
        return self:learnFromInventory(sender)
    end)

    self.bridge:register("get_recipe", function(sender, msg)
        return self:sendRecipeToComputer(sender, msg.item_name)
    end)

    print.info("[recipe] Recipe service ready -", self:getRecipeCount(), "recipes loaded")
end

-- Load all recipes from disk
function RecipeService:loadRecipesFromDisk()
    if not fs.exists(self.recipePath) then
        print.debug("[recipe] No recipe file found at", self.recipePath)
        self.recipes = {}
        return
    end

    local file = fs.open(self.recipePath, "r")
    local content = file.readAll()
    file.close()

    local loaded = textutils.unserialiseJSON(content)
    if loaded and type(loaded) == "table" then
        self.recipes = loaded
        print.info("[recipe] Loaded", self:getRecipeCount(), "recipes from disk")
    else
        print.error("[recipe] Failed to parse recipe file")
        self.recipes = {}
    end
end

-- Save all recipes to disk
function RecipeService:saveRecipesToDisk()
    local dir = fs.getDir(self.recipePath)
    if not fs.exists(dir) and dir ~= "" then
        fs.makeDir(dir)
    end

    local file = fs.open(self.recipePath, "w")
    file.write(textutils.serialiseJSON(self.recipes))
    file.close()

    print.debug("[recipe] Saved", self:getRecipeCount(), "recipes to disk")
end

-- Store a recipe
function RecipeService:storeRecipe(recipeId, recipeData)
    self.recipes[recipeId] = recipeData
    self:saveRecipesToDisk()
    print.info("[recipe] Stored recipe:", recipeId)
end

-- Get a recipe by item name
function RecipeService:getRecipe(itemName)
    return self.recipes[itemName]
end

-- Get count of stored recipes
function RecipeService:getRecipeCount()
    local count = 0
    for _ in pairs(self.recipes) do
        count = count + 1
    end
    return count
end

-- Send a specific recipe to computer
function RecipeService:sendRecipeToComputer(sender, itemName)
    local recipe = self:getRecipe(itemName)

    if recipe then
        self.bridge:send({
            action = "recipe_data",
            item_name = itemName,
            recipe = recipe,
            success = true
        }, sender)
        print.info("[recipe] Sent recipe for", itemName, "to computer", sender)
    else
        self.bridge:send({
            action = "recipe_data",
            item_name = itemName,
            success = false,
            error = "Recipe not found"
        }, sender)
        print.warn("[recipe] Recipe not found:", itemName)
    end
end

-- Convert item ID to its tag equivalent for substitution
function RecipeService:getItemTag(itemId)
    itemId = itemId:lower()

    -- Handle mod tags with paths (c:ingots/iron → c:ingots, forge:ingots/iron → forge:ingots)
    if itemId:match("^[%w_]+:[%w_]+/[%w_]+$") then
        local namespace, path = itemId:match("^([%w_]+):([%w_]+)/[%w_]+$")
        if namespace and path then
            return namespace .. ":" .. path
        end
    end

    -- Handle minecraft namespace - convert to plural tags
    if itemId:match("^minecraft:") then
        local itemName = itemId:match("^minecraft:(.+)$")

        -- Logs/stems → minecraft:logs
        if itemName:match("_log$") or itemName:match("_stem$") then
            return "minecraft:logs"

        -- Planks → minecraft:planks (plural)
        elseif itemName:match("_planks$") then
            return "minecraft:planks"

        -- Wool → minecraft:wool (already plural)
        elseif itemName:match("_wool$") then
            return "minecraft:wool"

        -- Slabs (wood) → minecraft:wooden_slabs (plural)
        elseif itemName:match("_slab$") and not itemName:match("stone") then
            return "minecraft:wooden_slabs"

        -- Stairs (wood) → minecraft:wooden_stairs (plural)
        elseif itemName:match("_stairs$") and not itemName:match("stone") then
            return "minecraft:wooden_stairs"

        -- Stone variants → minecraft:stone
        elseif itemName:match("stone$") or itemName:match("cobblestone$") then
            return "minecraft:stone"

        -- Coal/charcoal → minecraft:coals (plural)
        elseif itemName == "coal" or itemName == "charcoal" then
            return "minecraft:coals"

        -- Saplings → minecraft:saplings (plural)
        elseif itemName:match("_sapling$") then
            return "minecraft:saplings"

        -- Leaves → minecraft:leaves (plural)
        elseif itemName:match("_leaves$") then
            return "minecraft:leaves"

        -- Ingots → c:ingots or forge:ingots (use common tags for cross-mod support)
        -- Prefer c: (Common) tag for better mod compatibility
        elseif itemName:match("_ingot$") then
            local metal = itemName:match("^(.+)_ingot$")
            -- Use c: tag for ingots (standard in many mods)
            return "c:" .. metal .. "_ingots"

        -- Nuggets → c:nuggets
        elseif itemName:match("_nugget$") then
            local metal = itemName:match("^(.+)_nugget$")
            return "c:" .. metal .. "_nuggets"

        -- Gems → c:gems
        elseif itemName:match("diamond") or itemName:match("emerald") or itemName:match("amethyst") then
            local gem = itemName:match("^(.+)$")
            return "c:" .. gem .. "s"

        -- Ores → c:ores
        elseif itemName:match("_ore$") then
            local ore = itemName:match("^(.+)_ore$")
            return "c:" .. ore .. "_ores"

        -- Dusts/powders → c:dusts
        elseif itemName:match("_dust$") or itemName:match("powder$") then
            local material = itemName:match("^(.+)_dust$") or itemName:match("^(.+)_powder$")
            return "c:dusts"
        end
    end

    -- Handle forge/c tags directly (already modded items)
    if itemId:match("^forge:") or itemId:match("^c:") then
        -- Already a tag, make it plural if not already
        if not itemId:match("s$") then
            return itemId .. "s"
        end
        return itemId
    end

    -- No tag found
    return nil
end

-- Analyze the 3x3 grid to create pattern and key
-- Returns: recipe pattern, ingredient data (with symbols and item info)
function RecipeService:analyzeGrid(substitutionPreferences)
    print.debug("[recipe] Analyzing crafting grid...")
    substitutionPreferences = substitutionPreferences or {}

    local grid = {}
    local uniqueItems = {}
    local symbolMap = {}
    local ingredientInfo = {}  -- Track original item names for UI
    local nextSymbol = 97  -- 'a' in ASCII

    -- Read the 3x3 grid (turtle crafting slots: 1,2,3,5,6,7,9,10,11)
    -- Skip slots 4, 8, 12
    local craftingSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    local gridPos = 1

    for _, slot in ipairs(craftingSlots) do
        local item = turtle.getItemDetail(slot)
        if item then
            local itemKey = item.name .. "@" .. (item.nbt or "")

            -- Assign a symbol if we haven't seen this item yet
            if not symbolMap[itemKey] then
                local symbol = string.char(nextSymbol)
                symbolMap[itemKey] = symbol

                -- Store ingredient info for UI display
                local tag = self:getItemTag(item.name)
                ingredientInfo[symbol] = {
                    itemName = item.name,
                    displayName = item.displayName or item.name,
                    availableTag = tag,
                    symbol = symbol
                }

                -- Check if user wants substitution for this ingredient
                local useSubstitution = substitutionPreferences[symbol] or false
                local finalItem = (useSubstitution and tag) and tag or item.name

                uniqueItems[symbol] = {
                    item = finalItem,
                    wildcard = useSubstitution and tag ~= nil
                }

                print.debug("[recipe] Symbol", symbol, "=", finalItem,
                           useSubstitution and "(substitution enabled)" or "")
                nextSymbol = nextSymbol + 1
            end

            grid[gridPos] = symbolMap[itemKey]
        else
            grid[gridPos] = "e"  -- empty
        end

        gridPos = gridPos + 1
    end

    -- Convert grid to recipe pattern (3 strings)
    local recipe = {}
    for row = 0, 2 do
        local rowStr = ""
        for col = 1, 3 do
            local pos = row * 3 + col
            rowStr = rowStr .. (grid[pos] or "e")
            if col < 3 then rowStr = rowStr .. " " end
        end
        table.insert(recipe, rowStr)
        print.debug("[recipe] Row", row + 1, ":", rowStr)
    end

    -- Add 'e' for empty to the key
    uniqueItems["e"] = { item = "none" }

    return recipe, uniqueItems, ingredientInfo
end

-- Interactive recipe learning
function RecipeService:learnRecipe()
    print.info("[recipe] Starting interactive recipe learning...")

    print("=== Recipe Learning Mode ===")
    print("Place ingredients in crafting grid")
    print("(slots 1,2,3,5,6,7,9,10,11)")
    print("Current grid contents:")

    -- Show what's in the grid
    local hasItems = false
    local craftingSlots = {1, 2, 3, 5, 6, 7, 9, 10, 11}
    local gridPos = 1

    for _, slot in ipairs(craftingSlots) do
        local item = turtle.getItemDetail(slot)
        if item then
            local row = math.floor((gridPos - 1) / 3) + 1
            local col = ((gridPos - 1) % 3) + 1
            print(string.format("  [%d,%d]: %s x%d", row, col, item.displayName or item.name, item.count))
            hasItems = true
        end
        gridPos = gridPos + 1
    end

    if not hasItems then
        print("Grid is empty! Place items first.")
        return false, "Empty grid"
    end

    print("\nEnter display name for this recipe:")
    local displayName = read()

    -- First pass: analyze grid to get ingredient info (without substitutions)
    local _, _, ingredientInfo = self:analyzeGrid({})

    -- Ask about substitutions for each ingredient
    print("\n=== Ingredient Substitutions ===")
    print("Allow substitutions for each ingredient?")
    print("(e.g., any log instead of oak log)")
    print("")

    local substitutionPrefs = {}
    for symbol, info in pairs(ingredientInfo) do
        print(string.format("[%s] %s", symbol, info.displayName))

        if info.availableTag then
            print(string.format("    Can substitute with: %s", info.availableTag))
            print("    Allow substitutions? (y/n):")
            local response = read()
            substitutionPrefs[symbol] = (response:lower() == "y")

            if substitutionPrefs[symbol] then
                print(string.format("    -> Will use: %s", info.availableTag))
            else
                print(string.format("    -> Will use: %s (exact)", info.itemName))
            end
        else
            print("    (No substitution tag available)")
            substitutionPrefs[symbol] = false
        end
        print("")
    end

    -- Second pass: analyze grid with substitution preferences
    print.info("[recipe] Building recipe with substitution preferences...")
    local recipe, key = self:analyzeGrid(substitutionPrefs)

    -- Display the final pattern
    print("\nFinal recipe pattern:")
    for i, row in ipairs(recipe) do
        print("  " .. row)
    end

    print("\nKey mapping:")
    for symbol, data in pairs(key) do
        if symbol ~= "e" then
            print(string.format("  %s = %s%s",
                    symbol,
                    data.item,
                    data.wildcard and " (substitution)" or " (exact)"))
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

    -- Ask if result should use wildcards
    print("\nAllow result substitution? (y/n):")
    print("(For recipes that output different items based on input)")
    local resultSubInput = read()
    local resultWildcard = (resultSubInput:lower() == "y")

    local resultTag = nil
    if resultWildcard then
        resultTag = self:getItemTag(result.name)
        if resultTag then
            print(string.format("Result will use tag: %s", resultTag))
        else
            print("No tag available for result, using exact item")
            resultWildcard = false
        end
    end

    -- Create the recipe object
    local recipeId = result.name
    local recipeData = {
        display = displayName,
        wildcard = resultWildcard,
        key = key,
        recipe = recipe,
        result = {
            item = (resultWildcard and resultTag) and resultTag or result.name,
            count = result.count,
            wildcard = resultWildcard
        }
    }

    self.stats.learned = self.stats.learned + 1

    -- Store locally first
    self:storeRecipe(recipeId, recipeData)

    -- Send to computer
    print.info("[recipe] Sending recipe to storage system...")
    self:sendRecipe(recipeId, recipeData)

    print("\n=== Recipe Saved Successfully! ===")

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
-- Remote learning uses no substitutions by default (exact recipes)
function RecipeService:learnFromInventory(sender)
    print.info("[recipe] Remote recipe learning request from", sender)

    -- No substitutions for remote learning (use exact items)
    local recipe, key = self:analyzeGrid({})

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

    -- Build recipe data (exact recipe, no wildcards)
    local recipeData = {
        display = result.displayName or result.name,
        wildcard = false,
        key = key,
        recipe = recipe,
        result = {
            item = result.name,
            count = result.count,
            wildcard = false
        }
    }

    -- Store locally
    self:storeRecipe(result.name, recipeData)

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