-- Theme manager for CSS-like styling
local Theme = {}
Theme.__index = Theme

function Theme:new()
    local o = setmetatable({}, self)
    o.styles = {}
    o.currentTheme = "default"
    o.themes = {}

    return o
end

-- Load theme from CSS-like file
function Theme:loadTheme(name, filePath)
    if not fs.exists(filePath) then
        return false, "Theme file not found: " .. filePath
    end

    local file = fs.open(filePath, "r")
    if not file then
        return false, "Could not open theme file"
    end

    local content = file.readAll()
    file.close()

    local theme = self:parseCSS(content)
    self.themes[name] = theme

    return true
end

-- Parse CSS-like syntax
function Theme:parseCSS(content)
    local theme = {}
    local currentSelector = nil
    local currentRules = {}

    for line in content:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "") -- Trim

        -- Skip comments and empty lines
        if line:match("^//") or line:match("^#") or line == "" then
            goto continue
        end

        -- Selector (ends with {)
        if line:match("{$") then
            if currentSelector then
                theme[currentSelector] = currentRules
            end

            currentSelector = line:gsub("%s*{$", "")
            currentRules = {}

        -- End of rule block
        elseif line == "}" then
            if currentSelector then
                theme[currentSelector] = currentRules
                currentSelector = nil
                currentRules = {}
            end

        -- Property: value;
        elseif line:match(":") then
            local prop, value = line:match("([^:]+):%s*([^;]+)")
            if prop and value then
                prop = prop:gsub("^%s+", ""):gsub("%s+$", "")
                value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub(";$", "")

                currentRules[prop] = self:parseValue(value)
            end
        end

        ::continue::
    end

    -- Save last selector
    if currentSelector then
        theme[currentSelector] = currentRules
    end

    return theme
end

-- Parse CSS values (colors, numbers, etc.)
function Theme:parseValue(value)
    -- Check if it's a color
    if value:match("^colors%.") then
        local colorName = value:match("^colors%.(%w+)")
        return colors[colorName] or colors.white
    end

    -- Check if it's a number
    local num = tonumber(value)
    if num then
        return num
    end

    -- Check if it's a boolean
    if value == "true" then return true end
    if value == "false" then return false end

    -- Check if it's a table/object (simple JSON-like)
    if value:match("^{") and value:match("}$") then
        local result = {}
        local inner = value:gsub("^{", ""):gsub("}$", "")

        for pair in inner:gmatch("[^,]+") do
            local k, v = pair:match("([^:]+):%s*([^,]+)")
            if k and v then
                k = k:gsub("^%s+", ""):gsub("%s+$", "")
                v = v:gsub("^%s+", ""):gsub("%s+$", "")
                result[k] = self:parseValue(v)
            end
        end

        return result
    end

    -- Return as string
    return value
end

-- Set current theme
function Theme:setTheme(name)
    if not self.themes[name] then
        return false, "Theme not found: " .. name
    end

    self.currentTheme = name
    return true
end

-- Get style for a component by ID
function Theme:getStyle(id)
    local theme = self.themes[self.currentTheme]
    if not theme then return {} end

    -- Check for exact ID match (#id)
    local idStyle = theme["#" .. id]
    if idStyle then
        return idStyle
    end

    return {}
end

-- Get style for a component by type/class
function Theme:getStyleByClass(className)
    local theme = self.themes[self.currentTheme]
    if not theme then return {} end

    -- Check for class match (.className)
    local classStyle = theme["." .. className]
    if classStyle then
        return classStyle
    end

    -- Check for type match (element)
    local typeStyle = theme[className]
    if typeStyle then
        return typeStyle
    end

    return {}
end

-- Apply theme to component
function Theme:apply(component)
    local style = {}

    -- Get type/class styles
    local classStyle = self:getStyleByClass(component.type)
    for k, v in pairs(classStyle) do
        style[k] = v
    end

    -- Get ID-specific styles (override class styles)
    local idStyle = self:getStyle(component.id)
    for k, v in pairs(idStyle) do
        style[k] = v
    end

    -- Apply to component
    if style.bg then component.styles.bg = style.bg end
    if style.fg then component.styles.fg = style.fg end
    if style.hoverBg then component.styles.hoverBg = style.hoverBg end
    if style.hoverFg then component.styles.hoverFg = style.hoverFg end
    if style.clickBg then component.styles.clickBg = style.clickBg end
    if style.clickFg then component.styles.clickFg = style.clickFg end
    if style.disabledBg then component.styles.disabledBg = style.disabledBg end
    if style.disabledFg then component.styles.disabledFg = style.disabledFg end

    -- Padding
    if style.padding then
        component.styles.padding = style.padding
    end

    -- Margin
    if style.margin then
        component.styles.margin = style.margin
    end

    -- Border
    if style.border then
        component.styles.border = style.border
    end

    return component
end

-- Apply theme recursively to component tree
function Theme:applyRecursive(component)
    self:apply(component)

    for _, child in ipairs(component.children) do
        self:applyRecursive(child)
    end
end

return Theme
