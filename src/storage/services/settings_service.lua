local SettingsService = {}
SettingsService.__index = SettingsService

function SettingsService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger
    o.settings = context.settings
    o.settingsFile = "/storage/cfg/settings.json"

    return o
end

function SettingsService:start()
    -- Subscribe to settings changes
    self.eventBus:subscribe("settings.changed", function(event, data)
        self:applyChange(data)
    end)

    -- Subscribe to save requests
    self.eventBus:subscribe("settings.save", function()
        self:save()
    end)

    self.logger:info("SettingsService", "Service started")
end

function SettingsService:applyChange(change)
    -- Apply specific setting changes
    if change.logLevel then
        self.context.logger.level = self.context.logger.levels[change.logLevel]
        self.settings.logLevel = change.logLevel
    end

    if change.theme then
        self.settings.theme = change.theme
        -- Reload theme
        local Theme = require("ui.theme")
        local theme = Theme:new(change.theme)
        theme:apply()
    end

    if change.soundEnabled ~= nil then
        self.settings.soundEnabled = change.soundEnabled
        if self.context.services.sound then
            self.context.services.sound:setSoundEnabled(change.soundEnabled)
        end
    end

    if change.soundVolume then
        self.settings.soundVolume = change.soundVolume
        if self.context.services.sound then
            self.context.services.sound:setVolume(change.soundVolume)
        end
    end

    -- Auto-save
    self:save()
end

function SettingsService:save()
    local file = fs.open(self.settingsFile, "w")
    if file then
        file.write(textutils.serialiseJSON(self.settings))
        file.close()
        self.logger:debug("SettingsService", "Settings saved")
    else
        self.logger:error("SettingsService", "Failed to save settings")
    end
end

function SettingsService:load()
    if fs.exists(self.settingsFile) then
        local file = fs.open(self.settingsFile, "r")
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data then
            self.settings = data
            self.context.settings = data
            return true
        end
    end
    return false
end

function SettingsService:stop()
    self:save()
    self.logger:info("SettingsService", "Service stopped")
end

return SettingsService