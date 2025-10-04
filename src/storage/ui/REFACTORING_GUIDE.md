## UI Framework Refactoring Guide

This guide explains how to migrate existing UI pages to use the new UI framework.

---

## Overview

The new UI framework provides:
- **Component-based architecture** (Label, Button, List, Panel, Window)
- **CSS-like themes** for consistent styling
- **Flexbox layouts** for responsive design
- **Animations** with easing functions
- **Event handling** with hover, click, scroll states
- **Window management** for modals and dialogs

---

## Migration Steps

### 1. Extend BasePage

Instead of creating a page from scratch, extend `BasePage`:

**Old approach:**
```lua
local MyPage = {}
MyPage.__index = MyPage

function MyPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.width, o.height = term.getSize()
    return o
end
```

**New approach:**
```lua
local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")

local MyPage = setmetatable({}, {__index = BasePage})
MyPage.__index = MyPage

function MyPage:new(context)
    local o = BasePage.new(self, context, "mypage")
    o:setTitle("MY PAGE TITLE")
    -- Add custom properties
    return o
end
```

### 2. Build UI Components Instead of Drawing

**Old approach (direct term API):**
```lua
function MyPage:render()
    term.clear()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.write("TITLE")

    term.setCursorPos(2, 3)
    term.setBackgroundColor(colors.green)
    term.write(" BUTTON ")
end
```

**New approach (component-based):**
```lua
function MyPage:onEnter()
    self.content:removeAll()

    local title = UI.label("TITLE", 1, 1)
        :fg(colors.white)
        :bg(colors.gray)

    local button = UI.button("BUTTON", 2, 3)
        :bg(colors.green)
        :onClick(function()
            print("Clicked!")
        end)

    self.content:add(title)
    self.content:add(button)

    self:setFooter("Footer text here")
    self:render()
end
```

### 3. Replace Click Regions with Component Events

**Old approach (manual region tracking):**
```lua
self.buttonRegion = {x1 = 2, x2 = 10, y = 3}

function MyPage:handleClick(x, y)
    if x >= self.buttonRegion.x1 and x <= self.buttonRegion.x2 and y == self.buttonRegion.y then
        -- Handle click
    end
end
```

**New approach (component events):**
```lua
local button = UI.button("Click Me", 2, 3)
    :onClick(function(self, x, y)
        -- Handle click
    end)
```

### 4. Replace Lists with List Component

**Old approach (manual list rendering):**
```lua
function MyPage:drawList()
    for i, item in ipairs(items) do
        term.setCursorPos(2, i + 3)
        if i == self.selectedIndex then
            term.setBackgroundColor(colors.gray)
        else
            term.setBackgroundColor(colors.black)
        end
        term.write(item)
    end
end
```

**New approach (List component):**
```lua
local list = UI.list(2, 3, 30, 10)
    :setItems(items)
    :setOnItemClick(function(list, index, item)
        print("Selected:", item)
    end)

self.content:add(list)
```

### 5. Use Layouts for Positioning

**Old approach (manual positioning):**
```lua
local y = 5
for i, btn in ipairs(buttons) do
    btn.y = y
    y = y + 2
end
```

**New approach (FlexLayout):**
```lua
local panel = UI.panel(5, 5, 40, 20)
local layout = UI.flexLayout("column", "center", "stretch")
    :setGap(2)
panel:setLayout(layout)

for i, btnText in ipairs({"Button 1", "Button 2", "Button 3"}) do
    panel:add(UI.button(btnText))
end
```

### 6. Replace Modals with Windows

**Old approach (manual modal rendering):**
```lua
function MyPage:drawModal()
    -- Draw shadow
    -- Draw background
    -- Draw border
    -- Draw close button
    -- Track regions...
end
```

**New approach (Window component):**
```lua
local window = UI.window("Confirm", 40, 12)
    :setModal(true)
    :center(term.getSize())
    :onClose(function()
        -- Handle close
    end)

window:add(UI.label("Are you sure?", 2, 2))
window:add(UI.button("Yes", 2, 4):onClick(function()
    -- Handle yes
end))

UI.windowManager:add(window)
```

### 7. Event Handling Pattern

**Old approach:**
```lua
function MyPage:handleInput(event, param1, param2, param3)
    if event == "mouse_click" then
        self:handleClick(param2, param3)
    elseif event == "key" then
        -- Handle key
    end
end
```

**New approach (inherited from BasePage):**
```lua
function MyPage:handleInput(event, param1, param2, param3)
    -- Custom key handling
    if event == "key" and param1 == keys.enter then
        -- Do something
    end

    -- Call base handler (handles mouse, UI updates, etc.)
    BasePage.handleInput(self, event, param1, param2, param3)
end
```

---

## Complete Example: Refactoring a Page

### Before (Old Style)

```lua
local SettingsPage = {}
SettingsPage.__index = SettingsPage

function SettingsPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.width, o.height = term.getSize()
    o.selectedOption = 1
    o.options = {"Theme", "Volume", "Log Level"}
    return o
end

function SettingsPage:render()
    term.clear()

    -- Header
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write("SETTINGS")

    -- Options
    for i, option in ipairs(self.options) do
        term.setCursorPos(2, i + 2)
        if i == self.selectedOption then
            term.setBackgroundColor(colors.gray)
        else
            term.setBackgroundColor(colors.black)
        end
        term.write(option)
    end
end

function SettingsPage:handleClick(x, y)
    for i = 1, #self.options do
        if y == i + 2 then
            self.selectedOption = i
            self:render()
        end
    end
end
```

### After (New Framework Style)

```lua
local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")

local SettingsPage = setmetatable({}, {__index = BasePage})
SettingsPage.__index = SettingsPage

function SettingsPage:new(context)
    local o = BasePage.new(self, context, "settings")
    o:setTitle("SETTINGS")

    o.options = {"Theme", "Volume", "Log Level"}
    o.selectedOption = 1

    return o
end

function SettingsPage:onEnter()
    self.content:removeAll()

    local list = UI.list(2, 1, self.width - 4, self.height - 4)
        :setItems(self.options)
        :setOnItemClick(function(list, index, item)
            self.selectedOption = index
            self:showOptionEditor(item)
        end)

    self.content:add(list)
    self:setFooter("Click an option to edit")
    self:render()
end

function SettingsPage:showOptionEditor(option)
    -- Create editor window
    local window = UI.window("Edit: " .. option, 40, 10)
        :setModal(true)
        :center(self.width, self.height)

    -- Add editor content...

    UI.windowManager:add(window)
    self:render()
end
```

---

## Component Catalog

### Label
```lua
UI.label(text, x, y)
    :setText(text)
    :setTextAlign("center")  -- left, center, right
    :fg(color)
    :bg(color)
```

### Button
```lua
UI.button(text, x, y)
    :setText(text)
    :bg(color)
    :hoverBg(color)
    :clickBg(color)
    :onClick(function(self) end)
    :onHover(function(self) end)
```

### List
```lua
UI.list(x, y, width, height)
    :setItems(items)
    :setItemHeight(height)
    :setOnItemClick(function(self, index, item) end)
    :addItem(item)
    :removeItem(index)
    :clear()
```

### Panel
```lua
UI.panel(x, y, width, height)
    :setLayout(layout)
    :add(child)
    :remove(child)
    :removeAll()
    :bg(color)
    :padding(top, right, bottom, left)
    :border(enabled, color, char)
```

### Window
```lua
UI.window(title, width, height)
    :setTitle(title)
    :setModal(boolean)
    :setDraggable(boolean)
    :center(screenWidth, screenHeight)
    :onClose(function(self) end)
    :add(component)
```

---

## Layout Examples

### Vertical Stack
```lua
local panel = UI.panel(5, 5, 40, 20)
local layout = UI.flexLayout("column", "start", "stretch")
    :setGap(1)
panel:setLayout(layout)

panel:add(UI.label("Header"))
panel:add(UI.button("Button 1"))
panel:add(UI.button("Button 2"))
```

### Horizontal Button Row
```lua
local panel = UI.panel(5, 5, 40, 3)
local layout = UI.flexLayout("row", "center", "center")
    :setGap(2)
panel:setLayout(layout)

panel:add(UI.button("Save"))
panel:add(UI.button("Cancel"))
```

### Centered Modal Content
```lua
local window = UI.window("Confirm", 40, 15)
local content = UI.panel(1, 1, 38, 13)
local layout = UI.flexLayout("column", "center", "center")
    :setGap(2)
content:setLayout(layout)

content:add(UI.label("Are you sure?"))
content:add(UI.button("Yes"))
content:add(UI.button("No"))

window:add(content)
```

---

## Theme Integration

### Apply Theme to Page
```lua
function MyPage:onEnter()
    -- Build UI...

    -- Apply theme
    UI.applyTheme(self.root)

    self:render()
end
```

### Custom Component Styling
```lua
local button = UI.button("Primary", 10, 5)
    :setId("primaryButton")  -- Styled by #primaryButton in CSS

local errorLabel = UI.label("Error!", 10, 7)
    :setId("errorMessage")  -- Styled by #errorMessage in CSS
```

---

## Animation Examples

### Slide In
```lua
local panel = UI.panel(self.width, 5, 40, 10)
UI.animate(panel, "x", 5, 500, "easeOutQuad"):start()
```

### Fade Color
```lua
local label = UI.label("Success!", 10, 5)
UI.animate(label, "styles.fg", colors.lime, 300, "linear"):start()
```

### Bounce Button
```lua
local button = UI.button("Click", 10, 5)
button:onClick(function(self)
    UI.animate(self, "y", 7, 200, "easeOutBounce")
        :setOnComplete(function(btn)
            btn.y = 5  -- Reset
        end)
        :start()
end)
```

---

## Common Patterns

### Build-Rebuild Pattern
```lua
function MyPage:onEnter()
    self:buildMainView()
    self:render()
end

function MyPage:buildMainView()
    self.content:removeAll()

    -- Add components...

    self:setFooter("Main view")
end

function MyPage:buildDetailView(item)
    self.content:removeAll()

    -- Add detail components...

    self:setFooter("Detail view | ESC to go back")
    self:render()
end
```

### State Machine Pattern
```lua
function MyPage:onEnter()
    self.state = "list"
    self:updateView()
end

function MyPage:updateView()
    if self.state == "list" then
        self:buildListView()
    elseif self.state == "edit" then
        self:buildEditView()
    elseif self.state == "confirm" then
        self:buildConfirmView()
    end
    self:render()
end

function MyPage:setState(newState)
    self.state = newState
    self:updateView()
end
```

---

## Migration Checklist

- [ ] Extend `BasePage` instead of creating from scratch
- [ ] Replace `term` API calls with UI components
- [ ] Convert manual click regions to `onClick` handlers
- [ ] Replace custom lists with `UI.list()`
- [ ] Use layouts instead of manual positioning
- [ ] Convert modals to `UI.window()`
- [ ] Use `self.content` instead of rendering directly
- [ ] Call `BasePage.handleInput()` for event handling
- [ ] Apply themes with `UI.applyTheme()`
- [ ] Add animations for polish

---

## Tips & Best Practices

1. **Component Reuse**: Create common components once, reuse everywhere
2. **Layouts First**: Use FlexLayout before manual positioning
3. **Theme Everything**: Let CSS handle colors, not hardcoded values
4. **Build Methods**: Separate build logic from render logic
5. **State Management**: Keep state in page, rebuild UI on state change
6. **Performance**: Only rebuild components when state changes
7. **Responsive**: Use relative sizes and layouts for monitor resizing

---

## See Also

- `/ui/framework/UI_GUIDE.md` - Complete UI framework documentation
- `/ui/pages/withdraw_page.lua` - Complete refactored example
- `/ui/pages/base_page.lua` - Base page implementation
- `/ui/themes/` - Example theme files
