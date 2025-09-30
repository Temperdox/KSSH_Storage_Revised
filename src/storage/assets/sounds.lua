local Sounds = {
    -- Storage sounds
    storage = {
        input = "block.chest.open",
        output = "block.chest.close",
        move = "entity.item.pickup",
        error = "block.note_block.bass"
    },

    -- Task sounds
    task = {
        start = "block.note_block.harp",
        complete = "block.note_block.bell",
        error = "block.note_block.didgeridoo"
    },

    -- System sounds
    system = {
        startup = "block.note_block.chime",
        shutdown = "block.note_block.bass",
        alert = "block.note_block.pling",
        success = "entity.player.levelup",
        failure = "entity.villager.no"
    },

    -- UI sounds
    ui = {
        click = "ui.button.click",
        select = "block.lever.click",
        scroll = "block.comparator.click",
        type = "block.dispenser.dispense"
    },

    -- Network sounds
    network = {
        send = "block.note_block.bit",
        receive = "block.note_block.bit",
        error = "block.note_block.bass"
    },

    -- Test sounds
    test = {
        start = "block.anvil.use",
        pass = "entity.player.levelup",
        fail = "entity.villager.no",
        step = "block.note_block.hat"
    }
}

return Sounds
