local BasePage = require("ui.pages.base_page")

local NetPage = setmetatable({}, {__index = BasePage})
NetPage.__index = NetPage

function NetPage:new(context)
    local o = BasePage.new(self, context, "net")

    o.eventBus = context.eventBus
    o.logger = context.logger

    -- Find wireless modem
    o.modem = peripheral.find("modem", function(name, wrapped)
        return wrapped.isWireless()
    end)

    if o.modem then
        if not rednet.isOpen(peripheral.getName(o.modem)) then
            rednet.open(peripheral.getName(o.modem))
        end
    end

    o.computerId = os.getComputerID()
    o.connections = {}
    o.mode = "list" -- list, generate, enter_name, enter_code, awaiting, verify_pin, requests, details, select_type
    o.connectionName = ""
    o.enteredCode = ""
    o.currentCode = nil -- Current pairing code {code, pin, expiresAt}
    o.codeTimer = nil
    o.pendingRequests = {} -- List of incoming pairing requests
    o.pairingPin = nil -- 4-digit verification PIN for computer entering code
    o.selectedIndex = 1
    o.errorMessage = nil -- Error message to display
    o.errorTimer = nil -- Timer to clear error message
    o.selectedConnection = nil -- Connection being viewed in details mode
    o.pingTimer = nil -- Timer for periodic pings

    -- Button regions
    o.backLink = {}
    o.addButton = {}
    o.enterButton = {}
    o.requestsButton = {}
    o.requestButtons = {}
    o.cancelButton = {}
    o.confirmButton = {}
    o.typeChangeButton = {}
    o.typeButtons = {}
    o.connectionRegions = {}

    -- Custom header - don't use base page header
    o.header:removeAll()
    o.header.height = 0  -- Hide the header panel completely

    return o
end

function NetPage:onEnter()
    self:loadConnections()
    self:startListener()
    self:startPingService()
    self:broadcastAlive()
    self:render()
end

function NetPage:onLeave()
    if self.listenerRunning then
        self.listenerRunning = false
    end
    if self.codeTimer then
        os.cancelTimer(self.codeTimer)
        self.codeTimer = nil
    end
    if self.errorTimer then
        os.cancelTimer(self.errorTimer)
        self.errorTimer = nil
    end
    if self.pingTimer then
        os.cancelTimer(self.pingTimer)
        self.pingTimer = nil
    end
end

function NetPage:loadConnections()
    local content = self.context.diskManager:readFile("config", "net_connections.json")
    if content then
        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data then
            self.connections = data.connections or {}
        end
    end
end

function NetPage:saveConnections()
    local ok, serialized = pcall(textutils.serialiseJSON, {
        connections = self.connections,
        timestamp = os.epoch("utc")
    })

    if ok then
        self.context.diskManager:writeFile("config", "net_connections.json", serialized)
    end
end

function NetPage:startListener()
    if not self.modem then return end

    self.listenerRunning = true

    self.context.scheduler:submit("net", function()
        while self.listenerRunning do
            local senderId, message = rednet.receive("storage_pair", 0.1)

            if senderId and type(message) == "table" then
                if message.type == "pair_request" then
                    -- Validate PIN against current code
                    if self.currentCode and message.pin == self.currentCode.pin then
                        -- Valid PIN - generate verification PIN
                        local verifyPin = string.format("%04d", math.random(1000, 9999))

                        -- Store pending request
                        table.insert(self.pendingRequests, {
                            id = senderId,
                            name = message.name,
                            pin = verifyPin,
                            timestamp = os.epoch("utc")
                        })

                        -- Send verification PIN back
                        rednet.send(senderId, {
                            type = "pair_ack",
                            pin = verifyPin
                        }, "storage_pair")

                        self.logger:info("NetPage", "Valid pair request from #" .. senderId .. " (" .. message.name .. "), verification PIN: " .. verifyPin)
                    else
                        self.logger:info("NetPage", "Invalid pair request from #" .. senderId .. " - PIN mismatch")
                    end

                elseif message.type == "pair_ack" then
                    -- Set pairing PIN for verification
                    self.pairingPin = message.pin
                    self.logger:info("NetPage", "Received pairing PIN: " .. message.pin)

                elseif message.type == "pair_accept" then
                    -- Add connection
                    self:addConnection(senderId, message.name)
                    self.mode = "list"
                    self.logger:info("NetPage", "Pairing accepted by #" .. senderId)

                elseif message.type == "ping" then
                    -- Respond to ping
                    rednet.send(senderId, {
                        type = "pong",
                        timestamp = message.timestamp
                    }, "storage_pair")
                    self:trackPacket(senderId, "received", 50)

                elseif message.type == "pong" then
                    -- Calculate ping time
                    local pingTime = os.epoch("utc") - message.timestamp
                    self:updatePing(senderId, pingTime)
                    self:trackPacket(senderId, "received", 50)

                elseif message.type == "alive" then
                    -- Received alive broadcast - mark as online and respond
                    self:markConnectionOnline(senderId)
                    rednet.send(senderId, {
                        type = "alive_response",
                        name = "Computer " .. self.computerId
                    }, "storage_pair")
                    self:trackPacket(senderId, "received", 50)

                elseif message.type == "alive_response" then
                    -- Received alive response - mark as online
                    self:markConnectionOnline(senderId)
                    self:trackPacket(senderId, "received", 50)

                else
                    -- Try connection type message handler
                    local handled = false
                    for _, conn in ipairs(self.connections) do
                        if conn.id == senderId then
                            if self.context.services.connectionTypes then
                                handled = self.context.services.connectionTypes:handleMessage(conn, message)
                            end
                            break
                        end
                    end

                    if not handled then
                        self.logger:warn("NetPage", "Unhandled message type: " .. tostring(message.type))
                    end
                end
            end
        end
    end)
end

function NetPage:generateCode()
    -- Generate 4-digit random PIN
    local pin = string.format("%04d", math.random(1000, 9999))

    -- Create code: COMPUTERID_PIN
    local code = self.computerId .. "_" .. pin

    local epoch = os.epoch("utc")

    self.logger:info("NetPage", "Generated code: " .. code)

    return {
        code = code,
        pin = pin,
        generated = epoch,
        expiresAt = epoch + 30000  -- 30 seconds
    }
end

function NetPage:sendPairRequest(targetId, pin, myName)
    rednet.send(targetId, {
        type = "pair_request",
        pin = pin,
        name = myName
    }, "storage_pair")

    self.logger:info("NetPage", "Sent pair request to #" .. targetId .. " with PIN: " .. pin)
end

function NetPage:acceptPairing(request)
    -- Add connection
    self:addConnection(request.id, request.name)

    -- Send acceptance
    rednet.send(request.id, {
        type = "pair_accept",
        name = "Computer " .. self.computerId
    }, "storage_pair")

    -- Remove from pending
    for i, req in ipairs(self.pendingRequests) do
        if req.id == request.id then
            table.remove(self.pendingRequests, i)
            break
        end
    end

    self.logger:info("NetPage", "Accepted pairing with #" .. request.id)
end

function NetPage:addConnection(id, name)
    for _, conn in ipairs(self.connections) do
        if conn.id == id then
            return
        end
    end

    local now = os.epoch("utc")
    local connection = {
        id = id,
        name = name,
        addedAt = now,
        systemType = "storage",
        connectionTypeId = "storage",  -- Default to storage connection type
        metrics = {
            packetsSent = 0,
            packetsReceived = 0,
            bytesSent = 0,
            bytesReceived = 0,
            lastPing = nil,
            avgPing = 0,
            pingCount = 0,
            totalPing = 0,
            connectedAt = now,
            lastActive = now
        },
        presence = {
            online = false,  -- Start as offline until first response
            lastSeen = now
        }
    }

    table.insert(self.connections, connection)
    self:saveConnections()

    -- Call connection type onConnect lifecycle
    if self.context.services.connectionTypes then
        self.context.services.connectionTypes:onConnect(connection)
    end
end

function NetPage:removeConnection(conn)
    for i, c in ipairs(self.connections) do
        if c.id == conn.id then
            table.remove(self.connections, i)
            self:saveConnections()
            return
        end
    end
end

function NetPage:render()
    term.setBackgroundColor(colors.black)
    term.clear()

    self:drawHeader()

    if self.mode == "list" then
        self:drawConnectionsList()
    elseif self.mode == "generate" then
        self:drawGenerateMode()
    elseif self.mode == "enter_name" then
        self:drawEnterNameMode()
    elseif self.mode == "enter_code" then
        self:drawEnterCodeMode()
    elseif self.mode == "awaiting" then
        self:drawAwaitingMode()
    elseif self.mode == "verify_pin" then
        self:drawVerifyPinMode()
    elseif self.mode == "requests" then
        self:drawRequestsMode()
    elseif self.mode == "details" then
        self:drawConnectionDetails()
    elseif self.mode == "select_type" then
        self:drawSelectTypeMode()
    end

    self:drawFooter()
end

function NetPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()

    -- Store clickable regions
    self.navButtons = self.navButtons or {}

    -- Navigation bar
    local x = 2

    -- Console button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write("[Console]")
    self.navButtons.console = {y = 1, x1 = x, x2 = x + 8}
    x = x + 10

    -- Net button (active)
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.lightGray)
    term.setTextColor(colors.black)
    term.write("[Net]")
    self.navButtons.net = {y = 1, x1 = x, x2 = x + 4}
    x = x + 6

    -- Stats button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.cyan)
    term.write("[Stats]")
    self.navButtons.stats = {y = 1, x1 = x, x2 = x + 6}
    x = x + 8

    -- Tests button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lime)
    term.write("[Tests]")
    self.navButtons.tests = {y = 1, x1 = x, x2 = x + 6}
    x = x + 8

    -- Settings button
    term.setCursorPos(x, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.orange)
    term.write("[Settings]")
    self.navButtons.settings = {y = 1, x1 = x, x2 = x + 9}

    term.setBackgroundColor(colors.black)
end

function NetPage:drawConnectionsList()
    local y = 3

    -- Buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.green)
    term.setTextColor(colors.white)
    term.write(" + ADD CONNECTION ")
    self.addButton = {y = y, x1 = 2, x2 = 19}

    term.setCursorPos(21, y)
    term.setBackgroundColor(colors.blue)
    term.write(" ENTER CODE ")
    self.enterButton = {y = y, x1 = 21, x2 = 33}

    -- Requests button - ALWAYS visible
    term.setCursorPos(35, y)
    if #self.pendingRequests > 0 then
        term.setBackgroundColor(colors.orange)
        term.setTextColor(colors.white)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(string.format(" REQUESTS [%d] ", #self.pendingRequests))
    self.requestsButton = {y = y, x1 = 35, x2 = 51}

    y = y + 2

    -- Connections
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== PAIRED COMPUTERS ==")
    y = y + 1

    if #self.connections == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("No connections")
    else
        self.connectionRegions = {}
        for i, conn in ipairs(self.connections) do
            term.setCursorPos(2, y)
            term.setBackgroundColor(colors.gray)

            -- Determine online status color
            local isOnline = conn.presence and conn.presence.online
            local nameColor = isOnline and colors.lime or colors.red

            -- Format ping display
            local pingDisplay = "---"
            if conn.metrics and conn.metrics.lastPing then
                pingDisplay = string.format("%dms", conn.metrics.lastPing)
            end

            -- Write ID
            term.setTextColor(colors.white)
            term.write(string.format(" #%-3d  ", conn.id))

            -- Write name with status color
            term.setTextColor(nameColor)
            term.write(string.format("%-15s", conn.name:sub(1, 15)))

            -- Write ping
            term.setTextColor(colors.cyan)
            term.write(string.format("  %5s ", pingDisplay))

            -- Store clickable region for connection (calculate total width)
            local lineWidth = 29 -- " #123  Name12345678901  123ms "
            table.insert(self.connectionRegions, {
                y = y,
                x1 = 2,
                x2 = 2 + lineWidth,
                connection = conn
            })

            term.setBackgroundColor(colors.red)
            term.setTextColor(colors.white)
            term.write(" X ")

            y = y + 1
            term.setBackgroundColor(colors.black)
            if y >= self.height - 2 then break end
        end

        -- Instructions
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("(Click connection to view details)")
    end
end

function NetPage:drawGenerateMode()
    local centerY = math.floor(self.height / 2)
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" CANCEL ")
    self.cancelButton = {y = y, x1 = 2, x2 = 10}

    -- Requests button - ALWAYS visible
    term.setCursorPos(12, y)
    if #self.pendingRequests > 0 then
        term.setBackgroundColor(colors.orange)
        term.setTextColor(colors.white)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(string.format(" REQUESTS [%d] ", #self.pendingRequests))
    self.requestsButton = {y = y, x1 = 12, x2 = 28}

    term.setCursorPos(2, centerY - 5)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("PAIRING CODE FOR: " .. self.connectionName)

    if self.currentCode then
        -- Show pairing code
        term.setCursorPos(2, centerY - 3)
        term.setTextColor(colors.lightGray)
        term.write("Share this code:")

        term.setCursorPos(2, centerY - 2)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.yellow)
        local codeDisplay = " " .. self.currentCode.code .. " "
        term.write(codeDisplay)

        -- Countdown bar
        local timeLeft = math.max(0, (self.currentCode.expiresAt - os.epoch("utc")) / 1000)
        local barWidth = self.width - 4
        local fillWidth = math.floor((timeLeft / 30) * barWidth)

        term.setCursorPos(2, centerY)

        -- Determine bar color
        local barColor
        if timeLeft > 30 then
            barColor = colors.lime
        else
            barColor = colors.red
        end

        -- Draw filled portion
        for x = 1, fillWidth do
            term.setBackgroundColor(barColor)
            term.write(" ")
        end

        -- Draw empty portion
        for x = fillWidth + 1, barWidth do
            term.setBackgroundColor(colors.gray)
            term.write(" ")
        end

        -- Time text in center of bar with matching background
        local timeText = string.format("%ds", math.floor(timeLeft))
        local textX = math.floor((self.width - #timeText) / 2)
        term.setCursorPos(textX, centerY)

        -- Set background color to match the bar at this position
        local textPosition = textX - 2  -- Offset for bar start position
        if textPosition <= fillWidth then
            term.setBackgroundColor(barColor)
            if barColor == colors.lime then
                term.setTextColor(colors.black)
            else
                term.setTextColor(colors.white)
            end
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
        end
        term.write(timeText)

        -- Info
        term.setCursorPos(2, centerY + 2)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("Code regenerates every 30 seconds")
    end
end

function NetPage:drawEnterNameMode()
    local centerY = math.floor(self.height / 2)
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" CANCEL ")
    self.cancelButton = {y = y, x1 = 2, x2 = 10}

    term.setCursorPos(2, centerY - 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== ADD NEW CONNECTION ==")

    term.setCursorPos(2, centerY - 1)
    term.setTextColor(colors.lightGray)
    term.write("Enter a name for this connection:")

    term.setCursorPos(2, centerY + 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    local inputWidth = self.width - 4
    term.write(string.rep(" ", inputWidth))
    term.setCursorPos(3, centerY + 1)
    term.write(self.connectionName .. "_")

    -- Confirm button
    term.setCursorPos(2, centerY + 3)
    if self.connectionName ~= "" then
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(" CONFIRM ")
    self.confirmButton = {y = centerY + 3, x1 = 2, x2 = 12}

    term.setCursorPos(14, centerY + 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.write("or press ENTER")
end

function NetPage:drawEnterCodeMode()
    local centerY = math.floor(self.height / 2)
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" CANCEL ")
    self.cancelButton = {y = y, x1 = 2, x2 = 10}

    term.setCursorPos(2, centerY - 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== ENTER PAIRING CODE ==")

    term.setCursorPos(2, centerY - 1)
    term.setTextColor(colors.lightGray)
    term.write("Paste or type the pairing code:")

    term.setCursorPos(2, centerY + 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    local inputWidth = self.width - 4
    term.write(string.rep(" ", inputWidth))
    term.setCursorPos(3, centerY + 1)
    term.write(self.enteredCode .. "_")

    -- Error message
    if self.errorMessage then
        term.setCursorPos(2, centerY + 2)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.red)
        term.write("ERROR: " .. self.errorMessage)
    end

    -- Confirm button
    local btnY = centerY + 4
    term.setCursorPos(2, btnY)
    if self.enteredCode ~= "" then
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.lightGray)
    end
    term.write(" CONNECT ")
    self.confirmButton = {y = btnY, x1 = 2, x2 = 12}

    term.setCursorPos(14, btnY)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    term.write("or press ENTER")
end

function NetPage:drawAwaitingMode()
    local centerY = math.floor(self.height / 2)
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" CANCEL ")
    self.cancelButton = {y = y, x1 = 2, x2 = 10}

    term.setCursorPos(2, centerY - 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lime)
    term.write("== CONNECTING ==")

    -- Animated loading
    local dots = string.rep(".", ((os.epoch("utc") / 500) % 4) + 1)
    term.setCursorPos(2, centerY)
    term.setTextColor(colors.cyan)
    term.write("Waiting for response" .. dots .. string.rep(" ", 4 - #dots))

    term.setCursorPos(2, centerY + 2)
    term.setTextColor(colors.lightGray)
    term.write("This may take a few seconds...")
end

function NetPage:drawVerifyPinMode()
    local centerY = math.floor(self.height / 2)
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" CANCEL ")
    self.cancelButton = {y = y, x1 = 2, x2 = 10}

    term.setCursorPos(2, centerY - 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lime)
    term.write("== PAIRING PIN RECEIVED ==")

    term.setCursorPos(2, centerY - 2)
    term.setTextColor(colors.white)
    term.write("Tell the other computer this PIN:")

    -- Draw PIN box
    term.setCursorPos(2, centerY)
    term.setBackgroundColor(colors.orange)
    term.setTextColor(colors.white)
    local pinBox = "  PIN: " .. self.pairingPin .. "  "
    local pinX = math.floor((self.width - #pinBox) / 2)
    term.setCursorPos(pinX, centerY)
    term.write(pinBox)

    term.setCursorPos(2, centerY + 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("Waiting for them to accept...")

    -- Animated dots
    local dots = string.rep(".", ((os.epoch("utc") / 500) % 4) + 1)
    term.write(dots .. string.rep(" ", 4 - #dots))
end

function NetPage:drawRequestsMode()
    local y = 3

    -- Top buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" <- BACK ")
    self.cancelButton = {y = y, x1 = 2, x2 = 11}

    term.setCursorPos(14, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== PAIRING REQUESTS ==")

    y = y + 2

    self.requestButtons = {}

    if #self.pendingRequests == 0 then
        term.setCursorPos(2, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("No pending requests")

        term.setCursorPos(2, y + 2)
        term.setTextColor(colors.lightGray)
        term.write("When someone enters your pairing code,")
        term.setCursorPos(2, y + 3)
        term.write("their request will appear here.")
    else
        for i, request in ipairs(self.pendingRequests) do
            term.setCursorPos(2, y)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)

            local line = string.format(" #%-3d  %-15s  PIN: %s ",
                request.id,
                request.name:sub(1, 15),
                request.pin
            )
            term.write(line)

            term.setBackgroundColor(colors.lime)
            term.setTextColor(colors.black)
            term.write(" ACCEPT ")

            local acceptBtnEnd = #line + 9
            table.insert(self.requestButtons, {
                y = y,
                x1 = #line + 2,
                x2 = acceptBtnEnd,
                request = request
            })

            y = y + 1
            term.setBackgroundColor(colors.black)

            if y >= self.height - 2 then break end
        end
    end
end

function NetPage:drawSelectTypeMode()
    local y = 3

    -- Back button
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" <- BACK ")
    self.cancelButton = {y = y, x1 = 2, x2 = 11}

    y = y + 2

    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== SELECT CONNECTION TYPE ==")
    y = y + 2

    self.typeButtons = {}

    if self.context.services.connectionTypes then
        local types = self.context.services.connectionTypes:getConnectionTypes()

        for i, connType in ipairs(types) do
            term.setCursorPos(2, y)
            term.setBackgroundColor(connType.color or colors.gray)
            term.setTextColor(colors.white)

            local line = string.format(" [%s] %s ", connType.icon or "?", connType.name)
            term.write(line)

            table.insert(self.typeButtons, {
                y = y,
                x1 = 2,
                x2 = 2 + #line - 1,
                type = connType
            })

            term.setBackgroundColor(colors.black)
            term.setCursorPos(2 + #line + 2, y)
            term.setTextColor(colors.lightGray)
            term.write(connType.description or "")

            y = y + 1

            if y >= self.height - 2 then break end
        end
    end
end

function NetPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.setCursorPos(2, self.height)

    if self.mode == "list" then
        term.write("Click buttons to manage connections | Check REQUESTS for incoming pairs")
    elseif self.mode == "generate" then
        term.write("Share the code with the other computer | Check REQUESTS for responses")
    elseif self.mode == "enter_name" then
        term.write("Type a name and click CONFIRM or press ENTER")
    elseif self.mode == "enter_code" then
        term.write("Type the pairing code and click CONNECT or press ENTER")
    elseif self.mode == "awaiting" then
        term.write("Waiting for the other computer to respond...")
    elseif self.mode == "verify_pin" then
        term.write("Tell the other computer the PIN shown above")
    elseif self.mode == "requests" then
        term.write("Click ACCEPT to pair with a computer")
    elseif self.mode == "details" then
        term.write("Connection metrics | Pings every 5 seconds")
    elseif self.mode == "select_type" then
        term.write("Click a connection type to assign it to this connection")
    end
end

function NetPage:handleInput(event, param1, param2, param3)
    if event == "term_resize" then
        self.width, self.height = term.getSize()

        -- Rebuild UI components with new dimensions
        self.root:setSize(self.width, self.height)
        self.header:setSize(self.width, 1)
        self.content:setSize(self.width, self.height - 2)
        self.footer:setPosition(1, self.height)
        self.footer:setSize(self.width, 1)

        self:render()
        return

    elseif event == "key" then
        local key = param1

        if key == keys.escape then
            if self.mode == "list" then
                if self.context.router then
                    self.context.router:navigate("console")
                end
            else
                self.mode = "list"
                self.connectionName = ""
                self.enteredCode = ""
                if self.codeTimer then
                    os.cancelTimer(self.codeTimer)
                    self.codeTimer = nil
                end
                self:render()
            end

        elseif self.mode == "list" then
            -- No keyboard shortcuts - use buttons only

        elseif self.mode == "enter_name" then
            if key == keys.enter and self.connectionName ~= "" then
                if self.enteredCode == "" then
                    -- Adding connection - go to generate
                    self.mode = "generate"
                    self.currentCode = self:generateCode()

                    -- Start timer for regeneration
                    self.codeTimer = os.startTimer(1)
                    self:render()
                else
                    -- Entering code - go to enter_code
                    self.mode = "enter_code"
                    self:render()
                end
            elseif key == keys.backspace then
                self.connectionName = self.connectionName:sub(1, -2)
                self:render()
            end

        elseif self.mode == "enter_code" then
            if key == keys.enter and self.enteredCode ~= "" then
                self:attemptConnect()
            elseif key == keys.backspace then
                self.enteredCode = self.enteredCode:sub(1, -2)
                self:clearError()
                self:render()
            end

        elseif self.mode == "generate" then
            -- No keyboard shortcuts - use buttons only

        elseif self.mode == "requests" then
            -- Handled by mouse only
        end

    elseif event == "char" then
        if self.mode == "enter_name" then
            self.connectionName = self.connectionName .. param1
            self:render()
        elseif self.mode == "enter_code" then
            self.enteredCode = (self.enteredCode .. param1):upper()
            self:clearError()
            self:render()
        end

    elseif event == "mouse_click" then
        self:handleClick(param2, param3)

    elseif event == "timer" then
        if param1 == self.codeTimer then
            if self.mode == "generate" then
                -- Check if code expired
                if self.currentCode and os.epoch("utc") >= self.currentCode.expiresAt then
                    -- Generate new code
                    self.currentCode = self:generateCode()
                end

                -- Restart timer
                self.codeTimer = os.startTimer(1)
                self:render()
            end
        elseif param1 == self.errorTimer then
            -- Clear error message
            self.errorMessage = nil
            self.errorTimer = nil
            self:render()
        end
    end

    -- Check for incoming pairing ack
    if self.mode == "awaiting" then
        -- Listener will handle setting pairingPin
        if self.pairingPin then
            self.mode = "verify_pin"
            self:render()
        end
    end
end

function NetPage:handleClick(x, y)
    -- Check navigation button clicks
    if self.navButtons then
        if self.navButtons.console and y == self.navButtons.console.y and
           x >= self.navButtons.console.x1 and x <= self.navButtons.console.x2 then
            if self.context.router then
                self.context.router:navigate("console")
            end
            return
        elseif self.navButtons.net and y == self.navButtons.net.y and
           x >= self.navButtons.net.x1 and x <= self.navButtons.net.x2 then
            -- Already on net page, do nothing
            return
        elseif self.navButtons.stats and y == self.navButtons.stats.y and
               x >= self.navButtons.stats.x1 and x <= self.navButtons.stats.x2 then
            if self.context.router then
                self.context.router:navigate("stats")
            end
            return
        elseif self.navButtons.tests and y == self.navButtons.tests.y and
               x >= self.navButtons.tests.x1 and x <= self.navButtons.tests.x2 then
            if self.context.router then
                self.context.router:navigate("tests")
            end
            return
        elseif self.navButtons.settings and y == self.navButtons.settings.y and
               x >= self.navButtons.settings.x1 and x <= self.navButtons.settings.x2 then
            if self.context.router then
                self.context.router:navigate("settings")
            end
            return
        end
    end

    -- Back button in header (legacy - remove if not needed)
    if self.backLink and y == self.backLink.y and x >= self.backLink.x1 and x <= self.backLink.x2 then
        if self.context.router then
            self.context.router:navigate("console")
        end
        return
    end

    -- Cancel/Back buttons (used in most modes)
    if self.cancelButton and self.cancelButton.y == y and x >= self.cancelButton.x1 and x <= self.cancelButton.x2 then
        if self.mode == "list" then
            if self.context.router then
                self.context.router:navigate("console")
            end
        else
            -- Cancel current action and go back to list
            self.mode = "list"
            self.connectionName = ""
            self.enteredCode = ""
            self.pairingPin = nil
            if self.codeTimer then
                os.cancelTimer(self.codeTimer)
                self.codeTimer = nil
            end
            self:render()
        end
        return
    end

    if self.mode == "list" then
        if self.addButton.y == y and x >= self.addButton.x1 and x <= self.addButton.x2 then
            self.mode = "enter_name"
            self.connectionName = ""
            self.enteredCode = ""
            self:render()
            return
        end

        if self.enterButton.y == y and x >= self.enterButton.x1 and x <= self.enterButton.x2 then
            self.mode = "enter_name"
            self.connectionName = ""
            self.enteredCode = " "  -- Mark as entering code
            self:render()
            return
        end

        if self.requestsButton and self.requestsButton.y == y and x >= self.requestsButton.x1 and x <= self.requestsButton.x2 then
            self.mode = "requests"
            self:render()
            return
        end

        -- Check connection clicks
        if self.connectionRegions then
            for _, region in ipairs(self.connectionRegions) do
                if y == region.y and x >= region.x1 and x <= region.x2 then
                    -- Check if click is on delete button (last 3 chars)
                    if x >= region.x2 + 1 and x <= region.x2 + 3 then
                        -- Delete button clicked - handled by existing code below
                    else
                        -- Connection row clicked - show details
                        self.selectedConnection = region.connection
                        self.mode = "details"
                        self:render()
                        return
                    end
                end
            end
        end

    elseif self.mode == "generate" then
        if self.requestsButton and self.requestsButton.y == y and x >= self.requestsButton.x1 and x <= self.requestsButton.x2 then
            self.mode = "requests"
            self:render()
        end

    elseif self.mode == "requests" then
        for _, btn in ipairs(self.requestButtons) do
            if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                self:acceptPairing(btn.request)
                self.mode = "list"
                self:render()
                return
            end
        end

    elseif self.mode == "enter_name" then
        -- Confirm button
        if self.confirmButton and self.confirmButton.y == y and x >= self.confirmButton.x1 and x <= self.confirmButton.x2 then
            if self.connectionName ~= "" then
                if self.enteredCode == "" then
                    -- Adding connection - go to generate
                    self.mode = "generate"
                    self.currentCode = self:generateCode()

                    -- Start timer for regeneration
                    self.codeTimer = os.startTimer(1)
                    self:render()
                else
                    -- Entering code - go to enter_code
                    self.mode = "enter_code"
                    self:render()
                end
            end
        end

    elseif self.mode == "enter_code" then
        -- Connect button
        if self.confirmButton and self.confirmButton.y == y and x >= self.confirmButton.x1 and x <= self.confirmButton.x2 then
            if self.enteredCode ~= "" then
                self:attemptConnect()
            end
        end

    elseif self.mode == "details" then
        -- Type change button
        if self.typeChangeButton and self.typeChangeButton.y == y and x >= self.typeChangeButton.x1 and x <= self.typeChangeButton.x2 then
            self.mode = "select_type"
            self:render()
            return
        end

    elseif self.mode == "select_type" then
        -- Type selection buttons
        if self.typeButtons then
            for _, btn in ipairs(self.typeButtons) do
                if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                    -- Update connection type
                    if self.selectedConnection then
                        self.selectedConnection.connectionTypeId = btn.type.id
                        self:saveConnections()

                        -- Call new connection type onConnect
                        if self.context.services.connectionTypes then
                            self.context.services.connectionTypes:onConnect(self.selectedConnection)
                        end
                    end

                    self.mode = "details"
                    self:render()
                    return
                end
            end
        end
    end
end

-- Show error message with auto-clear
function NetPage:showError(message)
    self.errorMessage = message
    if self.errorTimer then
        os.cancelTimer(self.errorTimer)
    end
    self.errorTimer = os.startTimer(5) -- Clear after 5 seconds
    self:render()
end

function NetPage:clearError()
    self.errorMessage = nil
    if self.errorTimer then
        os.cancelTimer(self.errorTimer)
        self.errorTimer = nil
    end
end

function NetPage:attemptConnect()
    -- Trim whitespace and convert to uppercase
    self.enteredCode = self.enteredCode:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", ""):upper()

    if self.enteredCode == "" then
        self:showError("Please enter a pairing code")
        return
    end

    -- Clear any previous error
    self:clearError()

    self.logger:info("NetPage", "Attempting to connect with code: " .. self.enteredCode)

    -- Parse code: COMPUTERID_PIN
    local parts = {}
    for part in self.enteredCode:gmatch("[^_]+") do
        table.insert(parts, part)
    end

    if #parts ~= 2 then
        self:showError("Invalid code format (expected: COMPUTERID_PIN)")
        self.logger:info("NetPage", "Parse failed, got " .. #parts .. " parts instead of 2")
        return
    end

    local targetId = tonumber(parts[1])
    local pin = parts[2]

    if not targetId then
        self:showError("Invalid computer ID in code")
        self.logger:info("NetPage", "Failed to parse ID from: " .. parts[1])
        return
    end

    -- Validate PIN is 4 digits
    if #pin ~= 4 or not pin:match("^%d+$") then
        self:showError("Invalid PIN (must be 4 digits)")
        self.logger:info("NetPage", "Invalid PIN: " .. pin)
        return
    end

    self.logger:info("NetPage", "Sending pair request to #" .. targetId .. " with PIN: " .. pin)

    -- Success - send pairing request
    self:sendPairRequest(targetId, pin, self.connectionName)
    self.mode = "awaiting"
    self:render()
end

function NetPage:drawConnectionDetails()
    if not self.selectedConnection then
        self.mode = "list"
        self:render()
        return
    end

    local conn = self.selectedConnection
    local y = 3

    -- Back button
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.write(" <- BACK ")
    self.cancelButton = {y = y, x1 = 2, x2 = 11}

    y = y + 2

    -- Connection name header
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("== CONNECTION DETAILS ==")
    y = y + 2

    -- Connection info
    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Name:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.white)
    term.write(conn.name)
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Computer ID:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.yellow)
    term.write("#" .. conn.id)
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Status:")
    term.setCursorPos(20, y)
    local isOnline = conn.presence and conn.presence.online
    if isOnline then
        term.setTextColor(colors.lime)
        term.write("ONLINE")
    else
        term.setTextColor(colors.red)
        term.write("OFFLINE")
    end
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Connected:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.lime)
    local connTime = (os.epoch("utc") - conn.metrics.connectedAt) / 1000
    term.write(self:formatDuration(connTime))
    y = y + 1

    -- Connection Type Dropdown
    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Type:")
    term.setCursorPos(20, y)

    local connectionType = nil
    if self.context.services.connectionTypes then
        connectionType = self.context.services.connectionTypes:getConnectionType(conn.connectionTypeId or "storage")
    end

    local typeName = connectionType and connectionType.name or "Unknown"
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" " .. typeName .. " ")
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write(" [CHANGE] ")

    -- Store dropdown button region
    self.typeChangeButton = {y = y, x1 = 20 + #typeName + 3, x2 = 20 + #typeName + 12}

    y = y + 2

    -- Network metrics
    term.setCursorPos(2, y)
    term.setTextColor(colors.cyan)
    term.write("== NETWORK METRICS ==")
    y = y + 2

    local metrics = conn.metrics or {}

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Packets Sent:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.orange)
    term.write(tostring(metrics.packetsSent or 0))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Packets Received:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.lime)
    term.write(tostring(metrics.packetsReceived or 0))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Data Sent:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.orange)
    term.write(self:formatBytes(metrics.bytesSent or 0))
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Data Received:")
    term.setCursorPos(20, y)
    term.setTextColor(colors.lime)
    term.write(self:formatBytes(metrics.bytesReceived or 0))
    y = y + 2

    -- Ping stats
    term.setCursorPos(2, y)
    term.setTextColor(colors.cyan)
    term.write("== LATENCY ==")
    y = y + 2

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Last Ping:")
    term.setCursorPos(20, y)
    if metrics.lastPing then
        term.setTextColor(colors.yellow)
        term.write(string.format("%dms", metrics.lastPing))
    else
        term.setTextColor(colors.gray)
        term.write("N/A")
    end
    y = y + 1

    term.setCursorPos(2, y)
    term.setTextColor(colors.lightGray)
    term.write("Avg Ping:")
    term.setCursorPos(20, y)
    if metrics.avgPing and metrics.avgPing > 0 then
        term.setTextColor(colors.cyan)
        term.write(string.format("%dms", math.floor(metrics.avgPing)))
    else
        term.setTextColor(colors.gray)
        term.write("N/A")
    end
    y = y + 2

    -- Connection type-specific details
    local connectionType = nil
    if self.context.services.connectionTypes then
        connectionType = self.context.services.connectionTypes:getConnectionType(conn.connectionTypeId or "storage")
    end

    if connectionType and connectionType.drawDetails then
        y = connectionType:drawDetails(conn, 2, y, self.width - 4, self.height - y - 2)
    end
end

function NetPage:startPingService()
    self.context.scheduler:submit("net", function()
        while self.listenerRunning do
            for _, conn in ipairs(self.connections) do
                -- Send ping
                rednet.send(conn.id, {
                    type = "ping",
                    timestamp = os.epoch("utc")
                }, "storage_pair")

                self:trackPacket(conn.id, "sent", 50)

                -- Call connection type onUpdate
                if self.context.services.connectionTypes then
                    self.context.services.connectionTypes:onUpdate(conn)
                end
            end

            -- Check connection health (mark offline if no response)
            self:checkConnectionHealth()

            os.sleep(5) -- Ping every 5 seconds
        end
    end)
end

function NetPage:trackPacket(computerId, direction, bytes)
    for _, conn in ipairs(self.connections) do
        if conn.id == computerId then
            if not conn.metrics then
                conn.metrics = {
                    packetsSent = 0,
                    packetsReceived = 0,
                    bytesSent = 0,
                    bytesReceived = 0,
                    lastPing = nil,
                    avgPing = 0,
                    pingCount = 0,
                    totalPing = 0,
                    connectedAt = conn.addedAt or os.epoch("utc"),
                    lastActive = os.epoch("utc")
                }
            end

            conn.metrics.lastActive = os.epoch("utc")

            if direction == "sent" then
                conn.metrics.packetsSent = conn.metrics.packetsSent + 1
                conn.metrics.bytesSent = conn.metrics.bytesSent + bytes
            else
                conn.metrics.packetsReceived = conn.metrics.packetsReceived + 1
                conn.metrics.bytesReceived = conn.metrics.bytesReceived + bytes
            end

            self:saveConnections()
            break
        end
    end
end

function NetPage:updatePing(computerId, pingTime)
    for _, conn in ipairs(self.connections) do
        if conn.id == computerId then
            if not conn.metrics then
                conn.metrics = {}
            end

            conn.metrics.lastPing = pingTime
            conn.metrics.pingCount = (conn.metrics.pingCount or 0) + 1
            conn.metrics.totalPing = (conn.metrics.totalPing or 0) + pingTime
            conn.metrics.avgPing = conn.metrics.totalPing / conn.metrics.pingCount

            -- Mark as online when receiving pong
            if not conn.presence then
                conn.presence = {}
            end
            conn.presence.online = true
            conn.presence.lastSeen = os.epoch("utc")

            self:saveConnections()
            break
        end
    end
end

function NetPage:formatBytes(bytes)
    if bytes < 1024 then
        return string.format("%dB", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1fKB", bytes / 1024)
    else
        return string.format("%.2fMB", bytes / (1024 * 1024))
    end
end

function NetPage:formatDuration(seconds)
    if seconds < 60 then
        return string.format("%ds", math.floor(seconds))
    elseif seconds < 3600 then
        return string.format("%dm", math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format("%.1fh", seconds / 3600)
    else
        return string.format("%.1fd", seconds / 86400)
    end
end

function NetPage:getNetworkStats()
    local stats = {
        totalConnections = #self.connections,
        totalPacketsSent = 0,
        totalPacketsReceived = 0,
        totalBytesSent = 0,
        totalBytesReceived = 0,
        avgPing = 0,
        connections = {}
    }

    local pingSum = 0
    local pingCount = 0

    for _, conn in ipairs(self.connections) do
        if conn.metrics then
            stats.totalPacketsSent = stats.totalPacketsSent + (conn.metrics.packetsSent or 0)
            stats.totalPacketsReceived = stats.totalPacketsReceived + (conn.metrics.packetsReceived or 0)
            stats.totalBytesSent = stats.totalBytesSent + (conn.metrics.bytesSent or 0)
            stats.totalBytesReceived = stats.totalBytesReceived + (conn.metrics.bytesReceived or 0)

            if conn.metrics.lastPing then
                pingSum = pingSum + conn.metrics.lastPing
                pingCount = pingCount + 1
            end

            table.insert(stats.connections, {
                id = conn.id,
                name = conn.name,
                ping = conn.metrics.lastPing,
                packetsSent = conn.metrics.packetsSent,
                packetsReceived = conn.metrics.packetsReceived,
                online = conn.presence and conn.presence.online or false,
                dataFormatted = self:formatBytes((conn.metrics.bytesSent or 0) + (conn.metrics.bytesReceived or 0))
            })
        end
    end

    if pingCount > 0 then
        stats.avgPing = math.floor(pingSum / pingCount)
    end

    return stats
end

-- Listener sets this when pair_ack received
function NetPage:setPairingPin(pin)
    self.pairingPin = pin
end

function NetPage:broadcastAlive()
    if not self.modem then return end

    -- Send alive message to all connections
    for _, conn in ipairs(self.connections) do
        rednet.send(conn.id, {
            type = "alive",
            name = "Computer " .. self.computerId
        }, "storage_pair")

        self.logger:info("NetPage", "Sent alive broadcast to #" .. conn.id)
    end
end

function NetPage:markConnectionOnline(computerId)
    for _, conn in ipairs(self.connections) do
        if conn.id == computerId then
            if not conn.presence then
                conn.presence = {}
            end

            conn.presence.online = true
            conn.presence.lastSeen = os.epoch("utc")

            self.logger:info("NetPage", "Marked connection #" .. computerId .. " as online")
            self:saveConnections()

            -- Refresh UI if in list mode or details mode
            if self.mode == "list" or self.mode == "details" then
                self:render()
            end
            break
        end
    end
end

function NetPage:checkConnectionHealth()
    local now = os.epoch("utc")
    local timeout = 15000 -- 15 seconds (3x ping interval)

    for _, conn in ipairs(self.connections) do
        if conn.presence then
            local timeSinceLastSeen = now - (conn.presence.lastSeen or 0)

            if timeSinceLastSeen > timeout and conn.presence.online then
                conn.presence.online = false
                self.logger:info("NetPage", "Marked connection #" .. conn.id .. " as offline (timeout)")
                self:saveConnections()

                -- Refresh UI if in list mode or details mode
                if self.mode == "list" or self.mode == "details" then
                    self:render()
                end
            end
        end
    end
end

return NetPage
