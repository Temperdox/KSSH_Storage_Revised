--[[
    TURTLE CONNECTION TYPE

    Handles communication with crafting turtles for recipe storage and autocrafting
]]

local TurtleConnection = {}

-- ============================================================================
-- REQUIRED CONFIGURATION
-- ============================================================================

TurtleConnection.loadConnectionType = true
TurtleConnection.id = "turtle"
TurtleConnection.name = "Crafting Turtle"
TurtleConnection.description = "Turtle for autocrafting and recipe storage"
TurtleConnection.connectionType = "CUSTOM"
TurtleConnection.color = colors.lime
TurtleConnection.icon = "T"

-- ============================================================================
-- LIFECYCLE METHODS
-- ============================================================================

function TurtleConnection:onLoad(context)
    self.context = context
    self.logger = context.logger
    self.recipes = {}  -- In-memory recipe cache
    self.recipePath = "/disk/recipes.json"  -- Disk storage path

    -- Load existing recipes from disk
    self:loadRecipesFromDisk()

    self.logger:info("TurtleConnection", "Loaded with " .. self:getRecipeCount() .. " recipes")
end

function TurtleConnection:onConnect(connection)
    self.logger:info("TurtleConnection", "Turtle #" .. connection.id .. " connected")

    connection.customData = {
        status = "idle",
        craftsPending = 0,
        recipesKnown = self:getRecipeCount(),
        lastCraft = nil
    }
end

function TurtleConnection:onDisconnect(connection)
    self.logger:info("TurtleConnection", "Turtle #" .. connection.id .. " disconnected")
end

function TurtleConnection:onUpdate(connection)
    -- Update connection state periodically
    if connection.customData then
        connection.customData.recipesKnown = self:getRecipeCount()
    end
end

-- ============================================================================
-- RECIPE STORAGE
-- ============================================================================

function TurtleConnection:loadRecipesFromDisk()
    if not fs.exists(self.recipePath) then
        self.logger:debug("TurtleConnection", "No recipe file found at " .. self.recipePath)
        self.recipes = {}
        return
    end

    local file = fs.open(self.recipePath, "r")
    if not file then
        self.logger:error("TurtleConnection", "Failed to open recipe file")
        self.recipes = {}
        return
    end

    local content = file.readAll()
    file.close()

    local loaded = textutils.unserialiseJSON(content)
    if loaded and type(loaded) == "table" then
        self.recipes = loaded
        self.logger:info("TurtleConnection", "Loaded " .. self:getRecipeCount() .. " recipes from disk")
    else
        self.logger:error("TurtleConnection", "Failed to parse recipe file")
        self.recipes = {}
    end
end

function TurtleConnection:saveRecipesToDisk()
    local dir = fs.getDir(self.recipePath)
    if not fs.exists(dir) and dir ~= "" then
        fs.makeDir(dir)
    end

    local file = fs.open(self.recipePath, "w")
    if not file then
        self.logger:error("TurtleConnection", "Failed to open recipe file for writing")
        return false
    end

    file.write(textutils.serialiseJSON(self.recipes))
    file.close()

    self.logger:debug("TurtleConnection", "Saved " .. self:getRecipeCount() .. " recipes to disk")
    return true
end

function TurtleConnection:storeRecipe(recipeId, recipeData)
    self.recipes[recipeId] = recipeData
    self:saveRecipesToDisk()
    self.logger:info("TurtleConnection", "Stored recipe: " .. recipeId)
end

function TurtleConnection:getRecipe(itemName)
    return self.recipes[itemName]
end

function TurtleConnection:hasRecipe(itemName)
    return self.recipes[itemName] ~= nil
end

function TurtleConnection:getRecipeCount()
    local count = 0
    for _ in pairs(self.recipes) do
        count = count + 1
    end
    return count
end

function TurtleConnection:getAllRecipes()
    return self.recipes
end

-- ============================================================================
-- PROTOCOL METHODS
-- ============================================================================

function TurtleConnection:handleMessage(connection, message)
    if not message or type(message) ~= "table" then
        return false
    end

    local action = message.action

    -- Handle recipe storage from turtle
    if action == "store_recipe" then
        local recipeId = message.recipe_id
        local recipeData = message.recipe_data

        if recipeId and recipeData then
            self:storeRecipe(recipeId, recipeData)

            -- Send confirmation back to turtle
            self:sendMessage(connection, {
                action = "recipe_stored",
                recipe_id = recipeId,
                success = true
            })

            self.logger:info("TurtleConnection", "Received and stored recipe: " .. recipeId)
        else
            self:sendMessage(connection, {
                action = "recipe_stored",
                success = false,
                error = "Missing recipe_id or recipe_data"
            })
        end

        return true
    end

    -- Handle recipe request from turtle
    if action == "get_recipe" then
        local itemName = message.item_name
        local recipe = self:getRecipe(itemName)

        if recipe then
            self:sendMessage(connection, {
                action = "recipe_data",
                item_name = itemName,
                recipe = recipe,
                success = true
            })
        else
            self:sendMessage(connection, {
                action = "recipe_data",
                item_name = itemName,
                success = false,
                error = "Recipe not found"
            })
        end

        return true
    end

    -- Handle craft completion
    if action == "craft_complete" then
        local itemName = message.item
        local crafted = message.crafted or 0

        self.logger:info("TurtleConnection", "Turtle #" .. connection.id .. " crafted " .. crafted .. "x " .. itemName)

        if connection.customData then
            connection.customData.status = "idle"
            connection.customData.lastCraft = {
                item = itemName,
                amount = crafted,
                time = os.epoch("utc")
            }
        end

        return true
    end

    -- Handle craft failure
    if action == "craft_failed" then
        local itemName = message.item
        local reason = message.reason or "unknown"

        self.logger:warn("TurtleConnection", "Craft failed for " .. itemName .. ": " .. reason)

        if connection.customData then
            connection.customData.status = "idle"
        end

        return true
    end

    -- Handle heartbeat from turtle
    if action == "heartbeat" then
        if message.stats and connection.customData then
            connection.customData.stats = message.stats
        end
        return true
    end

    return false
end

function TurtleConnection:sendMessage(connection, message)
    rednet.send(connection.id, message, "storage_pair")
end

-- ============================================================================
-- TURTLE COMMANDS
-- ============================================================================

-- Request turtle to enter recipe save mode
function TurtleConnection:requestRecipeSave(connection, itemName)
    self.logger:info("TurtleConnection", "Requesting recipe save for " .. itemName)

    self:sendMessage(connection, {
        action = "enter_recipe_mode",
        item_name = itemName
    })

    if connection.customData then
        connection.customData.status = "recipe_mode"
    end
end

-- Request turtle to craft an item
function TurtleConnection:requestCraft(connection, itemName, amount, ingredients)
    self.logger:info("TurtleConnection", "Requesting craft: " .. amount .. "x " .. itemName)

    local recipe = self:getRecipe(itemName)

    if not recipe then
        self.logger:error("TurtleConnection", "No recipe for " .. itemName)
        return false, "No recipe found"
    end

    self:sendMessage(connection, {
        action = "craft_request",
        item = itemName,
        amount = amount,
        recipe = recipe,
        ingredients = ingredients or {}
    })

    if connection.customData then
        connection.customData.status = "crafting"
        connection.customData.craftsPending = (connection.customData.craftsPending or 0) + 1
    end

    return true
end

-- ============================================================================
-- UI METHODS
-- ============================================================================

function TurtleConnection:drawDetails(connection, x, y, width, height)
    term.setCursorPos(x, y)
    term.setTextColor(colors.cyan)
    term.write("== TURTLE STATUS ==")
    y = y + 2

    if connection.customData then
        -- Status
        term.setCursorPos(x, y)
        term.setTextColor(colors.lightGray)
        term.write("Status:")
        term.setCursorPos(x + 20, y)
        term.setTextColor(colors.white)
        term.write(connection.customData.status or "unknown")
        y = y + 1

        -- Recipes known
        term.setCursorPos(x, y)
        term.setTextColor(colors.lightGray)
        term.write("Recipes Known:")
        term.setCursorPos(x + 20, y)
        term.setTextColor(colors.white)
        term.write(tostring(self:getRecipeCount()))
        y = y + 1

        -- Last craft
        if connection.customData.lastCraft then
            term.setCursorPos(x, y)
            term.setTextColor(colors.lightGray)
            term.write("Last Craft:")
            term.setCursorPos(x + 20, y)
            term.setTextColor(colors.white)
            term.write(connection.customData.lastCraft.amount .. "x " .. connection.customData.lastCraft.item)
            y = y + 1
        end
    end

    return y
end

function TurtleConnection:getActions(connection)
    return {
        {
            label = "VIEW RECIPES",
            color = colors.blue,
            handler = function()
                self:showRecipeList()
            end
        },
        {
            label = "TEST CRAFT",
            color = colors.green,
            handler = function()
                -- Test craft functionality
                self.logger:info("TurtleConnection", "Test craft initiated")
            end
        }
    }
end

function TurtleConnection:showRecipeList()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("=== STORED RECIPES ===")
    print()

    local count = 0
    for itemName, recipe in pairs(self.recipes) do
        count = count + 1
        term.setTextColor(colors.white)
        print(count .. ". " .. (recipe.display or itemName))
        term.setTextColor(colors.lightGray)
        print("   ID: " .. itemName)
        if recipe.wildcard then
            print("   (Supports substitutions)")
        end
        print()
    end

    if count == 0 then
        term.setTextColor(colors.red)
        print("No recipes stored yet.")
    end

    print()
    term.setTextColor(colors.gray)
    print("Press any key to continue...")
    os.pullEvent("key")
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

function TurtleConnection:validate(connection)
    if not connection.id then
        return false, "Missing connection ID"
    end

    if not connection.name then
        return false, "Missing connection name"
    end

    return true, nil
end

-- ============================================================================
-- EXPORT
-- ============================================================================

return TurtleConnection
