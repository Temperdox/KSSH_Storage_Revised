-- Main UI Library Entry Point
local Component = require("ui.framework.component")
local Theme = require("ui.framework.theme")
local AnimLib = require("ui.framework.animation")
local WindowLib = require("ui.framework.window")
local FlexLayout = require("ui.layouts.flex_layout")

-- Components
local Label = require("ui.components.label")
local Button = require("ui.components.button")
local List = require("ui.components.list")
local Panel = require("ui.components.panel")

-- UI Library
local UI = {}

-- Global instances
UI.theme = Theme:new()
UI.animationManager = AnimLib.AnimationManager:new()
UI.windowManager = WindowLib.WindowManager:new()

-- Factory functions for creating components
function UI.label(text, x, y)
    local label = Label:new(text, x, y)
    UI.theme:apply(label)
    return label
end

function UI.button(text, x, y)
    local button = Button:new(text, x, y)
    UI.theme:apply(button)
    return button
end

function UI.list(x, y, width, height)
    local list = List:new(x, y, width, height)
    UI.theme:apply(list)
    return list
end

function UI.panel(x, y, width, height)
    local panel = Panel:new(x, y, width, height)
    UI.theme:apply(panel)
    return panel
end

function UI.window(title, width, height)
    local window = WindowLib.Window:new(title, width, height)
    UI.theme:apply(window)
    return window
end

function UI.dialog(title, message, buttons)
    return UI.windowManager:dialog(title, message, buttons)
end

-- Layout creators
function UI.flexLayout(direction, justifyContent, alignItems)
    return FlexLayout:new(direction, justifyContent, alignItems)
end

-- Animation creator
function UI.animate(component, property, endValue, duration, easing)
    local anim = AnimLib.animate(component, property, endValue, duration, easing)
    UI.animationManager:add(anim)
    return anim
end

-- Theme management
function UI.loadTheme(name, filePath)
    return UI.theme:loadTheme(name, filePath)
end

function UI.setTheme(name)
    return UI.theme:setTheme(name)
end

function UI.applyTheme(component)
    UI.theme:applyRecursive(component)
    return component
end

-- Update loop (call this in your main loop)
function UI.update()
    UI.animationManager:update()
end

-- Render all windows
function UI.renderWindows()
    UI.windowManager:render()
end

-- Event handling
function UI.handleClick(x, y)
    return UI.windowManager:handleClick(x, y)
end

function UI.handleMouseMove(x, y)
    return UI.windowManager:handleMouseMove(x, y)
end

function UI.handleMouseUp(x, y)
    return UI.windowManager:handleMouseUp(x, y)
end

function UI.handleScroll(direction, x, y)
    -- TODO: Implement scroll handling
    return false
end

-- Utility: Create a toast notification
function UI.toast(message, duration, color)
    local width, height = term.getSize()
    local toastWidth = math.min(#message + 4, width - 4)
    local toast = UI.panel(math.floor((width - toastWidth) / 2), height - 3, toastWidth, 3)

    toast:bg(color or colors.gray)
    toast:fg(colors.white)

    local label = UI.label(message, 2, 2)
    toast:add(label)

    -- Auto-hide after duration
    local hideAnim = UI.animate(toast, "y", height + 1, duration or 2000, "easeOutQuad")
    hideAnim:setOnComplete(function()
        toast:hide()
    end)
    hideAnim:start()

    return toast
end

-- Example usage documentation
UI.example = function()
    --[[

    USAGE EXAMPLES:

    -- Create components
    local title = UI.label("Hello World", 10, 5)
        :fg(colors.yellow)
        :bg(colors.blue)

    local btn = UI.button("Click Me", 10, 7)
        :hoverBg(colors.lime)
        :onClick(function(self)
            print("Button clicked!")
        end)

    -- Create a list
    local list = UI.list(1, 1, 30, 10)
        :setItems({"Item 1", "Item 2", "Item 3"})
        :setOnItemClick(function(self, index, item)
            print("Clicked: " .. item)
        end)

    -- Create a panel with flex layout
    local panel = UI.panel(5, 5, 40, 20)
    local layout = UI.flexLayout("column", "center", "center")
        :setGap(1)
    panel:setLayout(layout)

    panel:add(UI.label("Title"))
    panel:add(UI.button("Button 1"))
    panel:add(UI.button("Button 2"))

    -- Animate a component
    UI.animate(title, "x", 50, 1000, "easeInOutQuad"):start()

    -- Load and apply theme
    UI.loadTheme("dark", "/themes/dark.css")
    UI.setTheme("dark")
    UI.applyTheme(panel)

    -- Create a window/dialog
    local window = UI.window("My Window", 50, 15)
        :center(term.getSize())

    UI.windowManager:add(window)

    -- In your main loop:
    UI.update()  -- Update animations
    panel:render()  -- Render components
    UI.renderWindows()  -- Render windows/dialogs

    ]]
end

return UI
