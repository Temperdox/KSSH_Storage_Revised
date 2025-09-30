-- modules/config.lua
-- Configuration management

local Config = {}
Config.__index = Config

function Config:new(filepath)
    local self = setmetatable({}, Config)
    self.filepath = filepath or "config/storage.cfg"
    self.data = {
        api = {
            enabled = true,
            port = 9001
        },
        storage = {
            sortConsolidate = true,
            autoDeposit = true,
            autoReformat = false
        },
        display = {
            scale = 0.5,
            updateInterval = 0.1
        },
        sound = {
            enabled = true,
            volume = 0.5
        },
        logging = {
            level = "INFO",
            maxFileSize = 10000,
            maxFiles = 5
        }
    }

    return self
end

function Config:load()
    if fs.exists(self.filepath) then
        local file = fs.open(self.filepath, "r")
        if file then
            local content = file.readAll()
            file.close()

            local ok, data = pcall(textutils.unserialise, content)
            if ok and data then
                -- Merge loaded data with defaults
                self:merge(self.data, data)
            end
        end
    end
end

function Config:save()
    -- Ensure directory exists
    local dir = fs.getDir(self.filepath)
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file = fs.open(self.filepath, "w")
    if file then
        file.write(textutils.serialise(self.data))
        file.close()
    end
end

function Config:get(path, default)
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end

    local current = self.data
    for _, part in ipairs(parts) do
        if type(current) == "table" and current[part] ~= nil then
            current = current[part]
        else
            return default
        end
    end

    return current
end

function Config:set(path, value)
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end

    local current = self.data
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end

    current[parts[#parts]] = value
    self:save()
end

function Config:merge(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            self:merge(target[k], v)
        else
            target[k] = v
        end
    end
end

return Config