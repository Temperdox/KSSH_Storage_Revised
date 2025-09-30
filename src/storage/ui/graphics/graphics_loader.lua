-- Graphics Loader Module
local GraphicsLoader = {}

function GraphicsLoader.decodegraphic(imagePath)
    -- Try to require the module
    local success, graphicModule = pcall(require, imagePath)
    if not success then
        return nil
    end

    -- Check if it's already the expected format
    if type(graphicModule) == "table" then
        -- Handle embedded format from logo.lua
        for k, v in pairs(graphicModule) do
            if type(v) == "table" and v.width and v.image then
                return {
                    width = v.width,
                    image = v.image,
                }
            end
        end
    end

    return nil
end

function GraphicsLoader.drawgraphic(screen, imagePath, x, y, fg, bg)
    local img = GraphicsLoader.decodegraphic(imagePath)
    if not img then return false end

    screen.setCursorPos(x, y)
    for i = 1, #img.image do
        local ch, fgc, bgc = 0x80, fg, bg

        -- Decode the first 5 bits
        for i2 = 1, 5 do
            local c = img.image[i]:sub(i2, i2)
            if c == "1" then
                ch = ch + 2^(i2-1)
            end
        end

        -- Bit 6 inverts the character and swaps colors
        if img.image[i]:sub(6, 6) == "1" then
            ch = bit32.band(bit32.bnot(ch), 0x1F) + 0x80
            fgc, bgc = bgc, fgc
        end

        screen.setTextColor(fgc)
        screen.setBackgroundColor(bgc)
        screen.write(string.char(ch))

        -- Move to next line when reaching width
        if math.fmod(i - 1, img.width) == 0 and i > 1 then
            y = y + 1
            screen.setCursorPos(x, y)
        end
    end

    return true
end

function GraphicsLoader.getGraphicDimensions(imagePath)
    local img = GraphicsLoader.decodegraphic(imagePath)
    if not img then return nil, nil end
    local height = math.floor(#img.image / img.width)
    return img.width, height
end

return GraphicsLoader