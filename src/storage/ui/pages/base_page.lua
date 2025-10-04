-- Base Page class for all UI pages using the new framework
local UI = require("ui.framework.ui")

local BasePage = {}
BasePage.__index = BasePage

function BasePage:new(context, pageName)
    local o = setmetatable({}, self)
    o.context = context
    o.pageName = pageName or "page"
    o.width, o.height = term.getSize()

    -- Root container
    o.root = UI.panel(1, 1, o.width, o.height)
        :bg(colors.black)
        :fg(colors.white)

    -- Header
    o.header = UI.panel(1, 1, o.width, 1)
        :bg(colors.gray)
        :fg(colors.white)

    o.headerTitle = UI.label("", 2, 1)
        :fg(colors.white)
        :bg(colors.gray)

    o.backButton = UI.button("BACK", o.width - 6, 1)
        :bg(colors.red)
        :fg(colors.white)
        :onClick(function()
            o:navigateBack()
        end)

    o.header:add(o.headerTitle)
    o.header:add(o.backButton)

    -- Content area
    o.content = UI.panel(1, 2, o.width, o.height - 2)
        :bg(colors.black)

    -- Footer
    o.footer = UI.panel(1, o.height, o.width, 1)
        :bg(colors.gray)
        :fg(colors.white)

    o.footerText = UI.label("", 2, o.height)
        :fg(colors.white)
        :bg(colors.gray)

    o.footer:add(o.footerText)

    o.root:add(o.header)
    o.root:add(o.content)
    o.root:add(o.footer)

    return o
end

function BasePage:setTitle(title)
    self.headerTitle:setText(title)
    self.headerTitle.width = #title
    return self
end

function BasePage:setFooter(text)
    self.footerText:setText(text)
    self.footerText.width = #text
    return self
end

function BasePage:navigateBack()
    if self.context.router then
        self.context.router:navigate("console")
    end
end

function BasePage:onEnter()
    -- Override in subclass
    self:render()
end

function BasePage:onLeave()
    -- Override in subclass
end

function BasePage:render()
    term.setBackgroundColor(colors.black)
    term.clear()

    UI.update()
    self.root:render()
    UI.renderWindows()
end

function BasePage:handleInput(event, param1, param2, param3)
    if event == "mouse_click" then
        local x, y = param2, param3
        UI.handleClick(x, y)
        self.root:handleClick(x, y)

    elseif event == "mouse_move" or event == "mouse_drag" then
        local x, y = param1, param2
        UI.handleMouseMove(x, y)
        self.root:handleMouseMove(x, y)

    elseif event == "mouse_scroll" then
        local direction, x, y = param1, param2, param3
        self.root:handleScroll(direction, x, y)

    elseif event == "mouse_up" then
        local x, y = param2, param3
        self.root:handleMouseUp(x, y)

    elseif event == "key" then
        local key = param1
        if key == keys.escape then
            self:navigateBack()
        end
    end
end

return BasePage
