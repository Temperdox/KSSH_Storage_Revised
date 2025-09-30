local ViewFactory = {}
ViewFactory.__index = ViewFactory

function ViewFactory:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.views = {}
    o.currentView = nil

    -- Register default views
    self:registerDefaults()

    return o
end

function ViewFactory:registerDefaults()
    self.views = {
        console = {
            module = "ui.pages.console_page",
            title = "Console",
            icon = "[C]",
            order = 1
        },
        stats = {
            module = "ui.pages.stats_page",
            title = "Statistics",
            icon = "[S]",
            order = 2
        },
        tests = {
            module = "ui.pages.tests_page",
            title = "Tests",
            icon = "[T]",
            order = 3
        },
        settings = {
            module = "ui.pages.settings_page",
            title = "Settings",
            icon = "[X]",
            order = 4
        }
    }
end

function ViewFactory:register(name, config)
    self.views[name] = config
end

function ViewFactory:create(viewName)
    local config = self.views[viewName]
    if not config then
        error("Unknown view: " .. viewName)
    end

    -- Load view module
    local ok, View = pcall(require, config.module)
    if not ok then
        error("Failed to load view module: " .. config.module)
    end

    -- Create view instance
    local view = View:new(self.context)
    view.name = viewName
    view.title = config.title
    view.icon = config.icon

    return view
end

function ViewFactory:switchTo(viewName)
    if self.currentView and self.currentView.onLeave then
        self.currentView:onLeave()
    end

    self.currentView = self:create(viewName)

    if self.currentView.onEnter then
        self.currentView:onEnter()
    end

    self.context.eventBus:publish("ui.viewChanged", {
        from = self.currentView and self.currentView.name,
        to = viewName
    })

    return self.currentView
end

function ViewFactory:getCurrent()
    return self.currentView
end

function ViewFactory:getList()
    local list = {}
    for name, config in pairs(self.views) do
        table.insert(list, {
            name = name,
            title = config.title,
            icon = config.icon,
            order = config.order or 99
        })
    end

    table.sort(list, function(a, b)
        return a.order < b.order
    end)

    return list
end

return ViewFactory