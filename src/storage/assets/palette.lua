local Palette = {}

-- Pool colors for visualizer
Palette.pools = {
    IO = colors.cyan,
    INDEX = colors.yellow,
    UI = colors.magenta,
    NET = colors.blue,
    API = colors.orange,
    STATS = colors.green,
    TESTS = colors.pink,
    SOUND = colors.purple
}

-- Event type colors for visualizer
Palette.events = {
    -- Storage events
    ["storage.move"] = colors.cyan,
    ["storage.input"] = colors.lime,
    ["storage.output"] = colors.orange,
    ["storage.error"] = colors.red,

    -- Index events
    ["index.update"] = colors.yellow,
    ["index.rebuild"] = colors.gold,

    -- UI events
    ["ui.draw"] = colors.magenta,
    ["ui.interact"] = colors.pink,

    -- Network events
    ["net.request"] = colors.blue,
    ["net.response"] = colors.lightBlue,

    -- Task events
    ["task.start"] = colors.white,
    ["task.end"] = colors.white,
    ["task.error"] = colors.red,

    -- System events
    ["system.tick"] = colors.gray,
    ["system.alert"] = colors.yellow,

    -- Test events
    ["test.run"] = colors.pink,
    ["test.pass"] = colors.green,
    ["test.fail"] = colors.red
}

-- Log level colors
Palette.logLevels = {
    trace = colors.gray,
    debug = colors.lightGray,
    info = colors.white,
    warn = colors.yellow,
    error = colors.red
}

-- UI element colors by theme
Palette.themes = {
    dark = {
        background = colors.black,
        foreground = colors.white,
        border = colors.gray,
        header = colors.gray,
        selected = colors.blue,
        highlight = colors.yellow,
        success = colors.green,
        error = colors.red,
        warning = colors.yellow,
        info = colors.cyan,
        muted = colors.lightGray
    },
    light = {
        background = colors.white,
        foreground = colors.black,
        border = colors.lightGray,
        header = colors.lightBlue,
        selected = colors.blue,
        highlight = colors.orange,
        success = colors.green,
        error = colors.red,
        warning = colors.orange,
        info = colors.blue,
        muted = colors.gray
    },
    high_contrast = {
        background = colors.black,
        foreground = colors.white,
        border = colors.white,
        header = colors.yellow,
        selected = colors.cyan,
        highlight = colors.lime,
        success = colors.lime,
        error = colors.red,
        warning = colors.yellow,
        info = colors.cyan,
        muted = colors.lightGray
    }
}

return Palette