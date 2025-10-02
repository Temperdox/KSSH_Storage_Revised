local NetPage = {}
NetPage.__index = NetPage

-- XOR encryption with salt
local function encryptCode(plaintext, salt)
    local key = "KSSH_SECURE_2025"
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    local saltValue = 0
    for i = 1, #salt do
        saltValue = saltValue + salt:byte(i)
    end

    local encrypted = ""
    for i = 1, #plaintext do
        local plainChar = plaintext:sub(i, i)
        local keyChar = key:sub((i - 1) % #key + 1, (i - 1) % #key + 1)
        local plainByte = plainChar:byte()
        local keyByte = keyChar:byte()
        local xorResult = bit32.bxor(plainByte, bit32.bxor(keyByte, saltValue + i))
        encrypted = encrypted .. chars:sub((xorResult % 36) + 1, (xorResult % 36) + 1)
    end

    return encrypted .. salt
end

local function decryptCode(encrypted)
    local key = "KSSH_SECURE_2025"
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    if #encrypted < 5 then return nil end
    local salt = encrypted:sub(-4)
    local encryptedData = encrypted:sub(1, -5)

    local saltValue = 0
    for i = 1, #salt do
        saltValue = saltValue + salt:byte(i)
    end

    local plaintext = ""
    for i = 1, #encryptedData do
        local encChar = encryptedData:sub(i, i)
        local keyChar = key:sub((i - 1) % #key + 1, (i - 1) % #key + 1)
        local pos = chars:find(encChar, 1, true)
        if not pos then return nil end
        local xorResult = pos - 1
        local keyByte = keyChar:byte()
        local plainByte = bit32.bxor(xorResult, bit32.bxor(keyByte, saltValue + i))
        plaintext = plaintext .. string.char(plainByte % 256)
    end

    return plaintext
end

function NetPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
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
    o.mode = "list" -- list, generate, enter_name, enter_code, awaiting, verify_pin, requests
    o.connectionName = ""
    o.enteredCode = ""
    o.currentCode = nil
    o.codeTimer = nil
    o.sessionCodes = {} -- List of generated codes
    o.pendingRequests = {} -- List of incoming pairing requests
    o.pairingPin = nil -- 4-digit verification PIN for computer entering code
    o.selectedIndex = 1

    o.width, o.height = term.getSize()
    o.backLink = {}
    o.addButton = {}
    o.enterButton = {}
    o.requestsButton = {}
    o.requestButtons = {}

    return o
end

function NetPage:onEnter()
    self:loadConnections()
    self:startListener()
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
                    -- Validate plaintext code against session codes
                    local validCode = nil
                    for _, codeEntry in ipairs(self.sessionCodes) do
                        if codeEntry.pin == message.plaintext_code then
                            validCode = codeEntry
                            break
                        end
                    end

                    if validCode then
                        -- Generate 4-digit pairing PIN
                        local pairingPin = string.format("%04d", math.random(1000, 9999))

                        -- Store pending request
                        table.insert(self.pendingRequests, {
                            id = senderId,
                            name = message.name,
                            pin = pairingPin,
                            timestamp = os.epoch("utc")
                        })

                        -- Send pairing PIN back
                        rednet.send(senderId, {
                            type = "pair_ack",
                            pin = pairingPin
                        }, "storage_pair")

                        self.logger:info("NetPage", "Pairing request from #" .. senderId .. ", PIN: " .. pairingPin)
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
                end
            end
        end
    end)
end

function NetPage:generateCode()
    local epoch = os.epoch("utc")
    local pin = string.format("%04d", (epoch % 10000))
    local plaintext = self.computerId .. "_" .. pin

    -- Generate salt
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local salt = ""
    for i = 1, 4 do
        local idx = (epoch + i * 7) % 36 + 1
        salt = salt .. chars:sub(idx, idx)
    end

    local encrypted = encryptCode(plaintext, salt)

    -- Save to session codes
    table.insert(self.sessionCodes, {
        pin = pin,
        plaintext = plaintext,
        encrypted = encrypted,
        generated = epoch
    })

    self.logger:info("NetPage", "Generated code, PIN: " .. pin)

    return {
        encrypted = encrypted,
        pin = pin,
        generated = epoch,
        expiresAt = epoch + 60000
    }
end

function NetPage:sendPairRequest(targetId, plaintextCode, myName)
    rednet.send(targetId, {
        type = "pair_request",
        plaintext_code = plaintextCode,
        name = myName
    }, "storage_pair")

    self.logger:info("NetPage", "Sent pair request to #" .. targetId)
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

    table.insert(self.connections, {
        id = id,
        name = name,
        addedAt = os.epoch("utc"),
        systemType = "storage"
    })

    self:saveConnections()
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
    end

    self:drawFooter()
end

function NetPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.setCursorPos(2, 1)
    term.write("NETWORK CONNECTIONS")

    term.setCursorPos(self.width - 10, 1)
    term.setTextColor(colors.yellow)
    term.write("ID: " .. self.computerId)

    term.setCursorPos(self.width - 5, 1)
    term.setTextColor(colors.lightBlue)
    term.write("[ESC]")
    self.backLink = {y = 1, x1 = self.width - 5, x2 = self.width}
end

function NetPage:drawConnectionsList()
    local y = 3

    -- Buttons
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.green)
    term.setTextColor(colors.white)
    term.write(" [A] Add Connection ")
    self.addButton = {y = y, x1 = 2, x2 = 22}

    term.setCursorPos(25, y)
    term.setBackgroundColor(colors.blue)
    term.write(" [E] Enter Code ")
    self.enterButton = {y = y, x1 = 25, x2 = 41}

    y = y + 2

    -- Connections
    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("PAIRED COMPUTERS:")
    y = y + 1

    if #self.connections == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("No connections")
    else
        for i, conn in ipairs(self.connections) do
            term.setCursorPos(2, y)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
            local line = string.format(" #%-3d  %-20s ", conn.id, conn.name:sub(1, 20))
            term.write(line)

            term.setBackgroundColor(colors.red)
            term.write(" X ")

            y = y + 1
            term.setBackgroundColor(colors.black)
            if y >= self.height - 2 then break end
        end
    end

    -- Requests button
    if #self.pendingRequests > 0 then
        term.setCursorPos(2, self.height - 2)
        term.setBackgroundColor(colors.yellow)
        term.setTextColor(colors.black)
        term.write(string.format(" Requests [%d] ", #self.pendingRequests))
        self.requestsButton = {y = self.height - 2, x1 = 2, x2 = 20}
    end
end

function NetPage:drawGenerateMode()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 5)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("PAIRING CODE FOR: " .. self.connectionName)

    if self.currentCode then
        -- Show encrypted code
        term.setCursorPos(2, centerY - 3)
        term.setTextColor(colors.lightGray)
        term.write("Share this code:")

        term.setCursorPos(2, centerY - 2)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.yellow)
        term.write(" " .. self.currentCode.encrypted .. " ")

        -- Countdown bar
        local timeLeft = math.max(0, (self.currentCode.expiresAt - os.epoch("utc")) / 1000)
        local barWidth = self.width - 4
        local fillWidth = math.floor((timeLeft / 60) * barWidth)

        term.setCursorPos(2, centerY)
        term.setBackgroundColor(colors.black)

        -- Draw bar
        for x = 0, barWidth - 1 do
            if x < fillWidth then
                if fillWidth > barWidth * 0.5 then
                    term.setBackgroundColor(colors.lime)
                elseif fillWidth > barWidth * 0.25 then
                    term.setBackgroundColor(colors.yellow)
                else
                    term.setBackgroundColor(colors.red)
                end
            else
                term.setBackgroundColor(colors.gray)
            end
            term.write(" ")
        end

        -- Time text in center of bar
        local timeText = string.format("%ds", math.floor(timeLeft))
        local textX = math.floor((self.width - #timeText) / 2)
        term.setCursorPos(textX, centerY)

        if fillWidth > barWidth * 0.5 then
            term.setTextColor(colors.black)
        else
            term.setTextColor(colors.white)
        end
        term.write(timeText)

        -- Info
        term.setCursorPos(2, centerY + 2)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write("Code regenerates every 60 seconds")
    end

    -- Requests button
    if #self.pendingRequests > 0 then
        term.setCursorPos(2, self.height - 2)
        term.setBackgroundColor(colors.yellow)
        term.setTextColor(colors.black)
        term.write(string.format(" [R] Requests [%d] ", #self.pendingRequests))
        self.requestsButton = {y = self.height - 2, x1 = 2, x2 = 25}
    end
end

function NetPage:drawEnterNameMode()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("ADD CONNECTION")

    term.setCursorPos(2, centerY)
    term.setTextColor(colors.lightGray)
    term.write("Connection name:")

    term.setCursorPos(2, centerY + 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.write(" " .. self.connectionName .. "_")

    term.setCursorPos(2, centerY + 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("Press ENTER to generate code")
end

function NetPage:drawEnterCodeMode()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("ENTER PAIRING CODE")

    term.setCursorPos(2, centerY)
    term.setTextColor(colors.lightGray)
    term.write("Pairing code:")

    term.setCursorPos(2, centerY + 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.write(" " .. self.enteredCode .. "_")

    term.setCursorPos(2, centerY + 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.write("Press ENTER to connect")
end

function NetPage:drawAwaitingMode()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 1)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("AWAITING CONNECTION...")

    -- Animated loading
    local dots = string.rep(".", (os.epoch("utc") / 500) % 4)
    term.setCursorPos(2, centerY + 1)
    term.setTextColor(colors.lightGray)
    term.write("Waiting for pairing response" .. dots)
end

function NetPage:drawVerifyPinMode()
    local centerY = math.floor(self.height / 2)

    term.setCursorPos(2, centerY - 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lime)
    term.write("PAIRING PIN RECEIVED")

    term.setCursorPos(2, centerY - 1)
    term.setTextColor(colors.white)
    term.write("Tell the other person this PIN:")

    term.setCursorPos(2, centerY + 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.yellow)
    term.write(string.rep(" ", 20))
    term.setCursorPos(math.floor((self.width - 4) / 2), centerY + 1)
    term.write(" " .. self.pairingPin .. " ")

    term.setCursorPos(2, centerY + 3)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("Waiting for them to accept...")
end

function NetPage:drawRequestsMode()
    local y = 3

    term.setCursorPos(2, y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write("PAIRING REQUESTS")

    y = y + 2

    self.requestButtons = {}

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

        term.setBackgroundColor(colors.green)
        term.write(" PAIR ")

        table.insert(self.requestButtons, {
            y = y,
            x1 = self.width - 8,
            x2 = self.width - 2,
            request = request
        })

        y = y + 1
        term.setBackgroundColor(colors.black)

        if y >= self.height - 2 then break end
    end

    if #self.pendingRequests == 0 then
        term.setCursorPos(2, y)
        term.setTextColor(colors.gray)
        term.write("No pending requests")
    end
end

function NetPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)
    term.setCursorPos(2, self.height)

    if self.mode == "list" then
        term.write("A=Add | E=Enter Code | ESC=Back")
    elseif self.mode == "generate" then
        term.write("R=Requests | ESC=Cancel")
    elseif self.mode == "enter_name" then
        term.write("Type name, ENTER to continue | ESC=Cancel")
    elseif self.mode == "enter_code" then
        term.write("Type code, ENTER to connect | ESC=Cancel")
    elseif self.mode == "requests" then
        term.write("Click PAIR to accept | ESC=Back")
    else
        term.write("ESC=Cancel")
    end
end

function NetPage:handleInput(event, param1, param2, param3)
    if event == "key" then
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
            if key == keys.a then
                self.mode = "enter_name"
                self.connectionName = ""
                self:render()
            elseif key == keys.e then
                self.mode = "enter_name"
                self.connectionName = ""
                self.enteredCode = ""
                self:render()
            end

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
                -- Decrypt and send request
                local decrypted = decryptCode(self.enteredCode)
                if decrypted then
                    local parts = {}
                    for part in decrypted:gmatch("[^_]+") do
                        table.insert(parts, part)
                    end

                    if #parts == 2 then
                        local targetId = tonumber(parts[1])
                        local plaintextCode = parts[2]

                        if targetId then
                            self:sendPairRequest(targetId, plaintextCode, self.connectionName)
                            self.mode = "awaiting"
                            self:render()
                        end
                    end
                end
            elseif key == keys.backspace then
                self.enteredCode = self.enteredCode:sub(1, -2)
                self:render()
            end

        elseif self.mode == "generate" then
            if key == keys.r and #self.pendingRequests > 0 then
                self.mode = "requests"
                self:render()
            end

        elseif self.mode == "requests" then
            -- Handled by mouse
        end

    elseif event == "char" then
        if self.mode == "enter_name" then
            self.connectionName = self.connectionName .. param1
            self:render()
        elseif self.mode == "enter_code" then
            self.enteredCode = (self.enteredCode .. param1):upper()
            self:render()
        end

    elseif event == "mouse_click" then
        self:handleClick(param2, param3)

    elseif event == "timer" and param1 == self.codeTimer then
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
    if y == self.backLink.y and x >= self.backLink.x1 and x <= self.backLink.x2 then
        if self.context.router then
            self.context.router:navigate("console")
        end
        return
    end

    if self.mode == "list" then
        if self.addButton.y == y and x >= self.addButton.x1 and x <= self.addButton.x2 then
            self.mode = "enter_name"
            self.connectionName = ""
            self.enteredCode = ""
            self:render()
        end

        if self.enterButton.y == y and x >= self.enterButton.x1 and x <= self.enterButton.x2 then
            self.mode = "enter_name"
            self.connectionName = ""
            self.enteredCode = " "  -- Mark as entering code
            self:render()
        end

        if self.requestsButton.y == y and x >= self.requestsButton.x1 and x <= self.requestsButton.x2 then
            self.mode = "requests"
            self:render()
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
    end
end

-- Listener sets this when pair_ack received
function NetPage:setPairingPin(pin)
    self.pairingPin = pin
end

return NetPage
