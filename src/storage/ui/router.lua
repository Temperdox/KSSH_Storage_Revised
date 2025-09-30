local Router = {}
Router.__index = Router

function Router:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.pages = {}
    o.currentPage = nil
    o.history = {}

    return o
end

function Router:register(name, page)
    self.pages[name] = page
end

function Router:navigate(pageName)
    if not self.pages[pageName] then
        return false, "Page not found: " .. pageName
    end

    -- Leave current page
    if self.currentPage and self.currentPage.onLeave then
        self.currentPage:onLeave()
    end

    -- Add to history
    if self.currentPage then
        table.insert(self.history, self.currentPage.name)
        if #self.history > 10 then
            table.remove(self.history, 1)
        end
    end

    -- Enter new page
    self.currentPage = self.pages[pageName]
    self.currentPage.name = pageName

    if self.currentPage.onEnter then
        self.currentPage:onEnter()
    end

    -- Render
    if self.currentPage.render then
        self.currentPage:render()
    end

    return true
end

function Router:back()
    if #self.history > 0 then
        local previousPage = table.remove(self.history)
        return self:navigate(previousPage)
    end
    return false
end

function Router:handleInput(event, ...)
    if self.currentPage and self.currentPage.handleInput then
        self.currentPage:handleInput(event, ...)
    end
end

function Router:getCurrentPage()
    return self.currentPage
end

return Router