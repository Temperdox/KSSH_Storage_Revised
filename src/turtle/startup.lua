-- ------------- guards & label ----------------
if not turtle then
    print("This script must be run on a turtle!")
    return
end

if not os.getComputerLabel() then
    os.setComputerLabel(("KSSH_Turtle_%d"):format(os.getComputerID()))
end

-- ------------- small utils -------------------
local function isFile(p) return fs.exists(p) and not fs.isDir(p) end
local function isDir(p)  return fs.exists(p) and fs.isDir(p) end

local function findEntrypoint()
    local candidates = {
        "service/main.lua",
        "service/turtle_main.lua",
        "turtle_main.lua",
        "main.lua",
    }
    for _, p in ipairs(candidates) do
        if isFile(p) then return p end
        if isDir(p) and isFile(fs.combine(p, "main.lua")) then
            return fs.combine(p, "main.lua")
        end
    end
    return nil
end

local function centerWrite(y, text, color)
    local w, _ = term.getSize()
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    if color and term.isColor and term.isColor() then term.setTextColor(color) end
    term.setCursorPos(x, y)
    term.write(text)
end

-- ------------- splash ------------------------
local version = "1.2.0"
local logo = {
    "   _  __ ____ ____ _   _   ",
    " | |/ // ___) ___) | | \\",
    "|   ( \\__ \\ __ \\| |=| |",
    "|_|\\_\\(___/(___/|_| |_|",
    "Turtle Crafter v" .. version
}

local function drawSplash()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setTextColor(colors.purple)
    local w, h = term.getSize()
    local startY = math.floor((h - #logo) / 2) - 2
    for i, line in ipairs(logo) do
        centerWrite(startY + i, line, colors.purple)
    end
    return startY + #logo + 2 -- barY
end

local function drawBar(barY, width)
    local w, _ = term.getSize()
    local barX = math.max(1, math.floor((w - width) / 2) + 1)
    term.setTextColor(colors.white)
    term.setCursorPos(barX - 1, barY); term.write("[")
    term.setCursorPos(barX + width, barY); term.write("]")
    return barX
end

local function animateBar(barX, barY, width, delay)
    delay = delay or 0.03
    if term.isColor and term.isColor() then term.setTextColor(colors.lime) end
    for i = 1, width do
        term.setCursorPos(barX + i - 1, barY); term.write("=")
        sleep(delay)
    end
end

local function showStatus(msg, y, color)
    local w, _ = term.getSize()
    term.setTextColor(color or colors.white)
    term.setCursorPos(1, y); term.clearLine()
    centerWrite(y, msg, color)
end

-- ------------- boot flow ---------------------
local barY = drawSplash()
local barW = 30
local barX = drawBar(barY, barW)
animateBar(barX, barY, barW, 0.02)

local statusY = barY + 2
showStatus("Initializing systems...", statusY, colors.yellow); sleep(0.2)
showStatus("Loading executor service...", statusY, colors.yellow); sleep(0.2)
showStatus("Starting UI manager...", statusY, colors.yellow); sleep(0.2)
showStatus("Connecting to network...", statusY, colors.yellow); sleep(0.2)

local entry = findEntrypoint()
if not entry then
    term.setTextColor(colors.red)
    showStatus("No turtle entrypoint found.", statusY, colors.red)
    sleep(0.2)
    term.setCursorPos(1, statusY + 2)
    print("Expected one of:")
    print("  service/main.lua")
    print("  service/turtle_main.lua")
    print("  turtle_main.lua")
    print("  main.lua")
    return
end

showStatus("System ready!", statusY, colors.lime); sleep(0.6)

-- clear and launch
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("[startup] launching:", entry)

local ok, err = pcall(function() shell.run(entry) end)
if ok then return end

-- ------------- crash screen ------------------
local w, h = term.getSize()
term.setBackgroundColor(colors.black)
term.clear()
term.setTextColor(colors.red)
local title = "=== SYSTEM CRASHED ==="
centerWrite(2, title, colors.red)
term.setTextColor(colors.white)
term.setCursorPos(1, 4)
print("Entrypoint:", entry)
print("Error Details:")
print(tostring(err))
term.setCursorPos(1, h - 1)
term.setTextColor(colors.yellow)
print("Press any key to exit...")
os.pullEvent("key")
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
