local SettingsPage = {}
SettingsPage.__index = SettingsPage

function SettingsPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger
    o.settings = context.settings

    -- Setting groups
    o.settingGroups = {
        {
            name = "General",
            settings = {
                {id = "theme", label = "Theme", type = "select", options = {"dark", "light", "high_contrast"}},
                {id = "logLevel", label = "Log Level", type = "select", options = {"trace", "debug", "info", "warn", "error"}},
                {id = "autoScroll", label = "Auto-scroll logs", type = "boolean"}
            }
        },
        {
            name = "Storage",
            settings = {
                {id = "inputSide", label = "Input Chest", type = "select", options = {"top", "bottom", "left", "right", "front", "back"}},
                {id = "outputSide", label = "Output Chest", type = "select", options = {"top", "bottom", "left", "right", "front", "back"}},
                {id = "bufferSize", label = "Buffer Size", type = "number", min = 1, max = 108}
            }
        },
        {
            name = "Sound",
            settings = {
                {id = "soundEnabled", label = "Enable Sound", type = "boolean"},
                {id = "soundVolume", label = "Volume", type = "number", min = 0, max = 1, step = 0.1},
                {id = "soundProfile", label = "Sound Profile", type = "select", options = {"default", "quiet", "active", "musical"}}
            }
        },
        {
            name = "Performance",
            settings = {
                {id = "poolIO", label = "IO Workers", type = "number", min = 1, max = 8},
                {id = "poolIndex", label = "Index Workers", type = "number", min = 1, max = 4},
                {id = "poolUI", label = "UI Workers", type = "number", min = 1, max = 4},
                {id = "poolNet", label = "Network Workers", type = "number", min = 1, max = 4}
            }
        }
    }

    -- UI state
    o.selectedGroup = 1
    o.selectedSetting = 1
    o.editing = false
    o.editValue = ""

    o.width, o.height = term.getSize()

    return o
end

function SettingsPage:onEnter()
    self:loadSettings()
    self:render()
end

function SettingsPage:render()
    term.clear()

    -- Header
    self:drawHeader()

    -- Setting groups
    self:drawGroups()

    -- Settings list
    self:drawSettings()

    -- Footer
    self:drawFooter()
end

function SettingsPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)

    local title = " SYSTEM SETTINGS "
    term.setCursorPos(math.floor((self.width - #title) / 2), 1)
    term.write(title)

    -- Back link
    term.setCursorPos(self.width - 10, 1)
    term.setTextColor(colors.yellow)
    term.write("[B]ack")

    term.setBackgroundColor(colors.black)
end

function SettingsPage:drawGroups()
    local y = 3

    for i, group in ipairs(self.settingGroups) do
        term.setCursorPos(2, y)

        if i == self.selectedGroup then
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.yellow)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.lightGray)
        end

        term.write(" " .. group.name .. " ")
        term.setBackgroundColor(colors.black)
        term.write("  ")
    end
end

function SettingsPage:drawSettings()
    local y = 5
    local group = self.settingGroups[self.selectedGroup]

    term.setCursorPos(1, y)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", self.width))
    y = y + 1

    for i, setting in ipairs(group.settings) do
        term.setCursorPos(2, y)

        -- Selection indicator
        if i == self.selectedSetting then
            term.setTextColor(colors.yellow)
            term.write("> ")
        else
            term.write("  ")
        end

        -- Setting label
        term.setTextColor(colors.white)
        term.write(setting.label .. ": ")

        -- Setting value
        term.setCursorPos(25, y)

        if self.editing and i == self.selectedSetting then
            -- Edit mode
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            term.write(self.editValue .. "_")
            term.setBackgroundColor(colors.black)
        else
            -- Display current value
            local value = self:getSettingValue(setting.id)

            if setting.type == "boolean" then
                if value then
                    term.setTextColor(colors.green)
                    term.write("[ON]")
                else
                    term.setTextColor(colors.red)
                    term.write("[OFF]")
                end
            elseif setting.type == "select" then
                term.setTextColor(colors.cyan)
                term.write("[" .. tostring(value) .. "]")
            elseif setting.type == "number" then
                term.setTextColor(colors.orange)
                term.write(tostring(value))
            else
                term.setTextColor(colors.white)
                term.write(tostring(value))
            end
        end

        y = y + 2
    end
end

function SettingsPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setTextColor(colors.gray)

    if self.editing then
        term.write("Enter to confirm, ESC to cancel")
    else
        term.write("Arrow keys to navigate, Enter to edit, S to save, R to reset")
    end
end

function SettingsPage:loadSettings()
    -- Settings are already loaded in context
    self.settings = self.context.settings
end

function SettingsPage:getSettingValue(id)
    -- Map setting IDs to actual values
    if id == "poolIO" then
        return self.settings.pools.io
    elseif id == "poolIndex" then
        return self.settings.pools.index
    elseif id == "poolUI" then
        return self.settings.pools.ui
    elseif id == "poolNet" then
        return self.settings.pools.net
    elseif id == "autoScroll" then
        return self.settings.ui.autoScroll
    elseif id == "bufferSize" then
        return self.settings.bufferSize or 54
    elseif id == "soundProfile" then
        return self.settings.soundProfile or "default"
    else
        return self.settings[id]
    end
end

function SettingsPage:setSettingValue(id, value)
    -- Update setting value
    if id == "poolIO" then
        self.settings.pools.io = value
    elseif id == "poolIndex" then
        self.settings.pools.index = value
    elseif id == "poolUI" then
        self.settings.pools.ui = value
    elseif id == "poolNet" then
        self.settings.pools.net = value
    elseif id == "autoScroll" then
        self.settings.ui.autoScroll = value
    elseif id == "bufferSize" then
        self.settings.bufferSize = value
    elseif id == "soundProfile" then
        self.settings.soundProfile = value
    else
        self.settings[id] = value
    end

    -- Save settings
    self:saveSettings()

    -- Publish change event
    self.eventBus:publish("settings.changed", {
        setting = id,
        value = value
    })
end

function SettingsPage:saveSettings()
    local settingsPath = "/storage/cfg/settings.json"
    local file = fs.open(settingsPath, "w")

    if file then
        file.write(textutils.serialiseJSON(self.settings))
        file.close()

        self.logger:info("Settings", "Settings saved successfully")
    else
        self.logger:error("Settings", "Failed to save settings")
    end
end

function SettingsPage:resetSettings()
    -- Reset to defaults
    self.settings = {
        theme = "dark",
        logLevel = "info",
        inputSide = "right",
        outputSide = "left",
        soundEnabled = true,
        soundVolume = 0.5,
        pools = {
            io = 4,
            index = 2,
            ui = 2,
            net = 2
        },
        ui = {
            maxLogs = 50,
            autoScroll = true,
            showTimestamps = true
        }
    }

    self:saveSettings()
    self:render()
end

function SettingsPage:startEdit()
    local group = self.settingGroups[self.selectedGroup]
    local setting = group.settings[self.selectedSetting]

    self.editing = true
    self.editValue = tostring(self:getSettingValue(setting.id))

    self:render()
end

function SettingsPage:confirmEdit()
    local group = self.settingGroups[self.selectedGroup]
    local setting = group.settings[self.selectedSetting]

    -- Validate and convert value
    local value = self.editValue

    if setting.type == "boolean" then
        value = self.editValue:lower() == "true" or
                self.editValue:lower() == "on" or
                self.editValue == "1"
    elseif setting.type == "number" then
        value = tonumber(self.editValue)

        if not value then
            self.logger:error("Settings", "Invalid number value")
            self.editing = false
            self:render()
            return
        end

        if setting.min then
            value = math.max(setting.min, value)
        end
        if setting.max then
            value = math.min(setting.max, value)
        end
        if setting.step then
            value = math.floor(value / setting.step) * setting.step
        end
    elseif setting.type == "select" then
        -- Validate against options
        local valid = false
        for _, option in ipairs(setting.options) do
            if option == self.editValue then
                valid = true
                break
            end
        end

        if not valid then
            self.logger:error("Settings", "Invalid option: " .. self.editValue)
            self.editing = false
            self:render()
            return
        end
    end

    -- Apply setting
    self:setSettingValue(setting.id, value)

    self.editing = false
    self:render()
end

function SettingsPage:handleInput(event, param1, param2)
    if event == "key" then
        local key = param1

        if self.editing then
            if key == keys.enter then
                self:confirmEdit()
            elseif key == keys.escape then
                self.editing = false
                self:render()
            elseif key == keys.backspace then
                if #self.editValue > 0 then
                    self.editValue = self.editValue:sub(1, -2)
                    self:render()
                end
            end
        else
            if key == keys.b then
                -- Go back
                self.context.viewFactory:switchTo("console")
            elseif key == keys.up then
                self.selectedSetting = math.max(1, self.selectedSetting - 1)
                self:render()
            elseif key == keys.down then
                local group = self.settingGroups[self.selectedGroup]
                self.selectedSetting = math.min(#group.settings, self.selectedSetting + 1)
                self:render()
            elseif key == keys.left then
                self.selectedGroup = math.max(1, self.selectedGroup - 1)
                self.selectedSetting = 1
                self:render()
            elseif key == keys.right then
                self.selectedGroup = math.min(#self.settingGroups, self.selectedGroup + 1)
                self.selectedSetting = 1
                self:render()
            elseif key == keys.enter then
                self:startEdit()
            elseif key == keys.s then
                self:saveSettings()
                self.logger:info("Settings", "Settings saved")
                self:render()
            elseif key == keys.r then
                self:resetSettings()
                self.logger:info("Settings", "Settings reset to defaults")
            end
        end
    elseif event == "char" and self.editing then
        self.editValue = self.editValue .. param1
        self:render()
    end
end

return SettingsPage