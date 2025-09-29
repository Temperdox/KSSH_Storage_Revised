-- Main turtle program with UI-safe logging
-- Load UI Manager first
local UIManager = require("ui.ui_manager")

-- Create UI early
local ui = UIManager.new()

-- Initialize logging with UI console callback
local LogPrint = require("util.log_print")
LogPrint.init(function(msg)
    -- Send log messages to UI console
    if ui and ui.addConsoleMessage then
        ui:addConsoleMessage(msg)
    end
end)

-- Create a logger that only logs to file, not console
local log = LogPrint.print

log("=== Turtle System Starting ===")
log("Time:", os.date())
log("Turtle ID:", os.getComputerID())
log("Label:", os.getComputerLabel() or "unlabeled")

-- Load modules
local ExecutorService = require("service.executor_service")
local Bridge = require("tasks.bridge")
local CrafterService = require("service.crafter_service")
local RecipeService = require("service.recipe_service")

-- Create executor (smaller for turtle)
local CORE_THREADS = 4
local MAX_THREADS = 8

log("Creating executor service...")
local executor = ExecutorService.new(CORE_THREADS, MAX_THREADS)

-- Start log writer with executor
LogPrint.startWriter(executor)

-- Create bridge
log("Creating rednet bridge...")
local bridge = Bridge.new()
bridge:init(executor)

-- Create services
log("Creating services...")
local crafter = CrafterService.new(bridge)
local recipes = RecipeService.new(bridge)

-- Initialize services
crafter:init()
recipes:init()

-- Now initialize UI with all dependencies
log("Initializing UI...")
ui:init(executor, bridge, {
    crafter = crafter,
    recipes = recipes
})

-- Create a safe print that goes to UI console
local function uiPrint(...)
    local args = {...}
    local message = table.concat(args, " ")
    ui:addConsoleMessage(message)
    -- Also log to file
    log(...)
end

-- Override global print ONLY for service modules to use UI console
_G.print = uiPrint

-- UI is ready, show welcome message
ui:addConsoleMessage("=== KSSH Turtle Crafter ===")
ui:addConsoleMessage("System initialized")
ui:addConsoleMessage("Type 'help' or press Enter for commands")

-- Touch event handler (high priority)
executor:submit(function()
    log("Touch handler ready")
    while true do
        local event, side, x, y = os.pullEvent("mouse_click")
        -- Handle touch/click
        ui:handleTouch(x, y)
    end
end, "touch_handler", 10)

-- Key event handler for console scrolling and commands
executor:submit(function()
    log("Key handler ready")
    local inputMode = false
    local inputBuffer = ""

    while true do
        local event, key = os.pullEvent("key")

        if inputMode then
            -- We're in input mode
            if key == keys.enter then
                -- Process the command
                inputMode = false

                if inputBuffer ~= "" then
                    ui:addConsoleMessage("> " .. inputBuffer)

                    -- Process command
                    local parts = {}
                    for part in inputBuffer:gmatch("%S+") do
                        table.insert(parts, part)
                    end

                    local cmd = parts[1]

                    if cmd == "learn" then
                        ui:addConsoleMessage("Starting recipe learning...")
                        executor:submit(function()
                            local ok, result = pcall(function()
                                return recipes:learnRecipe()
                            end)
                            if ok and result then
                                ui:addConsoleMessage("Recipe learned successfully!")
                            else
                                ui:addConsoleMessage("Recipe learning failed: " .. tostring(result))
                            end
                        end, "learn_recipe", 8)

                    elseif cmd == "status" then
                        ui:showStatus()

                    elseif cmd == "test" then
                        ui:addConsoleMessage("Running test craft...")
                        executor:submit(function()
                            local testPattern = {
                                pattern = {"x e e", "e e e", "e e e"},
                                key = {
                                    x = {item = "minecraft:oak_log", wildcard = false},
                                    e = {item = "none"}
                                },
                                expect = {{need = 1, item = "minecraft:oak_log"}},
                                crafts = 1,
                                outId = "minecraft:oak_planks"
                            }

                            crafter.currentPattern = testPattern
                            local ok, err, made = crafter:craftN(1)

                            if ok then
                                ui:addConsoleMessage("Test craft successful! Made: " .. tostring(made))
                            else
                                ui:addConsoleMessage("Test craft failed: " .. tostring(err))
                            end
                        end, "test_craft", 7)

                    elseif cmd == "inventory" then
                        ui:addConsoleMessage("=== Turtle Inventory ===")
                        local total = 0
                        for slot = 1, 16 do
                            local item = turtle.getItemDetail(slot)
                            if item then
                                ui:addConsoleMessage(string.format("Slot %2d: %s x%d",
                                        slot, item.name, item.count))
                                total = total + item.count
                            end
                        end
                        ui:addConsoleMessage("Total items: " .. tostring(total))

                    elseif cmd == "clear" then
                        ui:clearConsole()

                    elseif cmd == "drop" then
                        ui:addConsoleMessage("Dropping all items...")
                        local dropped = 0
                        for slot = 1, 16 do
                            local item = turtle.getItemDetail(slot)
                            if item then
                                turtle.select(slot)
                                if turtle.drop() then
                                    dropped = dropped + (item and item.count or 0)
                                end
                            end
                        end
                        ui:addConsoleMessage("Dropped " .. tostring(dropped) .. " items")

                    elseif cmd == "help" then
                        ui:addConsoleMessage("=== Commands ===")
                        ui:addConsoleMessage("  learn - Interactive recipe learning")
                        ui:addConsoleMessage("  status - Show system status")
                        ui:addConsoleMessage("  test - Test craft with dummy recipe")
                        ui:addConsoleMessage("  inventory - Show current inventory")
                        ui:addConsoleMessage("  clear - Clear console")
                        ui:addConsoleMessage("  drop - Drop all items")
                        ui:addConsoleMessage("  help - Show this help")
                        ui:addConsoleMessage("Press Enter to type a command")

                    else
                        if #parts > 0 then
                            ui:addConsoleMessage("Unknown command: " .. tostring(cmd))
                        end
                    end
                end

                inputBuffer = ""

                -- Redraw UI
                ui:draw()

            elseif key == keys.backspace then
                if #inputBuffer > 0 then
                    inputBuffer = inputBuffer:sub(1, -2)
                    -- Update input display
                    term.setCursorPos(3 + #inputBuffer, ui.height - 1)
                    term.write(" ")
                    term.setCursorPos(3 + #inputBuffer, ui.height - 1)
                end

            else
                -- Add character to input
                local char = keys.getName(key)
                if char and #char == 1 then
                    inputBuffer = inputBuffer .. char
                    term.write(char)
                end
            end

        else
            -- Not in input mode, handle navigation keys
            if key == keys.enter then
                -- Enter input mode
                inputMode = true
                inputBuffer = ""

                -- Show input prompt
                term.setCursorPos(1, ui.height - 1)
                term.setBackgroundColor(colors.gray)
                term.clearLine()
                term.setTextColor(colors.white)
                term.write("> ")
                term.setCursorBlink(true)

            elseif key == keys.up then
                -- Scroll console up
                ui.consoleScroll = math.max(0, ui.consoleScroll - 1)
                ui:draw()

            elseif key == keys.down then
                -- Scroll console down
                local maxScroll = math.max(0, #ui.consoleLines - (ui.height - 9))
                ui.consoleScroll = math.min(maxScroll, ui.consoleScroll + 1)
                ui:draw()

            elseif key == keys.pageUp then
                -- Page up
                ui.consoleScroll = math.max(0, ui.consoleScroll - 5)
                ui:draw()

            elseif key == keys.pageDown then
                -- Page down
                local maxScroll = math.max(0, #ui.consoleLines - (ui.height - 9))
                ui.consoleScroll = math.min(maxScroll, ui.consoleScroll + 5)
                ui:draw()
            end
        end
    end
end, "key_handler", 9)

-- Bridge listener (high priority)
executor:submit(function()
    bridge:listen()
end, "bridge_listener", 10)

-- Statistics reporter (low priority, recurring)
executor:submitRecurring(function()
    local execStats = executor:getStats()
    local bridgeStats = bridge:getStats()

    -- Update UI stats
    ui:updateStatus()

    -- Log to file only (not console)
    log(string.format(
            "[stats] Tasks: %d/%d | Messages: %d rx, %d tx | Crafts: %d | Log queue: %d",
            execStats.tasks.completed,
            execStats.tasks.submitted,
            bridgeStats.received,
            bridgeStats.sent,
            crafter.stats.crafted,
            LogPrint.getQueueSize()
    ))
end, 60, "stats_reporter", 2)

-- Heartbeat to computer (low priority, recurring)
executor:submitRecurring(function()
    if bridge.computerId then
        bridge:send({
            action = "heartbeat",
            turtleId = os.getComputerID(),
            uptime = os.clock(),
            stats = {
                crafter = crafter.stats,
                recipes = recipes:getStats()
            }
        })
    end
end, 30, "heartbeat", 1)

-- Shutdown handler
local function shutdown()
    ui:addConsoleMessage("Shutting down...")
    LogPrint.flush()
    LogPrint.close()
    executor:shutdown()
    bridge:stop()

    -- Clear screen and show shutdown message
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    print("System shutdown complete")
end

-- Start executor
log("Starting executor with", CORE_THREADS, "core threads...")
local workers = executor:start()

if #workers == 0 then
    workers = { function() while true do sleep(1) end end }
end

ui:addConsoleMessage("System ready!")
ui:addConsoleMessage("Press Enter to type commands")
ui:addConsoleMessage("Use buttons for quick actions")

-- Run with error handling
local ok, err = pcall(function()
    parallel.waitForAll(table.unpack(workers))
end)

if not ok then
    log("[ERROR] System error:", err)
    shutdown()
    error(err)
end

shutdown()