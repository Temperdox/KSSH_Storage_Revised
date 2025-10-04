local BasePage = require("ui.pages.base_page")
local UI = require("ui.framework.ui")

local WithdrawPage = setmetatable({}, {__index = BasePage})
WithdrawPage.__index = WithdrawPage

function WithdrawPage:new(context)
    local o = BasePage.new(self, context, "withdraw")

    o:setTitle("WITHDRAW ITEMS")

    o.mode = "select_location"
    o.selectedLocation = nil
    o.selectedItem = nil
    o.quantity = ""
    o.availableItems = {}

    o.locationList = nil
    o.itemList = nil
    o.quantityPanel = nil
    o.confirmPanel = nil

    return o
end

function WithdrawPage:onEnter()
    self.mode = "select_location"
    self.selectedLocation = nil
    self.selectedItem = nil
    self.quantity = ""
    self:buildLocationView()
    self:render()
end

function WithdrawPage:buildLocationView()
    self.content:removeAll()

    local title = UI.label("== SELECT WITHDRAWAL LOCATION ==", 2, 1)
        :fg(colors.cyan)

    self.content:add(title)

    -- Location list
    local locations = {}

    -- Local storage
    table.insert(locations, {
        text = "[LOCAL] Local Storage - This computer's storage",
        type = "local"
    })

    -- Remote storage connections
    if self.context.router.pages.net then
        local netPage = self.context.router.pages.net
        local storageTypes = nil

        if self.context.services.connectionTypes then
            storageTypes = self.context.services.connectionTypes:getStorageConnectionTypes()
        end

        for _, conn in ipairs(netPage.connections) do
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
                table.insert(locations, {
                    text = "[" .. conn.connectionTypeId:upper():sub(1, 1) .. "] " .. conn.name .. " - Computer #" .. conn.id .. " (ONLINE)",
                    type = "remote",
                    connection = conn
                })
            end
        end
    end

    self.locationList = UI.list(2, 3, self.width - 4, self.height - 6)
        :setItems(locations)
        :setOnItemClick(function(list, index, item)
            if item.type == "local" then
                self.selectedLocation = {type = "local"}
            else
                self.selectedLocation = {type = "remote", connection = item.connection}
            end
            self.mode = "select_item"
            self:buildItemView()
            self:render()
        end)

    self.content:add(self.locationList)

    self:setFooter("Click a location to select it")
end

function WithdrawPage:buildItemView()
    self.content:removeAll()

    local locName = self.selectedLocation.type == "local" and "Local Storage" or self.selectedLocation.connection.name

    local title = UI.label("== SELECT ITEM ==", 2, 1)
        :fg(colors.cyan)

    local subtitle = UI.label("Location: " .. locName, 2, 2)
        :fg(colors.lightGray)

    self.content:add(title)
    self.content:add(subtitle)

    -- Get items
    self.availableItems = self:getItemsFromLocation(self.selectedLocation)

    local items = {}
    for _, item in ipairs(self.availableItems) do
        local shortName = item.name:match("([^:]+)$") or item.name
        if #shortName > 30 then
            shortName = shortName:sub(1, 27) .. "..."
        end
        table.insert(items, {
            text = string.format("%-30s x%-6d", shortName, item.count),
            item = item
        })
    end

    if #items == 0 then
        local noItems = UI.label("No items available at this location", 2, 4)
            :fg(colors.gray)
        self.content:add(noItems)
    else
        self.itemList = UI.list(2, 4, self.width - 4, self.height - 8)
            :setItems(items)
            :setOnItemClick(function(list, index, data)
                self.selectedItem = data.item
                self.quantity = ""
                self.mode = "enter_quantity"
                self:buildQuantityView()
                self:render()
            end)

        self.content:add(self.itemList)
    end

    self:setFooter("Click an item to select it | ESC to go back")
end

function WithdrawPage:buildQuantityView()
    self.content:removeAll()

    local centerY = math.floor(self.height / 2) - 4

    local title = UI.label("== ENTER QUANTITY ==", 2, centerY)
        :fg(colors.cyan)

    local shortName = self.selectedItem.name:match("([^:]+)$") or self.selectedItem.name

    local itemLabel = UI.label("Item: " .. shortName, 2, centerY + 2)
        :fg(colors.white)

    local availLabel = UI.label("Available: " .. tostring(self.selectedItem.count), 2, centerY + 3)
        :fg(colors.yellow)

    local qtyLabel = UI.label("Quantity to withdraw:", 2, centerY + 5)
        :fg(colors.lightGray)

    local qtyInput = UI.panel(2, centerY + 6, self.width - 4, 1)
        :bg(colors.gray)

    local qtyText = UI.label(self.quantity .. "_", 1, 0)
        :bg(colors.gray)
        :fg(colors.white)

    qtyInput:add(qtyText)

    local confirmBtn = UI.button("CONFIRM", 2, centerY + 8)
        :bg(self.quantity ~= "" and tonumber(self.quantity) and colors.green or colors.gray)
        :fg(colors.white)
        :onClick(function()
            if self.quantity ~= "" and tonumber(self.quantity) then
                self.mode = "confirm"
                self:buildConfirmView()
                self:render()
            end
        end)

    self.content:add(title)
    self.content:add(itemLabel)
    self.content:add(availLabel)
    self.content:add(qtyLabel)
    self.content:add(qtyInput)
    self.content:add(confirmBtn)

    self:setFooter("Type quantity and press ENTER or click CONFIRM")
end

function WithdrawPage:buildConfirmView()
    self.content:removeAll()

    local centerY = math.floor(self.height / 2) - 4

    local title = UI.label("== CONFIRM WITHDRAWAL ==", 2, centerY)
        :fg(colors.cyan)

    local shortName = self.selectedItem.name:match("([^:]+)$") or self.selectedItem.name
    local locName = self.selectedLocation.type == "local" and "Local Storage" or self.selectedLocation.connection.name

    local itemLabel = UI.label("Item: " .. shortName, 2, centerY + 2)
        :fg(colors.white)

    local qtyLabel = UI.label("Quantity: " .. self.quantity, 2, centerY + 3)
        :fg(colors.yellow)

    local locLabel = UI.label("Location: " .. locName, 2, centerY + 4)
        :fg(colors.lime)

    local btnPanel = UI.panel(2, centerY + 6, self.width - 4, 1)
    local layout = UI.flexLayout("row", "start", "center"):setGap(2)
    btnPanel:setLayout(layout)

    local confirmBtn = UI.button("WITHDRAW", 0, 0)
        :bg(colors.green)
        :fg(colors.white)
        :onClick(function()
            self:performWithdrawal()
        end)

    local cancelBtn = UI.button("CANCEL", 0, 0)
        :bg(colors.red)
        :fg(colors.white)
        :onClick(function()
            self.context.router:navigate("console")
        end)

    btnPanel:add(confirmBtn)
    btnPanel:add(cancelBtn)

    self.content:add(title)
    self.content:add(itemLabel)
    self.content:add(qtyLabel)
    self.content:add(locLabel)
    self.content:add(btnPanel)

    self:setFooter("Review and confirm withdrawal")
end

function WithdrawPage:getItemsFromLocation(location)
    if location.type == "local" then
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
        local withdrawn = self.context.services.storage:withdraw(self.selectedItem.name, qty)
        if withdrawn > 0 then
            self.context.logger:info("WithdrawPage", string.format("Withdrawn %d x %s from local storage", withdrawn, self.selectedItem.name))
            UI.toast("Withdrawn " .. withdrawn .. " items", 2000, colors.green)
        end
    else
        local conn = self.selectedLocation.connection
        local connectionType = self.context.services.connectionTypes:getConnectionType(conn.connectionTypeId)

        if connectionType and connectionType.requestWithdrawal then
            connectionType:requestWithdrawal(conn, self.selectedItem.name, qty)
            self.context.logger:info("WithdrawPage", string.format("Requested withdrawal of %d x %s from #%d", qty, self.selectedItem.name, conn.id))
            UI.toast("Withdrawal requested", 2000, colors.lime)
        end
    end

    self.context.router:navigate("console")
end

function WithdrawPage:handleInput(event, param1, param2, param3)
    if event == "key" and param1 == keys.escape then
        if self.mode == "select_location" then
            self:navigateBack()
        elseif self.mode == "select_item" then
            self.mode = "select_location"
            self:buildLocationView()
            self:render()
        elseif self.mode == "enter_quantity" then
            self.mode = "select_item"
            self:buildItemView()
            self:render()
        elseif self.mode == "confirm" then
            self.mode = "enter_quantity"
            self:buildQuantityView()
            self:render()
        end
        return
    end

    if event == "key" and self.mode == "enter_quantity" then
        if param1 == keys.enter and self.quantity ~= "" and tonumber(self.quantity) then
            self.mode = "confirm"
            self:buildConfirmView()
            self:render()
        elseif param1 == keys.backspace then
            self.quantity = self.quantity:sub(1, -2)
            self:buildQuantityView()
            self:render()
        end
    elseif event == "char" and self.mode == "enter_quantity" then
        if param1:match("%d") then
            self.quantity = self.quantity .. param1
            self:buildQuantityView()
            self:render()
        end
    end

    BasePage.handleInput(self, event, param1, param2, param3)
end

return WithdrawPage
