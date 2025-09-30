local Theme = {}
Theme.__index = Theme

function Theme:new(themeName)
    local o = setmetatable({}, self)

    local Palette = require("assets.palette")
    o.palette = Palette

    -- Load theme
    o.name = themeName or "dark"
    o.colors = Palette.themes[o.name] or Palette.themes.dark

    -- Load custom theme if exists
    local customPath = "/storage/cfg/themes/" .. o.name .. ".json"
    if fs.exists(customPath) then
        local file = fs.open(customPath, "r")
        local content = file.readAll()
        file.close()

        local ok, custom = pcall(textutils.unserialiseJSON, content)
        if ok and custom then
            for k, v in pairs(custom) do
                o.colors[k] = v
            end
        end
    end

    return o
end

function Theme:apply()
    term.setBackgroundColor(self.colors.background)
    term.setTextColor(self.colors.foreground)
    term.clear()
end

function Theme:setColors(bg, fg)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg) end
end

function Theme:drawBorder(x, y, width, height)
    self:setColors(self.colors.background, self.colors.border)

    -- Top border
    term.setCursorPos(x, y)
    term.write("+" .. string.rep("-", width - 2) .. "+")

    -- Side borders
    for i = 1, height - 2 do
        term.setCursorPos(x, y + i)
        term.write("|")
        term.setCursorPos(x + width - 1, y + i)
        term.write("|")
    end

    -- Bottom border
    term.setCursorPos(x, y + height - 1)
    term.write("+" .. string.rep("-", width - 2) .. "+")
end

function Theme:drawHeader(text, y)
    local width = term.getSize()

    term.setCursorPos(1, y)
    self:setColors(self.colors.header, self.colors.foreground)
    term.clearLine()

    local x = math.floor((width - #text) / 2)
    term.setCursorPos(x, y)
    term.write(text)

    self:setColors(self.colors.background, self.colors.foreground)
end

function Theme:drawButton(x, y, text, selected)
    if selected then
        self:setColors(self.colors.selected, self.colors.background)
    else
        self:setColors(self.colors.border, self.colors.foreground)
    end

    term.setCursorPos(x, y)
    term.write("[" .. text .. "]")

    self:setColors(self.colors.background, self.colors.foreground)
end

function Theme:getPoolColor(poolName)
    return self.palette.pools[poolName] or colors.white
end

function Theme:getEventColor(eventType)
    -- Find matching pattern
    for pattern, color in pairs(self.palette.events) do
        if eventType:find(pattern) then
            return color
        end
    end
    return colors.white
end

function Theme:getLogLevelColor(level)
    return self.palette.logLevels[level] or colors.white
end

return Theme