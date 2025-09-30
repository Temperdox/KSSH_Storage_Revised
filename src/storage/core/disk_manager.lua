-- /storage/core/disk_manager.lua
-- Manages network-connected disk drives for data, config, and log storage

local DiskManager = {}
DiskManager.__index = DiskManager

function DiskManager:new(eventBus)
    local o = setmetatable({}, self)
    o.eventBus = eventBus
    o.disks = {}
    o.currentDisk = nil
    o.minFreeSpace = 100000  -- Minimum free space before switching disks (in bytes)
    o.basePaths = {
        data = "/data",
        config = "/cfg",
        logs = "/logs"
    }

    return o
end

-- Scan for disk drives on the wired network
function DiskManager:scanForDisks()
    self.disks = {}

    -- Check all peripheral names on the network
    local peripheralNames = peripheral.getNames()

    for _, name in ipairs(peripheralNames) do
        if peripheral.getType(name) == "drive" then
            -- Check if drive has a disk mounted
            local mountPath = disk.getMountPath(name)
            if mountPath then
                local freeSpace = fs.getFreeSpace(mountPath)
                table.insert(self.disks, {
                    name = name,
                    mountPath = mountPath,
                    freeSpace = freeSpace,
                    totalSpace = freeSpace + self:getUsedSpace(mountPath)
                })
            end
        end
    end

    -- Sort disks by free space (most free first)
    table.sort(self.disks, function(a, b)
        return a.freeSpace > b.freeSpace
    end)

    -- Select the disk with the most free space
    if #self.disks > 0 then
        self.currentDisk = self.disks[1]
        self:ensureDirectories()
    end

    return #self.disks
end

-- Calculate used space on a disk
function DiskManager:getUsedSpace(mountPath)
    local used = 0
    local function calculateSize(path)
        if fs.isDir(path) then
            for _, file in ipairs(fs.list(path)) do
                calculateSize(fs.combine(path, file))
            end
        else
            used = used + fs.getSize(path)
        end
    end

    if fs.exists(mountPath) then
        calculateSize(mountPath)
    end

    return used
end

-- Ensure all required directories exist on current disk
function DiskManager:ensureDirectories()
    if not self.currentDisk then return false end

    for _, subPath in pairs(self.basePaths) do
        local fullPath = fs.combine(self.currentDisk.mountPath, subPath)
        if not fs.exists(fullPath) then
            fs.makeDir(fullPath)
        end
    end

    return true
end

-- Get the full path for a file on the current disk
function DiskManager:getPath(category, filename)
    if not self.currentDisk then
        return nil
    end

    local basePath = self.basePaths[category]
    if not basePath then
        error("Invalid category: " .. tostring(category))
    end

    return fs.combine(self.currentDisk.mountPath, basePath, filename)
end

-- Check if current disk is running low on space
function DiskManager:checkDiskSpace()
    if not self.currentDisk then return false end

    -- Update free space
    self.currentDisk.freeSpace = fs.getFreeSpace(self.currentDisk.mountPath)

    -- If running low on space, try to switch to another disk
    if self.currentDisk.freeSpace < self.minFreeSpace then
        return self:switchToNextDisk()
    end

    return true
end

-- Switch to the next available disk with enough space
function DiskManager:switchToNextDisk()
    if #self.disks < 2 then
        -- Only one disk available, can't switch
        if self.eventBus then
            self.eventBus:publish("disk.full", {
                disk = self.currentDisk.name,
                mountPath = self.currentDisk.mountPath
            })
        end
        return false
    end

    -- Find next disk with sufficient space
    for _, disk in ipairs(self.disks) do
        if disk.name ~= self.currentDisk.name then
            disk.freeSpace = fs.getFreeSpace(disk.mountPath)
            if disk.freeSpace >= self.minFreeSpace then
                local oldDisk = self.currentDisk
                self.currentDisk = disk
                self:ensureDirectories()

                if self.eventBus then
                    self.eventBus:publish("disk.switched", {
                        from = oldDisk.name,
                        to = disk.name,
                        reason = "low_space"
                    })
                end

                return true
            end
        end
    end

    -- No disks with sufficient space
    if self.eventBus then
        self.eventBus:publish("disk.all_full", {
            disks = self.disks
        })
    end

    return false
end

-- Write a file, with automatic disk switching if needed
function DiskManager:writeFile(category, filename, data)
    if not self.currentDisk then
        return false, "No disk available"
    end

    -- Check disk space before writing
    self:checkDiskSpace()

    local path = self:getPath(category, filename)
    if not path then
        return false, "Failed to get path"
    end

    local file = fs.open(path, "w")
    if not file then
        return false, "Failed to open file"
    end

    file.write(data)
    file.close()

    return true, path
end

-- Append to a file, with automatic disk switching if needed
function DiskManager:appendFile(category, filename, line)
    if not self.currentDisk then
        return false, "No disk available"
    end

    -- Check disk space before writing
    self:checkDiskSpace()

    local path = self:getPath(category, filename)
    if not path then
        return false, "Failed to get path"
    end

    local file = fs.open(path, "a")
    if not file then
        return false, "Failed to open file"
    end

    file.writeLine(line)
    file.close()

    return true, path
end

-- Read a file from any available disk (searches all disks)
function DiskManager:readFile(category, filename)
    -- Try current disk first
    if self.currentDisk then
        local path = self:getPath(category, filename)
        if path and fs.exists(path) then
            local file = fs.open(path, "r")
            if file then
                local content = file.readAll()
                file.close()
                return content, path
            end
        end
    end

    -- Search other disks
    for _, disk in ipairs(self.disks) do
        if disk.name ~= (self.currentDisk and self.currentDisk.name or nil) then
            local basePath = self.basePaths[category]
            local path = fs.combine(disk.mountPath, basePath, filename)
            if fs.exists(path) then
                local file = fs.open(path, "r")
                if file then
                    local content = file.readAll()
                    file.close()
                    return content, path
                end
            end
        end
    end

    return nil, nil
end

-- Get disk status information
function DiskManager:getStatus()
    local status = {
        diskCount = #self.disks,
        currentDisk = self.currentDisk and {
            name = self.currentDisk.name,
            mountPath = self.currentDisk.mountPath,
            freeSpace = self.currentDisk.freeSpace,
            totalSpace = self.currentDisk.totalSpace,
            usedPercent = math.floor((1 - self.currentDisk.freeSpace / self.currentDisk.totalSpace) * 100)
        } or nil,
        allDisks = {}
    }

    for _, disk in ipairs(self.disks) do
        table.insert(status.allDisks, {
            name = disk.name,
            mountPath = disk.mountPath,
            freeSpace = disk.freeSpace,
            totalSpace = disk.totalSpace,
            usedPercent = math.floor((1 - disk.freeSpace / disk.totalSpace) * 100)
        })
    end

    return status
end

return DiskManager