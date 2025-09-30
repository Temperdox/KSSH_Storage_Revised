-- NETStore Storage System Dynamic Installer
local GITHUB_REPO   = "Temperdox/KSSH_Storage_Revised"
local GITHUB_BRANCH = "master"
local GITHUB_PATH   = "src"
local VERSION       = "1.0.0"

-- Ignore patterns
local IGNORE_PATTERNS = {
    "^%.git", "^%.gitignore$", "README%.md$", "%.backup$", "install%.lua$", "^docs",
}

-- Color scheme
local COLORS = {
    background = colors.black, text = colors.white,
    highlight = colors.gray,   highlightText = colors.black,
    success = colors.lime,     error = colors.red,
    warning = colors.orange,   info = colors.purple,
    skip = colors.yellow
}

local INSTALL_MODE = { CLEAN = "clean", UPDATE = "update" }

-- ========= UI helpers =========
local function clamp(x,a,b) return math.max(a, math.min(b, x)) end
local function clearScreen()
    term.setBackgroundColor(COLORS.background)
    term.setTextColor(COLORS.text)
    term.clear(); term.setCursorPos(1,1)
end
local function drawHeader(title)
    local w = select(1, term.getSize())
    term.setCursorPos(1,1)
    term.setBackgroundColor(COLORS.info)
    term.setTextColor(COLORS.background)
    term.clearLine()
    local s = " "..title.." "
    term.setCursorPos(math.floor((w-#s)/2)+1,1)
    term.write(s)
    term.setBackgroundColor(COLORS.background)
    term.setTextColor(COLORS.text)
end

local function drawList(x,y,w,h,title,items,sel,scroll)
    local function line(s)
        term.setCursorPos(x,y); term.write((" "):rep(w))
        if s then term.setCursorPos(x+1,y); term.write(s:sub(1, math.max(0, w-2))) end
        y=y+1
    end
    if title then
        term.setCursorPos(x,y); term.write((" "):rep(w))
        term.setCursorPos(x+1,y); term.write(title:sub(1, math.max(0,w-2)))
        y=y+1
    end
    local visible = h - (title and 1 or 0)
    sel   = clamp(sel, 1, math.max(1, #items))
    scroll= clamp(scroll, 0, math.max(0, #items - visible))
    for i=1,visible do
        local idx = scroll + i
        local s = items[idx] or ""
        if idx == sel then
            term.setBackgroundColor(COLORS.highlight)
            term.setTextColor(COLORS.highlightText)
            line(s)
            term.setBackgroundColor(COLORS.background)
            term.setTextColor(COLORS.text)
        else line(s) end
    end
    return sel, scroll
end

local function move(sel, scroll, total, maxRows, delta)
    sel = clamp(sel + delta, 1, math.max(1,total))
    local top = sel-1; local bottom = sel
    if top < scroll then scroll = top
    elseif bottom > scroll + maxRows then scroll = bottom - maxRows end
    scroll = clamp(scroll, 0, math.max(0, total - maxRows))
    return sel, scroll
end

local function pickFromList(title, items, descriptions)
    if #items == 0 then return nil end
    if #items == 1 then return 1 end

    clearScreen(); drawHeader(title)
    local w,h = term.getSize()
    local listH = h - 6
    local sel, scr = 1, 0

    while true do
        -- clear body
        for i=3,h do term.setCursorPos(1,i); term.clearLine() end
        sel, scr = drawList(1,3,w,listH,nil,items,sel,scr)

        if descriptions and descriptions[sel] then
            term.setCursorPos(1,h-2); term.setTextColor(COLORS.info); term.write(string.rep("-", w))
            term.setCursorPos(2,h-1); term.write(descriptions[sel]:sub(1, w-2))
            term.setCursorPos(2,h);   local line2 = descriptions[sel]:sub(w-1, (w-2)*2); if #line2 > 0 then term.write(line2) end
            term.setTextColor(COLORS.text)
        end

        local e = { os.pullEvent() }
        local ev = e[1]
        if ev == "key" then
            local k = e[2]
            if k == keys.enter then return sel
            elseif k == keys.q then return nil
            elseif k == keys.up then sel, scr = move(sel,scr,#items,listH,-1)
            elseif k == keys.down then sel, scr = move(sel,scr,#items,listH, 1)
            elseif k == keys.pageUp then sel, scr = move(sel,scr,#items,listH, -(listH-1))
            elseif k == keys.pageDown then sel, scr = move(sel,scr,#items,listH,  (listH-1))
            elseif k == keys.home then sel, scr = move(1,0,#items,listH,0)
            elseif k == keys["end"] then sel, scr = move(#items, math.max(0, #items-listH), #items, listH, 0) end
        elseif ev == "mouse_scroll" then
            sel, scr = move(sel,scr,#items,listH, e[2])
        elseif ev == "mouse_click" then
            -- allow click-to-select
            local _, _, mx, my = table.unpack(e)
            local listTop = 3
            if my >= listTop and my < listTop + listH then
                local clicked = scr + (my - listTop) + 1
                if clicked >= 1 and clicked <= #items then sel = clicked; return sel end
            end
        elseif ev == "term_resize" then
            w,h = term.getSize(); listH = h - 6
            scr = clamp(scr, 0, math.max(0, #items - listH)); sel = clamp(sel, 1, math.max(1, #items))
        end
    end
end

local function showProgress(title, message, percent, color)
    clearScreen(); drawHeader(title)
    local w,h = term.getSize()
    local barWidth = math.min(40, w-4)
    local barX = math.floor((w - barWidth)/2)
    local barY = math.floor(h/2)

    term.setCursorPos(math.floor((w - #message)/2), barY-2)
    if color then term.setTextColor(color) end
    term.write(message); term.setTextColor(COLORS.text)

    term.setCursorPos(barX, barY); term.write("[")
    local filled = math.floor(barWidth * (percent/100))
    term.setTextColor(COLORS.success); term.write(string.rep("=", filled))
    term.setTextColor(COLORS.text);    term.write(string.rep(" ", barWidth - filled)); term.write("]")

    local p = math.floor(percent).."%"
    term.setCursorPos(math.floor((w - #p)/2), barY+2); term.write(p)
end

-- Graphic decoder functions
local function decodegraphic(jsonData)
    -- If jsonData is already a table (embedded), use it directly
    if type(jsonData) == "table" then
        for k, v in pairs(jsonData) do
            return {
                width = v.width,
                image = v.image,
            }
        end
    end
    -- Otherwise try to load from file
    local file = fs.open(jsonData..".json", "r")
    if not file then return nil end
    local contents = file.readAll()
    file.close()
    for k, v in pairs(textutils.unserialiseJSON(contents)) do
        return {
            width = v.width,
            image = v.image,
        }
    end
end

local function drawgraphic(screen, image, x, y, fg, bg)
    local img = decodegraphic(image)
    if not img then return end

    screen.setCursorPos(x, y)
    for i = 1, #img.image do
        local ch, fgc, bgc = 0x80, fg, bg
        for i2 = 1, 5 do
            local c = img.image[i]:sub(i2, i2)
            if c == "1" then
                ch = ch + 2^(i2-1)
            end
        end
        if img.image[i]:sub(6, 6) == "1" then
            ch = bit32.band(bit32.bnot(ch), 0x1F) + 0x80
            fgc, bgc = bgc, fgc
        end
        if math.fmod(i - 1, img.width) == 0 and i > 1 then
            y = y + 1
            screen.setCursorPos(x, y)
        end
        screen.blit(string.char(ch), colors.toBlit(fgc), colors.toBlit(bgc))
    end
end

-- Embedded sergal graphic data
local sergalGraphicData = {
    ["sergal"] = {
        width = 12,
        image = {
            "110100",
            "101111",
            "001111",
            "000011",
            "000010",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "010000",
            "111101",
            "111111",
            "111111",
            "111111",
            "001111",
            "001111",
            "000010",
            "000000",
            "000000",
            "000000",
            "000000",
            "000011",
            "001111",
            "111111",
            "111111",
            "111111",
            "111110",
            "111101",
            "111111",
            "001010",
            "000000",
            "000000",
            "011100",
            "111101",
            "111111",
            "111111",
            "111111",
            "111111",
            "111111",
            "011111",
            "111111",
            "111111",
            "101111",
            "001011",
            "000001",
            "111111",
            "111111",
            "111111",
            "111111",
            "111111",
            "111111",
            "110011",
            "111100",
            "111100",
            "111110",
            "111000",
            "011100",
            "111001",
            "111111",
            "111111",
            "111111",
            "111111",
            "111111",
            "111100",
            "111100",
            "111000",
            "000000",
            "000000",
            "000000",
            "010101",
            "111000",
            "111111",
            "111111",
            "111111",
            "111111",
            "001011",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "010000",
            "110100",
            "111101",
            "111111",
            "111010",
            "101000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "000000",
            "010000",
            "101000",
            "000000",
            "000000",
            "000000",
            "000000"
        }
    }
}

-- Simple animated splash screen
local function showAnimatedSplash()
    clearScreen()
    local w, h = term.getSize()

    local rainbowColors = {
        colors.red, colors.orange, colors.yellow, colors.lime,
        colors.green, colors.cyan, colors.lightBlue, colors.blue,
        colors.purple, colors.magenta, colors.pink
    }

    -- Calculate centering for the sergal (12 chars wide, ~9 rows tall based on the image data)
    local sergalWidth = 12
    local sergalHeight = math.ceil(#sergalGraphicData.sergal.image / sergalWidth)
    local startX = math.floor((w - sergalWidth) / 2) + 1
    local startY = math.floor((h - sergalHeight) / 2) - 2

    -- Ensure it fits on screen
    if startY < 1 then startY = 1 end

    -- Animation loop
    for cycle = 1, #rainbowColors do
        local currentColor = rainbowColors[cycle]

        -- Clear screen
        term.setBackgroundColor(colors.black)
        term.clear()

        -- Draw sergal with current rainbow color
        drawgraphic(term, sergalGraphicData, startX, startY, currentColor, colors.black)

        -- Draw text (stays white) - positioned below the sergal
        local textY = math.min(h - 2, startY + sergalHeight + 2)

        local title = "NETStore Storage System"
        term.setCursorPos(math.floor((w - #title) / 2) + 1, textY)
        term.setTextColor(colors.white)
        term.write(title)

        local version = "Installer v" .. VERSION
        term.setCursorPos(math.floor((w - #version) / 2) + 1, textY + 1)
        term.write(version)

        sleep(0.08)
    end

    -- Brief hold
    sleep(1.5)
    clearScreen()
end

-- ========= GitHub helpers =========
local function getGitHubAPIUrl(path)
    return string.format("https://api.github.com/repos/%s/contents/%s/%s?ref=%s", GITHUB_REPO, GITHUB_PATH, path or "", GITHUB_BRANCH)
end
local function getRawFileUrl(path)
    return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", GITHUB_REPO, GITHUB_BRANCH, GITHUB_PATH, path)
end
local function shouldIgnore(path)
    for _,pat in ipairs(IGNORE_PATTERNS) do if string.match(path, pat) then return true end end
    return false
end

local function fetchDirectoryContents(path, fileList, errorList)
    fileList = fileList or {}; errorList = errorList or {}
    local apiUrl = getGitHubAPIUrl(path)
    local headers = { ["User-Agent"]="CC-Installer/"..VERSION, ["Accept"]="application/vnd.github.v3+json" }
    local response = http.get(apiUrl, headers)
    if not response then table.insert(errorList, "Failed to fetch directory: "..(path or "root")); return fileList, errorList end
    local content = response.readAll(); response.close()

    local ok, data = pcall(textutils.unserializeJSON, content)
    if not ok or not data then table.insert(errorList, "Failed to parse GitHub API response for: "..(path or "root")); return fileList, errorList end

    if data.type == "file" then data = { data }
    elseif not data[1] then table.insert(errorList, "No contents found in: "..(path or "root")); return fileList, errorList end

    for _,item in ipairs(data) do
        local fullPath = path and (path.."/"..item.name) or item.name
        if not shouldIgnore(fullPath) and not shouldIgnore(item.name) then
            if item.type == "file" then
                table.insert(fileList, { path=fullPath, size=item.size, sha=item.sha, download_url=item.download_url or getRawFileUrl(fullPath) })
            elseif item.type == "dir" then
                fetchDirectoryContents(fullPath, fileList, errorList)
            end
        end
    end
    return fileList, errorList
end

local function getSystemFiles(systemType)
    local basePath = (systemType == "storage") and "storage" or "turtle"
    return fetchDirectoryContents(basePath)
end

-- ========= File management =========
local function downloadFile(fileInfo, destination, mode)
    local url = fileInfo.download_url or getRawFileUrl(fileInfo.path)
    local response = http.get(url)
    if not response then return false, "Failed to download: "..fileInfo.path end
    local content = response.readAll(); response.close()

    if mode == INSTALL_MODE.UPDATE and fs.exists(destination) then
        local fh = fs.open(destination, "r")
        if fh then
            local existing = fh.readAll(); fh.close()
            if existing == content then return true, nil, true end
        end
    end

    local dir = fs.getDir(destination)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    if mode == INSTALL_MODE.UPDATE and fs.exists(destination) then
        local backup = destination..".backup"
        if fs.exists(backup) then fs.delete(backup) end
        fs.copy(destination, backup)
    end

    local out = fs.open(destination, "w")
    if not out then return false, "Failed to write: "..destination end
    out.write(content); out.close()
    return true, nil, false
end

-- ========= Install routines =========
local function cleanInstall()
    clearScreen(); drawHeader("Clean Install - Complete System Wipe")
    local w = select(1, term.getSize())
    term.setCursorPos(2,3); term.setTextColor(COLORS.warning); term.write("DELETING ALL FILES..."); term.setTextColor(COLORS.text)

    local currentProgram = shell.getRunningProgram()
    local function deleteRecursive(path)
        if fs.isDir(path) then
            for _,file in ipairs(fs.list(path)) do deleteRecursive(fs.combine(path,file)) end
        end
        if not fs.isReadOnly(path) and path ~= currentProgram then fs.delete(path) end
    end

    local all = fs.list("/"); local total = #all; local deleted = 0
    for i,file in ipairs(all) do
        local p = fs.combine("/", file)
        if not fs.isReadOnly(p) and p ~= currentProgram and file ~= currentProgram then
            term.setCursorPos(2,4); term.clearLine()
            term.write("Deleting: "..file.." ("..math.floor(i*100/total).."%)")
            local ok = pcall(deleteRecursive, p); if ok then deleted = deleted + 1 end
            sleep(0.03)
        end
    end
    term.setCursorPos(2,6); term.setTextColor(COLORS.success); term.write("Deleted "..deleted.." files/directories"); term.setTextColor(COLORS.text)
    term.setCursorPos(2,8); term.write("System cleaned. Installing fresh...")
    sleep(0.6)
end

local function installFiles(fileList, systemType, mode)
    local total, completed, skipped, updated = #fileList, 0, 0, 0
    local errors = {}

    if mode == INSTALL_MODE.CLEAN then cleanInstall() end

    for _,fi in ipairs(fileList) do
        completed = completed + 1
        local percent = (completed/total) * 100
        local displayName = fi.path:match("([^/]+)$") or fi.path

        local localPath
        if systemType == "storage" then localPath = fi.path:gsub("^storage/", "")
        else localPath = fi.path:gsub("^turtle/", "") end

        local ok, err, wasSkipped = downloadFile(fi, localPath, mode)
        if not ok then
            table.insert(errors, err)
            showProgress("Installing "..systemType, "ERROR: "..displayName, percent, COLORS.error)
        elseif wasSkipped then
            skipped = skipped + 1
            showProgress("Installing "..systemType, "Skipped (unchanged): "..displayName, percent, COLORS.skip)
        else
            updated = updated + 1
            showProgress("Installing "..systemType, "Updated: "..displayName, percent, COLORS.success)
        end
        sleep(0.03)
    end

    return #errors == 0, errors, { total=total, updated=updated, skipped=skipped, errors=#errors }
end

-- ========= Detection =========
local function detectSystemType() return turtle and "turtle" or "computer" end

local function detectExistingInstallation()
    -- Check if there are any files/directories other than rom and the installer
    local currentProgram = shell.getRunningProgram()
    local hasFiles = false

    for _, file in ipairs(fs.list("/")) do
        local fullPath = fs.combine("/", file)
        -- Skip rom directory and the installer itself
        if file ~= "rom" and fullPath ~= currentProgram and file ~= currentProgram then
            hasFiles = true
            break
        end
    end

    -- If there are any files (other than rom and installer), consider it an existing installation
    if hasFiles then
        return "storage"  -- Default to storage type for existing installations
    else
        return nil  -- Clean system
    end
end

-- ========= Prompts (list-based / auto-continue) =========
local function promptInstallMode()
    local options = { "Update (preserve settings & logs)", "Clean Install (remove everything)", "Cancel" }
    local descriptions = {
        "Updates code files only, skips unchanged files, preserves logs, configs, and data",
        "Removes ALL files except ROM and this installer - complete fresh start",
        "Exit installer without making changes"
    }
    local sel = pickFromList("Existing Installation Detected", options, descriptions)
    if not sel or sel == 3 then return nil
    elseif sel == 1 then return INSTALL_MODE.UPDATE
    else return INSTALL_MODE.CLEAN end
end

local function confirmInstall(systemType, selection, mode)
    local options = { "Proceed with Install", "Cancel" }
    local desc = {
        (mode == INSTALL_MODE.UPDATE)
                and "Update: preserves logs/config, skips unchanged, backs up modified files"
                or  "CLEAN INSTALL: deletes EVERYTHING except ROM & installer, then fresh install",
        "Return to previous menu"
    }

    -- render summary once behind the picker
    clearScreen(); drawHeader("Confirm Installation")
    local y = 4
    term.setCursorPos(2,y); term.write("Installation Summary:"); y=y+2
    term.setCursorPos(2,y); term.setTextColor(COLORS.info); term.write("System Type: "..selection); term.setTextColor(COLORS.text); y=y+1
    term.setCursorPos(2,y); term.write("Device Type: "..(systemType=="turtle" and "Turtle" or "Computer")); y=y+1
    term.setCursorPos(2,y); term.write("Install Mode: "..(mode==INSTALL_MODE.UPDATE and "Update" or "Clean Install")); y=y+2

    -- list picker at the bottom
    local picked = pickFromList("Confirm Installation", options, desc)
    return picked == 1
end

local function preflightCheck(systemType)
    clearScreen(); drawHeader("Checking GitHub Repository...")
    term.setCursorPos(2,4); term.write("Fetching file list from GitHub...")

    local fileList, errors = getSystemFiles(systemType)
    if #errors > 0 then
        term.setCursorPos(2,6); term.setTextColor(COLORS.error); term.write("Failed to fetch file list:"); term.setTextColor(COLORS.text)
        local y = 8
        for _,err in ipairs(errors) do term.setCursorPos(2,y); term.write("- "..err); y=y+1 end
        term.setCursorPos(2,y+1); term.write("Press any key to exit"); os.pullEvent("key")
        return nil
    end

    term.setCursorPos(2,6); term.setTextColor(COLORS.success); term.write("Found "..#fileList.." files to process"); term.setTextColor(COLORS.text)
    term.setCursorPos(2,8); term.write("File structure:")

    local dirs = {}; for _,fi in ipairs(fileList) do local d=fs.getDir(fi.path); if d~="" and not dirs[d] then dirs[d]=true end end
    local y=9; local w,h = term.getSize()
    for d,_ in pairs(dirs) do
        if y < h-3 then term.setCursorPos(4,y); term.write("- "..d.."/"); y=y+1 end
    end
    if y >= h-3 then term.setCursorPos(4,y); term.write("... and more") end

    -- Auto-continue after a short pause (no extra keypress)
    sleep(0.7)
    return fileList
end

local function showComplete(selection, hasStartup, stats, mode)
    clearScreen(); drawHeader("Installation Complete!")
    local y=4
    term.setCursorPos(2,y); term.setTextColor(COLORS.success); term.write("Successfully installed: "..selection); term.setTextColor(COLORS.text); y=y+2
    if mode == INSTALL_MODE.UPDATE and stats then
        term.setCursorPos(2,y); term.write("Update Statistics:"); y=y+1
        term.setCursorPos(2,y); term.write(string.format("- Files checked: %d", stats.total)); y=y+1
        term.setCursorPos(2,y); term.setTextColor(COLORS.success); term.write(string.format("- Files updated: %d", stats.updated)); term.setTextColor(COLORS.text); y=y+1
        term.setCursorPos(2,y); term.setTextColor(COLORS.skip); term.write(string.format("- Files skipped (unchanged): %d", stats.skipped)); term.setTextColor(COLORS.text); y=y+2
    end

    term.setCursorPos(2,y); term.write("To start the system:"); y=y+1
    term.setCursorPos(2,y); term.setTextColor(COLORS.info); term.write("  Run: main"); term.setTextColor(COLORS.text); y=y+1
    term.setCursorPos(2,y); term.write("  or reboot the "..(selection=="Storage Computer" and "computer" or "turtle")); y=y+2

    term.setCursorPos(2,y); term.write("Configuration:"); y=y+1
    if selection == "Storage Computer" then
        term.setCursorPos(2,y); term.write("- Connect chests via wired modem"); y=y+1
        term.setCursorPos(2,y); term.write("- Regular chest = input"); y=y+1
        term.setCursorPos(2,y); term.write("- Trapped chest = output"); y=y+1
        term.setCursorPos(2,y); term.write("- All others = storage")
    else
        term.setCursorPos(2,y); term.write("- Connect wireless modem"); y=y+1
        term.setCursorPos(2,y); term.write("- Place chest in front for buffer"); y=y+1
        term.setCursorPos(2,y); term.write("- Use recipe learning system")
    end

    -- brief pause so user can read
    sleep(0.8)
end

-- ========= Main =========
local function main()
    showAnimatedSplash()

    local systemType = detectSystemType()

    -- Existing install?
    local existing = detectExistingInstallation()
    local installMode = INSTALL_MODE.CLEAN
    if existing then
        installMode = promptInstallMode()
        if not installMode then clearScreen(); print("Installation cancelled."); return end
    end

    -- System choice
    local options = { "Storage Computer", "Crafting Turtle", "Cancel" }
    local descriptions = {
        "Main storage management system with inventory, sorting, and order processing",
        "Turtle-based crafting system with recipe learning and remote control",
        "Exit installer without making changes"
    }
    local selection = pickFromList("NETStore Installer - Select System Type", options, descriptions)
    if not selection or selection == 3 then clearScreen(); print("Installation cancelled."); return end

    local selectedType = options[selection]
    local selectedSystem = (selectedType == "Storage Computer") and "storage" or "turtle"

    -- Confirm (list UI)
    if not confirmInstall(systemType, selectedType, installMode) then
        clearScreen(); print("Installation cancelled."); return
    end

    -- Fetch list + auto-continue
    local fileList = preflightCheck(selectedSystem)
    if not fileList then clearScreen(); print("Installation cancelled."); return end

    -- Install
    local ok, errs, stats = installFiles(fileList, selectedSystem, installMode)
    if not ok then
        clearScreen(); term.setTextColor(COLORS.error); print("Installation failed with errors:"); term.setTextColor(COLORS.text)
        for _,e in ipairs(errs) do print("  - "..e) end
        print("\nPress any key to exit"); os.pullEvent("key"); return
    end

    local hasStartup = fs.exists("startup.lua")
    showComplete(selectedType, hasStartup, stats, installMode)

    -- Set label if needed
    if not os.getComputerLabel() then
        if selectedType == "Storage Computer" then os.setComputerLabel("KSSH_Storage_"..os.getComputerID())
        else os.setComputerLabel("NETStore_Turtle_"..os.getComputerID()) end
    end

    -- Final action (list-based, no Y/N keys)
    clearScreen(); drawHeader("Installation Complete!")

    local finalOptions
    if hasStartup then
        finalOptions = { "Start now (run startup)", "Exit to shell", "Reboot computer" }
    else
        finalOptions = { "Start now (run main)", "Exit to shell", "Reboot computer" }
    end
    local pick = pickFromList("What would you like to do?", finalOptions, {
        hasStartup and "Runs your startup script immediately" or "Runs 'main' to start the system",
        "Return to CraftOS shell",
        "Reboots this computer"
    })

    if pick == 1 then
        clearScreen(); term.setCursorPos(1,1)
        print("Starting NETStore Storage System...")
        sleep(0.4)
        if hasStartup then shell.run("startup") else shell.run("main") end
    elseif pick == 2 then
        clearScreen(); term.setCursorPos(1,1); print("Installation complete!"); if not hasStartup then print("Run 'main' to start the system.") end
    elseif pick == 3 then
        clearScreen(); term.setCursorPos(1,1); print("Rebooting..."); sleep(0.4); os.reboot()
    else
        clearScreen(); term.setCursorPos(1,1); print("Done.")
    end
end

main()