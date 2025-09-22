--- Audio file paths for the audio demo.

local record sounds
    drum: string
    keyboard: string
    bassline: string
    pad: string
end

function sounds.load(): sounds
    return {
        drum     = "sounds/drums.ogg",
        keyboard = "sounds/keyboard.ogg",
        bassline = "sounds/bass.ogg",
        pad      = "sounds/pad.ogg",
    }
end

return sounds
