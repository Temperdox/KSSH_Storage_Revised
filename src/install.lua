-- KSSH Storage System Dynamic Installer with Rainbow Splash
local GITHUB_REPO = "Temperdox/KSSH_Storage_Revised"
local GITHUB_BRANCH = "master"
local GITHUB_PATH = "src"
local VERSION = "1.0.0"

-- Ignore patterns - files/dirs that should not be downloaded
local IGNORE_PATTERNS = {
    "^%.git",           -- .git directory
    "^%.gitignore$",    -- .gitignore file
    "README%.md$",      -- README files
    "%.backup$",        -- backup files
    "install%.lua$",    -- installer itself
    "^test",           -- test directories
    "^docs",           -- documentation
}

-- Color scheme
local COLORS = {
    background = colors.black,
    text = colors.white,
    highlight = colors.gray,
    highlightText = colors.black,
    success = colors.lime,
    error = colors.red,
    warning = colors.orange,
    info = colors.purple,
    skip = colors.yellow
}

-- Installation mode
local INSTALL_MODE = {
    CLEAN = "clean",
    UPDATE = "update"
}

-- UI Helper Functions
local function clamp(x, a, b)
    return math.max(a, math.min(b, x))
end

local function clearScreen()
    term.setBackgroundColor(COLORS.background)
    term.setTextColor(COLORS.text)
    term.clear()
    term.setCursorPos(1, 1)
end

local function drawHeader(title)
    local w, h = term.getSize()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(COLORS.info)
    term.setTextColor(COLORS.background)
    term.clearLine()
    local titleText = " " .. title .. " "
    local x = math.floor((w - #titleText) / 2) + 1
    term.setCursorPos(x, 1)
    term.write(titleText)
    term.setBackgroundColor(COLORS.background)
    term.setTextColor(COLORS.text)
end

local function drawList(x, y, w, h, title, items, sel, scroll)
    local function line(s)
        term.setCursorPos(x, y)
        term.write((" "):rep(w))
        if s then
            term.setCursorPos(x + 1, y)
            term.write(s:sub(1, math.max(0, w - 2)))
        end
        y = y + 1
    end

    -- Draw title if present
    if title then
        term.setCursorPos(x, y)
        term.write((" "):rep(w))
        term.setCursorPos(x + 1, y)
        term.write(title:sub(1, math.max(0, w - 2)))
        y = y + 1
    end

    local visible = h - (title and 1 or 0)
    sel = clamp(sel, 1, math.max(1, #items))
    scroll = clamp(scroll, 0, math.max(0, #items - visible))

    for i = 1, visible do
        local idx = scroll + i
        local s = items[idx] or ""
        if idx == sel then
            term.setBackgroundColor(COLORS.highlight)
            term.setTextColor(COLORS.highlightText)
            line(s)
            term.setBackgroundColor(COLORS.background)
            term.setTextColor(COLORS.text)
        else
            line(s)
        end
    end
    return sel, scroll
end

local function move(sel, scroll, total, maxRows, delta)
    sel = clamp(sel + delta, 1, math.max(1, total))
    local top = sel - 1
    local bottom = sel
    if top < scroll then
        scroll = top
    elseif bottom > scroll + maxRows then
        scroll = bottom - maxRows
    end
    scroll = clamp(scroll, 0, math.max(0, total - maxRows))
    return sel, scroll
end

local function pickFromList(title, items, descriptions)
    if #items == 0 then return nil end
    if #items == 1 then return 1 end

    clearScreen()
    drawHeader(title)

    local w, h = term.getSize()
    local listH = h - 6  -- Leave room for header and description
    local sel, scr = 1, 0

    while true do
        -- Clear and redraw
        term.setCursorPos(1, 3)
        for i = 3, h do
            term.setCursorPos(1, i)
            term.clearLine()
        end

        -- Draw the list
        sel, scr = drawList(1, 3, w, listH, nil, items, sel, scr)

        -- Draw description if available
        if descriptions and descriptions[sel] then
            term.setCursorPos(1, h - 2)
            term.setTextColor(COLORS.info)
            term.write(string.rep("-", w))
            term.setCursorPos(2, h - 1)
            term.write(descriptions[sel]:sub(1, w - 2))
            term.setCursorPos(2, h)
            local line2 = descriptions[sel]:sub(w - 1, (w - 2) * 2)
            if #line2 > 0 then
                term.write(line2)
            end
            term.setTextColor(COLORS.text)
        end

        -- Handle input
        local e = {os.pullEvent()}
        local ev = e[1]
        if ev == "key" then
            local k = e[2]
            if k == keys.enter then
                return sel
            elseif k == keys.q then
                return nil
            elseif k == keys.up then
                sel, scr = move(sel, scr, #items, listH, -1)
            elseif k == keys.down then
                sel, scr = move(sel, scr, #items, listH, 1)
            elseif k == keys.pageUp then
                sel, scr = move(sel, scr, #items, listH, -(listH - 1))
            elseif k == keys.pageDown then
                sel, scr = move(sel, scr, #items, listH, (listH - 1))
            elseif k == keys.home then
                sel, scr = move(1, 0, #items, listH, 0)
            elseif k == keys["end"] then
                sel, scr = move(#items, math.max(0, #items - listH), #items, listH, 0)
            end
        elseif ev == "mouse_scroll" then
            local d = e[2]
            sel, scr = move(sel, scr, #items, listH, d)
        elseif ev == "term_resize" then
            w, h = term.getSize()
            listH = h - 6
            scr = clamp(scr, 0, math.max(0, #items - listH))
            sel = clamp(sel, 1, math.max(1, #items))
        end
    end
end

local function showProgress(title, message, percent, color)
    clearScreen()
    drawHeader(title)

    local w, h = term.getSize()
    local barWidth = math.min(40, w - 4)
    local barX = math.floor((w - barWidth) / 2)
    local barY = math.floor(h / 2)

    -- Message
    term.setCursorPos(math.floor((w - #message) / 2), barY - 2)
    if color then
        term.setTextColor(color)
    end
    term.write(message)
    term.setTextColor(COLORS.text)

    -- Progress bar
    term.setCursorPos(barX, barY)
    term.write("[")
    local filled = math.floor(barWidth * (percent / 100))  -- This line was missing!
    term.setTextColor(COLORS.success)
    term.write(string.rep("=", filled))
    term.setTextColor(COLORS.text)
    term.write(string.rep(" ", barWidth - filled))
    term.write("]")

    -- Percentage
    local percentText = math.floor(percent) .. "%"
    term.setCursorPos(math.floor((w - #percentText) / 2), barY + 2)
    term.write(percentText)
end

-- Rainbow Splash Animation
local function showAnimatedSplash()
    clearScreen()

    local w, h = term.getSize()

    -- Image drawing function
    local function drawimage(image, x, y, width, bgcolor, fgcolor)
        local startY = y
        term.setCursorPos(x, y)
        for i = 1, #image do
            if math.fmod(i - 1, width) == 0 and i > 1 then
                y = y + 1
                term.setCursorPos(x, y)
            end
            if image[i][2] then
                term.setBackgroundColor(fgcolor)
                term.setTextColor(bgcolor)
            else
                term.setBackgroundColor(bgcolor)
                term.setTextColor(fgcolor)
            end
            if image[i][1] then
                term.write(image[i][1])
            else
                term.write(" ")
            end
        end
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
    end

    -- KSSH logo image data
    local image = {
        {"\x82"}, {"\x90", true}, {"\x82", true}, {"\x90"}, {}, {}, {}, {}, {" ", true}, {" ", true}, {" ", true}, {" ", true}, {" ", true}, {" ", true}, {" ", true}, {"\x83", true}, {},
        {}, {}, {"\x8b"}, {" ", true}, {"\x8b", true}, {}, {}, {}, {" ", true}, {"\x95"}, {}, {}, {}, {}, {"\x82"}, {" ", true}, {"\x95"},
        {}, {}, {}, {"\x82"}, {"\x90", true}, {"\x82", true}, {"\x90"}, {}, {" ", true}, {"\x95"}, {}, {}, {}, {}, {"\x97", true}, {" ", true}, {"\x95"},
        {}, {}, {}, {}, {}, {"\x84", true}, {" ", true}, {"\x95"}, {" ", true}, {"\x95"}, {"\x83", true}, {"\x83", true}, {"\x83", true}, {"\x81", true}, {" ", true}, {"\x9f"}, {},
        {}, {}, {}, {"\x9f", true}, {"\x81", true}, {"\x9f"}, {"\x81"}, {}, {" ", true}, {"\x95"}, {"\x83"}, {"\x90", true}, {" ", true}, {"\x93"}, {"\x81"}, {}, {},
        {}, {}, {"\x87", true}, {" ", true}, {"\x87"}, {}, {}, {}, {" ", true}, {"\x95"}, {}, {}, {"\x8b"}, {" ", true}, {"\x8b", true}, {}, {},
        {"\x9f", true}, {"\x81", true}, {"\x9f"}, {"\x81"}, {}, {}, {}, {}, {" ", true}, {"\x95"}, {}, {}, {}, {"\x82"}, {"\x90", true}, {"\x82", true}, {"\x90"},
    }

    -- Calculate centered position
    local imageWidth = 17
    local imageHeight = 7
    local centerX = math.floor((w - imageWidth) / 2) + 1
    local centerY = math.floor((h - imageHeight) / 2) - 2

    -- Rainbow color sequence
    local rainbowColors = {
        colors.red,
        colors.orange,
        colors.yellow,
        colors.lime,
        colors.green,
        colors.cyan,
        colors.lightBlue,
        colors.blue,
        colors.purple,
        colors.magenta,
        colors.pink
    }

    -- Animate through rainbow colors
    for cycle = 1, #rainbowColors do
        drawimage(image, centerX, centerY, imageWidth, colors.black, rainbowColors[cycle])

        -- Draw title below image
        local title = "KSSH Storage System"
        term.setCursorPos(math.floor((w - #title) / 2) + 1, centerY + imageHeight + 2)
        term.setTextColor(rainbowColors[cycle])
        term.write(title)

        local version = "Installer v" .. VERSION
        term.setCursorPos(math.floor((w - #version) / 2) + 1, centerY + imageHeight + 3)
        term.write(version)

        sleep(0.1)
    end

    -- Fade out effect
    for i = 1, 3 do
        term.setTextColor(colors.gray)
        drawimage(image, centerX, centerY, imageWidth, colors.black, colors.gray)

        local title = "KSSH Storage System"
        term.setCursorPos(math.floor((w - #title) / 2) + 1, centerY + imageHeight + 2)
        term.write(title)

        local version = "Installer v" .. VERSION
        term.setCursorPos(math.floor((w - #version) / 2) + 1, centerY + imageHeight + 3)
        term.write(version)

        sleep(0.1)

        if i < 3 then
            clearScreen()
            sleep(0.05)
        end
    end

    -- Final pause
    term.setCursorPos(math.floor((w - 23) / 2), h - 2)
    term.setTextColor(colors.lightGray)
    term.write("Press any key to begin")

    os.pullEvent("key")
    clearScreen()
end

-- GitHub API Functions
local function getGitHubAPIUrl(path)
    return string.format(
            "https://api.github.com/repos/%s/contents/%s/%s?ref=%s",
            GITHUB_REPO,
            GITHUB_PATH,
            path or "",
            GITHUB_BRANCH
    )
end

local function getRawFileUrl(path)
    return string.format(
            "https://raw.githubusercontent.com/%s/%s/%s/%s",
            GITHUB_REPO,
            GITHUB_BRANCH,
            GITHUB_PATH,
            path
    )
end

local function shouldIgnore(path)
    for _, pattern in ipairs(IGNORE_PATTERNS) do
        if string.match(path, pattern) then
            return true
        end
    end
    return false
end

local function fetchDirectoryContents(path, fileList, errorList)
    fileList = fileList or {}
    errorList = errorList or {}

    local apiUrl = getGitHubAPIUrl(path)

    local headers = {
        ["User-Agent"] = "CC-Installer/" .. VERSION,
        ["Accept"] = "application/vnd.github.v3+json"
    }

    local response = http.get(apiUrl, headers)

    if not response then
        table.insert(errorList, "Failed to fetch directory: " .. (path or "root"))
        return fileList, errorList
    end

    local content = response.readAll()
    response.close()

    local ok, data = pcall(textutils.unserializeJSON, content)
    if not ok or not data then
        table.insert(errorList, "Failed to parse GitHub API response for: " .. (path or "root"))
        return fileList, errorList
    end

    if data.type and data.type == "file" then
        data = {data}
    elseif not data[1] then
        table.insert(errorList, "No contents found in: " .. (path or "root"))
        return fileList, errorList
    end

    for _, item in ipairs(data) do
        local fullPath = path and (path .. "/" .. item.name) or item.name

        if not shouldIgnore(fullPath) and not shouldIgnore(item.name) then
            if item.type == "file" then
                table.insert(fileList, {
                    path = fullPath,
                    size = item.size,
                    sha = item.sha,
                    download_url = item.download_url or getRawFileUrl(fullPath)
                })
            elseif item.type == "dir" then
                fetchDirectoryContents(fullPath, fileList, errorList)
            end
        end
    end

    return fileList, errorList
end

local function getSystemFiles(systemType)
    local basePath = systemType == "storage" and "storage" or "turtle"
    local fileList, errors = fetchDirectoryContents(basePath)
    return fileList, errors
end

-- File Management Functions
local function downloadFile(fileInfo, destination, mode)
    local url = fileInfo.download_url or getRawFileUrl(fileInfo.path)

    local response = http.get(url)
    if not response then
        return false, "Failed to download: " .. fileInfo.path
    end

    local content = response.readAll()
    response.close()

    if mode == INSTALL_MODE.UPDATE and fs.exists(destination) then
        local existingFile = fs.open(destination, "r")
        if existingFile then
            local existingContent = existingFile.readAll()
            existingFile.close()

            if existingContent == content then
                return true, nil, true
            end
        end
    end

    local dir = fs.getDir(destination)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    if mode == INSTALL_MODE.UPDATE and fs.exists(destination) then
        local backupPath = destination .. ".backup"
        if fs.exists(backupPath) then
            fs.delete(backupPath)
        end
        fs.copy(destination, backupPath)
    end

    local file = fs.open(destination, "w")
    if not file then
        return false, "Failed to write: " .. destination
    end

    file.write(content)
    file.close()

    return true, nil, false
end

-- Installation Functions
local function cleanInstall(installType)
    clearScreen()
    drawHeader("Clean Install - Complete System Wipe")

    local w, h = term.getSize()
    term.setCursorPos(2, 3)
    term.setTextColor(COLORS.warning)
    term.write("DELETING ALL FILES...")
    term.setTextColor(COLORS.text)

    local currentProgram = shell.getRunningProgram()

    local function deleteRecursive(path)
        if fs.isDir(path) then
            for _, file in ipairs(fs.list(path)) do
                deleteRecursive(fs.combine(path, file))
            end
        end
        if not fs.isReadOnly(path) and path ~= currentProgram then
            fs.delete(path)
        end
    end

    local allFiles = fs.list("/")
    local totalFiles = #allFiles
    local deletedCount = 0

    for i, file in ipairs(allFiles) do
        local path = fs.combine("/", file)

        if not fs.isReadOnly(path) and path ~= currentProgram and file ~= currentProgram then
            term.setCursorPos(2, 4)
            term.clearLine()
            term.write("Deleting: " .. file .. " (" .. math.floor(i * 100 / totalFiles) .. "%)")

            local ok, err = pcall(deleteRecursive, path)
            if ok then
                deletedCount = deletedCount + 1
            else
                term.setCursorPos(2, 5)
                term.setTextColor(COLORS.error)
                term.write("Failed to delete: " .. file)
                term.setTextColor(COLORS.text)
                sleep(0.5)
            end

            sleep(0.05)
        end
    end

    term.setCursorPos(2, 6)
    term.setTextColor(COLORS.success)
    term.write("Deleted " .. deletedCount .. " files/directories")
    term.setTextColor(COLORS.text)

    term.setCursorPos(2, 8)
    term.write("System cleaned. Installing fresh...")
    sleep(1)
end

local function installFiles(fileList, systemType, mode)
    local total = #fileList
    local completed = 0
    local skipped = 0
    local updated = 0
    local errors = {}

    if mode == INSTALL_MODE.CLEAN then
        cleanInstall(systemType)
    end

    for _, fileInfo in ipairs(fileList) do
        completed = completed + 1
        local percent = (completed / total) * 100

        local displayName = fileInfo.path:match("([^/]+)$") or fileInfo.path

        local localPath = fileInfo.path
        if systemType == "storage" then
            localPath = fileInfo.path:gsub("^storage/", "")
        else
            localPath = fileInfo.path:gsub("^turtle/", "")
        end

        local statusMsg = mode == INSTALL_MODE.UPDATE and "Checking: " .. displayName or "Downloading: " .. displayName

        local success, err, wasSkipped = downloadFile(fileInfo, localPath, mode)

        if not success then
            table.insert(errors, err)
            showProgress("Installing " .. systemType, "ERROR: " .. displayName, percent, COLORS.error)
        elseif wasSkipped then
            skipped = skipped + 1
            showProgress("Installing " .. systemType, "Skipped (unchanged): " .. displayName, percent, COLORS.skip)
        else
            updated = updated + 1
            showProgress("Installing " .. systemType, "Updated: " .. displayName, percent, COLORS.success)
        end

        sleep(0.05)
    end

    return #errors == 0, errors, {
        total = total,
        updated = updated,
        skipped = skipped,
        errors = #errors
    }
end

-- Detection Functions
local function detectSystemType()
    if turtle then
        return "turtle"
    else
        return "computer"
    end
end

local function detectExistingInstallation()
    local storageFiles = {"main.lua", "core/inventory.lua"}
    local turtleFiles = {"main.lua", "service/crafter_service.lua"}

    local hasStorage = true
    for _, file in ipairs(storageFiles) do
        if not fs.exists(file) then
            hasStorage = false
            break
        end
    end

    local hasTurtle = true
    for _, file in ipairs(turtleFiles) do
        if not fs.exists(file) then
            hasTurtle = false
            break
        end
    end

    if hasStorage then
        return "storage"
    elseif hasTurtle then
        return "turtle"
    else
        return nil
    end
end

local function promptInstallMode()
    local options = {
        "Update (preserve settings & logs)",
        "Clean Install (remove everything)",
        "Cancel"
    }

    local descriptions = {
        "Updates code files only, skips unchanged files, preserves logs, configs, and data",
        "Removes ALL files except ROM and this installer - complete fresh start",
        "Exit installer without making changes"
    }

    local selection = pickFromList("Existing Installation Detected", options, descriptions)

    if not selection or selection == 3 then
        return nil
    elseif selection == 1 then
        return INSTALL_MODE.UPDATE
    else
        return INSTALL_MODE.CLEAN
    end
end

local function confirmInstall(systemType, selection, mode)
    clearScreen()
    drawHeader("Confirm Installation")

    local w, h = term.getSize()
    local y = 4

    term.setCursorPos(2, y)
    term.write("Installation Summary:")
    y = y + 2

    term.setCursorPos(2, y)
    term.setTextColor(COLORS.info)
    term.write("System Type: " .. selection)
    term.setTextColor(COLORS.text)
    y = y + 1

    term.setCursorPos(2, y)
    term.write("Device Type: " .. (systemType == "turtle" and "Turtle" or "Computer"))
    y = y + 1

    term.setCursorPos(2, y)
    term.write("Install Mode: " .. (mode == INSTALL_MODE.UPDATE and "Update" or "Clean Install"))
    y = y + 2

    if mode == INSTALL_MODE.UPDATE then
        term.setCursorPos(2, y)
        term.setTextColor(COLORS.info)
        term.write("Update will:")
        term.setTextColor(COLORS.text)
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Preserve logs and configurations")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Skip unchanged files")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Create backups of modified files")
        y = y + 2
    else
        term.setCursorPos(2, y)
        term.setTextColor(COLORS.warning)
        term.write("CLEAN INSTALL WILL:")
        term.setTextColor(COLORS.text)
        y = y + 1
        term.setCursorPos(2, y)
        term.setTextColor(COLORS.error)
        term.write("- DELETE EVERYTHING except ROM & installer")
        term.setTextColor(COLORS.text)
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Remove ALL logs, configs, and programs")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Perform complete fresh installation")
        y = y + 2
    end

    term.setCursorPos(2, y)
    term.write("Press ENTER to continue or Q to cancel")

    while true do
        local event, key = os.pullEvent("key")
        if key == keys.enter then
            return true
        elseif key == keys.q then
            return false
        end
    end
end

local function preflightCheck(systemType)
    clearScreen()
    drawHeader("Checking GitHub Repository...")

    local w, h = term.getSize()
    term.setCursorPos(2, 4)
    term.write("Fetching file list from GitHub...")

    local fileList, errors = getSystemFiles(systemType)

    if #errors > 0 then
        term.setCursorPos(2, 6)
        term.setTextColor(COLORS.error)
        term.write("Failed to fetch file list:")
        term.setTextColor(COLORS.text)

        local y = 8
        for _, err in ipairs(errors) do
            term.setCursorPos(2, y)
            term.write("- " .. err)
            y = y + 1
        end

        term.setCursorPos(2, y + 1)
        term.write("Press any key to exit")
        os.pullEvent("key")
        return nil
    end

    term.setCursorPos(2, 6)
    term.setTextColor(COLORS.success)
    term.write("Found " .. #fileList .. " files to process")
    term.setTextColor(COLORS.text)

    term.setCursorPos(2, 8)
    term.write("File structure:")

    local dirs = {}
    for _, fileInfo in ipairs(fileList) do
        local dir = fs.getDir(fileInfo.path)
        if dir ~= "" and not dirs[dir] then
            dirs[dir] = true
        end
    end

    local y = 9
    for dir, _ in pairs(dirs) do
        if y < h - 3 then
            term.setCursorPos(4, y)
            term.write("- " .. dir .. "/")
            y = y + 1
        end
    end

    if y >= h - 3 then
        term.setCursorPos(4, y)
        term.write("... and more")
    end

    term.setCursorPos(2, h - 1)
    term.write("Press ENTER to continue or Q to cancel")

    while true do
        local event, key = os.pullEvent("key")
        if key == keys.enter then
            return fileList
        elseif key == keys.q then
            return nil
        end
    end
end

local function showComplete(selection, hasStartup, stats, mode)
    clearScreen()
    drawHeader("Installation Complete!")

    local w, h = term.getSize()
    local y = 4

    term.setCursorPos(2, y)
    term.setTextColor(COLORS.success)
    term.write("Successfully installed: " .. selection)
    term.setTextColor(COLORS.text)
    y = y + 2

    if mode == INSTALL_MODE.UPDATE and stats then
        term.setCursorPos(2, y)
        term.write("Update Statistics:")
        y = y + 1
        term.setCursorPos(2, y)
        term.write(string.format("- Files checked: %d", stats.total))
        y = y + 1
        term.setCursorPos(2, y)
        term.setTextColor(COLORS.success)
        term.write(string.format("- Files updated: %d", stats.updated))
        term.setTextColor(COLORS.text)
        y = y + 1
        term.setCursorPos(2, y)
        term.setTextColor(COLORS.skip)
        term.write(string.format("- Files skipped (unchanged): %d", stats.skipped))
        term.setTextColor(COLORS.text)
        y = y + 2
    end

    term.setCursorPos(2, y)
    term.write("To start the system:")
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(COLORS.info)
    term.write("  Run: main")
    term.setTextColor(COLORS.text)
    y = y + 1
    term.setCursorPos(2, y)
    term.write("  or reboot the " .. (selection == "Storage Computer" and "computer" or "turtle"))

    y = y + 2
    term.setCursorPos(2, y)
    term.write("Configuration:")
    y = y + 1

    if selection == "Storage Computer" then
        term.setCursorPos(2, y)
        term.write("- Connect chests via wired modem")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Regular chest = input")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Trapped chest = output")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- All others = storage")
    else
        term.setCursorPos(2, y)
        term.write("- Connect wireless modem")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Place chest in front for buffer")
        y = y + 1
        term.setCursorPos(2, y)
        term.write("- Use recipe learning system")
    end

    term.setCursorPos(2, h - 1)
    term.write("Press any key to continue")
    os.pullEvent("key")
end

-- Main Program
local function main()
    -- Show animated splash screen
    showAnimatedSplash()

    -- Detect system type
    local systemType = detectSystemType()

    -- Check for existing installation
    local existingInstall = detectExistingInstallation()
    local installMode = INSTALL_MODE.CLEAN

    if existingInstall then
        installMode = promptInstallMode()
        if not installMode then
            clearScreen()
            print("Installation cancelled.")
            return
        end
    end

    -- Present options
    local options = {
        "Storage Computer",
        "Crafting Turtle",
        "Cancel"
    }

    local descriptions = {
        "Main storage management system with inventory, sorting, and order processing",
        "Turtle-based crafting system with recipe learning and remote control",
        "Exit installer without making changes"
    }

    local selection = pickFromList("KSSH Installer - Select System Type", options, descriptions)

    if not selection or selection == 3 then
        clearScreen()
        print("Installation cancelled.")
        return
    end

    local selectedType = options[selection]
    local selectedSystem = selectedType == "Storage Computer" and "storage" or "turtle"

    -- Confirm installation
    if not confirmInstall(systemType, selectedType, installMode) then
        clearScreen()
        print("Installation cancelled.")
        return
    end

    -- Preflight check - fetch file list from GitHub
    local fileList = preflightCheck(selectedSystem)
    if not fileList then
        clearScreen()
        print("Installation cancelled.")
        return
    end

    -- Perform installation
    local success, errors, stats = installFiles(fileList, selectedSystem, installMode)

    if not success then
        clearScreen()
        term.setTextColor(COLORS.error)
        print("Installation failed with errors:")
        term.setTextColor(COLORS.text)
        for _, err in ipairs(errors) do
            print("  - " .. err)
        end
        print("\nPress any key to exit")
        os.pullEvent("key")
        return
    end

    -- Check for startup file
    local hasStartup = fs.exists("startup.lua")

    -- Show completion screen
    showComplete(selectedType, hasStartup, stats, installMode)

    -- Set computer label if not set
    if not os.getComputerLabel() then
        if selectedType == "Storage Computer" then
            os.setComputerLabel("KSSH_Storage_" .. os.getComputerID())
        else
            os.setComputerLabel("KSSH_Turtle_" .. os.getComputerID())
        end
    end

    -- Final prompt for auto-start
    clearScreen()
    drawHeader("Installation Complete!")

    local w, h = term.getSize()
    term.setCursorPos(2, 4)
    term.setTextColor(COLORS.success)
    print("KSSH Storage System installed successfully!")
    term.setTextColor(COLORS.text)

    if hasStartup then
        term.setCursorPos(2, 6)
        print("Would you like to start the system now?")
        term.setCursorPos(2, 8)
        term.setTextColor(COLORS.info)
        print("[Y] Yes - Run startup script")
        print("[N] No - Exit to shell")
        print("[R] Reboot computer")
        term.setTextColor(COLORS.text)

        while true do
            local event, key = os.pullEvent("key")
            if key == keys.y then
                clearScreen()
                term.setCursorPos(1, 1)
                print("Starting KSSH Storage System...")
                sleep(0.5)
                shell.run("startup")
                return
            elseif key == keys.n then
                clearScreen()
                term.setCursorPos(1, 1)
                print("Installation complete!")
                print("Run 'startup' to start the system.")
                return
            elseif key == keys.r then
                clearScreen()
                term.setCursorPos(1, 1)
                print("Rebooting...")
                sleep(0.5)
                os.reboot()
            end
        end
    else
        term.setCursorPos(2, 6)
        print("Run 'main' to start the system")
        term.setCursorPos(2, 8)
        print("Press any key to exit to shell...")
        os.pullEvent("key")
        clearScreen()
        term.setCursorPos(1, 1)
    end
end

-- Run the installer
main()