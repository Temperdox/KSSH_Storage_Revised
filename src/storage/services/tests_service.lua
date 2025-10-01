-- ============================================================================
-- TESTS SERVICE
-- ============================================================================

-- /services/tests_service.lua
-- System testing service with various test suites

local TestsService = {}
TestsService.__index = TestsService

function TestsService:new(context)
    local o = setmetatable({}, self)
    o.context = context
    o.eventBus = context.eventBus
    o.scheduler = context.scheduler
    o.logger = context.logger

    -- Test configurations
    o.tests = {
        io_burst = {
            name = "IO Burst Test",
            description = "Test high-speed item I/O operations",
            duration = 10,
            enabled = true
        },
        index_stress = {
            name = "Index Stress Test",
            description = "Test index performance with many items",
            duration = 15,
            enabled = true
        },
        net_load = {
            name = "Network Load Test",
            description = "Test Rednet API under load",
            duration = 20,
            enabled = true
        },
        event_storm = {
            name = "Event Storm Test",
            description = "Generate high event throughput",
            duration = 5,
            enabled = true
        },
        memory = {
            name = "Memory Test",
            description = "Check memory usage and leaks",
            duration = 30,
            enabled = true
        },
        pool_saturation = {
            name = "Pool Saturation Test",
            description = "Test thread pool under saturation",
            duration = 10,
            enabled = true
        },
        storage_capacity = {
            name = "Storage Capacity Test",
            description = "Test storage at maximum capacity",
            duration = 15,
            enabled = true
        },
        peripheral_reliability = {
            name = "Peripheral Reliability Test",
            description = "Test peripheral connection stability",
            duration = 20,
            enabled = true
        }
    }

    -- Test state
    o.runningTests = {}
    o.testResults = {}
    o.testArtifacts = {}

    -- Test metrics
    o.metrics = {
        totalTests = 0,
        passed = 0,
        failed = 0,
        aborted = 0,
        lastRun = nil
    }

    return o
end

function TestsService:start()
    -- Load previous test results
    self:loadTestResults()

    -- Subscribe to test events
    self.eventBus:subscribe("tests.run", function(event, data)
        self:runTest(data.test, data.params)
    end)

    self.eventBus:subscribe("tests.stop", function(event, data)
        self:stopTest(data.test)
    end)

    self.eventBus:subscribe("tests.stopAll", function()
        self:stopAllTests()
    end)

    -- Subscribe to test page events
    self.eventBus:subscribe("tests.getResults", function(event, data)
        self.eventBus:publish("tests.results", {
            results = self:getTestResults(data.test)
        })
    end)

    self.logger:info("TestsService", "Service started with " .. self:countTests() .. " tests")
end

function TestsService:stop()
    -- Stop all running tests
    self:stopAllTests()

    -- Save test results
    self:saveTestResults()

    self.logger:info("TestsService", "Service stopped")
end

function TestsService:countTests()
    local count = 0
    for _, test in pairs(self.tests) do
        if test.enabled then
            count = count + 1
        end
    end
    return count
end

function TestsService:runTest(testName, params)
    -- Check if test exists
    local testConfig = self.tests[testName]
    if not testConfig then
        self.logger:error("TestsService", "Unknown test: " .. testName)
        self.eventBus:publish("tests.error", {
            test = testName,
            error = "Unknown test"
        })
        return false
    end

    -- Check if test is already running
    if self.runningTests[testName] then
        self.logger:warn("TestsService", "Test already running: " .. testName)
        return false
    end

    -- Initialize test state
    self.runningTests[testName] = {
        startTime = os.epoch("utc"),
        params = params or {},
        status = "running",
        taskId = nil
    }

    self.metrics.totalTests = self.metrics.totalTests + 1
    self.metrics.lastRun = os.epoch("utc")

    -- Publish test start event
    self.eventBus:publish("tests.started", {
        test = testName,
        config = testConfig,
        timestamp = os.epoch("utc")
    })

    self.logger:info("TestsService", "Starting test: " .. testConfig.name)

    -- Run test in scheduler
    local task = self.scheduler:submit("tests", function()
        local success, result = self:executeTest(testName, params)
        self:completeTest(testName, success, result)
    end)

    self.runningTests[testName].taskId = task

    return true
end

function TestsService:executeTest(testName, params)
    local success, result

    if testName == "io_burst" then
        success, result = self:executeIOBurstTest(params)
    elseif testName == "index_stress" then
        success, result = self:executeIndexStressTest(params)
    elseif testName == "net_load" then
        success, result = self:executeNetworkLoadTest(params)
    elseif testName == "event_storm" then
        success, result = self:executeEventStormTest(params)
    elseif testName == "memory" then
        success, result = self:executeMemoryTest(params)
    elseif testName == "pool_saturation" then
        success, result = self:executePoolSaturationTest(params)
    elseif testName == "storage_capacity" then
        success, result = self:executeStorageCapacityTest(params)
    elseif testName == "peripheral_reliability" then
        success, result = self:executePeripheralReliabilityTest(params)
    else
        return false, {error = "Test not implemented"}
    end

    return success, result
end

-- ============================================================================
-- TEST IMPLEMENTATIONS
-- ============================================================================

function TestsService:executeIOBurstTest(params)
    local iterations = params.iterations or 100
    local itemsPerBurst = params.itemsPerBurst or 10

    local results = {
        iterations = iterations,
        itemsPerBurst = itemsPerBurst,
        successful = 0,
        failed = 0,
        operations = {},
        throughput = 0,
        errors = {}
    }

    local startTime = os.epoch("utc")

    for i = 1, iterations do
        -- Check if test should stop
        if not self.runningTests["io_burst"] or
                self.runningTests["io_burst"].status == "stopping" then
            results.aborted = true
            break
        end

        -- Simulate item burst
        local burstStart = os.epoch("utc")
        local burstOps = 0
        local burstErrors = 0

        for j = 1, itemsPerBurst do
            -- Simulate item movement
            self.eventBus:publish("tests.io.operation", {
                iteration = i,
                item = j,
                operation = "move"
            })

            -- Random success/failure
            if math.random() > 0.05 then  -- 95% success rate
                burstOps = burstOps + 1
                results.successful = results.successful + 1
            else
                burstErrors = burstErrors + 1
                results.failed = results.failed + 1
                table.insert(results.errors, {
                    iteration = i,
                    item = j,
                    error = "Simulated failure"
                })
            end

            -- Small delay to simulate real operations
            os.sleep(0.01)
        end

        local burstTime = os.epoch("utc") - burstStart

        table.insert(results.operations, {
            iteration = i,
            operations = burstOps,
            errors = burstErrors,
            time = burstTime
        })

        -- Log progress
        if i % 10 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "io_burst",
                progress = i / iterations,
                message = string.format("Completed %d/%d iterations", i, iterations)
            })
        end
    end

    -- Calculate throughput
    local totalTime = (os.epoch("utc") - startTime) / 1000  -- Convert to seconds
    results.throughput = results.successful / totalTime
    results.totalTime = totalTime

    -- Determine success
    local successRate = results.successful / (results.successful + results.failed)
    local success = successRate >= 0.9 and not results.aborted

    return success, results
end

function TestsService:executeIndexStressTest(params)
    local itemCount = params.itemCount or 1000
    local lookupCount = params.lookupCount or 500

    local results = {
        itemCount = itemCount,
        lookupCount = lookupCount,
        itemsAdded = 0,
        lookupsPerformed = 0,
        addTime = 0,
        lookupTime = 0,
        errors = {}
    }

    -- Phase 1: Add items to index
    local addStart = os.epoch("utc")

    for i = 1, itemCount do
        if not self.runningTests["index_stress"] or
                self.runningTests["index_stress"].status == "stopping" then
            results.aborted = true
            break
        end

        local itemName = string.format("test:stress_item_%d", i)
        local count = math.random(1, 64)

        -- Add to index (simulated)
        self.eventBus:publish("tests.index.add", {
            item = itemName,
            count = count,
            test = true
        })

        results.itemsAdded = results.itemsAdded + 1

        if i % 100 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "index_stress",
                progress = (i / itemCount) * 0.5,  -- First half of test
                message = string.format("Added %d/%d items", i, itemCount)
            })
        end
    end

    results.addTime = (os.epoch("utc") - addStart) / 1000

    -- Phase 2: Perform lookups
    local lookupStart = os.epoch("utc")
    local lookupHits = 0
    local lookupMisses = 0

    for i = 1, lookupCount do
        if not self.runningTests["index_stress"] or
                self.runningTests["index_stress"].status == "stopping" then
            results.aborted = true
            break
        end

        -- Random lookup
        local lookupId = math.random(1, itemCount + 100)  -- Some will miss
        local itemName = string.format("test:stress_item_%d", lookupId)

        self.eventBus:publish("tests.index.lookup", {
            item = itemName,
            test = true
        })

        if lookupId <= itemCount then
            lookupHits = lookupHits + 1
        else
            lookupMisses = lookupMisses + 1
        end

        results.lookupsPerformed = results.lookupsPerformed + 1

        if i % 50 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "index_stress",
                progress = 0.5 + (i / lookupCount) * 0.5,  -- Second half
                message = string.format("Performed %d/%d lookups", i, lookupCount)
            })
        end
    end

    results.lookupTime = (os.epoch("utc") - lookupStart) / 1000
    results.lookupHits = lookupHits
    results.lookupMisses = lookupMisses

    -- Calculate metrics
    results.addRate = results.itemsAdded / results.addTime
    results.lookupRate = results.lookupsPerformed / results.lookupTime
    results.hitRate = lookupHits / results.lookupsPerformed

    local success = not results.aborted and results.itemsAdded > 0

    return success, results
end

function TestsService:executeNetworkLoadTest(params)
    local messageCount = params.messageCount or 100
    local messageSize = params.messageSize or 100

    local results = {
        messageCount = messageCount,
        messageSize = messageSize,
        sent = 0,
        received = 0,
        errors = 0,
        latencies = {},
        throughput = 0
    }

    local startTime = os.epoch("utc")

    for i = 1, messageCount do
        if not self.runningTests["net_load"] or
                self.runningTests["net_load"].status == "stopping" then
            results.aborted = true
            break
        end

        local msgStart = os.epoch("utc")

        -- Create test message
        local message = {
            id = i,
            test = "net_load",
            data = string.rep("x", messageSize),
            timestamp = msgStart
        }

        -- Simulate network send
        self.eventBus:publish("tests.net.send", message)
        results.sent = results.sent + 1

        -- Simulate network latency
        os.sleep(0.05 + math.random() * 0.05)  -- 50-100ms

        -- Simulate response
        local msgEnd = os.epoch("utc")
        local latency = msgEnd - msgStart

        table.insert(results.latencies, latency)

        self.eventBus:publish("tests.net.receive", {
            id = i,
            latency = latency
        })
        results.received = results.received + 1

        if i % 20 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "net_load",
                progress = i / messageCount,
                message = string.format("Sent %d/%d messages", i, messageCount)
            })
        end
    end

    local totalTime = (os.epoch("utc") - startTime) / 1000

    -- Calculate statistics
    if #results.latencies > 0 then
        table.sort(results.latencies)
        results.minLatency = results.latencies[1]
        results.maxLatency = results.latencies[#results.latencies]

        local sum = 0
        for _, lat in ipairs(results.latencies) do
            sum = sum + lat
        end
        results.avgLatency = sum / #results.latencies

        -- P95 latency
        local p95Index = math.ceil(#results.latencies * 0.95)
        results.p95Latency = results.latencies[p95Index]
    end

    results.throughput = results.sent / totalTime
    results.totalTime = totalTime

    local success = not results.aborted and results.sent > 0

    return success, results
end

function TestsService:executeEventStormTest(params)
    local eventCount = params.eventCount or 1000
    local eventTypes = params.eventTypes or 10

    local results = {
        eventCount = eventCount,
        eventTypes = eventTypes,
        generated = 0,
        byType = {},
        rate = 0,
        peakRate = 0
    }

    local startTime = os.epoch("utc")
    local rateWindow = {}

    for i = 1, eventCount do
        if not self.runningTests["event_storm"] or
                self.runningTests["event_storm"].status == "stopping" then
            results.aborted = true
            break
        end

        local eventType = "test.storm.type" .. math.random(1, eventTypes)

        -- Track by type
        results.byType[eventType] = (results.byType[eventType] or 0) + 1

        -- Fire event
        self.eventBus:publish(eventType, {
            index = i,
            timestamp = os.epoch("utc"),
            data = math.random()
        })

        results.generated = results.generated + 1

        -- Track rate
        local now = os.epoch("utc")
        table.insert(rateWindow, now)

        -- Clean old entries (keep 1 second window)
        while #rateWindow > 0 and rateWindow[1] < now - 1000 do
            table.remove(rateWindow, 1)
        end

        local currentRate = #rateWindow
        if currentRate > results.peakRate then
            results.peakRate = currentRate
        end

        if i % 100 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "event_storm",
                progress = i / eventCount,
                message = string.format("Generated %d/%d events", i, eventCount)
            })
        end
    end

    local totalTime = (os.epoch("utc") - startTime) / 1000
    results.rate = results.generated / totalTime
    results.totalTime = totalTime

    local success = not results.aborted and results.generated > 0

    return success, results
end

function TestsService:executeMemoryTest(params)
    local iterations = params.iterations or 5
    local allocSize = params.allocSize or 100

    local results = {
        iterations = iterations,
        allocSize = allocSize,
        measurements = {},
        leak = false,
        leakAmount = 0
    }

    -- Initial garbage collection
    collectgarbage("collect")
    collectgarbage("collect")  -- Run twice to be thorough
    local initialMem = collectgarbage("count")

    results.initialMemory = initialMem

    for i = 1, iterations do
        if not self.runningTests["memory"] or
                self.runningTests["memory"].status == "stopping" then
            results.aborted = true
            break
        end

        -- Allocate memory
        local allocations = {}
        for j = 1, allocSize do
            allocations[j] = {}
            for k = 1, 100 do
                allocations[j][k] = string.rep("test", 100)
            end
        end

        local afterAlloc = collectgarbage("count")

        -- Clear allocations
        allocations = nil

        -- Force garbage collection
        collectgarbage("collect")
        local afterGC = collectgarbage("count")

        table.insert(results.measurements, {
            iteration = i,
            beforeAlloc = afterGC,
            afterAlloc = afterAlloc,
            afterGC = afterGC,
            allocated = afterAlloc - afterGC,
            freed = afterAlloc - afterGC
        })

        self.eventBus:publish("tests.progress", {
            test = "memory",
            progress = i / iterations,
            message = string.format("Memory test %d/%d", i, iterations)
        })

        os.sleep(1)  -- Let system stabilize
    end

    -- Final measurement
    collectgarbage("collect")
    collectgarbage("collect")
    local finalMem = collectgarbage("count")

    results.finalMemory = finalMem
    results.leakAmount = finalMem - initialMem

    -- Determine if there's a leak (threshold: 100KB)
    if results.leakAmount > 100 then
        results.leak = true
    end

    local success = not results.aborted and not results.leak

    return success, results
end

function TestsService:executePoolSaturationTest(params)
    local taskCount = params.taskCount or 100
    local pools = params.pools or {"io", "index", "ui", "net"}

    local results = {
        taskCount = taskCount,
        pools = pools,
        submitted = 0,
        completed = 0,
        errors = 0,
        poolMetrics = {}
    }

    local startTime = os.epoch("utc")
    local tasks = {}

    -- Submit tasks to each pool
    for _, poolName in ipairs(pools) do
        results.poolMetrics[poolName] = {
            submitted = 0,
            completed = 0,
            maxQueue = 0,
            avgQueueTime = 0
        }

        for i = 1, taskCount do
            if not self.runningTests["pool_saturation"] or
                    self.runningTests["pool_saturation"].status == "stopping" then
                results.aborted = true
                break
            end

            local task = self.scheduler:submit(poolName, function()
                -- Simulate work
                os.sleep(0.1 + math.random() * 0.1)

                -- Track completion
                results.poolMetrics[poolName].completed =
                results.poolMetrics[poolName].completed + 1
                results.completed = results.completed + 1
            end)

            table.insert(tasks, task)
            results.poolMetrics[poolName].submitted =
            results.poolMetrics[poolName].submitted + 1
            results.submitted = results.submitted + 1

            -- Check queue depth
            local pool = self.context.scheduler.pools[poolName]
            if pool and #pool.queue > results.poolMetrics[poolName].maxQueue then
                results.poolMetrics[poolName].maxQueue = #pool.queue
            end
        end
    end

    -- Wait for completion or timeout
    local timeout = 30  -- 30 seconds
    local waited = 0

    while results.completed < results.submitted and waited < timeout do
        os.sleep(1)
        waited = waited + 1

        self.eventBus:publish("tests.progress", {
            test = "pool_saturation",
            progress = results.completed / results.submitted,
            message = string.format("Completed %d/%d tasks",
                    results.completed, results.submitted)
        })
    end

    local totalTime = (os.epoch("utc") - startTime) / 1000
    results.totalTime = totalTime
    results.throughput = results.completed / totalTime

    local success = not results.aborted and
            results.completed == results.submitted

    return success, results
end

function TestsService:executeStorageCapacityTest(params)
    local testItems = params.testItems or 500

    local results = {
        testItems = testItems,
        stored = 0,
        retrieved = 0,
        errors = 0,
        capacityUsed = 0,
        capacityTotal = 0
    }

    -- Calculate total capacity
    for _, storage in ipairs(self.context.storageMap) do
        results.capacityTotal = results.capacityTotal + storage.size
    end

    -- Phase 1: Fill storage
    for i = 1, testItems do
        if not self.runningTests["storage_capacity"] or
                self.runningTests["storage_capacity"].status == "stopping" then
            results.aborted = true
            break
        end

        local itemName = string.format("test:capacity_item_%d", i)

        self.eventBus:publish("tests.storage.store", {
            item = itemName,
            count = math.random(1, 64)
        })

        results.stored = results.stored + 1

        if i % 50 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "storage_capacity",
                progress = (i / testItems) * 0.5,
                message = string.format("Stored %d/%d items", i, testItems)
            })
        end
    end

    -- Check capacity usage
    local usedSlots = 0
    for _, storage in ipairs(self.context.storageMap) do
        local inv = peripheral.wrap(storage.name)
        if inv then
            local items = inv.list()
            for _ in pairs(items) do
                usedSlots = usedSlots + 1
            end
        end
    end

    results.capacityUsed = usedSlots
    results.utilizationPercent = (usedSlots / results.capacityTotal) * 100

    -- Phase 2: Retrieve items
    for i = 1, math.min(100, testItems) do  -- Test retrieval of first 100
        if not self.runningTests["storage_capacity"] or
                self.runningTests["storage_capacity"].status == "stopping" then
            results.aborted = true
            break
        end

        local itemName = string.format("test:capacity_item_%d", i)

        self.eventBus:publish("tests.storage.retrieve", {
            item = itemName
        })

        results.retrieved = results.retrieved + 1

        if i % 20 == 0 then
            self.eventBus:publish("tests.progress", {
                test = "storage_capacity",
                progress = 0.5 + (i / 100) * 0.5,
                message = string.format("Retrieved %d items", i)
            })
        end
    end

    local success = not results.aborted and results.stored > 0

    return success, results
end

function TestsService:executePeripheralReliabilityTest(params)
    local checkCount = params.checkCount or 20
    local checkInterval = params.checkInterval or 1

    local results = {
        checkCount = checkCount,
        checks = {},
        failures = {},
        reliability = 100
    }

    local expectedPeripherals = {}

    -- Initial scan
    for _, storage in ipairs(self.context.storageMap) do
        expectedPeripherals[storage.name] = true
    end
    expectedPeripherals[self.context.bufferInventory.name] = true

    for i = 1, checkCount do
        if not self.runningTests["peripheral_reliability"] or
                self.runningTests["peripheral_reliability"].status == "stopping" then
            results.aborted = true
            break
        end

        local checkResult = {
            iteration = i,
            timestamp = os.epoch("utc"),
            present = 0,
            missing = 0,
            missingNames = {}
        }

        -- Check each peripheral
        for name, _ in pairs(expectedPeripherals) do
            if peripheral.isPresent(name) then
                checkResult.present = checkResult.present + 1
            else
                checkResult.missing = checkResult.missing + 1
                table.insert(checkResult.missingNames, name)

                -- Track failures
                if not results.failures[name] then
                    results.failures[name] = 0
                end
                results.failures[name] = results.failures[name] + 1
            end
        end

        table.insert(results.checks, checkResult)

        self.eventBus:publish("tests.progress", {
            test = "peripheral_reliability",
            progress = i / checkCount,
            message = string.format("Check %d/%d: %d present, %d missing",
                    i, checkCount, checkResult.present, checkResult.missing)
        })

        os.sleep(checkInterval)
    end

    -- Calculate reliability
    local totalChecks = checkCount * #expectedPeripherals
    local totalFailures = 0

    for _, count in pairs(results.failures) do
        totalFailures = totalFailures + count
    end

    results.reliability = 100 * (1 - totalFailures / totalChecks)

    local success = not results.aborted and results.reliability >= 95

    return success, results
end

-- ============================================================================
-- TEST MANAGEMENT
-- ============================================================================

function TestsService:completeTest(testName, success, result)
    local testConfig = self.tests[testName]
    local runInfo = self.runningTests[testName]

    if not runInfo then
        return
    end

    -- Calculate duration
    local duration = (os.epoch("utc") - runInfo.startTime) / 1000

    -- Store results
    self.testResults[testName] = {
        success = success,
        result = result,
        duration = duration,
        timestamp = os.epoch("utc"),
        params = runInfo.params
    }

    -- Update metrics
    if success then
        self.metrics.passed = self.metrics.passed + 1
    else
        self.metrics.failed = self.metrics.failed + 1
    end

    -- Clear running state
    self.runningTests[testName] = nil

    -- Save artifacts
    self:saveTestArtifact(testName, result)

    -- Publish completion event
    self.eventBus:publish("tests.completed", {
        test = testName,
        success = success,
        duration = duration,
        result = result
    })

    self.logger:info("TestsService", string.format(
            "Test '%s' completed: %s (%.2fs)",
            testConfig.name,
            success and "PASSED" or "FAILED",
            duration
    ))
end

function TestsService:stopTest(testName)
    local runInfo = self.runningTests[testName]
    if runInfo then
        runInfo.status = "stopping"
        self.metrics.aborted = self.metrics.aborted + 1

        self.eventBus:publish("tests.stopped", {
            test = testName
        })

        self.logger:info("TestsService", "Stopping test: " .. testName)
    end
end

function TestsService:stopAllTests()
    for testName, _ in pairs(self.runningTests) do
        self:stopTest(testName)
    end
end

function TestsService:getTestResults(testName)
    if testName then
        return self.testResults[testName]
    else
        return self.testResults
    end
end

function TestsService:saveTestArtifact(testName, result)
    local filename = string.format("/logs/test-%s-%s.log",
            testName, os.date("%Y%m%d-%H%M%S"))

    local file = fs.open(filename, "w")
    if file then
        local ok, json = pcall(textutils.serialiseJSON, {
            test = testName,
            timestamp = os.epoch("utc"),
            result = result
        })

        if ok then
            file.write(json)
            self.testArtifacts[testName] = filename
        else
            file.write(string.format("[ERROR] Failed to serialize test result for %s: %s", testName, tostring(json)))
        end
        file.close()
    end
end

function TestsService:loadTestResults()
    local resultsFile = "/data/test_results.json"

    if fs.exists(resultsFile) then
        local file = fs.open(resultsFile, "r")
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialiseJSON, content)
        if ok and data then
            self.testResults = data.results or {}
            self.metrics = data.metrics or self.metrics
        end
    end
end

function TestsService:saveTestResults()
    local resultsFile = "/data/test_results.json"

    local data = {
        results = self.testResults,
        metrics = self.metrics,
        timestamp = os.epoch("utc")
    }

    local file = fs.open(resultsFile, "w")
    if file then
        local ok, json = pcall(textutils.serialiseJSON, data)

        if ok then
            file.write(json)
        else
            file.write(string.format("[ERROR] Failed to serialize test results: %s", tostring(json)))
        end
        file.close()
    end
end

function TestsService:getTestList()
    local list = {}
    for id, config in pairs(self.tests) do
        if config.enabled then
            table.insert(list, {
                id = id,
                name = config.name,
                description = config.description,
                duration = config.duration,
                running = self.runningTests[id] ~= nil,
                lastResult = self.testResults[id] and
                        self.testResults[id].success
            })
        end
    end
    return list
end

return TestsService