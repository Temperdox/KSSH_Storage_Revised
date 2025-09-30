local TestsPage = {}
TestsPage.__index = TestsPage

function TestsPage:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.logger = context.logger

    -- Test configurations
    o.tests = {
        {
            name = "IO Burst Test",
            id = "io_burst",
            description = "Test high-speed item I/O operations",
            duration = 10
        },
        {
            name = "Index Stress Test",
            id = "index_stress",
            description = "Test index performance with many items",
            duration = 15
        },
        {
            name = "Network Load Test",
            id = "net_load",
            description = "Test Rednet API under load",
            duration = 20
        },
        {
            name = "Event Storm Test",
            id = "event_storm",
            description = "Generate high event throughput",
            duration = 5
        },
        {
            name = "Memory Test",
            id = "memory",
            description = "Check memory usage and leaks",
            duration = 30
        }
    }

    -- Test state
    o.runningTest = nil
    o.testResults = {}
    o.testOutput = {}
    o.maxOutput = 100

    o.width, o.height = term.getSize()

    -- Scroll state
    o.testScrollOffset = 0
    o.maxVisibleTests = 4

    -- Clickable regions
    o.backLink = {}
    o.testRegions = {}

    return o
end

function TestsPage:onEnter()
    -- Subscribe to test events
    self.eventBus:subscribe("tests%..*", function(event, data)
        self:onTestEvent(event, data)
    end)

    self:render()
end

function TestsPage:onTestEvent(event, data)
    -- Handle test events if needed
    -- This method was referenced but not implemented
end

function TestsPage:render()
    term.clear()

    -- Header
    self:drawHeader()

    -- Test list
    self:drawTestList()

    -- Output console
    self:drawOutput()

    -- Footer
    self:drawFooter()
end

function TestsPage:drawHeader()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
    term.setTextColor(colors.white)

    -- Title on the left
    term.setCursorPos(2, 1)
    term.write("SYSTEM TESTS")

    -- Back link on the right
    local x = self.width - 6
    term.setCursorPos(x, 1)
    term.setTextColor(colors.yellow)
    term.write("Back")
    self.backLink = {x1 = x, x2 = x + 3, y = 1}

    term.setBackgroundColor(colors.black)
end

function TestsPage:drawTestList()
    local startY = 4
    local linesPerTest = 3  -- Name line + description line + blank line

    term.setCursorPos(1, 3)
    term.setTextColor(colors.white)
    term.write("AVAILABLE TESTS:")

    -- Calculate visible test range
    local visibleStart = self.testScrollOffset + 1
    local visibleEnd = math.min(visibleStart + self.maxVisibleTests - 1, #self.tests)

    -- Clear test area
    for clearY = startY, startY + (self.maxVisibleTests * linesPerTest) - 1 do
        term.setCursorPos(1, clearY)
        term.clearLine()
    end

    -- Draw visible tests
    self.testRegions = {}
    local y = startY
    for i = visibleStart, visibleEnd do
        local test = self.tests[i]

        term.setCursorPos(2, y)

        -- Test number/key
        term.setTextColor(colors.yellow)
        term.write("[" .. i .. "] ")

        -- Test name
        if self.runningTest == test.id then
            term.setTextColor(colors.lime)
            term.write(test.name .. " [RUNNING]")
        else
            term.setTextColor(colors.white)
            term.write(test.name)
        end

        -- Duration
        term.setCursorPos(35, y)
        term.setTextColor(colors.gray)
        term.write("(" .. test.duration .. "s)")

        -- Result indicator
        if self.testResults[test.id] then
            term.setCursorPos(45, y)
            if self.testResults[test.id].success then
                term.setTextColor(colors.green)
                term.write("[PASS]")
            else
                term.setTextColor(colors.red)
                term.write("[FAIL]")
            end
        end

        -- Store clickable region
        self.testRegions[i] = {x1 = 2, x2 = self.width - 1, y1 = y, y2 = y + 1, testId = test.id, testIndex = i}

        y = y + 1

        -- Description
        term.setCursorPos(6, y)
        term.setTextColor(colors.lightGray)
        term.write(test.description)
        y = y + 2
    end

    -- Draw scroll bar if needed
    if #self.tests > self.maxVisibleTests then
        local scrollBarHeight = self.maxVisibleTests * linesPerTest
        local scrollBarY = startY
        local scrollBarPos = math.floor(self.testScrollOffset / (#self.tests - self.maxVisibleTests) * (scrollBarHeight - 1))

        for i = 0, scrollBarHeight - 1 do
            term.setCursorPos(self.width, scrollBarY + i)
            if i == scrollBarPos then
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
                term.write("\138")  -- Slim scroll indicator
            else
                term.setBackgroundColor(colors.lightGray)
                term.setTextColor(colors.black)
                term.write("\149")  -- Track character
            end
        end
        term.setBackgroundColor(colors.black)
    end
end

function TestsPage:drawOutput()
    local startY = 15
    local endY = self.height - 2

    -- Output header
    term.setCursorPos(1, startY - 1)
    term.setTextColor(colors.gray)
    term.write(string.rep("-", self.width))
    term.setCursorPos(1, startY - 1)
    term.write(" TEST OUTPUT ")

    -- Output lines
    local visibleLines = endY - startY + 1
    local startIdx = math.max(1, #self.testOutput - visibleLines + 1)

    for i = 0, visibleLines - 1 do
        local lineIdx = startIdx + i
        local line = self.testOutput[lineIdx]

        term.setCursorPos(1, startY + i)
        term.clearLine()

        if line then
            -- Parse line type
            if line:find("%[ERROR%]") then
                term.setTextColor(colors.red)
            elseif line:find("%[WARN%]") then
                term.setTextColor(colors.yellow)
            elseif line:find("%[OK%]") or line:find("%[PASS%]") then
                term.setTextColor(colors.green)
            elseif line:find("%[INFO%]") then
                term.setTextColor(colors.white)
            else
                term.setTextColor(colors.lightGray)
            end

            -- Truncate if too long
            if #line > self.width then
                line = line:sub(1, self.width - 3) .. "..."
            end

            term.write(line)
        end
    end
end

function TestsPage:drawFooter()
    term.setCursorPos(1, self.height)
    term.setTextColor(colors.gray)

    if self.runningTest then
        term.write("Test running... Press [S] to stop")
    else
        term.write("Press test number to run, [C] to clear, [B] to go back")
    end
end

function TestsPage:runTest(testId)
    if self.runningTest then
        self:addOutput("[WARN] A test is already running")
        return
    end

    local test = self:getTestById(testId)
    if not test then
        self:addOutput("[ERROR] Unknown test: " .. testId)
        return
    end

    self.runningTest = testId
    self.testOutput = {}

    self:addOutput("[INFO] Starting " .. test.name .. "...")
    self:addOutput("[INFO] Duration: " .. test.duration .. " seconds")

    -- Execute test based on type
    if self.context.scheduler then
        self.context.scheduler:submit("tests", function()
            if testId == "io_burst" then
                self:runIOBurstTest(test)
            elseif testId == "index_stress" then
                self:runIndexStressTest(test)
            elseif testId == "net_load" then
                self:runNetworkLoadTest(test)
            elseif testId == "event_storm" then
                self:runEventStormTest(test)
            elseif testId == "memory" then
                self:runMemoryTest(test)
            end
        end)
    else
        -- Run directly if no scheduler
        if testId == "io_burst" then
            self:runIOBurstTest(test)
        elseif testId == "index_stress" then
            self:runIndexStressTest(test)
        elseif testId == "net_load" then
            self:runNetworkLoadTest(test)
        elseif testId == "event_storm" then
            self:runEventStormTest(test)
        elseif testId == "memory" then
            self:runMemoryTest(test)
        end
    end

    self:render()
end

function TestsPage:runIOBurstTest(test)
    self:addOutput("[TEST] Generating burst I/O operations...")

    local startTime = os.epoch("utc")
    local operations = 0
    local errors = 0

    -- Simulate rapid item movements
    for i = 1, 100 do
        self.eventBus:publish("tests.io.operation", {
            operation = i,
            type = "move"
        })

        -- Simulate item move
        local success = math.random() > 0.05  -- 95% success rate
        if success then
            operations = operations + 1

            if i % 10 == 0 then
                self:addOutput(string.format("[OK] Completed %d operations", i))
            end
        else
            errors = errors + 1
            self:addOutput(string.format("[ERROR] Operation %d failed", i))
        end

        os.sleep(0.1)
    end

    local duration = (os.epoch("utc") - startTime) / 1000
    local opsPerSec = operations / duration

    self:addOutput(string.format("[INFO] Test completed in %.2fs", duration))
    self:addOutput(string.format("[INFO] Operations: %d successful, %d failed", operations, errors))
    self:addOutput(string.format("[INFO] Throughput: %.1f ops/sec", opsPerSec))

    local success = errors < 10
    self:completeTest(test.id, success, {
        operations = operations,
        errors = errors,
        throughput = opsPerSec
    })
end

function TestsPage:runIndexStressTest(test)
    self:addOutput("[TEST] Stressing item index...")

    local startTime = os.epoch("utc")
    local itemsAdded = 0
    local lookups = 0

    -- Add many items to index
    for i = 1, 1000 do
        local itemName = string.format("test:item_%d", i)

        self.eventBus:publish("tests.index.add", {
            item = itemName,
            count = math.random(1, 64)
        })

        itemsAdded = itemsAdded + 1

        if i % 100 == 0 then
            self:addOutput(string.format("[OK] Added %d items to index", i))
        end

        -- Random lookups
        if math.random() > 0.7 then
            local lookupItem = string.format("test:item_%d", math.random(1, i))
            self.eventBus:publish("tests.index.lookup", {
                item = lookupItem
            })
            lookups = lookups + 1
        end
    end

    local duration = (os.epoch("utc") - startTime) / 1000

    self:addOutput(string.format("[INFO] Test completed in %.2fs", duration))
    self:addOutput(string.format("[INFO] Items indexed: %d", itemsAdded))
    self:addOutput(string.format("[INFO] Lookups performed: %d", lookups))
    self:addOutput(string.format("[INFO] Index rate: %.1f items/sec", itemsAdded / duration))

    self:completeTest(test.id, true, {
        itemsAdded = itemsAdded,
        lookups = lookups,
        duration = duration
    })
end

function TestsPage:runNetworkLoadTest(test)
    self:addOutput("[TEST] Testing network capacity...")

    local messages = 0
    local errors = 0
    local startTime = os.epoch("utc")

    for i = 1, 50 do
        -- Simulate RPC call
        self.eventBus:publish("tests.net.request", {
            id = i,
            method = "test",
            params = {data = string.rep("x", 100)}
        })

        messages = messages + 1

        if i % 10 == 0 then
            self:addOutput(string.format("[OK] Sent %d network messages", i))
        end

        os.sleep(0.2)
    end

    local duration = (os.epoch("utc") - startTime) / 1000
    local msgPerSec = messages / duration

    self:addOutput(string.format("[INFO] Test completed in %.2fs", duration))
    self:addOutput(string.format("[INFO] Messages sent: %d", messages))
    self:addOutput(string.format("[INFO] Message rate: %.1f msg/sec", msgPerSec))

    self:completeTest(test.id, true, {
        messages = messages,
        rate = msgPerSec
    })
end

function TestsPage:runEventStormTest(test)
    self:addOutput("[TEST] Generating event storm...")

    local events = 0
    local startTime = os.epoch("utc")

    for i = 1, 1000 do
        local eventType = ({
            "test.storm.alpha",
            "test.storm.beta",
            "test.storm.gamma",
            "test.storm.delta"
        })[math.random(1, 4)]

        self.eventBus:publish(eventType, {
            index = i,
            timestamp = os.epoch("utc"),
            data = math.random()
        })

        events = events + 1

        if i % 250 == 0 then
            self:addOutput(string.format("[OK] Generated %d events", i))
        end
    end

    local duration = (os.epoch("utc") - startTime) / 1000
    local eventsPerSec = events / duration

    self:addOutput(string.format("[INFO] Test completed in %.2fs", duration))
    self:addOutput(string.format("[INFO] Events generated: %d", events))
    self:addOutput(string.format("[INFO] Event rate: %.1f events/sec", eventsPerSec))

    self:completeTest(test.id, true, {
        events = events,
        rate = eventsPerSec
    })
end

function TestsPage:runMemoryTest(test)
    self:addOutput("[TEST] Checking memory usage...")

    -- Collect garbage first
    collectgarbage("collect")
    local initialMem = collectgarbage("count")

    self:addOutput(string.format("[INFO] Initial memory: %.1f KB", initialMem))

    -- Allocate some memory
    local tables = {}
    for i = 1, 100 do
        tables[i] = {}
        for j = 1, 100 do
            tables[i][j] = string.rep("x", 100)
        end

        if i % 25 == 0 then
            local currentMem = collectgarbage("count")
            self:addOutput(string.format("[INFO] Memory after %d allocations: %.1f KB", i, currentMem))
        end
    end

    local peakMem = collectgarbage("count")
    self:addOutput(string.format("[INFO] Peak memory: %.1f KB", peakMem))

    -- Clear and collect
    tables = nil
    collectgarbage("collect")
    local finalMem = collectgarbage("count")

    self:addOutput(string.format("[INFO] Final memory: %.1f KB", finalMem))
    self:addOutput(string.format("[INFO] Memory freed: %.1f KB", peakMem - finalMem))

    local leak = finalMem - initialMem
    local hasLeak = leak > 100  -- More than 100KB difference

    if hasLeak then
        self:addOutput(string.format("[WARN] Possible memory leak: %.1f KB", leak))
    else
        self:addOutput("[OK] No significant memory leak detected")
    end

    self:completeTest(test.id, not hasLeak, {
        initial = initialMem,
        peak = peakMem,
        final = finalMem,
        leak = leak
    })
end

function TestsPage:completeTest(testId, success, results)
    self.testResults[testId] = {
        success = success,
        results = results,
        timestamp = os.epoch("utc")
    }

    self.runningTest = nil

    if success then
        self:addOutput("[PASS] Test completed successfully")
    else
        self:addOutput("[FAIL] Test failed")
    end

    -- Save test results
    self:saveTestResults()

    -- Fire completion event
    self.eventBus:publish("tests.completed", {
        test = testId,
        success = success,
        results = results
    })

    self:render()
end

function TestsPage:addOutput(line)
    table.insert(self.testOutput, os.date("%H:%M:%S ") .. line)

    -- Trim to max size
    while #self.testOutput > self.maxOutput do
        table.remove(self.testOutput, 1)
    end

    -- Re-render if visible (check if getCurrent exists first)
    if self.context.viewFactory and self.context.viewFactory.getCurrent then
        if self.context.viewFactory:getCurrent() == self then
            self:render()
        end
    else
        -- Fallback: just render
        self:render()
    end
end

function TestsPage:getTestById(id)
    for _, test in ipairs(self.tests) do
        if test.id == id then
            return test
        end
    end
    return nil
end

function TestsPage:saveTestResults()
    local resultsFile = "/storage/logs/tests-" .. os.date("%Y%m%d") .. ".log"
    local file = fs.open(resultsFile, "a")

    if file then
        for testId, result in pairs(self.testResults) do
            file.writeLine(textutils.serialiseJSON({
                test = testId,
                success = result.success,
                results = result.results,
                timestamp = result.timestamp
            }))
        end
        file.close()
    end
end

function TestsPage:handleInput(event, param1, param2, param3)
    if event == "key" then
        local key = param1
        -- Removed 'B' key binding to avoid conflicts
        if key == keys.c then
            -- Clear output
            self.testOutput = {}
            self:render()
        elseif key == keys.s and self.runningTest then
            -- Stop test
            self:addOutput("[WARN] Test stopped by user")
            self:completeTest(self.runningTest, false, {stopped = true})
        elseif key == keys.up then
            -- Scroll up
            self.testScrollOffset = math.max(0, self.testScrollOffset - 1)
            self:render()
        elseif key == keys.down then
            -- Scroll down
            local maxScroll = math.max(0, #self.tests - self.maxVisibleTests)
            self.testScrollOffset = math.min(maxScroll, self.testScrollOffset + 1)
            self:render()
        elseif key >= keys.one and key <= keys.five then
            -- Run test by number
            local testIndex = key - keys.one + 1
            if self.tests[testIndex] then
                self:runTest(self.tests[testIndex].id)
            end
        end
    elseif event == "mouse_scroll" then
        -- Handle mouse scroll
        local maxScroll = math.max(0, #self.tests - self.maxVisibleTests)
        self.testScrollOffset = math.max(0, math.min(maxScroll, self.testScrollOffset + param1))
        self:render()
    elseif event == "mouse_click" then
        -- param1 = button, param2 = x, param3 = y
        self:handleClick(param2, param3)
    end
end

function TestsPage:handleClick(x, y)
    -- Check back link
    if y == self.backLink.y and x >= self.backLink.x1 and x <= self.backLink.x2 then
        if self.context.router then
            self.context.router:navigate("console")
        end
        return
    end

    -- Check test regions
    for _, region in pairs(self.testRegions) do
        if y >= region.y1 and y <= region.y2 and x >= region.x1 and x <= region.x2 then
            self:runTest(region.testId)
            return
        end
    end
end

return TestsPage