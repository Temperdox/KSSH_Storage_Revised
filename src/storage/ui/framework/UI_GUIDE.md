# KSSH Storage UI Framework Guide

A comprehensive, JavaFX-inspired UI framework for ComputerCraft with animations, themes, and responsive layouts.

## 📚 Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Components](#components)
4. [Layouts](#layouts)
5. [Themes & Styling](#themes--styling)
6. [Animations](#animations)
7. [Windows & Dialogs](#windows--dialogs)
8. [Event Handling](#event-handling)
9. [Examples](#examples)

---

## Quick Start

```lua
local UI = require("ui.framework.ui")

-- Create components
local button = UI.button("Click Me", 10, 5)
    :hoverBg(colors.lime)
    :onClick(function(self)
        print("Button clicked!")
    end)

-- Render in your main loop
button:render()

-- Handle events
-- In your event loop:
if event == "mouse_click" then
    button:handleClick(x, y)
end
```

---

## Core Concepts

### Component Hierarchy

All UI elements inherit from the base `Component` class:

```
Component
├── Label
├── Button
├── Panel
├── List
├── Window
└── [Your Custom Components]
```

### Chainable Methods

All setter methods return `self` for method chaining:

```lua
local label = UI.label("Title")
    :setPosition(10, 5)
    :fg(colors.yellow)
    :bg(colors.blue)
    :padding(1, 2)
```

---

## Components

### Label

```lua
local title = UI.label("Hello World", x, y)
    :setText("New Text")
    :setTextAlign("center")  -- left, center, right
    :fg(colors.yellow)
    :bg(colors.blue)
```

### Button

```lua
local btn = UI.button("Click Me", x, y)
    :setText("New Label")
    :bg(colors.green)
    :fg(colors.white)
    :hoverBg(colors.lime)
    :hoverFg(colors.black)
    :clickBg(colors.white)
    :clickFg(colors.black)
    :onClick(function(self, x, y)
        print("Clicked at", x, y)
    end)
    :onHover(function(self, x, y)
        print("Hovering")
    end)
    :onLeave(function(self, x, y)
        print("Left button")
    end)
```

### List

```lua
local list = UI.list(1, 1, 30, 10)
    :setItems({"Item 1", "Item 2", "Item 3"})
    :setItemHeight(1)
    :setOnItemClick(function(self, index, item)
        print("Selected:", item)
    end)

-- Manage items
list:addItem("New Item")
list:removeItem(1)
list:clear()

-- Scrolling (automatic with mouse wheel)
```

### Panel (Container)

```lua
local panel = UI.panel(5, 5, 40, 20)
    :bg(colors.black)
    :border(true, colors.gray, "-")
    :padding(1)  -- All sides
    :padding(1, 2)  -- Top/bottom, left/right
    :padding(1, 2, 1, 2)  -- Top, right, bottom, left

-- Add children
panel:add(UI.label("Child 1"))
panel:add(UI.button("Child 2"))

-- Set layout
local layout = UI.flexLayout("column", "center", "center")
panel:setLayout(layout)
```

---

## Layouts

### FlexLayout

Similar to CSS Flexbox:

```lua
local layout = UI.flexLayout(direction, justifyContent, alignItems)
    :setDirection("row")  -- row, column
    :setJustifyContent("center")  -- start, center, end, space-between, space-around
    :setAlignItems("center")  -- start, center, end, stretch
    :setGap(2)  -- Space between items
    :setWrap(true)  -- Enable wrapping

-- Apply to panel
panel:setLayout(layout)
```

**Example: Centered Column Layout**

```lua
local panel = UI.panel(10, 5, 40, 20)
local layout = UI.flexLayout("column", "center", "center"):setGap(1)
panel:setLayout(layout)

panel:add(UI.label("Title"))
panel:add(UI.button("Button 1"))
panel:add(UI.button("Button 2"))
```

---

## Themes & Styling

### CSS-like Theming

Create `.css` files in `/ui/themes/`:

```css
// dark.css

// Global styles
* {
    bg: colors.black;
    fg: colors.white;
}

// Component type styles
button {
    bg: colors.gray;
    fg: colors.white;
    hoverBg: colors.lightGray;
    clickBg: colors.white;
    clickFg: colors.black;
}

// ID-specific styles
#primaryButton {
    bg: colors.green;
    hoverBg: colors.lime;
}

#errorMessage {
    bg: colors.red;
    fg: colors.white;
}
```

### Loading Themes

```lua
-- Load theme
UI.loadTheme("dark", "/ui/themes/dark.css")
UI.loadTheme("light", "/ui/themes/light.css")

-- Switch theme
UI.setTheme("dark")

-- Apply to component tree
UI.applyTheme(rootPanel)
```

### Manual Styling

```lua
component
    :bg(colors.black)          -- Background color
    :fg(colors.white)          -- Foreground/text color
    :hoverBg(colors.gray)      -- Hover background
    :hoverFg(colors.yellow)    -- Hover foreground
    :clickBg(colors.white)     -- Click background
    :clickFg(colors.black)     -- Click foreground
    :padding(1, 2, 1, 2)       -- Padding
    :margin(1, 2, 1, 2)        -- Margin
    :border(true, colors.white, "-")  -- Border
    :overflow("scroll")        -- visible, hidden, scroll
```

---

## Animations

### Easing Functions

- `linear`
- `easeInQuad`, `easeOutQuad`, `easeInOutQuad`
- `easeInCubic`, `easeOutCubic`, `easeInOutCubic`
- `easeInQuart`, `easeOutQuart`
- `easeInElastic`, `easeOutElastic`
- `easeInBounce`, `easeOutBounce`, `easeInOutBounce`

### Creating Animations

```lua
-- Animate position
UI.animate(component, "x", 50, 1000, "easeInOutQuad")
    :setOnComplete(function(comp)
        print("Animation done!")
    end)
    :start()

-- Animate color
UI.animate(button, "styles.bg", colors.green, 500, "linear"):start()

-- Animate size
UI.animate(panel, "width", 60, 1000, "easeOutBounce"):start()

-- In your main loop
UI.update()  -- Updates all animations
```

---

## Windows & Dialogs

### Creating Windows

```lua
local window = UI.window("My Window", 50, 15)
    :setTitle("Updated Title")
    :setModal(true)  -- Blocks interaction with other windows
    :setDraggable(true)
    :setCloseButton(true)
    :center(term.getSize())  -- Center on screen
    :onClose(function(self)
        print("Window closed")
    end)

-- Add content
window:add(UI.label("Content here"))

-- Add to window manager
UI.windowManager:add(window)

-- Render (in main loop)
UI.renderWindows()
```

### Dialog Helper

```lua
local dialog = UI.dialog("Confirm", "Are you sure?", {
    {text = "Yes", onClick = function() print("Yes") end},
    {text = "No", onClick = function() print("No") end}
})
```

### Toast Notifications

```lua
UI.toast("Operation successful!", 3000, colors.green)
UI.toast("Error occurred", 3000, colors.red)
```

---

## Event Handling

### Component Events

```lua
component
    :onClick(function(self, x, y)
        print("Clicked")
    end)
    :onHover(function(self, x, y)
        print("Mouse entered")
    end)
    :onLeave(function(self, x, y)
        print("Mouse left")
    end)
    :onFocus(function(self)
        print("Focused")
    end)
    :onBlur(function(self)
        print("Lost focus")
    end)
    :onScroll(function(self, direction)
        print("Scrolled", direction)
    end)
```

### Main Event Loop

```lua
while running do
    local event = {os.pullEvent()}

    if event[1] == "mouse_click" then
        local x, y = event[3], event[4]
        UI.handleClick(x, y)
        component:handleClick(x, y)

    elseif event[1] == "mouse_move" or event[1] == "mouse_drag" then
        local x, y = event[2], event[3]
        UI.handleMouseMove(x, y)
        component:handleMouseMove(x, y)

    elseif event[1] == "mouse_scroll" then
        local direction, x, y = event[2], event[3], event[4]
        component:handleScroll(direction, x, y)
    end

    -- Update animations
    UI.update()

    -- Render
    component:render()
    UI.renderWindows()

    os.sleep(0.05)  -- 20 FPS
end
```

---

## Examples

### Complete Application Example

```lua
local UI = require("ui.framework.ui")

-- Load theme
UI.loadTheme("dark", "/ui/themes/dark.css")
UI.setTheme("dark")

-- Create main panel
local mainPanel = UI.panel(1, 1, 51, 19)
local layout = UI.flexLayout("column", "start", "stretch"):setGap(1)
mainPanel:setLayout(layout)

-- Header
local header = UI.label("KSSH Storage System")
    :setId("header")
header.width = 51

-- Buttons
local btnPanel = UI.panel(1, 1, 51, 3)
local btnLayout = UI.flexLayout("row", "center", "center"):setGap(2)
btnPanel:setLayout(btnLayout)

btnPanel:add(UI.button("Withdraw"):setId("primaryButton"))
btnPanel:add(UI.button("Deposit"):setId("primaryButton"))
btnPanel:add(UI.button("Stats"))

-- List
local itemList = UI.list(1, 1, 51, 10)
    :setItems({"Diamond x64", "Iron Ingot x128", "Gold Ingot x32"})
    :setOnItemClick(function(self, index, item)
        UI.toast("Selected: " .. item, 2000, colors.green)
    end)

-- Assemble
mainPanel:add(header)
mainPanel:add(btnPanel)
mainPanel:add(itemList)

-- Apply theme
UI.applyTheme(mainPanel)

-- Main loop
local running = true
while running do
    local event = {os.pullEvent()}

    if event[1] == "mouse_click" then
        mainPanel:handleClick(event[3], event[4])
        UI.handleClick(event[3], event[4])
    elseif event[1] == "mouse_move" then
        mainPanel:handleMouseMove(event[2], event[3])
    elseif event[1] == "mouse_scroll" then
        mainPanel:handleScroll(event[2], event[3], event[4])
    end

    UI.update()
    term.clear()
    mainPanel:render()
    UI.renderWindows()
    os.sleep(0.05)
end
```

---

## Advanced Features

### Overflow Handling

```lua
panel:overflow("scroll")  -- Show scrollbar
panel:overflow("hidden")  -- Hide overflow
panel:overflow("visible")  -- Show overflow (default)
```

### Custom Components

```lua
local MyComponent = setmetatable({}, {__index = Component})
MyComponent.__index = MyComponent

function MyComponent:new()
    local o = Component.new(self, "mycomponent")
    -- Custom initialization
    return o
end

function MyComponent:render()
    -- Custom rendering
    Component.render(self)
end

return MyComponent
```

---

## Performance Tips

1. **Minimize renders**: Only call `render()` when needed
2. **Batch animations**: Group animations together
3. **Use layouts**: Let layout managers handle positioning
4. **Theme once**: Apply themes during initialization, not every frame
5. **Event bubbling**: Events propagate from children to parents

---

## API Reference

### Component Base Class

```lua
component:setId(id)
component:setPosition(x, y)
component:setSize(width, height)
component:setBounds(x, y, width, height)
component:bg([color])
component:fg([color])
component:hoverBg(color)
component:hoverFg(color)
component:clickBg(color)
component:clickFg(color)
component:padding(top, [right, bottom, left])
component:margin(top, [right, bottom, left])
component:border(enabled, [color, char])
component:overflow(mode)
component:show()
component:hide()
component:enable()
component:disable()
component:add(child)
component:remove(child)
component:removeAll()
component:onClick(handler)
component:onHover(handler)
component:onLeave(handler)
component:render()
```

---

Happy UI building! 🎨
