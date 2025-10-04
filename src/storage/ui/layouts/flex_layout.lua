-- Flexbox-like layout manager
local FlexLayout = {}
FlexLayout.__index = FlexLayout

function FlexLayout:new(direction, justifyContent, alignItems)
    local o = setmetatable({}, self)
    o.direction = direction or "row" -- row, column
    o.justifyContent = justifyContent or "start" -- start, center, end, space-between, space-around
    o.alignItems = alignItems or "start" -- start, center, end, stretch
    o.gap = 0
    o.wrap = false

    return o
end

function FlexLayout:setDirection(direction)
    self.direction = direction
    return self
end

function FlexLayout:setJustifyContent(justify)
    self.justifyContent = justify
    return self
end

function FlexLayout:setAlignItems(align)
    self.alignItems = align
    return self
end

function FlexLayout:setGap(gap)
    self.gap = gap
    return self
end

function FlexLayout:setWrap(wrap)
    self.wrap = wrap
    return self
end

function FlexLayout:apply(container)
    local children = container.children
    if #children == 0 then return end

    local containerWidth = container.width - container.styles.padding.left - container.styles.padding.right
    local containerHeight = container.height - container.styles.padding.top - container.styles.padding.bottom

    if self.direction == "row" then
        self:layoutRow(children, containerWidth, containerHeight)
    else
        self:layoutColumn(children, containerWidth, containerHeight)
    end
end

function FlexLayout:layoutRow(children, containerWidth, containerHeight)
    -- Calculate total width needed
    local totalWidth = 0
    for _, child in ipairs(children) do
        totalWidth = totalWidth + child.width + child.styles.margin.left + child.styles.margin.right
    end
    totalWidth = totalWidth + (self.gap * (#children - 1))

    -- Calculate starting position based on justifyContent
    local x = 0
    local spacing = 0

    if self.justifyContent == "center" then
        x = math.floor((containerWidth - totalWidth) / 2)
    elseif self.justifyContent == "end" then
        x = containerWidth - totalWidth
    elseif self.justifyContent == "space-between" then
        if #children > 1 then
            spacing = (containerWidth - totalWidth + (self.gap * (#children - 1))) / (#children - 1)
        end
    elseif self.justifyContent == "space-around" then
        spacing = (containerWidth - totalWidth + (self.gap * (#children - 1))) / #children
        x = spacing / 2
    end

    -- Position children
    for i, child in ipairs(children) do
        child.x = x + child.styles.margin.left

        -- Align items vertically
        if self.alignItems == "center" then
            child.y = math.floor((containerHeight - child.height) / 2) + child.styles.margin.top
        elseif self.alignItems == "end" then
            child.y = containerHeight - child.height - child.styles.margin.bottom
        elseif self.alignItems == "stretch" then
            child.y = child.styles.margin.top
            child.height = containerHeight - child.styles.margin.top - child.styles.margin.bottom
        else -- start
            child.y = child.styles.margin.top
        end

        x = x + child.width + child.styles.margin.left + child.styles.margin.right + self.gap + spacing
    end
end

function FlexLayout:layoutColumn(children, containerWidth, containerHeight)
    -- Calculate total height needed
    local totalHeight = 0
    for _, child in ipairs(children) do
        totalHeight = totalHeight + child.height + child.styles.margin.top + child.styles.margin.bottom
    end
    totalHeight = totalHeight + (self.gap * (#children - 1))

    -- Calculate starting position based on justifyContent
    local y = 0
    local spacing = 0

    if self.justifyContent == "center" then
        y = math.floor((containerHeight - totalHeight) / 2)
    elseif self.justifyContent == "end" then
        y = containerHeight - totalHeight
    elseif self.justifyContent == "space-between" then
        if #children > 1 then
            spacing = (containerHeight - totalHeight + (self.gap * (#children - 1))) / (#children - 1)
        end
    elseif self.justifyContent == "space-around" then
        spacing = (containerHeight - totalHeight + (self.gap * (#children - 1))) / #children
        y = spacing / 2
    end

    -- Position children
    for i, child in ipairs(children) do
        child.y = y + child.styles.margin.top

        -- Align items horizontally
        if self.alignItems == "center" then
            child.x = math.floor((containerWidth - child.width) / 2) + child.styles.margin.left
        elseif self.alignItems == "end" then
            child.x = containerWidth - child.width - child.styles.margin.right
        elseif self.alignItems == "stretch" then
            child.x = child.styles.margin.left
            child.width = containerWidth - child.styles.margin.left - child.styles.margin.right
        else -- start
            child.x = child.styles.margin.left
        end

        y = y + child.height + child.styles.margin.top + child.styles.margin.bottom + self.gap + spacing
    end
end

return FlexLayout
