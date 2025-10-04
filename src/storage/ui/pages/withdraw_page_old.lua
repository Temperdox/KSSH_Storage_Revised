local WithdrawPage = {}
WithdrawPage.__index = WithdrawPage

function WithdrawPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    o.mode = "select_location" -- select_location, select_item, enter_quantity, confirm
    o.selectedLocation = nil -- {type = "local" or "remote", connection = conn}
    o.selectedItem = nil
    o.quantity = ""
    o.availableItems = {}

    o.width, o.height = term.getSize()
    o.backLink = {}
    o.locationButtons = {}
    o.itemButtons = {}
    o.confirmButton = {}
    o.cancelButton = {}

    return o
end

function WithdrawPage:onEnter()
    self.mode = "select_location"
    self.selectedLocation = nil
    self.selectedItem = nil
    self.quantity = ""
    self:render()
end

function WithdrawPage:onLeave()
    -- Clean up
end

function WithdrawPage:render()
    term.setBackgroundColor(colors.black)
    term.clear()

    self:drawHeader()

    if self.mode == "select_location" then
        self:drawLocationSelection()
    elseif self.mode == "select_item" then
        self:drawItemSelection()
    elseif self.mode == "enter_quantity" then
        self:drawQuantityInput()
    elseif self.mode == "confirm" then
        self:drawConfirmation()
    end

    self:drawFooter()
end

function WithdrawPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.setCursorPos(2, 1)
    term.write("WITHDRAW ITEMS")

    term.setCursorPos(self.width - 6, 1)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" BACK ")
    self.backLink = {y = 1, x1 = self.width - 6, x2 = self.width}
end

function WithdrawPage:drawLocationSelection()
    local y = 3

    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== SELECT WITHDRAWAL LOCATION ==")
    y = y + 2

    self.locationButtons = {}

    -- Local storage option
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.green)
    term.setTextColor(colors.white)
    term.write(" [LOCAL] Local Storage ")
    table.insert(self.locationButtons, {
        y = y,
        x1 = 2,
        x2 = 24,
        location = {type = "local"}
    })

    term.setBackgroundColor(colors.black)
    term.setCursorPos(26, y)
    term.setTextColor(colors.lightGray)
    term.write("Withdraw from this computer's storage")
    y = y + 2

    -- Remote storage connections
    term.setCursorPos(2, y)
    term.setTextColor(colors.cyan)
    term.write("== REMOTE STORAGE ==")
    y = y + 1

    local hasRemote = false
    if self.context.router.pages.net then
        local netPage = self.context.router.pages.net
        local storageTypes = nil

        if self.context.services.connectionTypes then
            storageTypes = self.context.services.connectionTypes:getStorageConnectionTypes()
        end

        for _, conn in ipairs(netPage.connections) do
            -- Check if connection is storage type
            local isStorage = false
            if storageTypes then
                for _, storageType in ipairs(storageTypes) do
                    if conn.connectionTypeId == storageType.id then
                        isStorage = true
                        break
                    end
                end
            end

            if isStorage and conn.presence and conn.presence.online then
                hasRemote = true
                term.setCursorPos(2, y)
                term.setBackgroundColor(colors.orange)
                term.setTextColor(colors.white)

                local label = string.format(" [%s] %s ", conn.connectionTypeId:upper():sub(1, 1), conn.name)
                term.write(label)

                table.insert(self.locationButtons, {
                    y = y,
                    x1 = 2,
                    x2 = 2 + #label - 1,
                    location = {type = "remote", connection = conn}
                })

                term.setBackgroundColor(colors.black)
                term.setCursorPos(2 + #label + 2, y)
                term.setTextColor(colors.lime)
                term.write("ONLINE")
                term.setTextColor(colors.lightGray)
                term.write(" - Computer #" .. conn.id)

                y = y + 1

                if y >= self.height - 3 then break end
            end
        end
    end

    if not hasRemote then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("No online remote storage connections")
        y = y + 1

        term.setCursorPos(2, y)
        term.setTextColor(colors.lightGray)
        term.write("Tip: Connect remote storage via Network page")
    end
end

function WithdrawPage:drawItemSelection()
    local y = 3

    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== SELECT ITEM ==")
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    local locName = self.selectedLocation.type == "local" and "Local Storage" or self.selectedLocation.connection.name
    term.write("Location: " .. locName)
    y = y + 2

    self.itemButtons = {}

    -- Get items from selected location
    self.availableItems = self:getItemsFromLocation(self.selectedLocation)

    if #self.availableItems == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("No items available at this location")
    else
        for i, item in ipairs(self.availableItems) do
            term.setCursorPos(2, y)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)

            local shortName = item.name:match("([^:]+)$") or item.name
            if #shortName > 30 then
                shortName = shortName:sub(1, 27) .. "..."
            end

            local line = string.format(" %-30s x%-6d ", shortName, item.count)
            term.write(line)

            table.insert(self.itemButtons, {
                y = y,
                x1 = 2,
                x2 = 2 + #line - 1,
                item = item
            })

            y = y + 1
            term.setBackgroundColor(colors.black)

            if y >= self.height - 3 then break end
        end
    end
end

function WithdrawPage:drawQuantityInput()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== ENTER QUANTITY ==")

    term.setCursorPos(2, centerY - 1)
    term.setTextColor(colors.lightGray)
    term.write("Item: ")
    term.setTextColor(colors.white)
    local shortName = self.selectedItem.name:match("([^:]+)$") or self.selectedItem.name
    term.write(shortName)

    term.setCursorPos(2, centerY)
    term.setTextColor(colors.lightGray)
    term.write("Available: ")
    term.setTextColor(colors.yellow)
    term.write(tostring(self.selectedItem.count))

    term.setCursorPos(2, centerY + 2)
    term.setTextColor(colors.lightGray)
    term.write("Quantity to withdraw:")

    term.setCursorPos(2, centerY + 3)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    local inputWidth = self.width - 4
    term.write(string.rep(" ", inputWidth))
    term.setCursorPos(3, centerY + 3)
    term.write(self.quantity .. "_")

    -- Confirm button
    term.setCursorPos(2, centerY + 5)
    if self.quantity ~= "" and tonumber(self.quantity) then
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(" CONFIRM ")
    self.confirmButton = {y = centerY + 5, x1 = 2, x2 = 12}

    term.setCursorPos(14, centerY + 5)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.write("or press ENTER")
end

function WithdrawPage:drawConfirmation()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== CONFIRM WITHDRAWAL ==")

    term.setCursorPos(2, centerY - 2)
    term.setTextColor(colors.lightGray)
    term.write("Item: ")
    term.setTextColor(colors.white)
    local shortName = self.selectedItem.name:match("([^:]+)$") or self.selectedItem.name
    term.write(shortName)

    term.setCursorPos(2, centerY - 1)
    term.setTextColor(colors.lightGray)
    term.write("Quantity: ")
    term.setTextColor(colors.yellow)
    term.write(self.quantity)

    term.setCursorPos(2, centerY)
    term.setTextColor(colors.lightGray)
    term.write("Location: ")
    term.setTextColor(colors.lime)
    local locName = self.selectedLocation.type == "local" and "Local Storage" or self.selectedLocation.connection.name
    term.write(locName)

    -- Confirm button
    term.setCursorPos(2, centerY + 2)
    term.setBackgroundColor(colors.green)
    term.setTextColor(colors.white)
    term.write(" WITHDRAW ")
    self.confirmButton = {y = centerY + 2, x1 = 2, x2 = 12}

    -- Cancel button
    term.setCursorPos(14, centerY + 2)
    term.setBackgroundColor(colors.red)
    term.write(" CANCEL ")
    self.cancelButton = {y = centerY + 2, x1 = 14, x2 = 22}
end

function WithdrawPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.setCursorPos(2, self.height)

    if self.mode == "select_location" then
        term.write("Click a location to select it")
    elseif self.mode == "select_item" then
        term.write("Click an item to select it")
    elseif self.mode == "enter_quantity" then
        term.write("Type quantity and press ENTER or click CONFIRM")
    elseif self.mode == "confirm" then
        term.write("Review and confirm withdrawal")
    end
end

function WithdrawPage:getItemsFromLocation(location)
    if location.type == "local" then
        -- Get items from local storage
        local items = self.context.services.storage:getItems()
        local result = {}
        for _, item in ipairs(items) do
            table.insert(result, {
                name = item.key,
                count = item.value.count or 0
            })
        end
        return result
    else
        -- Get items from remote connection
        local conn = location.connection
        local connectionType = self.context.services.connectionTypes:getConnectionType(conn.connectionTypeId)

        if connectionType and connectionType.getAvailableItems then
            local items = connectionType:getAvailableItems(conn)
            local result = {}
            for name, count in pairs(items) do
                table.insert(result, {
                    name = name,
                    count = count
                })
            end
            return result
        end

        return {}
    end
end

function WithdrawPage:performWithdrawal()
    local qty = tonumber(self.quantity)
    if not qty or qty <= 0 then
        return
    end

    if self.selectedLocation.type == "local" then
        -- Local withdrawal
        local withdrawn = self.context.services.storage:withdraw(self.selectedItem.name, qty)
        if withdrawn > 0 then
            self.logger:info("WithdrawPage", string.format("Withdrawn %d x %s from local storage", withdrawn, self.selectedItem.name))
        end
    else
        -- Remote withdrawal
        local conn = self.selectedLocation.connection
        local connectionType = self.context.services.connectionTypes:getConnectionType(conn.connectionTypeId)

        if connectionType and connectionType.requestWithdrawal then
            connectionType:requestWithdrawal(conn, self.selectedItem.name, qty)
            self.logger:info("WithdrawPage", string.format("Requested withdrawal of %d x %s from #%d", qty, self.selectedItem.name, conn.id))
        end
    end

    -- Return to console
    self.context.router:navigate("console")
end

function WithdrawPage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1

        if key == keys.escape then
            if self.mode == "select_location" then
                self.context.router:navigate("console")
            else
                -- Go back one step
                if self.mode == "select_item" then
                    self.mode = "select_location"
                elseif self.mode == "enter_quantity" then
                    self.mode = "select_item"
                elseif self.mode == "confirm" then
                    self.mode = "enter_quantity"
                end
                self:render()
            end

        elseif self.mode == "enter_quantity" then
            if key == keys.enter and self.quantity ~= "" and tonumber(self.quantity) then
                self.mode = "confirm"
                self:render()
            elseif key == keys.backspace then
                self.quantity = self.quantity:sub(1, -2)
                self:render()
            end
        end

    elseif event == "char" then
        if self.mode == "enter_quantity" then
            -- Only allow digits
            if param1:match("%d") then
                self.quantity = self.quantity .. param1
                self:render()
            end
        end

    elseif event == "mouse_click" then
        self:handleClick(param2, param3)
    end
end

function WithdrawPage:handleClick(x, y)
    -- Back button
    if y == self.backLink.y and x >= self.backLink.x1 and x <= self.backLink.x2 then
        self.context.router:navigate("console")
        return
    end

    if self.mode == "select_location" then
        for _, btn in ipairs(self.locationButtons) do
            if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                self.selectedLocation = btn.location
                self.mode = "select_item"
                self:render()
                return
            end
        end

    elseif self.mode == "select_item" then
        for _, btn in ipairs(self.itemButtons) do
            if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                self.selectedItem = btn.item
                self.quantity = ""
                self.mode = "enter_quantity"
                self:render()
                return
            end
        end

    elseif self.mode == "enter_quantity" then
        if self.confirmButton and self.confirmButton.y == y and x >= self.confirmButton.x1 and x <= self.confirmButton.x2 then
            if self.quantity ~= "" and tonumber(self.quantity) then
                self.mode = "confirm"
                self:render()
            end
        end

    elseif self.mode == "confirm" then
        if self.confirmButton and self.confirmButton.y == y and x >= self.confirmButton.x1 and x <= self.confirmButton.x2 then
            self:performWithdrawal()
        elseif self.cancelButton and self.cancelButton.y == y and x >= self.cancelButton.x1 and x <= self.cancelButton.x2 then
            self.context.router:navigate("console")
        end
    end
end

return WithdrawPage
