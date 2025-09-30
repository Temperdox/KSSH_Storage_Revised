local fsx = {}

function fsx.ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

function fsx.readJson(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local content = file.readAll()
    file.close()

    local ok, data = pcall(textutils.unserialiseJSON, content)
    if not ok then
        return nil
    end

    return data
end

function fsx.writeJson(path, data)
    local ok, content = pcall(textutils.serialiseJSON, data)

    if not ok then
        error(string.format("[fsx.writeJson] Failed to serialize data for '%s': %s", path, tostring(content)))
        return false
    end

    -- Atomic write
    local tmpPath = path .. ".tmp"
    local file = fs.open(tmpPath, "w")
    if not file then
        error(string.format("[fsx.writeJson] Failed to open file '%s' for writing", tmpPath))
        return false
    end

    file.write(content)
    file.close()

    if fs.exists(path) then
        fs.delete(path)
    end
    fs.move(tmpPath, path)

    return true
end

function fsx.readLines(path, maxLines)
    if not fs.exists(path) then
        return {}
    end

    local lines = {}
    local file = fs.open(path, "r")
    if not file then
        return lines
    end

    local count = 0
    while true do
        local line = file.readLine()
        if not line then break end
        table.insert(lines, line)
        count = count + 1
        if maxLines and count >= maxLines then break end
    end

    file.close()
    return lines
end

function fsx.appendLine(path, line)
    local file = fs.open(path, "a")
    if not file then
        return false
    end

    file.writeLine(line)
    file.close()
    return true
end

return fsx